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
    pthread_mutex_lock(&g_pq_mu); while (fg_busy()) pthread_cond_wait(&g_pq_cv, &g_pq_mu); pthread_mutex_unlock(&g_pq_mu);
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
    NSUInteger w, h;
    id<MTLTexture> src = nil, generated = nil;
    CHECK(fg_rate_fits(1. / 30, 60) && fg_rate_fits(1. / 60, 120), "30-to-60 and 60-to-120 fit whole screen refreshes");
    CHECK(!fg_rate_fits(1. / 60, 60) && !fg_rate_fits(1. / 20, 60), "a missing or fractional midpoint refresh keeps the original cadence");
    CHECK(!fg_rate_fits(NAN, 120) && !fg_rate_fits(0, 120), "invalid frame periods never reach MetalFX");
    fg_extent(1600, 900, &w, &h); CHECK(w == 1280 && h == 720, "below 1080p automatically uses the 720p budget");
    fg_extent(1920, 1080, &w, &h); CHECK(w == 1920 && h == 1080, "1080p input automatically uses the 1080p budget");
    fg_extent(1920, 1078, &w, &h); CHECK(fg_limit(1920, 1078) == 720 && w * h <= 1280u * 720u, "just below 1080p keeps the lower budget");
    fg_extent(2560, 1440, &w, &h); CHECK(w == 1920 && h == 1080, "larger inputs stay within the automatic 1080p budget");
    fg_extent(2868, 1320, &w, &h); CHECK(w * h <= 1920u * 1080u && fabs((double)w / h - 2868. / 1320) < .005, "wide picture keeps its aspect within the memory budget");
    fg_extent(960, 540, &w, &h); CHECK(w == 960 && h == 540, "540p input stays at 540p");
    fg_extent(320, 180, &w, &h); CHECK(w == 320 && h == 180, "small input is never upscaled for interpolation");
    for (int i = 0; i < 10; i++) { int ready = fg_cadence(1 + i / 30., 1. / 30); CHECK(i == 6 || ready == (i > 6), "cadence must settle before showing generated images"); }
    CHECK(!fg_cadence(5, 1. / 30) && !g_fg.history, "a loading gap discards history");
    atomic_store(&g_fg_reset, 1); CHECK(!fg_cadence(5 + 1. / 30, 1. / 30), "an explicit reset restarts warmup");
    if (argc > 1 && !strcmp(argv[1], "--cpu")) goto done;
    mtl_init();
    if (!mtl_framegen_supported()) { fprintf(stderr, "SKIP: MetalFX frame interpolation unavailable\n"); goto done; }
    CHECK(mtl_framegen_set(1), "supported GPU accepts frame generation");
    src = fg_texture(MTLPixelFormatBGRA8Unorm, 320, 180, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"fixture"); res_commit(); fill(src);
    for (int i = 0; i < 12; i++) { generated = fg_prepare(src, NULL, 1. / 30, 10 + i / 30., 120); idle(); }
    CHECK(generated != nil && g_fg_generated > 0, "settled inputs produce a real MetalFX output");
    CHECK(generated && pixels(generated), "every generated pixel preserves the known BGRA colour");
    CHECK(mtl_framegen_present_count() == 0, "encoding an output alone is not counted as an on-screen generated frame");
    res_remove(src);
    src = fg_texture(MTLPixelFormatBGRA8Unorm, 384, 180, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"wide moving fixture"); res_commit();
    for (int i = 0; i < 12; i++) { moving_bar(src, 40 + 12 * i); generated = fg_prepare(src, NULL, 1. / 30, 15 + i / 30., 120); idle(); }
    double middle = center(generated), actual = center(src);
    fprintf(stderr, "moving wide image: generated center %.3f, current %.3f, expected midpoint %.3f\n", middle, actual, actual - 6);
    CHECK(generated && generated.width == 384 && generated.height == 180, "the GPU preserves a wide picture without cropping to 16:9");
    CHECK(fabs(middle - (actual - 6)) < 3, "a moving object is generated between the two input positions, rather than repeating the current picture");
    res_remove(src);
    src = fg_texture(MTLPixelFormatBGRA8Unorm, 1920, 1080, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, @"cropped window fixture"); res_commit();
    int crop[4] = {64, 32, 1280, 720}; fill_content(src, crop);
    for (int i = 0; i < 12; i++) { generated = fg_prepare(src, crop, 1. / 30, 25 + i / 30., 120); idle(); }
    CHECK(generated && generated.width == 1280 && generated.height == 720, "a 720p valid picture in a 1080p allocation selects 720p automatically");
    CHECK(generated && pixels(generated), "the capture contains only the valid crop, without its surrounding padding");
    fill(src);
    for (int i = 0; i < 12; i++) { generated = fg_prepare(src, NULL, 1. / 30, 30 + i / 30., 120); idle(); }
    CHECK(generated && generated.width == 1920 && generated.height == 1080, "a full 1080p picture automatically selects 1080p");
    CHECK(generated && pixels(generated), "automatic 1080p output preserves the complete picture");
    CHECK(!fg_prepare(src, NULL, 1. / 30, 50, 120), "the first image after a loading gap stays real-only"); idle();
    CHECK(!fg_prepare(src, NULL, 1. / 60, 51, 60) && g_fg.fi, "a temporary rate mismatch skips interpolation without rebuilding its cached session");
    CHECK(mtl_framegen_set(0) && !mtl_framegen_enabled(), "turning interpolation off restores the real-frame path");
    CHECK(!fg_prepare(src, NULL, 1. / 30, 52, 120) && !g_fg.fi, "turning interpolation off releases its scratch buffers after GPU completion");
    res_remove(src); res_commit();
done:
    printf("t_framegen: %d checks, %d failed\n", checks, failed); return failed != 0;
}}
