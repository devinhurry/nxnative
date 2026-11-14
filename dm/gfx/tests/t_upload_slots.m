// Exercise staging reuse with several batches in flight. Distinct edge bytes
// in every allocation detect aliasing within a batch and reuse before a read.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
static int fill_staging;
#define CHECK(label,c) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
enum { BATCHES = 24, RANGES = 4, EDGE = 256, BYTES = BATCHES * RANGES * 2 * EDGE };
static void batch(unsigned batch, const size_t *sizes, unsigned count, id<MTLBuffer> input, id<MTLBuffer> output) {
    up_begin();
    id<MTLBuffer> blocks[RANGES]; size_t offsets[RANGES];
    for (unsigned i = 0; i < count; i++) {
        size_t off; id<MTLBuffer> b = up_alloc(sizes[i], &off);
        blocks[i] = b; offsets[i] = off;
        if (fill_staging) [g_up_ce fillBuffer:b range:NSMakeRange(off, sizes[i]) value:0x5a];
        CHECK("allocation fits its block", off + sizes[i] <= b.length);
        CHECK("staging offset is aligned", !(off & 255));
        for (unsigned j = 0; j < i; j++) CHECK("same-batch ranges do not overlap", b != blocks[j] || off >= offsets[j] + sizes[j] || offsets[j] >= off + sizes[i]);
        size_t at = (batch * RANGES + i) * 2 * EDGE;
        enc_b_copy_buffer(g_up_ce, input, at, b, off, EDGE);
        enc_b_copy_buffer(g_up_ce, input, at + EDGE, b, off + sizes[i] - EDGE, EDGE);
        [g_up_ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
        enc_b_copy_buffer(g_up_ce, b, off, output, at, EDGE);
        enc_b_copy_buffer(g_up_ce, b, off + sizes[i] - EDGE, output, at + EDGE, EDGE);
    }
    up_flush();
}
static size_t cache_bytes(void) {
    size_t n = 0; for (unsigned i = 0; i < 3; i++) n += g_up_slot_blk[i].length + g_up_slot_over[i].length; return n;
}
static uint64_t footprint(void) {
    task_vm_info_data_t t = {0}; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    return task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&t, &n) == KERN_SUCCESS ? t.phys_footprint : 0;
}
int main(void) { @autoreleasepool {
    mtl_init();
    id<MTLBuffer> input = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    res_add(input); res_add(output);
    for (unsigned i = 0; i < BYTES; i++) ((uint8_t *)input.contents)[i] = (uint8_t)((i / EDGE) * 37 + i * 13 + 1);
    memset(output.contents, 0, BYTES);
    const size_t normal[] = {512, 24u << 20, 24u << 20};
    const size_t burst[] = {512, 24u << 20, 24u << 20, 24u << 20};
    const size_t oversized[] = {UP_BLOCK_SIZE + 256};
    uint64_t warmed = 0;
    mtl_sub_begin();
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:gate value:1];
    for (unsigned i = 0; i < BATCHES; i++) {
        if (i == 3) {
            CHECK("first slot still has pending GPU work", atomic_load(&g_up_alloc_busy[0]));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100000000), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ gate.signaledValue = 1; });
        }
        batch(i, i == BATCHES - 2 ? burst : i == BATCHES - 1 ? oversized : normal,
              i == BATCHES - 2 ? 4 : i == BATCHES - 1 ? 1 : 3, input, output);
        if (i == 3) CHECK("slot reuse waited for its pending upload", gate.signaledValue == 1);
        if (i == 5) warmed = g_up_blocks_new;
        if (i == BATCHES - 3) CHECK("warm batches avoid new staging allocations", up_reuse() ? g_up_blocks_new == warmed : g_up_blocks_new > warmed);
        // Drain periodically even in the baseline: its temporary allocations
        // are retired by submission fences, not just upload slot completion.
        if (i % 9 == 8 || i + 1 == BATCHES) {
            CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
            CHECK("GPU has no submission error", !mtl_last_commit_error());
            if (i + 1 < BATCHES) mtl_sub_begin();
        }
    }
    mtl_drain();
    for (unsigned b = 0; b < BATCHES; b++) {
        unsigned count = b == BATCHES - 2 ? 4 : b == BATCHES - 1 ? 1 : 3;
        for (unsigned i = 0; i < count; i++) {
            size_t at = (b * RANGES + i) * 2 * EDGE;
            CHECK("literal edge bytes survive later batches", !memcmp((char *)input.contents + at, (char *)output.contents + at, 2 * EDGE));
        }
    }
    size_t retained = 0;
    for (unsigned i = 0; i < 3; i++) {
        CHECK("primary block stays bounded", g_up_slot_blk[i].length <= UP_BLOCK_SIZE);
        CHECK("overflow block stays bounded", g_up_slot_over[i].length <= UP_BLOCK_SIZE);
        CHECK("slot is no longer in flight", !atomic_load(&g_up_alloc_busy[i]));
        retained += g_up_slot_blk[i].length + g_up_slot_over[i].length;
    }
    CHECK("retained memory stays within 192 MiB", retained <= 6u * UP_BLOCK_SIZE);
    CHECK("oversized upload did not become persistent", g_up_block == nil);

    // A scene's streaming burst must not set the idle cache size for the rest of
    // the process. Touch its full backing, then keep uploading a light workload.
    const size_t heavy[] = {UP_BLOCK_SIZE, UP_BLOCK_SIZE}, light[] = {1u << 20};
    mtl_sub_begin(); fill_staging = 1;
    for (unsigned i = 0; i < 3; i++) batch(i, heavy, 2, input, output);
    CHECK("heavy cache submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    mtl_drain(); fill_staging = 0;
    size_t heavy_bytes = cache_bytes(); uint64_t heavy_footprint = footprint(), light_warmed = 0;
    for (unsigned i = 0; i < 256; i++) {
        if (i % 8 == 0) mtl_sub_begin();
        batch(i % BATCHES, light, 1, input, output);
        if (i == 191) light_warmed = g_up_blocks_new;
        if (i % 8 == 7) CHECK("light cache submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    }
    mtl_drain();
    size_t light_bytes = cache_bytes(); uint64_t light_footprint = footprint();
    if (up_reuse()) {
        CHECK("a prolonged light workload releases burst-only staging", light_bytes <= 3u * UP_SLOT_BLOCK);
        CHECK("settled light uploads do not keep allocating", g_up_blocks_new == light_warmed);
    }
    for (unsigned i = 0; i < BATCHES; i++) CHECK("light upload edge bytes remain correct", !memcmp((char *)input.contents + i * RANGES * 2 * EDGE, (char *)output.contents + i * RANGES * 2 * EDGE, 2 * EDGE));
    // Returning to a heavy workload may grow the cache once, but must reuse it.
    for (unsigned i = 0; i < 108; i++) {
        if (i % 3 == 0) mtl_sub_begin();
        batch(i % BATCHES, heavy, 2, input, output);
        if (i == 5) warmed = g_up_blocks_new;
        if (i % 3 == 2) CHECK("heavy cache resumes correctly", mtl_wait(mtl_sub_commit(), 5000000000ull));
    }
    if (up_reuse()) CHECK("a resumed stable heavy workload reuses its cache", g_up_blocks_new == warmed);
    for (unsigned i = 0; i < BATCHES; i++) for (unsigned j = 0; j < 2; j++) {
        size_t at = (i * RANGES + j) * 2 * EDGE;
        CHECK("resumed heavy upload edge bytes remain correct", !memcmp((char *)input.contents + at, (char *)output.contents + at, 2 * EDGE));
    }
    // Each slot sees a burst every 16 uses, within the cache's demand window.
    // Oscillating between large and small uploads must not repeatedly trim it.
    warmed = g_up_blocks_new;
    for (unsigned i = 0; i < 192; i++) {
        if (i % 8 == 0) mtl_sub_begin();
        batch(i % BATCHES, i % 16 ? light : heavy, i % 16 ? 1 : 2, input, output);
        if (i % 8 == 7) CHECK("recurring upload burst completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    }
    if (up_reuse()) {
        CHECK("recurring bursts retain their useful staging cache", cache_bytes() == heavy_bytes);
        CHECK("oscillating uploads do not churn staging allocations", g_up_blocks_new == warmed);
    }
    CHECK("cache reuse has no GPU submission error", !mtl_last_commit_error());
    printf("staging heavy -> light: cache %zu -> %zu MiB, footprint %llu -> %llu MiB\n", heavy_bytes >> 20, light_bytes >> 20, (unsigned long long)(heavy_footprint >> 20), (unsigned long long)(light_footprint >> 20));
    printf("t_upload_slots: %d checks, %d failed; staging allocations %llu, retained %zu MiB\n", checks, failed, (unsigned long long)g_up_blocks_new, retained >> 20);
    return failed != 0;
} }
