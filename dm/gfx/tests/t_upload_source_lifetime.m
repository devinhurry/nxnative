// Upload-only views must retire after the last upload, even while the main
// rendering submission remains open. Exercise shared ownership across batches.
#include "../nvn/nvn_mtl.m"
#include "../../host/file_backed_heap.h"
#include <assert.h>
#include <sys/mman.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fails;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); fails++; } } while (0)
static size_t resident(void *p, size_t n) {
    size_t page = (size_t)getpagesize(), count = 0;
    char *v = calloc(n / page, 1); assert(v && !mincore(p, n, v));
    for (size_t i = 0; i < n / page; i++) count += !!(v[i] & MINCORE_INCORE);
    free(v); return count * page;
}
int main(void) { @autoreleasepool {
    setenv("DM_LOW_MEMORY", "1", 1);
    setenv("DM_NVN_TRANSIENT_UPLOADS", "1", 1);
    const size_t n = 64u << 20; const char *dir = getenv("TMPDIR");
    size_t page = (size_t)getpagesize();
    if (!dir) dir = "/tmp";
    void *mem = mmap(NULL, n + page, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(mem != MAP_FAILED && !dm_file_heap_back(mem, n + page, dir));
    assert(!mprotect(mem, n + page, PROT_READ | PROT_WRITE));
    uint32_t *data = mem;
    for (size_t i = 0; i < n / 4; i++) data[i] = (uint32_t)i * 2654435761u;
    for (size_t i = n / 4; i < (n + page) / 4; i++) data[i] = 0xff332211u;
    mtl_pool_add(mem, n + page);
    id<MTLBuffer> dst = [g_dev newBufferWithLength:n * 2 options:MTLResourceStorageModeShared];
    assert(dst); res_add(dst);
    mtl_sub_begin();
    uint64_t off; NvUploadSource *source = up_source_new(mem, n, &off);
    __weak NvUploadSource *observed_owner = source;
    __weak id<MTLBuffer> observed = source->buffer;
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:gate value:1]; // hold both batches in flight deterministically
    for (int i = 0; i < 2; i++) {
        up_begin(); up_source_use(source);
        enc_b_copy_buffer(g_up_ce, source->buffer, off, dst, i * n, n);
        up_flush();
        @autoreleasepool { CHECK(observed != nil); }
    }
    CHECK(g_pool_res_n == 0); // the full NVN pool was never promoted
    source = nil;
    CHECK(atomic_load(&g_up_source_bytes) == n);
    @autoreleasepool { CHECK(observed_owner != nil); }
    // The actual packaged-texture upload path must use a temporary source too,
    // rather than passing only the lower-level ownership fixture above.
    tex_t tex = {0};
    tex.d = (nvn_texdesc){.target=1, .format=0x25, .samples=1, .width=8, .height=4, .depth=1, .levels=1};
    nvn_tex_layout(&tex.d, &tex.L); assert(tex.L.size <= page);
    tex.mem = (uint8_t *)mem + n;
    id<MTLTexture> packaged = pkg_upload_(&tex, NULL, nil, 0);
    CHECK(packaged != nil); CHECK(atomic_load(&g_up_source_bytes) > n);
    up_flush(); CHECK(g_pool_res_n == 0);
    gate.signaledValue = 1;
    rec_publish(); up_wait_zero(&g_up_pending, WS_DIAG);
    CHECK(atomic_load(&g_up_source_bytes) == 0);
    @autoreleasepool { CHECK(observed_owner == nil); }
    CHECK(g_cb != nil); // source retirement did not wait for the rendering fence
    uint32_t *out = dst.contents;
    for (size_t i = 0; i < n / 4; i++) {
        if (out[i] != data[i] || out[n / 4 + i] != data[i]) { CHECK(0); break; }
    }
    @autoreleasepool {
        id<MTLBuffer> pixels = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
        [enc copyFromTexture:packaged sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,4,1)
                   toBuffer:pixels destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted);
        const uint32_t *p = pixels.contents;
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) CHECK(p[y * 64 + x] == 0xff332211u);
    }
    res_commit();
    // Observe asynchronous driver teardown, not a timing-based host policy.
    double until = CACurrentMediaTime() + 2;
    size_t remaining;
    do {
        CHECK(!msync(mem, n, MS_SYNC | MS_INVALIDATE));
        remaining = resident(mem, n);
        if (remaining) usleep(10000);
    } while (remaining && CACurrentMediaTime() < until);
    CHECK(remaining == 0);
    CHECK(g_cb != nil); // real page eviction also precedes the rendering fence
    printf("upload source after completion: %zu MiB resident; %d failures\n", remaining >> 20, fails);
    for (size_t i = 0; i < n / 4; i++) if (data[i] != (uint32_t)i * 2654435761u) { CHECK(0); break; }
    uint64_t fence = mtl_sub_commit(); CHECK(mtl_wait(fence, 5000000000ull));
    CHECK(!mtl_last_commit_error());
    return fails ? 1 : 0;
} }
