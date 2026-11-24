// Native sources at each target use the game queue. Exercise real Metal and offscreen drawables.
#define NVN_NATIVE30_IDLE_TEST 1
#define nvn_game_fps test_game_fps_now
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
int test_focus = 1, test_fullscreen, test_variable_refresh, test_game_fps = 30, test_screen_hz, test_match_fps;
uint64_t test_focus_since;
static CAMetalLayer *g_test_layer;
void *front_metal_layer(void) { return (__bridge void *)g_test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
@interface QueueLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@end
@implementation QueueLinkUpdate
@end
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static tex_t source(unsigned serial, uint8_t value) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; uint8_t bytes[256];
    for (int i = 0; i < 64; i++) { bytes[4*i] = bytes[4*i+1] = bytes[4*i+2] = value; bytes[4*i+3] = 255; }
    [mt replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:bytes bytesPerRow:32];
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
static id<CAMetalDrawable> drawable(void) {
    if (!g_test_layer) {
        g_test_layer = [CAMetalLayer layer]; g_test_layer.device = g_dev;
        g_test_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_test_layer.framebufferOnly = NO; g_test_layer.drawableSize = CGSizeMake(8, 8);
    }
    return [g_test_layer nextDrawable];
}
static NvMetalDisplayLinkDelegate *g_delegate;
static void tick_with(id<CAMetalDrawable> dr) {
    static double target; if (!target) target = CACurrentMediaTime(); target += .1;
    QueueLinkUpdate *u = [QueueLinkUpdate new]; u.drawable = dr; u.targetPresentationTimestamp = target;
    [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u];
}
static id<CAMetalDrawable> tick(void) { id<CAMetalDrawable> dr = drawable(); tick_with(dr); return dr; }
static uint64_t enqueue(const tex_t *t, double gpu_ms) {
    static uint64_t frame = 16;
    gpu_tag_begin(frame - 8); gpu_tag_done(frame - 8, 10, 10 + gpu_ms / 1000);
    mtl_set_frame(frame++);
    uint64_t copy = 0, ticket = mtl_present(t, 1. / test_game_fps, NULL, &copy);
    if (!ticket || !copy) { fprintf(stderr, "no native snapshot or ticket\n"); exit(2); }
    return ticket;
}
static void pixels(id<MTLTexture> t, uint8_t want) {
    id<MTLBuffer> out = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
        toBuffer:out destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int bad = 0; const uint8_t *p = out.contents;
    for (int i = 0; i < 64; i++) bad += p[4*i] != want || p[4*i+1] != want || p[4*i+2] != want || p[4*i+3] != 255;
    CHECK("display reads the correct snapshot pixels", !bad);
}
static int display_completed(uint64_t serial, int ms) {
    uint64_t end = bp_now() + ms * NSEC_PER_MSEC;
    int done;
    do {
        pthread_mutex_lock(&g_pq_mu); done = g_present_alloc_done[serial % 3] >= serial; pthread_mutex_unlock(&g_pq_mu);
        if (done) break;
        usleep(1000);
    } while (bp_now() < end);
    return done;
}
static void target(int rate) {
    test_game_fps = rate;
    char value[8]; snprintf(value, sizeof value, "%d", rate); setenv("DM_FPS_TARGET", value, 1);
}
static void shared(const tex_t *src, int rate) { @autoreleasepool {
    target(rate);
    enqueue(src, 5);
    id<MTLSharedEvent> copied = [g_dev newSharedEvent], gate = [g_dev newSharedEvent];
    [g_q4 signalEvent:copied value:1];
    CHECK("game snapshot completed before the shared-queue gate", [copied waitUntilSignaledValue:1 timeoutMS:2000]);
    // Gate the game queue AFTER its snapshot. An independent display queue could already read this image.
    [g_q4 waitForEvent:gate value:1];
    uint64_t serial = g_present_serial + 1;
    id<CAMetalDrawable> dr = tick();
    CHECK("one native image uses one display allocator", g_present_serial == serial);
    CHECK("native display waits behind work on the game queue", !display_completed(serial, 100));
    gate.signaledValue = 1;
    CHECK("native display completes when the game queue resumes", display_completed(serial, 2000));
    pixels(dr.texture, 70);
    CHECK("native presentation creates no interpolation session or generated frames", !g_fg_session && !mtl_framegen_present_count());
    printf("native shared queue: %d fps\n", rate);
} }
static void render(const tex_t *src, double gpu_ms) { @autoreleasepool {
    enqueue(src, gpu_ms); tick();
    if (!display_completed(g_present_serial, 2000)) { fprintf(stderr, "display did not complete\n"); exit(2); }
} }
static int keepalive_progress(const tex_t *src) {
    uint64_t before = atomic_load(&g_native30_idle_completed);
    for (int i = 0; i < 100 && atomic_load(&g_native30_idle_completed) == before; i++) {
        render(src, 25); usleep(1000);
    }
    return atomic_load(&g_native30_idle_completed) > before;
}
static void failure_recovery(const tex_t *src) {
    native30_idle_stop();
    CHECK("keep-alive is drained before failure injection", native30_idle_drain());
    int failures = atomic_load(&g_native30_idle_test_failures);
    atomic_store(&g_native30_idle_test_error, MTLCommandBufferErrorNotPermitted);
    for (int i = 0; i < 100 && atomic_load(&g_native30_idle_test_failures) == failures; i++) {
        render(src, 25); usleep(1000);
    }
    CHECK("a real GPU completion delivers the injected access denial", atomic_load(&g_native30_idle_test_failures) == failures + 1);
    native30_idle_stop(); CHECK("the failed pulse retires before retry", native30_idle_drain());
    CHECK("access denial cancels the lease without declaring GPU loss", !atomic_load(&g_native30_idle_until) && !atomic_load(&g_gpu_lost));
    CHECK("a fresh source frame recovers after access denial", keepalive_progress(src));

    mtl_present_discard(1);
    NSError *timeout = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:nil];
    native30_idle_failed(timeout, NATIVE30_IDLE_EXECUTION);
    CHECK("a background failure stays stopped", !atomic_load(&g_native30_idle_until) && atomic_load(&g_native30_idle_suspended));
    mtl_present_discard(0); mtl_framegen_resume();
    CHECK("foreground resumes real GPU pulses after a background failure", keepalive_progress(src));
    native30_idle_stop(); CHECK("foreground work drains before another failure", native30_idle_drain());
    native30_idle_failed(timeout, NATIVE30_IDLE_EXECUTION);
    CHECK("an isolated execution failure also permits a fresh-frame retry", keepalive_progress(src));
}
static void failure_backoff(const tex_t *src) {
    native30_idle_stop(); CHECK("work drains before retry-backoff checks", native30_idle_drain());
    uint64_t failures = atomic_load(&g_native30_idle_failures);
    native30_idle_failed(nil, NATIVE30_IDLE_ALLOCATION);
    CHECK("an allocation failure is counted and recoverable", atomic_load(&g_native30_idle_failures) == failures + 1 && keepalive_progress(src));
    native30_idle_stop(); CHECK("work drains before an encoder failure", native30_idle_drain());
    native30_idle_failed(nil, NATIVE30_IDLE_ENCODER);
    CHECK("an encoder failure is counted and recoverable", atomic_load(&g_native30_idle_failures) == failures + 2 && keepalive_progress(src));
    native30_idle_stop(); CHECK("work drains before consecutive failures", native30_idle_drain());
    NSError *error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:nil];
    for (int i = 0; i < 3; i++) native30_idle_failed(error, NATIVE30_IDLE_EXECUTION);
    uint64_t retry = atomic_load(&g_native30_idle_retry_at), before = atomic_load(&g_native30_idle_completed);
    CHECK("three consecutive failures start a two-second backoff", atomic_load(&g_native30_idle_failure_streak) == 3 && retry > bp_now() && retry <= bp_now() + 2 * NSEC_PER_SEC);
    for (int i = 0; i < 5; i++) render(src, 25);
    CHECK("heavy frames cannot submit pulses during backoff", !atomic_load(&g_native30_idle_until) && atomic_load(&g_native30_idle_completed) == before && !native30_idle_gap());
    CHECK("heavy frames do not extend the retry deadline", atomic_load(&g_native30_idle_retry_at) == retry);
    CHECK("all failed attempts are counted", atomic_load(&g_native30_idle_failures) == failures + 5);
    while (bp_now() < retry) usleep(10000);
    CHECK("new heavy frames resume real GPU work when backoff expires", keepalive_progress(src));
    CHECK("a successful pulse resets consecutive failures and backoff", !atomic_load(&g_native30_idle_failure_streak) && !atomic_load(&g_native30_idle_retry_at));
}
static void bounded_drain(void) {
    native30_idle_stop();
    CHECK("work drains before the missing-completion regression", native30_idle_drain());
    dispatch_group_enter(g_native30_idle_work); // a completion that has not arrived
    uint64_t start = bp_now();
    int done = native30_idle_drain();
    double ms = (bp_now() - start) / 1e6;
    CHECK("a missing completion returns at the bounded deadline", !done && ms >= 80 && ms < 500);
    CHECK("timeout leaves the outstanding completion registered", dispatch_group_wait(g_native30_idle_work, DISPATCH_TIME_NOW) != 0);
    dispatch_group_leave(g_native30_idle_work);
    CHECK("a late completion still drains safely", native30_idle_drain());

    dispatch_semaphore_t release = dispatch_semaphore_create(0), entered = dispatch_semaphore_create(0);
    dispatch_async(g_native30_idle_worker, ^{
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    });
    CHECK("the worker backlog is in place", !dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    // Release even if the drain regresses to an unbounded wait.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        dispatch_semaphore_signal(release);
    });
    start = bp_now(); done = native30_idle_drain(); ms = (bp_now() - start) / 1e6;
    dispatch_semaphore_signal(release);
    CHECK("worker backlog is included in the same drain deadline", !done && ms >= 80 && ms < 500);
    CHECK("the worker can drain after the timed-out barrier", native30_idle_drain());
}
static void bounded_kernel(void) {
    NSError *error = nil;
    id<MTLFunction> fn = [host_lib("native30_idle", &error) newFunctionWithName:@"native30_idle"];
    id<MTLComputePipelineState> pipeline = [g_dev newComputePipelineStateWithFunction:fn error:&error];
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    id<MTLBuffer> result = [g_dev newBufferWithLength:32 * sizeof(uint32_t) options:MTLResourceStorageModeShared];
    CHECK("the finite keep-alive kernel compiles", pipeline && queue && result);
    if (!pipeline || !queue || !result) return;
    const uint32_t limits[] = {NATIVE30_IDLE_MIN_STEPS, NATIVE30_IDLE_MAX_STEPS};
    for (unsigned n = 0; n < sizeof limits / sizeof limits[0]; n++) {
        uint32_t steps = limits[n];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        [enc setBuffer:result offset:0 atIndex:0];
        [enc setBytes:&steps length:sizeof steps atIndex:1];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        int valid = cb.status == MTLCommandBufferStatusCompleted;
        const uint32_t *actual = result.contents;
        for (unsigned lane = 0; lane < 32; lane++) {
            uint32_t expected = lane + 1;
            for (uint32_t i = 0; i < steps; i++) { expected = expected * 1664525u + 1013904223u; expected ^= expected >> 13; }
            valid &= actual[lane] == expected;
        }
        CHECK("every GPU lane completes exactly its finite iteration count", valid);
        printf("finite keep-alive kernel: %u iterations, %.3f ms GPU\n", steps, (cb.GPUEndTime - cb.GPUStartTime) * 1000.);
    }
}
static void busy_transfers(const tex_t *src) {
    const NSUInteger size = 16u << 20;
    id<MTLBuffer> buf = [g_dev newBufferWithLength:size options:MTLResourceStorageModeShared];
    res_add(buf); res_commit();
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:gate value:1];
    up_begin();
    [g_up_ce fillBuffer:buf range:NSMakeRange(0, size) value:0x5a];
    up_flush();
    native30_idle_drain(); // retire any pulse issued before the upload
    uint64_t before = atomic_load(&g_native30_idle_completed);
    unsigned hold = 0;
    native30_idle_frame(&hold, 27);
    dispatch_sync(g_native30_idle_worker, ^{ native30_idle_run(); });
    CHECK("a pending upload blocks an armed keep-alive", hold && atomic_load(&g_up_pending) && !native30_idle_gap());
    CHECK("the pending upload admits zero new pulses", atomic_load(&g_native30_idle_completed) == before);
    gate.signaledValue = 1;
    up_wait_zero(&g_up_pending, WS_OLDQ);
    const uint8_t *pixels = buf.contents;
    CHECK("the GPU wrote both ends of the 16 MiB upload buffer", pixels[0] == 0x5a && pixels[size - 1] == 0x5a);

    id<MTLSharedEvent> copy_gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:copy_gate value:1];
    CHECK("a framebuffer copy queues behind its own gate", snap_take(src));
    uint64_t copy = atomic_load(&g_snap_v);
    native30_idle_drain();
    before = atomic_load(&g_native30_idle_completed);
    native30_idle_frame(&hold, 27);
    dispatch_sync(g_native30_idle_worker, ^{ native30_idle_run(); });
    printf("pending snapshot: lease %u, copy %llu, GPU completed %llu, gap %d\n", hold,
           (unsigned long long)copy, (unsigned long long)g_snap_ev.signaledValue, native30_idle_gap());
    CHECK("the framebuffer copy alone blocks an armed keep-alive", hold && g_snap_ev.signaledValue < copy && !native30_idle_gap());
    uint64_t extra = atomic_load(&g_native30_idle_completed) - before;
    printf("busy transfer queue: 16 MiB, %llu new keep-alive pulses\n", (unsigned long long)extra);
    CHECK("no new pulses while game transfers are outstanding", extra == 0);
    copy_gate.signaledValue = 1;
    CHECK("the game's snapshot completes", [g_snap_ev waitUntilSignaledValue:copy timeoutMS:2000]);
    res_remove(buf); res_commit();
}
int main(int argc, char **argv) { @autoreleasepool {
    alarm(45); setvbuf(stdout, NULL, _IONBF, 0);
    int off = argc > 1 && !strcmp(argv[1], "--off");
    setenv("DM_NATIVE_60_PRESENT_QUEUE", "1", 1); setenv("DM_NATIVE_30_PAIRED_PRESENT", "1", 1); // settings left by older builds
    setenv("DM_FRAMEGEN", "0", 1); setenv("DM_PSO_PREPARE", "0", 1);
    setenv("DM_PRESENT_SNAP", "2", 1); setenv("DM_NVN_ENC_THREAD", "0", 1); setenv("DM_PRESENT_HZ", "0", 1);
    mtl_init(); mtl_present_layer(8, 8);
    g_present_link_env = 1; g_dm_present_link = g_link_mode = 1; g_link_started = g_link_owns_layer = 1;
    g_delegate = [NvMetalDisplayLinkDelegate new];
    tex_t a = source(93001, 70);
    shared(&a, 30); shared(&a, 60); shared(&a, 120);
    render(&a, 27); target(60); render(&a, 27);
    test_game_fps = 30; render(&a, 27); // a requested 60 that is currently at 30
    CHECK("light native 30, native 60/120 and an adaptive 60 target leave the worker asleep", !atomic_load(&g_native30_idle_started));
    target(30); render(&a, 25);
    CHECK("heavy native 30 keeps the original 30 Hz link and latency 1", g_link_mode == 3 && link_latency() == 1);
    CHECK("keep-alive defaults on and explicit opt-out is respected", native30_idle_enabled() == !off);
    if (off) {
        CHECK("opt-out allocates no keep-alive GPU resources", !atomic_load(&g_native30_idle_started));
    } else {
        bounded_kernel();
        render(&a, 25);
        CHECK("a heavy frame on the ordinary presenter starts real keep-alive work", keepalive_progress(&a));
        render(&a, 15);
        CHECK("moderate load sustains the lease", atomic_load(&g_native30_idle_until)>bp_now());
        id<MTLSharedEvent> gate = [g_dev newSharedEvent];
        uint64_t epoch = atomic_load(&g_native30_idle_epoch);
        mtl_sub_begin(); [g_q4 waitForEvent:gate value:1];
        uint64_t fence = mtl_sub_commit();
        native30_idle_drain();
        CHECK("a game submission invalidates pending keep-alive dispatches", atomic_load(&g_native30_idle_epoch) > epoch && !native30_idle_gap() && !atomic_load(&g_native30_idle_busy));
        gate.signaledValue=1; CHECK("real drawing completes on the normal fence", mtl_wait(fence, 2000000000ull));
        busy_transfers(&a);
        for (int i=0; i<30; i++) render(&a, 5);
        CHECK("30 light frames withdraw the lease", !atomic_load(&g_native30_idle_until));
        render(&a, 25); dispatch_sync(g_native30_idle_worker, ^{}); usleep(110000);
        CHECK("source silence expires the lease", !native30_idle_gap());
        render(&a, 15); CHECK("return from silence requires a fresh expensive frame", !atomic_load(&g_native30_idle_until));
        render(&a, 25); target(60); render(&a, 25); CHECK("switching to 60 cancels keep-alive", !atomic_load(&g_native30_idle_until));
        target(30); render(&a, 25); mtl_present_discard(1);
        CHECK("background drains keep-alive work", !atomic_load(&g_native30_idle_until) && atomic_load(&g_native30_idle_suspended) && !atomic_load(&g_native30_idle_busy));
        mtl_present_discard(0); mtl_framegen_resume();
        failure_recovery(&a);
        failure_backoff(&a);
        bounded_drain();
        if (mtl_framegen_supported()) {
            render(&a, 25);
            CHECK("turning on interpolation cancels keep-alive immediately", mtl_framegen_set(1) && !atomic_load(&g_native30_idle_until));
            CHECK("interpolation keeps the original iOS frame latency", link_latency() == 1);
        }
    }
    if (!off) CHECK("all keep-alive callbacks finish before final statistics", native30_idle_drain());
    native30_idle_diag(300);
    native30_idle_diag(600);
    printf("native shared presentation: %d checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
} }
