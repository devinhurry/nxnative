// Driver metadata must remain immutable for earlier draws and indirect dispatches.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static uint32_t word(id<MTLBuffer> b, uint64_t gpu, size_t offset) {
    uint32_t v; memcpy(&v, (const uint8_t *)b.contents + gpu - b.gpuAddress + offset, 4); return v;
}
int main(void) { @autoreleasepool {
    unsetenv("DM_NVN_DRV_CACHE");
    CHECK("metadata reuse remains opt-in", !driver_cache_on());
    setenv("DM_NVN_DRV_CACHE", "1", 1); g_driver_cache_on = -1;
    setenv("DM_NVN_DRV_CACHE_CHECK", "1", 1);
    mtl_init(); arena_begin(); NvShader *sh = [NvShader new];
    __unsafe_unretained id<MTLBuffer> a, b;
    S.ssbo[0][3].addr = 0x12345678; S.ssbo[0][3].size = 96; g_draw_binst = 7;
    uint64_t ga = driver_bank_gpu(0, 0, sh, &a), gb = driver_bank_gpu(0, 0, sh, &b);
    CHECK("unchanged graphics bindings reuse the allocation", ga == gb && g_driver_hit == 1);
    CHECK("storage address and size have the existing ABI", word(a, ga, 0x140) == 0x12345678 && word(a, ga, 0x148) == 96);
    CHECK("base instance is preserved", word(a, ga, 0x644) == 7);
    S.ssbo[0][3].addr++;
    gb = driver_bank_gpu(0, 0, sh, &b);
    CHECK("changed storage binding allocates new metadata", gb != ga && word(b, gb, 0x140) == 0x12345679);
    CHECK("earlier draw keeps the old address", word(a, ga, 0x140) == 0x12345678);
    g_draw_binst = 8; ga = driver_bank_gpu(0, 0, sh, &a);
    CHECK("different base instance cannot reuse the old bank", ga != gb && word(a, ga, 0x644) == 8);

    g_dispatch_dim[0] = 3; g_dispatch_dim[1] = 4; g_dispatch_dim[2] = 5;
    S.ubo[5][7].addr = 0x22334455; S.ubo[5][7].size = 144;
    ga = driver_bank_gpu(0, 5, sh, &a); gb = driver_bank_gpu(0, 5, sh, &b);
    CHECK("unchanged direct dispatch can reuse metadata", ga == gb && word(a, ga, 0x200) == 3);
    CHECK("compute uniform table retains its layout", word(a, ga, 0x280) == 0x22334455 && word(a, ga, 0x288) == 144);
    g_dispatch_dim[0] = 9; gb = driver_bank_gpu(0, 5, sh, &b);
    CHECK("dispatch size participates in the key", ga != gb && word(b, gb, 0x200) == 9 && word(a, ga, 0x200) == 3);
    S.ubo[5][7].size++; ga = driver_bank_gpu(0, 5, sh, &a);
    CHECK("compute uniform size participates in the key", ga != gb && word(a, ga, 0x288) == 145);
    g_dispatch_indirect = 1;
    gb = driver_bank_gpu(0, 5, sh, &b);
    CHECK("indirect dispatch owns a fresh bank", gb != ga && g_c0_dim_buf == b);
    memset((uint8_t *)g_c0_dim_buf.contents + g_c0_dim_off, 0x5a, 12);
    uint64_t gc = driver_bank_gpu(0, 5, sh, &b);
    CHECK("second indirect dispatch cannot overwrite the first", gc != gb);
    g_dispatch_indirect = 0; gc = driver_bank_gpu(0, 5, sh, &b);
    CHECK("GPU-patched indirect bank cannot poison the direct cache", gc == ga && word(b, gc, 0x200) == 9);

    S.tex[1][3] = 129 | (65ull << 20); S.samp[1][2] = 65ull << 20;
    ga = driver_bank_gpu(2, 1, sh, &a); gb = driver_bank_gpu(2, 1, sh, &b);
    CHECK("unchanged texture handles reuse metadata", ga == gb && word(a, ga, 0x38) == (129 | (65u << 20)));
    sh->rf.pool = 1; S.tex_base = 128; S.samp_base = 64;
    gb = driver_bank_gpu(2, 1, sh, &b);
    CHECK("pool bases and shader pool mode participate in the key", gb != ga && word(b, gb, 0x38) == (1 | (1u << 20)));
    CHECK("separate sampler handles use the same local base", word(b, gb, DMSH_C2_SAMP + 16) == 1u << 20);
    sh->rf.dyn = 1; ga = driver_bank_gpu(2, 1, sh, &a);
    CHECK("dynamic shader handles cannot reuse literal handles", ga != gb && word(a, ga, 0x38) == (3 | (3u << 20)));
    S.img[1][0] = 777; gb = driver_bank_gpu(2, 1, sh, &b);
    CHECK("image handles participate in the key", ga != gb && word(b, gb, DMSH_C2_IMG) == 777);
    S.tex[1][NVN_SEPTEX_SLOT0 + 10] = 150; ga = driver_bank_gpu(2, 1, sh, &a);
    CHECK("separate texture slots participate in the key", ga != gb && word(a, ga, DMSH_C2_SEPTEX + 80) == 10);
    g_driver_cache_on = 0; gb = driver_bank_gpu(2, 1, sh, &b);
    CHECK("uncached reference has identical bytes", ga != gb && !memcmp((uint8_t *)a.contents + ga - a.gpuAddress, (uint8_t *)b.contents + gb - b.gpuAddress, DMSH_DRV_SIZE));
    g_driver_cache_on = 1; uint64_t epoch = g_arena_epoch; arena_begin(); gb = driver_bank_gpu(2, 1, sh, &b);
    CHECK("a new submission cannot reuse reclaimed addresses", g_arena_epoch != epoch && ga != gb);
    CHECK("cache hits were checked against a fresh fill", g_driver_check >= 3);
    printf("t_driver_bank: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
