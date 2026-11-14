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
    for (;;) { __block int busy; dispatch_sync(g_fg_wq, ^{ busy = F.count || (g_fg_session && g_fg_session->in_flight); }); if (!busy) return; usleep(1000); }
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
    dispatch_sync(g_fg_wq, ^{ F.onscreen = 1; fg_on_capture(s, slot, seq, seq, time, 120); }); idle();
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
