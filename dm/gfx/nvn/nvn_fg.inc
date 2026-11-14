// Full-picture MetalFX interpolation. Like the reference iOS build, it uses
// constant depth and zero game motion, without game addresses or shader changes.
// All work uses the existing Metal 4 queue; only the classic present thread owns
// the state. Generated images go through the normal layout/filter pass.
static _Atomic int g_fg_requested = -1, g_fg_reset;
static _Atomic uint64_t g_fg_displayed;
static uint64_t g_fg_generated;
__attribute__((weak)) void front_framegen_rate(int fps) { (void)fps; }
static void fg_refresh_request(int fps) {
    static int requested;
    if (requested != fps) { requested = fps; front_framegen_rate(fps); }
}
int mtl_framegen_supported(void) {
    static int supported; static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(macOS 26.0, iOS 26.0, *)) {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            supported = dev && [MTLFXFrameInterpolatorDescriptor supportsMetal4FX:dev];
        }
    });
    return supported;
}
static int fg_choice(_Atomic int *value, const char *name, int fallback) {
    int v = atomic_load(value);
    if (v < 0) { const char *s = getenv(name); int initial = s ? atoi(s) != 0 : fallback;
        atomic_compare_exchange_strong(value, &v, initial); v = atomic_load(value); }
    return v;
}
int mtl_framegen_enabled(void) { return fg_choice(&g_fg_requested, "DM_FRAMEGEN", 0) && mtl_framegen_supported(); }
int mtl_framegen_set(int on) {
    if (on && !mtl_framegen_supported()) return 0;
    atomic_store(&g_fg_requested, on != 0); atomic_store(&g_fg_reset, 1); return 1;
}
void mtl_framegen_reset(void) { atomic_store(&g_fg_reset, 1); }
uint64_t mtl_framegen_present_count(void) { return atomic_load(&g_fg_displayed); }

enum { FG_SLOTS = 3 };
typedef struct {
    id<MTL4FXFrameInterpolator> fi;
    id<MTLTexture> color[2], depth, motion, ui, output[FG_SLOTS];
    id<MTL4CommandAllocator> alloc[FG_SLOTS];
    id<MTL4CommandBuffer> cb[FG_SLOTS];
    id<MTL4ArgumentTable> args[FG_SLOTS];
    id<MTLBuffer> uv[FG_SLOTS];
    id<MTLRenderPipelineState> copy;
    id<MTLSamplerState> sampler;
    id<MTLFence> fence;
    _Atomic int busy[FG_SLOTS];
    NSUInteger source_w, source_h;
    int cur, slot, initialized, history, stable, crop[4];
    double last_time, period, stable_time;
} fg_state;
static fg_state g_fg;

static NSUInteger fg_limit(NSUInteger w, NSUInteger h) { return MIN(w, h) >= 1080 ? 1080 : 720; }
static void fg_extent(NSUInteger w, NSUInteger h, NSUInteger *ow, NSUInteger *oh) {
    if (!w || !h) { *ow = *oh = 0; return; }
    double edge = fg_limit(w, h);
    double scale = fmin(1., fmin(edge / fmin(w, h), sqrt(edge * edge * 16. / 9. / ((double)w * h))));
    *ow = MAX(2u, (NSUInteger)(w * scale) & ~(NSUInteger)1);
    *oh = MAX(2u, (NSUInteger)(h * scale) & ~(NSUInteger)1);
}
static int fg_cadence(double now, double period) {
    int reset = atomic_exchange(&g_fg_reset, 0);
    double dt = now - g_fg.last_time;
    if (reset || !g_fg.last_time || fabs(period - g_fg.period) > period * .1 || dt <= 0 || fabs(dt - period) > period * .3) {
        g_fg.history = 0; g_fg.stable = 0; g_fg.stable_time = now;
    } else g_fg.stable++;
    g_fg.last_time = now; g_fg.period = period;
    return g_fg.stable >= 6 && now - g_fg.stable_time >= .2;
}
static int fg_busy(void) { for (int i = 0; i < FG_SLOTS; i++) if (atomic_load(&g_fg.busy[i])) return 1; return 0; }
static int fg_rate_fits(double period, int screen_hz) {
    if (!isfinite(period) || period < 1. / 61 || period > 1. / 19 || screen_hz <= 0) return 0;
    double refreshes = period * screen_hz / 2;
    return refreshes >= .95 && fabs(refreshes - round(refreshes)) < .05;
}
static void fg_release(void) {
    // Configuration changes alone wait. Ordinary frames never wait for a free
    // capture slot; a busy ring keeps the real frame and resets interpolation.
    pthread_mutex_lock(&g_pq_mu);
    while (g_pq_inflight || fg_busy()) pthread_cond_wait(&g_pq_cv, &g_pq_mu);
    pthread_mutex_unlock(&g_pq_mu);
    for (int i = 0; i < 2; i++) res_remove(g_fg.color[i]);
    res_remove(g_fg.depth); res_remove(g_fg.motion); res_remove(g_fg.ui);
    for (int i = 0; i < FG_SLOTS; i++) { res_remove(g_fg.output[i]); res_remove(g_fg.uv[i]); }
    g_fg = (fg_state){0}; res_commit();
}
static id<MTLTexture> fg_texture(MTLPixelFormat format, NSUInteger w, NSUInteger h, MTLTextureUsage usage, NSString *label) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; t.label = label; if (t) res_add(t); return t;
}
static int fg_configure(NSUInteger source_w, NSUInteger source_h) {
    if (!source_w || !source_h) return 0;
    if (g_fg.fi && g_fg.source_w == source_w && g_fg.source_h == source_h) return 1;
    if (g_fg.fi || g_fg.copy) fg_release();
    NSUInteger w, h; fg_extent(source_w, source_h, &w, &h);
    MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
    d.inputWidth = d.outputWidth = w; d.inputHeight = d.outputHeight = h;
    d.colorTextureFormat = d.outputTextureFormat = d.uiTextureFormat = MTLPixelFormatBGRA8Unorm;
    d.depthTextureFormat = MTLPixelFormatR32Float; d.motionTextureFormat = MTLPixelFormatRG16Float;
    NSError *error = nil;
    id<MTL4Compiler> compiler = [g_dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&error];
    g_fg.fi = compiler ? [d newFrameInterpolatorWithDevice:g_dev compiler:compiler] : nil;
    if (!g_fg.fi) { MLOG("[RED] frame generation: MetalFX refused %lux%lu; keeping real frames", (unsigned long)w, (unsigned long)h); mtl_framegen_set(0); return 0; }
    id<MTL4FXFrameInterpolator> fi = g_fg.fi;
    for (int i = 0; i < 2; i++) g_fg.color[i] = fg_texture(d.colorTextureFormat, w, h, fi.colorTextureUsage | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"framegen captured picture");
    g_fg.depth = fg_texture(d.depthTextureFormat, w, h, fi.depthTextureUsage | MTLTextureUsageRenderTarget, @"framegen constant depth");
    g_fg.motion = fg_texture(d.motionTextureFormat, w, h, fi.motionTextureUsage | MTLTextureUsageRenderTarget, @"framegen zero motion");
    g_fg.ui = fg_texture(d.uiTextureFormat, w, h, fi.uiTextureUsage | MTLTextureUsageRenderTarget, @"framegen empty UI overlay");
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxTextureBindCount = ad.maxSamplerStateBindCount = ad.maxBufferBindCount = 1;
    int ok = g_fg.color[0] && g_fg.color[1] && g_fg.depth && g_fg.motion && g_fg.ui;
    for (int i = 0; i < FG_SLOTS; i++) {
        g_fg.output[i] = fg_texture(d.outputTextureFormat, w, h, fi.outputTextureUsage | MTLTextureUsageShaderRead, @"framegen MetalFX picture");
        g_fg.alloc[i] = [g_dev newCommandAllocator]; g_fg.cb[i] = [g_dev newCommandBuffer];
        g_fg.args[i] = [g_dev newArgumentTableWithDescriptor:ad error:&error];
        g_fg.uv[i] = [g_dev newBufferWithLength:8 * sizeof(float) options:MTLResourceStorageModeShared];
        if (g_fg.uv[i]) res_add(g_fg.uv[i]);
        ok &= g_fg.output[i] && g_fg.alloc[i] && g_fg.cb[i] && g_fg.args[i] && g_fg.uv[i];
    }
    g_fg.fence = [g_dev newFence]; ok &= g_fg.fence != nil;
    if (!ok) { MLOG("[RED] frame generation: cannot allocate capture buffers; keeping real frames"); fg_release(); mtl_framegen_set(0); return 0; }
    present_pipeline(d.colorTextureFormat); g_fg.copy = g_blit_pso; g_fg.sampler = g_blit_samp;
    g_fg.source_w = source_w; g_fg.source_h = source_h;
    res_commit();
    MLOG("frame generation: %lux%lu MetalFX, constant depth / zero game motion, automatic %lup budget, %d bounded output slots", (unsigned long)w, (unsigned long)h, (unsigned long)fg_limit(source_w, source_h), FG_SLOTS);
    return 1;
}
static void fg_clear(id<MTL4CommandBuffer> cb, id<MTLTexture> t, double value) {
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(value, 0, 0, 0);
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];
    [en endEncoding];
}
static id<MTLTexture> fg_prepare(id<MTLTexture> src, const int crop[4], double period, double now, int screen_hz) {
    if (!mtl_framegen_enabled()) {
        fg_refresh_request(0);
        if (g_fg.fi) fg_release(); return nil;
    }
    if (!g_q4 || !fg_rate_fits(period, screen_hz)) { fg_refresh_request(0); atomic_store(&g_fg_reset, 1); return nil; }
    fg_refresh_request((int)round(2 / period));
    NSUInteger valid[4]; if (!present_crop_rect(src, crop, valid)) { atomic_store(&g_fg_reset, 1); return nil; }
    if (!fg_configure(valid[2], valid[3])) return nil;
    int different_crop = crop ? memcmp(g_fg.crop, crop, sizeof g_fg.crop) : (g_fg.crop[2] || g_fg.crop[3]);
    if (different_crop) { memset(g_fg.crop, 0, sizeof g_fg.crop); if (crop) memcpy(g_fg.crop, crop, sizeof g_fg.crop); atomic_store(&g_fg_reset, 1); }
    int stable = fg_cadence(now, period), slot = -1;
    for (int i = 0; i < FG_SLOTS; i++) { int candidate = (g_fg.slot + i) % FG_SLOTS; if (!atomic_load(&g_fg.busy[candidate])) { slot = candidate; break; } }
    if (slot < 0) { atomic_store(&g_fg_reset, 1); return nil; }
    g_fg.slot = (slot + 1) % FG_SLOTS; atomic_store(&g_fg.busy[slot], 1);
    id<MTL4CommandBuffer> cb = g_fg.cb[slot]; [g_fg.alloc[slot] reset]; [cb beginCommandBufferWithAllocator:g_fg.alloc[slot]];
    if (!g_fg.initialized) { fg_clear(cb, g_fg.depth, .5); fg_clear(cb, g_fg.motion, 0); fg_clear(cb, g_fg.ui, 0); g_fg.initialized = 1; }
    id<MTLTexture> input = g_fg.color[g_fg.cur], raw = present_raw_src(src);
    MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
    rp.colorAttachments[0].texture = input; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
    [en barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];
    float uv[8] = {(float)valid[0] / src.width, (float)valid[1] / src.height, (float)valid[2] / src.width, (float)valid[3] / src.height,
        (valid[0] + .5f) / src.width, (valid[1] + .5f) / src.height, (valid[0] + valid[2] - .5f) / src.width, (valid[1] + valid[3] - .5f) / src.height};
    memcpy(g_fg.uv[slot].contents, uv, sizeof uv);
    [g_fg.args[slot] setTexture:raw.gpuResourceID atIndex:0]; [g_fg.args[slot] setSamplerState:g_fg.sampler.gpuResourceID atIndex:0]; [g_fg.args[slot] setAddress:g_fg.uv[slot].gpuAddress atIndex:0];
    [en setArgumentTable:g_fg.args[slot] atStages:MTLRenderStageFragment]; [en setRenderPipelineState:g_fg.copy];
    [en setViewport:(MTLViewport){0, 0, input.width, input.height, 0, 1}]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [en updateFence:g_fg.fence afterEncoderStages:MTLStageFragment]; [en endEncoding];
    id<MTL4FXFrameInterpolator> fi = g_fg.fi;
    int show = stable && g_fg.history;
    if (stable) {
    fi.colorTexture = input; fi.prevColorTexture = g_fg.color[g_fg.cur ^ 1]; fi.outputTexture = g_fg.output[slot];
    fi.depthTexture = g_fg.depth; fi.motionTexture = g_fg.motion; fi.uiTexture = g_fg.ui; fi.uiTextureComposited = NO;
    fi.fence = g_fg.fence; fi.motionVectorScaleX = fi.motionVectorScaleY = 1;
    fi.nearPlane = .1; fi.farPlane = 1000; fi.fieldOfView = 60; fi.aspectRatio = (float)input.width / input.height;
    fi.deltaTime = period; fi.depthReversed = NO; fi.shouldResetHistory = !g_fg.history;
    [fi encodeToCommandBuffer:cb];
    }
    [cb endCommandBuffer];
    NSArray *keep = @[src, raw, fi, g_fg.color[0], g_fg.color[1], g_fg.depth, g_fg.motion, g_fg.ui, g_fg.output[slot], g_fg.uv[slot], g_fg.copy, g_fg.sampler, g_fg.fence, g_fg.alloc[slot], cb];
    fi.colorTexture = fi.prevColorTexture = fi.outputTexture = fi.depthTexture = fi.motionTexture = fi.uiTexture = nil;
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        (void)keep;
        if (feedback.error) { atomic_store(&g_fg_reset, 1); MLOG("[RED] frame interpolation command buffer: %s", feedback.error.description.UTF8String); gpu_lost_check(feedback.error, "frame interpolation"); }
        pthread_mutex_lock(&g_pq_mu); atomic_store(&g_fg.busy[slot], 0); pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    }];
    [g_q4 commit:&cb count:1 options:options];
    g_fg.cur ^= 1; g_fg.history = stable;
    if (show) g_fg_generated++;
    return show ? g_fg.output[slot] : nil;
}
