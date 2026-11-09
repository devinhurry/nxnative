// mtl_addr_known answers whether a range lies in one memory pool as mtl_addr finds it, with no side effect: hle_nvn.c keys_hash asks it whether a shader's code is mapped, and
// through mtl_addr every pool holding shader code went into the residency set though the GPU never reads it (docs/reference/memory.md). A large pool (BIG_MIN or more)
// is answered from its range: its lookup would make a chunk buffer over the range
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static int pool_resident(uint64_t a) { pthread_mutex_lock(&g_mu); int i = pool_find(a, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
int main(void) { @autoreleasepool {
    mtl_init();
    const size_t n = 4u << 20;
    uint8_t *mem = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    uint64_t base = (uint64_t)(uintptr_t)mem;
    mtl_pool_add(mem, n);
    int res0 = g_pool_res_n;
    CHECK("a range inside the pool is known", mtl_addr_known(base + 4096, 2048));
    CHECK("the pool's last bytes are known", mtl_addr_known(base + n - 16, 16));
    CHECK("a range past the pool's end is not", !mtl_addr_known(base + n - 16, 32));
    CHECK("an address outside every pool is not", !mtl_addr_known(base + n + 4096, 16));
    CHECK("asking makes no pool resident", g_pool_res_n == res0 && !pool_resident(base));
    void *mb = NULL; uint64_t mo = 0;
    CHECK("mtl_addr finds the same range", mtl_addr(base + 4096, 2048, &mb, &mo) && mo == 4096);
    CHECK("mtl_addr makes the pool resident (what keys_hash did)", g_pool_res_n == res0 + 1 && pool_resident(base));
    mtl_pool_del(mem);
    CHECK("a removed pool holds nothing", !mtl_addr_known(base + 4096, 2048));

    // CPU-only reads in low-memory mode must not make a Metal buffer or pin the pool.
    // A later real GPU lookup must still create it and produce the correct address.
    uint8_t *cpu_mem = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (cpu_mem == MAP_FAILED) abort();
    uint64_t cpu_addr = (uint64_t)(uintptr_t)cpu_mem; uint32_t pattern[4] = {0x12345678, 0x9abcdef0, 0x76543210, 0x13579bdf};
    memcpy(cpu_mem + 32, pattern, sizeof pattern);
    mtl_pool_add(cpu_mem, n);
    int low = lowmem_cpu_lookups(), ci = pool_find(cpu_addr, 1), before = g_pool_res_n;
    CHECK("CPU pool registered", ci >= 0);
    CHECK("low-memory pool buffer is lazy", !!g_pools[ci].buf == !low);
    S.ubo[0][0].addr = cpu_addr + 32; S.ubo[0][0].size = sizeof pattern;
    uint32_t out[4] = {0}; ubo_read(0, 0, 0, sizeof out, out);
    CHECK("CPU uniform lookup reads the original bytes", !memcmp(out, pattern, sizeof out));
    CHECK("CPU lookup respects the selected residency mode", g_pool_res_n == before + !low);
    CHECK("out-of-range CPU address rejected", !mtl_cpu_ptr(cpu_addr + n - 8, 16));
    CHECK("overflowing CPU address rejected", !mtl_cpu_ptr(UINT64_MAX - 3, 8));
    uint64_t gpu = 0;
    CHECK("later GPU lookup succeeds", mtl_gpu_addr(cpu_addr + 32, sizeof pattern, &mb, &mo, &gpu));
    CHECK("later GPU lookup makes the pool resident", g_pool_res_n == before + 1);
    CHECK("later GPU view points to the original bytes", (uint8_t *)[(__bridge id<MTLBuffer>)mb contents] + mo == cpu_mem + 32);
    CHECK("later GPU address matches its view", gpu == [(__bridge id<MTLBuffer>)mb gpuAddress] + mo);
    mtl_pool_del(cpu_mem);
    memset(out, 0xff, sizeof out); ubo_read(0, 0, 0, sizeof out, out);
    uint32_t zero[4] = {0}; CHECK("removed pool cannot be read", !memcmp(out, zero, sizeof out));
    uint8_t *never_used = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (never_used == MAP_FAILED) abort();
    mtl_pool_add(never_used, n); mtl_pool_del(never_used);
    CHECK("an unused pool can be removed", !mtl_addr_known((uint64_t)(uintptr_t)never_used, 1));

    // A large pool: anonymous pages, untouched, so its size costs nothing
    const size_t nb = (size_t)BIG_MIN + (32u << 20);
    uint8_t *big = mmap(NULL, nb, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (big == MAP_FAILED) abort();
    uint64_t bb = (uint64_t)(uintptr_t)big;
    mtl_pool_add(big, nb);
    int np0 = g_npool, rb0 = g_pool_res_n;
    CHECK("the large pool is in chunks", big_of(bb) >= 0);
    CHECK("a range in the large pool is known", mtl_addr_known(bb + (100u << 20), 4096));
    CHECK("the large pool's last bytes are known", mtl_addr_known(bb + nb - 16, 16));
    CHECK("a range past the large pool's end is not", !mtl_addr_known(bb + nb - 16, 32));
    CHECK("asking makes no chunk and nothing resident", g_npool == np0 && g_pool_res_n == rb0);
    CHECK("mtl_addr makes a chunk for the same range", mtl_addr(bb + (100u << 20), 4096, &mb, &mo) && g_npool == np0 + 1);
    mtl_pool_del(big);
    printf("t_addr_known: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
