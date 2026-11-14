// Full-picture MetalFX interpolation with a serial worker and bounded queues.
// Capture and final drawing use the backend's Metal 4 presentation hooks.
// Quality follows the valid picture size automatically.
enum { FG_SLOTS = 3, FG_JOBS = 4, FG_NATIVE = 0, FG_ACTIVE = 1, FG_LEAVING = 2 };
static _Atomic int g_fg_requested = -1, g_fg_reset, g_fg_phase;
static _Atomic uint64_t g_fg_displayed, g_fg_gen, g_fg_source_seq;
static dispatch_queue_t g_fg_wq;
static MTLSharedEventListener *g_fg_listener;
__attribute__((weak)) void front_framegen_rate(int fps) { (void)fps; }
__attribute__((weak)) uint64_t front_framegen_rate_ticks(void) { return 0; }
static void fg_pump(void);
static void fg_leave_check(void);
static void fg_leave(const char *reason, int failed);

@interface FgSlot : NSObject { @public
    id<MTLTexture> texture;
    id<MTL4CommandAllocator> allocator;
    id<MTL4CommandBuffer> buffer;
    id<MTL4ArgumentTable> arguments;
    id<MTLBuffer> uv;
    _Atomic int busy, failed;
}
@end
@implementation FgSlot
- (void)dealloc { res_remove(texture); res_remove(uv); res_commit(); }
@end
@interface FgSession : NSObject { @public
    NSUInteger w, h;
    int hi;
    id<MTLFXFrameInterpolator> fi;
    id<MTLTexture> hist[2], gen[FG_SLOTS], depth, motion;
    FgSlot *slots[FG_SLOTS];
    id<MTLCommandQueue> queue;
    id<MTL4CommandQueue> present_queue;
    id<MTLSharedEvent> capture_event;
    CAMetalLayer *layer;
    int output_busy[FG_SLOTS], in_flight, pending;
    uint64_t epoch, presentation_epoch;
}
@end
@implementation FgSession
- (void)dealloc {
    for (int i = 0; i < 2; i++) res_remove(hist[i]);
    for (int i = 0; i < FG_SLOTS; i++) res_remove(gen[i]);
    res_remove(depth); res_remove(motion); res_commit();
}
@end
@interface FgJob : NSObject { @public
    FgSession *session;
    FgSlot *slot;
    uint64_t sequence, ticket;
    int ready, discarded, generated, paired;
    double period;
    const char *reason;
}
@end
@implementation FgJob
@end
@interface FgPresent : NSObject { @public
    _Atomic int called;
    int original; _Atomic int gpu_done;
    uint64_t ticket, hgen;
    double submitted;
    FgSession *session;
    __weak id<MTL4CommandBuffer> buffer;
}
@end
@implementation FgPresent
@end
static FgSession *g_fg_session; // published / withdrawn under g_pq_mu
static FgJob *g_fg_jobs[FG_JOBS]; // all subsequent state belongs to g_fg_wq
static struct {
    double last, intervals[8], fps, target, stable_since, previous_time, leave_time, report_time;
    int samples, have_last, tier, tier_samples, maximum, mode, stable, primed, warm;
    int head, count, generated_jobs, requested, failed, recovering, recoveries, skipped, onscreen, seed_skipped;
    uint64_t previous_sequence, encoded_sequence, sources, generated, originals, shed, dropped,
        gaps, unprimed, warm_hidden, resets, no_drawable, shown, never_shown, last_ticks;
    double gpu_ms[300]; int gpu_n;
} F;
static void fg_queue_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_fg_wq = dispatch_queue_create("dm.nvn.framegen", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        g_fg_listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:g_fg_wq];
    });
}
int mtl_framegen_supported(void) {
    static int supported; static dispatch_once_t once;
    dispatch_once(&once, ^{ if (@available(macOS 26.0, iOS 26.0, *)) {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); supported = dev && [MTLFXFrameInterpolatorDescriptor supportsDevice:dev];
    }}); return supported;
}
int mtl_framegen_enabled(void) {
    int v = atomic_load(&g_fg_requested);
    if (v < 0) { const char *s = getenv("DM_FRAMEGEN"); int initial = s && atoi(s) != 0; atomic_compare_exchange_strong(&g_fg_requested, &v, initial); v = atomic_load(&g_fg_requested); }
    return v && mtl_framegen_supported();
}
int mtl_framegen_set(int on) {
    if (on && !mtl_framegen_supported()) return 0;
    int was = atomic_exchange(&g_fg_requested, on != 0);
    fg_queue_init(); dispatch_async(g_fg_wq, ^{ F.failed = 0; if (!on && was > 0) fg_leave("setting_off", 0); }); return 1;
}
void mtl_framegen_reset(void) { atomic_store(&g_fg_reset, 1); }
uint64_t mtl_framegen_present_count(void) { return atomic_load(&g_fg_displayed); }
static NSUInteger fg_limit(NSUInteger w, NSUInteger h) { return MIN(w, h) >= 1080 ? 1080 : 720; }
static void fg_extent(NSUInteger w, NSUInteger h, NSUInteger *ow, NSUInteger *oh) {
    if (!w || !h) { *ow = *oh = 0; return; }
    double edge = fg_limit(w, h);
    double scale = fmin(1., fmin(edge / fmin(w, h), sqrt(edge * edge * 16. / 9. / ((double)w * h))));
    *ow = MAX(2u, (NSUInteger)(w * scale) & ~(NSUInteger)1);
    *oh = MAX(2u, (NSUInteger)(h * scale) & ~(NSUInteger)1);
}
static void fg_rate(int fps) { if (F.requested != fps) { F.requested = fps; front_framegen_rate(fps); } }
static void fg_observe(double now, int screen_hz) {
    if (isfinite(now)) {
        if (F.have_last) {
            double dt = now - F.last; F.last = now;
            if (isfinite(dt) && dt > 0) {
                if (F.samples == 8) { memmove(F.intervals, F.intervals + 1, 7 * sizeof(double)); F.samples--; }
                F.intervals[F.samples++] = fmin(1. / 15, fmax(1. / 120, dt));
                if (F.samples >= 4 && !(F.samples & 1)) {
                    double sorted[8]; memcpy(sorted, F.intervals, F.samples * sizeof(double));
                    for (int i = 1; i < F.samples; i++) { double v = sorted[i]; int j = i; while (j && sorted[j - 1] > v) { sorted[j] = sorted[j - 1]; j--; } sorted[j] = v; }
                    int cut = F.samples / 4; double sum = 0; for (int i = cut; i < F.samples - cut; i++) sum += sorted[i];
                    F.fps = (F.samples - 2 * cut) / sum;
                }
            } else F.samples = 0;
        } else { F.have_last = 1; F.last = now; }
    }
    F.maximum = screen_hz + 6 >= 120 ? 2 : screen_hz + 3 >= 60 ? 1 : 0;
    if (F.tier > F.maximum) F.tier = F.maximum;
    int next = F.tier;
    if (next < F.maximum && F.fps >= (next + 1) * 35.) next++;
    else if (next && F.fps < next * 35.) next--;
    if (next == F.tier) F.tier_samples = 0;
    else if (++F.tier_samples >= (next > F.tier ? 3 : 8)) { F.tier = next; F.tier_samples = 0; }
    F.target = F.maximum ? MIN(F.tier + 1, F.maximum) * 60. : 60.;
    F.mode = F.samples < 8 || !(F.fps > 0) ? 0 : F.fps >= F.target - fmax(1., F.target * .05) ? 1 : F.tier >= F.maximum ? 2 : 3;
}
static id<MTLTexture> fg_mfx_tex(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage, NSString *label) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; t.label = label; if (t) res_add(t); return t;
}
static id<MTL4ArgumentTable> fg_arguments(void) {
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new]; d.maxTextureBindCount = d.maxBufferBindCount = d.maxSamplerStateBindCount = 4;
    return [g_dev newArgumentTableWithDescriptor:d error:nil];
}
static void fg_slot_release(FgJob *job) {
    FgSlot *slot = job->slot; id<MTLSharedEvent> event = job->session->capture_event;
    if (event.signaledValue >= job->sequence) atomic_store(&slot->busy, 0);
    else [event notifyListener:g_fg_listener atValue:job->sequence block:^(id<MTLSharedEvent> e, uint64_t value) { (void)e; (void)value; atomic_store(&slot->busy, 0); fg_leave_check(); }];
}
static void fg_jobs_clear(void) {
    while (F.count) {
        FgJob *job = g_fg_jobs[F.head]; g_fg_jobs[F.head] = nil; F.head = (F.head + 1) % FG_JOBS; F.count--;
        if (job->generated) job->session->output_busy[job->generated - 1] = 0;
        g_pres[job->ticket % PRING] = (pres_ent){job->ticket, -1}; fg_slot_release(job); F.dropped++;
    }
    F.generated_jobs = 0;
}
static void fg_leave_check(void) {
    if (atomic_load(&g_fg_phase) != FG_LEAVING) return;
    FgSession *s = g_fg_session; int busy = 0;
    if (s) for (int i = 0; i < FG_SLOTS; i++) busy += atomic_load(&s->slots[i]->busy);
    if (s && (busy || s->in_flight) && CACurrentMediaTime() - F.leave_time <= 2.) return;
    if (s && (busy || s->in_flight)) MLOG("[fg] leaving: %d command buffers and %d slots still busy after 2 s; native present takes over", s->in_flight, busy);
    pthread_mutex_lock(&g_pq_mu); g_fg_session = nil; atomic_store(&g_fg_phase, FG_NATIVE); pthread_mutex_unlock(&g_pq_mu);
    fg_rate(0); MLOG("[fg] native present again");
}
static void fg_leave(const char *reason, int failed) {
    if (failed) F.failed = 1;
    F.have_last = F.samples = F.tier = F.tier_samples = F.stable = F.primed = F.warm = 0;
    if (atomic_load(&g_fg_phase) != FG_ACTIVE) return;
    atomic_store(&g_fg_phase, FG_LEAVING); atomic_fetch_add(&g_fg_gen, 1); F.leave_time = CACurrentMediaTime();
    fg_jobs_clear(); MLOG("[fg] leaving frame generation: %s", reason); fg_leave_check();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), g_fg_wq, ^{ fg_leave_check(); });
}
static void fg_session_start(NSUInteger w, NSUInteger h, MTLPixelFormat format, double now, int screen_hz) {
    if (!mtl_framegen_enabled() || F.failed || atomic_load(&g_fg_phase) != FG_NATIVE) return;
    fg_observe(now, screen_hz);
    if (!isfinite(now) || F.mode != 3) { F.stable = 0; return; }
    if (!F.stable) { F.stable = 1; F.stable_since = now; return; }
    if (++F.stable < 8 || now - F.stable_since < .5) return;
    FgSession *s = [FgSession new]; s->w = w; s->h = h;
    s->queue = [g_dev newCommandQueue];
    // A second descriptor sharing g_feedback_q over-releases that dispatch
    // queue on descriptor destruction (SIGTRAP in dispatch_release). Let Metal
    // own this queue's feedback executor; handlers still marshal to g_fg_wq.
    s->present_queue = [g_dev newMTL4CommandQueue];
    s->capture_event = [g_dev newSharedEvent];
    if (!s->queue || !s->present_queue || !s->capture_event) { F.failed = 1; MLOG("[RED] [fg] cannot start (queues)"); return; }
    [s->present_queue addResidencySet:g_res];
    MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
    d.inputWidth = d.outputWidth = w; d.inputHeight = d.outputHeight = h;
    d.colorTextureFormat = d.outputTextureFormat = format; d.depthTextureFormat = MTLPixelFormatR32Float; d.motionTextureFormat = MTLPixelFormatRG16Float;
    s->fi = [d newFrameInterpolatorWithDevice:g_dev];
    if (!s->fi) { F.failed = 1; MLOG("[RED] [fg] MetalFX makes no frame interpolator for %lux%lu", (unsigned long)w, (unsigned long)h); return; }
    int ok = 1;
    for (int i = 0; i < 2; i++) { s->hist[i] = fg_mfx_tex(format, w, h, s->fi.colorTextureUsage | MTLTextureUsageShaderRead, @"framegen previous frame"); ok &= s->hist[i] != nil; }
    for (int i = 0; i < FG_SLOTS; i++) {
        s->gen[i] = fg_mfx_tex(format, w, h, s->fi.outputTextureUsage | MTLTextureUsageShaderRead, @"framegen MetalFX frame");
        FgSlot *slot = [FgSlot new]; s->slots[i] = slot;
        slot->texture = fg_mfx_tex(format, w, h, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget, @"framegen capture");
        slot->allocator = [g_dev newCommandAllocator]; slot->buffer = [g_dev newCommandBuffer]; slot->arguments = fg_arguments();
        slot->uv = [g_dev newBufferWithLength:NX_GFX_PRESENT_FLOATS * sizeof(float) options:MTLResourceStorageModeShared]; if (slot->uv) res_add(slot->uv);
        ok &= s->gen[i] && slot->texture && slot->allocator && slot->buffer && slot->arguments && slot->uv;
    }
    s->depth = fg_mfx_tex(d.depthTextureFormat, w, h, s->fi.depthTextureUsage | MTLTextureUsageRenderTarget, @"framegen constant depth");
    s->motion = fg_mfx_tex(d.motionTextureFormat, w, h, s->fi.motionTextureUsage | MTLTextureUsageRenderTarget, @"framegen zero motion");
    if (!ok || !s->depth || !s->motion) { F.failed = 1; MLOG("[RED] [fg] cannot start (textures)"); return; }
    id<MTLCommandBuffer> cb = [s->queue commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = s->depth; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 0);
    rp.colorAttachments[1].texture = s->motion; rp.colorAttachments[1].loadAction = MTLLoadActionClear; rp.colorAttachments[1].storeAction = MTLStoreActionStore; rp.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; res_commit();
    F.primed = F.warm = F.recovering = F.recoveries = F.skipped = 0; F.previous_sequence = F.encoded_sequence = 0;
    s->epoch = atomic_fetch_add(&g_fg_gen, 1) + 1; F.report_time = CACurrentMediaTime(); F.last_ticks = front_framegen_rate_ticks();
    pthread_mutex_lock(&g_pq_mu); g_fg_session = s; atomic_store(&g_fg_phase, FG_ACTIVE); pthread_mutex_unlock(&g_pq_mu);
    MLOG("[fg] session %lux%lu started: constant depth 1, zero motion; 3 capture slots, 2 previous frames, 3 outputs; reference 8 samples / 0.5 s startup", (unsigned long)w, (unsigned long)h);
}
static int fg_free_for(FgSession *s, int images) {
    CAMetalLayer *layer = (__bridge CAMetalLayer *)front_metal_layer();
    if (!layer) return 1;
    return s->pending + F.onscreen + images - 1 < MAX(1, layer.maximumDrawableCount);
}
static void fg_on_presented(FgPresent *p, double time) {
    if (atomic_exchange(&p->called, 1)) return;
    FgSession *s = p->session;
    if (p->original && p->ticket) g_pres[p->ticket % PRING] = (pres_ent){p->ticket, time > 0 ? time : -1};
    if (s->epoch != atomic_load(&g_fg_gen)) return;
    if (p->hgen == s->presentation_epoch && s->pending) s->pending--;
    if (atomic_load(&g_fg_phase) == FG_ACTIVE) dispatch_async(g_fg_wq, ^{ fg_pump(); });
    if (isfinite(time) && time > 0) {
        F.shown++;
        if (!p->original) {
            if (!atomic_fetch_add(&g_fg_displayed, 1)) MLOG("frame generation: first interpolated image confirmed on screen");
        } else if (p->hgen == s->presentation_epoch) F.onscreen = 1, F.seed_skipped = F.skipped = F.recoveries = 0;
        return;
    }
    F.never_shown++;
    if (p->hgen != s->presentation_epoch) return;
    const char *reason = isfinite(time) ? "drawable_present_skipped" : "drawable_presented_time_nonfinite";
    if (atomic_load(&p->gpu_done)) {
        if (isfinite(time) && p->original && !F.onscreen && F.seed_skipped < 3) {
            F.seed_skipped++; MLOG("[fg] original skipped while priming (%s)", reason); return;
        }
        if (isfinite(time) && F.onscreen) {
            if (F.skipped < 3) { F.skipped++; MLOG("[fg] skipped presented callback (%s)", reason); return; }
        } else { fg_leave(reason, 1); return; }
    }
    if (F.recoveries >= (F.onscreen ? 3 : 1)) { fg_leave(reason, 1); return; }
    F.recoveries++; s->presentation_epoch++; F.onscreen = 0;
    MLOG("[fg] presentation stall recovery %d (%s): queued frames dropped, pairs start again", F.recoveries, reason);
    fg_jobs_clear(); F.primed = F.warm = 0; s->pending = 0;
}
static int fg_present(FgSession *s, id<MTLTexture> texture, int original, uint64_t ticket, double duration, void (^completed)(void)) {
    if (atomic_load(&g_gpu_lost)) return 0;
    CAMetalLayer *layer = (__bridge CAMetalLayer *)front_metal_layer(); if (!layer) return 0;
    uint64_t begin = now_ns(); id<CAMetalDrawable> drawable = [layer nextDrawable];
    uint64_t waited = now_ns() - begin; atomic_fetch_add(&g_drawable_ns, waited);
    if (waited > 100000000ull) MLOG("[fg] nextDrawable waited %.0f ms (%d pending, maximum %lu)%s", waited / 1e6, s->pending, (unsigned long)layer.maximumDrawableCount, drawable ? "" : ": none came");
    if (!drawable) return 0;
    if (s->layer != layer) { [s->present_queue addResidencySet:layer.residencySet]; s->layer = layer; }
    id<MTL4CommandAllocator> allocator = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer];
    id<MTL4ArgumentTable> args = fg_arguments(); id<MTLBuffer> uv = [g_dev newBufferWithLength:NX_GFX_PRESENT_FLOATS * sizeof(float) options:MTLResourceStorageModeShared];
    if (!allocator || !cb || !args || !uv) return 0;
    res_add(uv); res_commit(); [s->present_queue waitForDrawable:drawable];
    [cb beginCommandBufferWithAllocator:allocator];
    int kind = present_encode_m4_args(cb, texture, drawable.texture, NULL, uv, &g_fx_present, args, 2);
    [cb endCommandBuffer];
    if (!kind) { [s->present_queue signalDrawable:drawable]; res_remove(uv); res_commit(); return 0; }
    FgPresent *p = [FgPresent new]; p->original = original; p->ticket = ticket; p->session = s;
    p->hgen = s->presentation_epoch; p->submitted = CACurrentMediaTime(); p->buffer = cb;
    s->pending++; s->in_flight++;
    pthread_mutex_lock(&g_pq_mu); g_pq_inflight++; pthread_mutex_unlock(&g_pq_mu);
    [drawable addPresentedHandler:^(id<MTLDrawable> d) { double t = d.presentedTime; dispatch_async(g_fg_wq, ^{ fg_on_presented(p, t); }); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), g_fg_wq, ^{ fg_on_presented(p, NAN); });
    NSArray *keep = @[s, texture, allocator, cb, args, uv];
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        (void)keep; atomic_store(&p->gpu_done, 1);
        pthread_mutex_lock(&g_pq_mu); g_pq_inflight--; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
        res_remove(uv); res_commit();
        dispatch_async(g_fg_wq, ^{
            s->in_flight--;
            if (completed) completed();
            if (feedback.error) { MLOG("[RED] [fg] present command buffer: %s", feedback.error.description.UTF8String); fg_leave("present_command_buffer_failed", 1); }
            fg_leave_check();
        });
    }];
    [s->present_queue commit:&cb count:1 options:options]; [s->present_queue signalDrawable:drawable];
    if (duration > 0) [drawable presentAfterMinimumDuration:duration]; else [drawable present];
    if (original) F.originals++; else F.generated++;
    return 1;
}
static void fg_pump(void) {
    while (F.count) {
        FgJob *job = g_fg_jobs[F.head]; FgSession *s = job->session;
        if (!job->ready) return;
        if (job->discarded) {
            g_fg_jobs[F.head] = nil; F.head = (F.head + 1) % FG_JOBS; F.count--;
            if (job->generated) { s->output_busy[job->generated - 1] = 0; F.generated_jobs--; }
            g_pres[job->ticket % PRING] = (pres_ent){job->ticket, -1}; F.dropped++; fg_slot_release(job); continue;
        }
        if (job->generated) {
            int one = fg_free_for(s, 1), two = fg_free_for(s, 2);
            int action = F.count >= 2 ? (two ? 0 : 2) : (one ? 0 : 1);
            if (action == 1) return;
            int output = job->generated - 1; job->generated = 0; F.generated_jobs--;
            if (action == 2) {
                s->output_busy[output] = 0; F.no_drawable++;
            } else {
                job->paired = fg_present(s, s->gen[output], 0, 0, 0, ^{ s->output_busy[output] = 0; });
                if (!job->paired) s->output_busy[output] = 0;
            }
        }
        if (!fg_free_for(s, 1)) return;
        g_fg_jobs[F.head] = nil; F.head = (F.head + 1) % FG_JOBS; F.count--;
        if (!fg_present(s, job->slot->texture, 1, job->ticket, job->paired ? job->period : 0, ^{ fg_slot_release(job); })) {
            g_pres[job->ticket % PRING] = (pres_ent){job->ticket, -1}; F.dropped++; fg_slot_release(job);
        }
    }
}
static double fg_ms_p(double *values, int n, double fraction) {
    if (!n) return 0; double sorted[300]; n = MIN(n, 300); memcpy(sorted, values, n * sizeof(double));
    for (int i = 1; i < n; i++) { double v = sorted[i]; int j = i; while (j && sorted[j - 1] > v) { sorted[j] = sorted[j - 1]; j--; } sorted[j] = v; }
    return sorted[MIN(n - 1, (int)(n * fraction))];
}
static void fg_on_capture(FgSession *s, FgSlot *slot, uint64_t sequence, uint64_t ticket, double time, int screen_hz) {
    FgJob *job = [FgJob new]; job->session = s; job->slot = slot; job->sequence = sequence; job->ticket = ticket; job->ready = 1;
    if (s->epoch != atomic_load(&g_fg_gen) || atomic_load(&g_fg_phase) != FG_ACTIVE) { g_pres[ticket % PRING] = (pres_ent){ticket, -1}; fg_slot_release(job); return; }
    if (!mtl_framegen_enabled()) { fg_slot_release(job); fg_leave("setting_off", 0); return; }
    fg_observe(time, screen_hz); fg_rate(F.mode == 3 ? (int)F.target : 0); F.sources++;
    if (F.sources % 300 == 0) {
        double now = CACurrentMediaTime(), span = now - F.report_time; uint64_t ticks = front_framegen_rate_ticks();
        MLOG("[fg] %llu source frames: generated %llu, originals %llu, warmup %llu, after gap %llu, unprimed %llu, shed %llu, dropped %llu, no drawable %llu; history resets %llu; game %.1f fps, target %.0f; interpolation GPU p50 %.2f / p95 %.2f ms; shown %llu, never shown %llu; refresh callback %.1f Hz", F.sources, F.generated, F.originals, F.warm_hidden, F.gaps, F.unprimed, F.shed, F.dropped, F.no_drawable, F.resets, F.fps, F.target, fg_ms_p(F.gpu_ms, F.gpu_n, .5), fg_ms_p(F.gpu_ms, F.gpu_n, .95), F.shown, F.never_shown, span > 0 ? (ticks - F.last_ticks) / span : 0.);
        F.report_time = now; F.last_ticks = ticks;
    }
    if (F.count == FG_JOBS) { fg_slot_release(job); F.shed++; return; }
    g_fg_jobs[(F.head + F.count++) % FG_JOBS] = job;
    if (atomic_load(&slot->failed)) { job->discarded = 1; job->reason = "capture_command_buffer_failed"; F.primed = 0; fg_pump(); return; }
    const char *reason = NULL;
    if (!F.primed) { reason = "fixed_pair_seed"; F.unprimed++; }
    else if (sequence != F.previous_sequence + 1) reason = "input_pair_not_adjacent";
    else if (!isfinite(time) || !isfinite(F.previous_time) || time <= F.previous_time) reason = "fixed_pair_pts_invalid";
    else if (time - F.previous_time > 1. / 15) { reason = "fixed_pair_discontinuity"; F.gaps++; }
    else if (F.mode != 3) reason = "source_rate_or_screen";
    else if (!F.onscreen) reason = "pair_reservation_original_fallback";
    if (F.mode != 3) { F.primed = 0; fg_pump(); return; }
    int output = reason ? -1 : (int)(sequence % FG_SLOTS);
    if (output >= 0 && s->output_busy[output]) { output = -1; reason = "metalfx_output_busy"; }
    int reset = F.encoded_sequence != F.previous_sequence;
    id<MTLCommandBuffer> wait = [s->queue commandBuffer]; [wait encodeWaitForEvent:s->capture_event value:sequence]; [wait commit];
    id<MTLCommandBuffer> cb = [s->queue commandBuffer]; cb.label = @"framegen (MetalFX interpolation)";
    int show = 0;
    if (output >= 0) {
        if (reset) { F.warm = 0; F.resets++; }
        id<MTLFXFrameInterpolator> fi = s->fi;
        fi.colorTexture = slot->texture; fi.prevColorTexture = s->hist[s->hi]; fi.outputTexture = s->gen[output];
        fi.depthTexture = s->depth; fi.motionTexture = s->motion; fi.motionVectorScaleX = fi.motionVectorScaleY = 1;
        fi.deltaTime = time > F.previous_time && F.primed ? time - F.previous_time : 1. / 30;
        fi.nearPlane = .1; fi.farPlane = 1000; fi.fieldOfView = 60; fi.aspectRatio = (float)s->w / s->h;
        fi.jitterOffsetX = fi.jitterOffsetY = 0; fi.depthReversed = NO; fi.shouldResetHistory = reset;
        [fi encodeToCommandBuffer:cb]; fi.outputTexture = fi.prevColorTexture = fi.colorTexture = nil;
        F.encoded_sequence = sequence; s->output_busy[output] = 1;
        show = ++F.warm > 2 && !reason;
        if (!show) F.warm_hidden++;
    }
    id<MTLBlitCommandEncoder> copy = [cb blitCommandEncoder];
    [copy copyFromTexture:slot->texture toTexture:s->hist[s->hi ^ 1]]; [copy endEncoding]; s->hi ^= 1;
    F.primed = 1; F.previous_sequence = sequence; F.previous_time = time;
    job->ready = 0;
    if (show) { job->generated = output + 1; job->period = 1. / F.target; F.generated_jobs++; }
    s->in_flight++;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        NSError *error = done.error; double gpu = (done.GPUEndTime - done.GPUStartTime) * 1000;
        dispatch_async(g_fg_wq, ^{
            s->in_flight--;
            if (!show && output >= 0) s->output_busy[output] = 0;
            if (s->epoch != atomic_load(&g_fg_gen)) { if (show) s->output_busy[output] = 0; fg_leave_check(); return; }
            if (gpu > 0 && gpu < 1000) F.gpu_ms[F.gpu_n++ % 300] = gpu;
            if (error) { MLOG("[RED] [fg] MetalFX frame interpolation command buffer failed: %s", error.description.UTF8String); fg_leave("metalfx_failed", 1); return; }
            job->ready = 1; fg_pump(); fg_leave_check();
        });
    }];
    [cb commit]; fg_pump();
}
// -1 uses the ordinary native presenter; 0 is a shed/drop; 1 means
// the capture was submitted and the worker now owns both images of the pair.
static int fg_route(id<MTLTexture> source, const int crop[4], uint64_t ticket, double time, CAMetalLayer *layer) {
    fg_queue_init(); int phase = atomic_load(&g_fg_phase);
    if (!mtl_framegen_enabled()) {
        if (phase) { dispatch_async(g_fg_wq, ^{ fg_leave("setting_off", 0); }); return 0; }
        return -1;
    }
    if (!g_q4 || !layer) return -1;
    NSUInteger valid[4]; if (!present_crop_rect(source, crop, valid)) return -1;
    NSUInteger w, h; fg_extent(valid[2], valid[3], &w, &h); int hz = mtl_display_hz();
    if (atomic_exchange(&g_fg_reset, 0) && phase) { dispatch_async(g_fg_wq, ^{ F.primed = F.warm = 0; F.encoded_sequence = 0; }); }
    if (phase == FG_LEAVING) return 0;
    if (phase == FG_NATIVE) { MTLPixelFormat format = layer.pixelFormat; dispatch_async(g_fg_wq, ^{ fg_session_start(w, h, format, time, hz); }); return -1; }
    pthread_mutex_lock(&g_pq_mu); FgSession *s = g_fg_session;
    if (!s || atomic_load(&g_fg_phase) != FG_ACTIVE) { pthread_mutex_unlock(&g_pq_mu); return 0; }
    if (s->w != w || s->h != h) { pthread_mutex_unlock(&g_pq_mu); dispatch_async(g_fg_wq, ^{ fg_leave("picture_size_changed", 0); }); return -1; }
    FgSlot *slot = nil;
    for (int i = 0; i < FG_SLOTS; i++) { int zero = 0; if (atomic_compare_exchange_strong(&s->slots[i]->busy, &zero, 1)) { slot = s->slots[i]; break; } }
    pthread_mutex_unlock(&g_pq_mu);
    uint64_t sequence = atomic_fetch_add(&g_fg_source_seq, 1) + 1;
    if (!slot) { g_pres[ticket % PRING] = (pres_ent){ticket, -1}; dispatch_async(g_fg_wq, ^{ F.shed++; }); return 0; }
    atomic_store(&slot->failed, 0); [slot->allocator reset];
    id<MTL4CommandBuffer> cb = slot->buffer; [cb beginCommandBufferWithAllocator:slot->allocator];
    NX_GFX_CAPTURE_BEGIN();
    int kind = present_encode_m4_args(cb, source, slot->texture, crop, slot->uv, NULL, slot->arguments, 1);
    NX_GFX_CAPTURE_END(); [cb endCommandBuffer];
    if (!kind) { atomic_store(&slot->busy, 0); return 0; }
    MTL4CommitOptions *options = [MTL4CommitOptions new]; FgSlot *captured = slot;
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        (void)source;
        if (feedback.error) { atomic_store(&captured->failed, 1); if (s->capture_event.signaledValue < sequence) s->capture_event.signaledValue = sequence; MLOG("[RED] [fg] capture command buffer: %s", feedback.error.description.UTF8String); }
        pthread_mutex_lock(&g_pq_mu); if (ticket > g_pq_done) g_pq_done = ticket; g_pq_inflight--; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    }];
    pthread_mutex_lock(&g_pq_mu); g_pq_inflight++; pthread_mutex_unlock(&g_pq_mu);
    pthread_mutex_lock(&g_res_commit_mu); [g_q4 commit:&cb count:1 options:options]; [g_q4 signalEvent:s->capture_event value:sequence]; pthread_mutex_unlock(&g_res_commit_mu);
    dispatch_async(g_fg_wq, ^{ fg_on_capture(s, captured, sequence, ticket, time, hz); });
    return 1;
}
static void fg_suspend(void) {
    if (!g_fg_wq) return;
    dispatch_async(g_fg_wq, ^{ fg_leave("background", 0); });
}
