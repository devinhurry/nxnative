// Exercise the production full-picture interpolator without a game or window.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, s) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", s); } } while (0)
static void idle(void) {
    if (!g_fg_wq) return;
    for (;;) {
        __block int busy;
        dispatch_sync(g_fg_wq, ^{
            busy = g_fg_session && g_fg_session->in_flight;
            if (!busy) fg_jobs_clear();   // No display link in the headless fixture.
        });
        if (!busy) return;
        usleep(1000);
    }
}
static void session(NSUInteger w, NSUInteger h) {
    fg_queue_init(); dispatch_sync(g_fg_wq, ^{ fg_leave("fixture", 0); }); idle();
    dispatch_sync(g_fg_wq, ^{ F = (typeof(F)){0}; for (int i = 0; i < 40; i++) fg_session_start(w, h, MTLPixelFormatBGRA8Unorm, 10 + i / 30., 120); });
}
static id<MTLTexture> fixture(id<MTLTexture> source, const int crop[4], double time) {
    idle(); FgSession *s = g_fg_session; if (!s) return nil;
    uint64_t seq = atomic_fetch_add(&g_fg_source_seq, 1) + 1; FgSlot *slot = s->slots[seq % FG_SLOTS];
    atomic_store(&slot->busy, 1);
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> copy = [cb blitCommandEncoder];
    [copy copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(crop ? crop[0] : 0, crop ? crop[1] : 0, 0) sourceSize:MTLSizeMake(s->w, s->h, 1) toTexture:slot->texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [copy endEncoding]; [cb commit]; [cb waitUntilCompleted]; s->capture_event.signaledValue = seq;
    // Emulate the presenter having confirmed an original; no window or actual
    // presentation is invented, and the public displayed counter must stay zero.
    atomic_store(&slot->capture_status, FG_CAPTURE_OK);
    dispatch_sync(g_fg_wq, ^{ F.onscreen = 1; fg_on_capture(s, slot, seq, seq, time, 1. / 30, 120); }); idle();
    return s->gen[seq % FG_SLOTS];
}
static void fill(id<MTLTexture> t) {
    id<MTLCommandBuffer> cb = q_cb(); MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(.25, .5, .75, 1);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static void fill_content(id<MTLTexture> t, const int crop[4]) {
    NSUInteger bytes = t.width * t.height * 4;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    uint8_t *p = b.contents;
    for (NSUInteger y = 0; y < t.height; y++) for (NSUInteger x = 0; x < t.width; x++) {
        NSUInteger at = 4 * (y * t.width + x);
        int valid = x >= crop[0] && x < crop[0] + crop[2] && y >= crop[1] && y < crop[1] + crop[3];
        p[at] = valid ? 191 : 0; p[at + 1] = valid ? 128 : 0; p[at + 2] = valid ? 64 : 0; p[at + 3] = 255;
    }
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
    [en copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:t.width * 4 sourceBytesPerImage:bytes sourceSize:MTLSizeMake(t.width, t.height, 1)
             toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static int pixels(id<MTLTexture> t) {
    NSUInteger bytes = t.width * t.height * 4;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
    [en copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1)
              toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 4 destinationBytesPerImage:bytes];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint8_t *p = b.contents;
    for (NSUInteger i = 0; i < bytes; i += 4) if (abs(p[i] - 191) > 4 || abs(p[i + 1] - 128) > 4 || abs(p[i + 2] - 64) > 4 || p[i + 3] < 250) {
        fprintf(stderr, "pixel %lu = %u,%u,%u,%u\n", (unsigned long)(i / 4), p[i], p[i + 1], p[i + 2], p[i + 3]); return 0;
    }
    return 1;
}
static void moving_bar(id<MTLTexture> t, int left) {
    NSUInteger bytes = t.width * t.height * 4;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    uint8_t *p = b.contents;
    for (NSUInteger y = 0; y < t.height; y++) for (NSUInteger x = 0; x < t.width; x++) {
        NSUInteger at = 4 * (y * t.width + x); int white = x >= left && x < left + 20 && y >= 40 && y < 140;
        p[at] = p[at + 1] = p[at + 2] = white ? 255 : 0; p[at + 3] = 255;
    }
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
    [en copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:t.width * 4 sourceBytesPerImage:bytes sourceSize:MTLSizeMake(t.width, t.height, 1)
             toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
}
static double center(id<MTLTexture> t) {
    if (!t) return -1;
    NSUInteger bytes = t.width * t.height * 4;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> en = [cb blitCommandEncoder];
    [en copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1)
              toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 4 destinationBytesPerImage:bytes];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint8_t *p = b.contents; double sum = 0, weighted = 0;
    for (NSUInteger y = 40; y < 140; y++) for (NSUInteger x = 0; x < t.width; x++) { double value = p[4 * (y * t.width + x)]; sum += value; weighted += x * value; }
    return sum ? weighted / sum : -1;
}
static void lifecycle(void) {
    FgSession *old = [FgSession new], *current = [FgSession new];
    for (int i = 0; i < FG_SLOTS; i++) { old->slots[i] = [FgSlot new]; current->slots[i] = [FgSlot new]; }
    NSError *error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorNotPermitted userInfo:nil];
    dispatch_sync(g_fg_wq, ^{
        F = (typeof(F)){0}; old->epoch = atomic_fetch_add(&g_fg_gen, 1) + 1; old->in_flight = 1;
        g_fg_session = old; atomic_store(&g_fg_phase, FG_ACTIVE); atomic_store(&g_fg_requested, 1);
    });
    fg_suspend();
    dispatch_sync(g_fg_wq, ^{
        CHECK(atomic_load(&g_fg_phase) == FG_LEAVING, "background retires the active session");
        F.failed = 1; // A failure already recorded around the background transition.
    });
    dm_gfx_suspend(0); // Production foreground entry, without submitting GPU work.
    dispatch_sync(g_fg_wq, ^{
        CHECK(!F.failed && atomic_load(&g_fg_requested) == 1, "foreground rearms interpolation and preserves the enabled setting");
        F.leave_time = CACurrentMediaTime() - 3; fg_leave_check();
        CHECK(atomic_load(&g_fg_phase) == FG_NATIVE, "a delayed old session can hand back presentation");
        current->epoch = atomic_load(&g_fg_gen); current->in_flight = 1;
        g_fg_session = current; atomic_store(&g_fg_phase, FG_ACTIVE);
        __block int released = 0; fg_on_present_completed(old, error, ^{ released++; });
        CHECK(old->in_flight == 0 && released == 1, "retired feedback still releases its resources");
        CHECK(!F.failed && g_fg_session == current && atomic_load(&g_fg_phase) == FG_ACTIVE, "retired feedback cannot fail the resumed session");
        FgPresent *midpoint = [FgPresent new]; midpoint->session = current; atomic_store(&midpoint->gpu_done, 1);
        fg_on_presented(midpoint, NAN);
        CHECK(!F.recoveries && atomic_load(&g_fg_phase) == FG_ACTIVE, "an unshown midpoint with completed GPU work leaves originals scheduled");
        fg_on_present_completed(current, error, nil);
        CHECK(F.failed && atomic_load(&g_fg_phase) == FG_NATIVE, "a current-session GPU error still stops interpolation");
        atomic_store(&g_fg_requested, 0);
    });
    dm_gfx_suspend(0);
    dispatch_sync(g_fg_wq, ^{
        CHECK(!F.failed && atomic_load(&g_fg_requested) == 0 && atomic_load(&g_fg_phase) == FG_NATIVE, "foreground preserves the disabled setting");
        F = (typeof(F)){0}; atomic_store(&g_fg_requested, -1);
    });
}
static void presentation_timing(void) {
    double refresh = 1. / 120, mid = 60., original = mid + refresh;
    CHECK(fg_frame_for_update(mid, refresh, original, mid, 1, 1) == FG_TICK_GENERATED, "interpolation has the middle 120 Hz update");
    CHECK(fg_frame_for_update(mid, refresh, original, mid, 1, 0) == FG_TICK_EMPTY, "a late interpolation leaves its update empty");
    CHECK(fg_frame_for_update(original, refresh, original, mid, 1, 0) == FG_TICK_ORIGINAL, "capture-ready original presents while interpolation is outstanding");
    CHECK(fg_frame_for_update(original, refresh, original, mid, 1, 1) == FG_TICK_ORIGINAL, "a completed but late interpolation cannot take the original update");
    CHECK(fg_frame_for_update(original, refresh, original, mid, 0, 1) == FG_TICK_EMPTY, "an unavailable original prevents display of its midpoint");
    CHECK(fg_frame_for_update(original + refresh, refresh, original, mid, 1, 1) == FG_TICK_ORIGINAL, "a missing display update does not replay an expired midpoint");
    CHECK(fg_frame_for_update(mid + refresh, refresh, mid + 3 * refresh, mid, 1, 1) == FG_TICK_EMPTY, "an expired midpoint cannot use an unrelated refresh");

    double original_at = 0;
    int originals = 0, generated = 0;
    for (int tick = 1; tick <= 120; tick++) {
        double target = tick * refresh;
        int choice = fg_frame_for_update(target, refresh, original_at + 1. / 50, original_at + .5 / 50, 1, !generated);
        if (choice == FG_TICK_GENERATED) generated = 1;
        if (choice == FG_TICK_ORIGINAL) { originals++; original_at += 1. / 50; generated = 0; }
    }
    CHECK(originals == 50, "fractional source periods preserve 50 originals on 120 refreshes");
}
static void presentation_handoff(void) {
    dispatch_sync(g_fg_wq, ^{ F.refresh_ticks = 0; atomic_store(&g_fg_phase, FG_ACTIVE); });
    dispatch_suspend(g_fg_wq);
    dispatch_group_t caller = dispatch_group_create();
    dispatch_group_async(caller, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        double deadline = CACurrentMediaTime() + 1.;
        fg_display_update(nil, deadline, deadline, 120);
        fg_display_update(nil, deadline, deadline, 120);
    });
    int returned = dispatch_group_wait(caller, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) == 0;
    dispatch_resume(g_fg_wq);
    dispatch_group_wait(caller, DISPATCH_TIME_FOREVER);
    CHECK(returned, "the display callback returns while the frame-generation worker is busy");
    dispatch_sync(g_fg_wq, ^{
        CHECK(F.refresh_ticks == 1 && !atomic_load(&g_fg_update_pending), "the worker consumes at most one pending display update");
        atomic_store(&g_fg_phase, FG_NATIVE);
    });
}
int main(int argc, char **argv) { @autoreleasepool {
    NSUInteger w, h; id<MTLTexture> src = nil, generated = nil;
    fg_extent(1600, 900, &w, &h); CHECK(w == 1280 && h == 720, "900p selects the automatic 720p budget");
    fg_extent(1920, 1080, &w, &h); CHECK(w == 1920 && h == 1080, "1080p selects the automatic 1080p budget");
    fg_extent(960, 540, &w, &h); CHECK(w == 960 && h == 540, "smaller input is not upscaled");
    fg_queue_init(); dispatch_sync(g_fg_wq, ^{
        for (int i = 0; i < 40; i++) fg_observe(1 + i / 30., 120);
        CHECK(F.mode == 3 && fabs(F.fps - 30) < .01 && F.target == 60, "reference source estimator selects 30 to 60");
        double now = F.last;
        for (int i = 0; i < 60; i++) { now += i % 2 ? .021 : .045; fg_observe(now, 120); }
        CHECK(F.mode == 3 && F.target == 60 && F.fps > 29 && F.fps < 32, "45/21 ms source jitter does not stop interpolation");
        F = (typeof(F)){0}; for (int i = 0; i < 40; i++) fg_observe(1 + i / 60., 120);
        CHECK(F.mode == 3 && F.target == 120, "60 fps selects the 120 Hz tier");
        F = (typeof(F)){0}; for (int i = 0; i < 40; i++) fg_observe(1 + i / 60., 60);
        CHECK(F.mode != 3, "60 fps on a 60 Hz screen keeps original images");
    });
    presentation_timing(); presentation_handoff(); lifecycle();
    if (argc > 1 && !strcmp(argv[1], "--cpu")) goto done;
    mtl_init(); if (!mtl_framegen_supported()) { fprintf(stderr, "SKIP: MetalFX frame interpolation unavailable\n"); goto done; }
    CHECK(mtl_framegen_set(1), "supported GPU accepts frame generation");
    session(320, 180); CHECK(g_fg_session != nil, "reference startup creates a session asynchronously");
    src = fg_mfx_tex(MTLPixelFormatBGRA8Unorm, 320, 180, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"fixture"); res_commit(); fill(src);
    for (int i = 0; i < 16; i++) generated = fixture(src, NULL, 20 + i / 30.);
    CHECK(generated && pixels(generated), "production interpolation preserves constant colour");
    CHECK(mtl_framegen_present_count() == 0, "headless encoding is not counted as on-screen output");
    res_remove(src); session(384, 180);
    src = fg_mfx_tex(MTLPixelFormatBGRA8Unorm, 384, 180, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"moving wide fixture"); res_commit();
    for (int i = 0; i < 16; i++) { moving_bar(src, 40 + 8 * i); generated = fixture(src, NULL, 30 + i / 30.); }
    CHECK(generated && fabs(center(generated) - (center(src) - 4)) < 3, "moving image is interpolated between its real neighbours");
    res_remove(src); session(1280, 720);
    src = fg_mfx_tex(MTLPixelFormatBGRA8Unorm, 1920, 1080, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"cropped fixture"); res_commit();
    int crop[4] = {64, 32, 1280, 720}; fill_content(src, crop);
    for (int i = 0; i < 16; i++) generated = fixture(src, crop, 40 + i / 30.);
    CHECK(generated && generated.width == 1280 && generated.height == 720 && pixels(generated), "valid cropped picture is preserved");
    CHECK(mtl_framegen_set(0), "interpolation can be switched off"); idle();
    dispatch_sync(g_fg_wq, ^{ fg_leave_check(); }); CHECK(atomic_load(&g_fg_phase) == FG_NATIVE, "leaving returns ownership to the native presenter");
    res_remove(src); res_commit();
done:
    printf("t_framegen: %d checks, %d failed\n", checks, failed); return failed != 0;
}}
