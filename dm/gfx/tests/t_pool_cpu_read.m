// Off retains the original CPU lookup's GPU residency; on avoids promoting it.
// Both modes must read the same bytes and allow a later GPU lookup.
#include "../nvn/nvn_mtl.m"
#include "../../host/file_backed_heap.h"
#include <assert.h>
#include <sys/mman.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int failures;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); failures++; } } while (0)
static size_t resident(void *p, size_t n) {
    size_t page = (size_t)getpagesize(), count = 0;
    char *v = calloc(n / page, 1); assert(v && !mincore(p, n, v));
    for (size_t i = 0; i < n / page; i++) count += !!(v[i] & MINCORE_INCORE);
    free(v); return count * page;
}
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2 && (!strcmp(argv[1], "on") || !strcmp(argv[1], "off")));
    int experiment = !strcmp(argv[1], "on");
    CHECK(up_transient_sources() == experiment);
    const size_t n = 64u << 20; const char *dir = getenv("TMPDIR");
    if (!dir) dir = "/tmp";
    void *mem = mmap(NULL, n, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(mem != MAP_FAILED && !dm_file_heap_back(mem, n, dir));
    assert(!mprotect(mem, n, PROT_READ | PROT_WRITE));
    uint32_t *data = mem;
    for (size_t i = 0; i < n / 4; i++) data[i] = (uint32_t)i * 2654435761u;
    mtl_pool_add(mem, n);
    CHECK((g_pools[0].buf == nil) == experiment);
    if (experiment) {
        CHECK(g_pools[0].buf == nil);
        // A source-only pool may be finalized without ever creating a buffer.
        mtl_pool_add((uint8_t *)mem + n - getpagesize(), getpagesize());
        mtl_pool_del((uint8_t *)mem + n - getpagesize());
        CHECK(g_npool == 1 && g_pools[0].buf == nil);
    }
    uint64_t addr = (uintptr_t)mem;
    S.ubo[0][0].addr = addr + 32; S.ubo[0][0].size = 16;
    uint32_t out[4]; ubo_read(0, 0, 0, sizeof out, out);
    CHECK(!memcmp(out, data + 8, sizeof out));
    tex_t tex = {0}; tex.mem = (uint8_t *)mem + 64; tex.L.size = 16;
    CHECK(tex_storage_live(&tex));
    CHECK(g_pool_res_n == (experiment ? 0 : 1));
    CHECK((pc_get(addr + 32, 16) == NULL) == experiment);
    // Committing unrelated work activates the queue's residency set, as happens
    // every frame in a game. Merely adding to an inactive set may not pin yet.
    mtl_sub_begin(); uint64_t fence = mtl_sub_commit();
    CHECK(mtl_wait(fence, 5000000000ull)); CHECK(!mtl_last_commit_error());
    CHECK(!msync(mem, n, MS_SYNC | MS_INVALIDATE));
    size_t cold = resident(mem, n);
    printf("CPU-only pool: %zu MiB resident after eviction\n", cold >> 20);
    CHECK(experiment ? cold == 0 : cold == n);
    // Both lookup modes preserve the bytes. Only the experimental CPU-only
    // lookup avoids residency and leaves the GPU fast-path cache empty.
    ubo_read(0, 0, 0, sizeof out, out);
    for (int i = 0; i < 4; i++) CHECK(out[i] == (uint32_t)(i + 8) * 2654435761u);
    CHECK(g_pool_res_n == (experiment ? 0 : 1));
    void *buffer; uint64_t off, gpu;
    CHECK(mtl_gpu_addr(addr + 32, 16, &buffer, &off, &gpu));
    CHECK(g_pool_res_n == 1);
    CHECK((uint8_t *)[(__bridge id<MTLBuffer>)buffer contents] + off == (uint8_t *)mem + 32);
    CHECK(gpu == [(__bridge id<MTLBuffer>)buffer gpuAddress] + off);
    ubo_read(0, 0, 0, sizeof out, out); CHECK(g_pool_res_n == 1);
    mtl_pool_del(mem);
    memset(out, 0xff, sizeof out); ubo_read(0, 0, 0, sizeof out, out);
    CHECK(out[0] == 0 && out[1] == 0 && out[2] == 0 && out[3] == 0);
    CHECK(!tex_storage_live(&tex));
    // No GPU commands were submitted. Keep backing until process teardown,
    // since the host intentionally defers pool destruction to a later fence.
    printf("CPU pool lookup (%s): %d failures\n", argv[1], failures);
    return failures ? 1 : 0;
} }
