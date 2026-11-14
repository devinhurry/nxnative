// Uploads from a large pool (BIG_MIN) read their storage through a zero-copy buffer of the upload batch (up_big_src), which the batch makes resident and retires. One texture
// needs one such buffer: a second is made only when taking its staging flushed the batch that held the first. Before, every staged upload made two, and a scene load of Switch
// Sports Resort (855 textures, 908 MB) added twice its storage to the residency set. Checks the count and every texel, for small textures in one batch and for 64 MB ones whose
// staging splits the batches (UP_BATCH_BYTES). CPU-repacked textures also verify
// small uploads are batched within UP_BLOCK_SIZE and oversized stages stay alone.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

enum { POOL_SIZE = 768u << 20 };

typedef struct { tex_t t; uint8_t *ref; size_t bytes; } upl;

static void make(upl *u, uint8_t *pool_mem, pool_t *pool, size_t off, NVNformat format, unsigned w, unsigned h, unsigned seed) {
    static uint64_t serial = 77000;
    memset(u, 0, sizeof *u);
    u->t = (tex_t){.magic = MAGIC('T', 'E', 'X', 0), .has_layout = 1, .serial = serial++};
    u->t.d = (nvn_texdesc){.target = 1, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&u->t.d, &u->t.L);
    u->t.pool = pool; u->t.mem = pool_mem + off; u->t.off = off;
    int bw, bh, bpp = nvn_fmt_bpb(format, &bw, &bh);
    u->bytes = (size_t)w * h * bpp;
    u->ref = malloc(u->bytes);
    uint32_t *p = (uint32_t *)u->ref;
    for (size_t i = 0; i < u->bytes / 4; i++) p[i] = (uint32_t)(i * 2654435761u + seed * 40503u);
    dm_guest_write_prepare(u->t.mem, u->t.L.size);
    CHECK("reference swizzle succeeds", !nvn_swizzle(&u->t.d, 0, 0, u->ref, w * bpp, u->t.mem));
}

static int same_texels(id<MTLTexture> tex, const upl *u) {
    unsigned w = u->t.d.width, h = u->t.d.height;
    int bw, bh, bpp = nvn_fmt_bpb(u->t.d.format, &bw, &bh);
    id<MTLBuffer> rb = [g_dev newBufferWithLength:u->bytes options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> ce = [cb blitCommandEncoder];
    [ce copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:w * bpp destinationBytesPerImage:u->bytes];
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int shift = rb_packed_shift(u->t.d.format);
    if (shift) rb_swap_rows(rb.contents, w * bpp, h, 1, w * bpp, u->bytes, shift);
    return cb.status == MTLCommandBufferStatusCompleted && !memcmp(rb.contents, u->ref, u->bytes);
}

// Uploads n textures in one submission; returns the zero-copy source buffers made and the upload batches begun
static uint64_t g_submit_ns, g_complete_ns;
static void upload_all(upl *u, int n, uint64_t *made, unsigned *batches) {
    uint64_t m0 = g_up_src_made; unsigned s0 = g_up_seq;
    uint64_t start = bp_now();
    mtl_sub_begin();
    id<MTLTexture> got[16];
    for (int i = 0; i < n; i++) { got[i] = tex_mtl(&u[i].t); CHECK("texture resolves", got[i] != nil); }
    uint64_t fence = mtl_sub_commit(); g_submit_ns = bp_now() - start;
    CHECK("submission completes", mtl_wait(fence, 10000000000ull)); g_complete_ns = bp_now() - start;
    CHECK("no GPU error", !mtl_last_commit_error());
    *made = g_up_src_made - m0; *batches = g_up_seq - s0;
    for (int i = 0; i < n; i++) CHECK("every texel matches the CPU reference", got[i] && same_texels(got[i], &u[i]));
}

static int compare_ns(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return (x > y) - (x < y); }
static void cpu_cost(upl *u) {
    enum { WARM = 4, SAMPLES = 12 }; uint64_t submit[SAMPLES], complete[SAMPLES], made; unsigned batches = 0;
    for (int r = 0; r < WARM + SAMPLES; r++) {
        for (int i = 0; i < 8; i++) {
            u[i].ref[0] ^= (uint8_t)(r + 1);
            dm_guest_write_prepare(u[i].t.mem, u[i].t.L.size);
            CHECK("CPU benchmark swizzle succeeds", !nvn_swizzle(&u[i].t.d, 0, 0, u[i].ref, u[i].t.d.width * 2, u[i].t.mem));
        }
        upload_all(u, 8, &made, &batches);
        if (r >= WARM) { submit[r - WARM] = g_submit_ns; complete[r - WARM] = g_complete_ns; }
    }
    qsort(submit, SAMPLES, sizeof *submit, compare_ns); qsort(complete, SAMPLES, sizeof *complete, compare_ns);
    printf("CPU 8-texture re-upload median: submit %.3f ms, to GPU completion %.3f ms, %u batches per submission\n",
           submit[SAMPLES / 2] / 1e6, complete[SAMPLES / 2] / 1e6, batches);
}

int main(void) { @autoreleasepool {
    mtl_init();
    CHECK("GPU deswizzle is available", g_nvn_deswz_gpu);
    uint8_t *mem = mmap(NULL, POOL_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (mem == MAP_FAILED) abort();
    pool_t pool = {.magic = MAGIC('P', 'O', 'O', 'L'), .mem = mem, .size = POOL_SIZE, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    mtl_pool_add(mem, POOL_SIZE); nvn_dirty_add_range(mem, POOL_SIZE);

    upl small[8]; uint64_t made; unsigned batches;
    for (int i = 0; i < 8; i++) make(&small[i], mem, &pool, (size_t)i << 20, NVN_FORMAT_RGBA8, 256, 128 + 16 * i, i);
    upload_all(small, 8, &made, &batches);
    printf("small: %llu source buffers for 8 textures, %u batches\n", (unsigned long long)made, batches);
    CHECK("one zero-copy source buffer per texture in one batch", made == 8 && batches == 1);

    upl big[3];   // 64 MB each: the third's staging no longer fits the batch's 128 MB, so taking it flushes the batch
    for (int i = 0; i < 3; i++) make(&big[i], mem, &pool, (size_t)(16 + 72 * i) << 20, NVN_FORMAT_RGBA8, 4096, 4096, 100 + i);
    upload_all(big, 3, &made, &batches);
    printf("big: %llu source buffers for 3 textures, %u batches\n", (unsigned long long)made, batches);
    CHECK("staging splits the batches", batches >= 2);
    CHECK("a second source buffer only for a texture whose staging flushed its batch", made == 3 + (batches - 1));

    for (int i = 0; i < 8; i++) { mtl_tex_release(&small[i].t); free(small[i].ref); }
    for (int i = 0; i < 3; i++) { mtl_tex_release(&big[i].t); free(big[i].ref); }
    mtl_drain();

    // RGB565 always takes the CPU path: its packed components must be reordered.
    // Small uploads share a batch within UP_BLOCK_SIZE; larger stages commit alone.
    upl cpu[8];
    for (int i = 0; i < 8; i++) make(&cpu[i], mem, &pool, (size_t)i << 20, NVN_FORMAT_RGB565, 256, 128 + 16 * i, 200 + i);
    upload_all(cpu, 8, &made, &batches);
    printf("CPU small: %u batches for 8 textures\n", batches);
    CHECK("CPU uploads share one batch", batches == 1 && made == 0);
    cpu_cost(cpu);
    for (int i = 0; i < 8; i++) { mtl_tex_release(&cpu[i].t); free(cpu[i].ref); }
    mtl_drain();
    for (int i = 0; i < 3; i++) make(&cpu[i], mem, &pool, (size_t)(16 + 72 * i) << 20, NVN_FORMAT_RGB565, 2048, 4096, 300 + i);
    upload_all(cpu, 3, &made, &batches);
    printf("CPU bounded: %u batches for 3 x 16 MiB textures\n", batches);
    CHECK("CPU upload staging splits at one block's byte budget", batches == 2 && made == 0);
    for (int i = 0; i < 3; i++) { mtl_tex_release(&cpu[i].t); free(cpu[i].ref); }
    mtl_drain();
    for (int i = 0; i < 3; i++) make(&cpu[i], mem, &pool, (size_t)(16 + 72 * i) << 20, NVN_FORMAT_RGB565, 4096, 8192, 300 + i);
    upload_all(cpu, 3, &made, &batches);
    printf("CPU big: %u batches for 3 x 64 MiB textures\n", batches);
    CHECK("oversized CPU upload stages each commit alone", batches == 3 && made == 0);
    for (int i = 0; i < 3; i++) { mtl_tex_release(&cpu[i].t); free(cpu[i].ref); }
    mtl_drain(); mtl_alias_drop_pool(&pool); nvn_dirty_remove_range(mem); mtl_pool_del(mem); mtl_drain(); munmap(mem, POOL_SIZE);
    printf("t_upload_src: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
