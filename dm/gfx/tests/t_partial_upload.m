// Re-uploads of a texture taken from guest memory read only the images (a layer's level, a 3D level) whose pages were written since its upload and copy the others from the
// texture they replace (pkg_written in nvn_mtl.m), through the production lookup (tex_mtl): after each write every image of the texture the host returns is compared with a CPU
// reference, and the bytes read from guest memory with those of the images whose pages the write touched. Ocarina of Time's 1800x1380x8 R16 array, written layer by layer while
// drawn, was read whole 13 times in 6 frames (docs/reference/frame-rate.md)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
static const char *g_case = "";
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s: %s (line %d)\n", g_case, label, __LINE__); } } while (0)
static void finish(void) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes"); CHECK(!mtl_last_commit_error(), "GPU has no submission error"); }

typedef struct {
    tex_t t; pool_t pool; void *mem; size_t poolsize;
    unsigned levels, layers, bpb, bw, bh; int d3;
    size_t bytes, *at, *len; uint64_t *lo, *hi;   // per image (level * layers + layer): its place in the linear reference, and its byte range in the storage
    uint8_t *expected, *written; unsigned fill;
} fix_t;
static unsigned img(const fix_t *f, unsigned l, unsigned a) { return l * f->layers + a; }
static void geom(const fix_t *f, unsigned l, unsigned *w, unsigned *h, unsigned *z, size_t *pitch, size_t *rows) {
    *w = MAX(f->t.d.width >> l, 1u); *h = f->t.d.target == NVN_TEXTURE_TARGET_1D_ARRAY ? 1 : MAX(f->t.d.height >> l, 1u); *z = f->d3 ? MAX(f->t.d.depth >> l, 1u) : 1;
    *pitch = (size_t)((*w + f->bw - 1) / f->bw) * f->bpb; *rows = (*h + f->bh - 1) / f->bh;
}
static fix_t *make(int target, NVNformat format, unsigned w, unsigned h, unsigned depth, unsigned levels, size_t source_offset) {
    static uint64_t serial = 97000;
    fix_t *f = calloc(1, sizeof *f); int bw, bh;
    f->t = (tex_t){.magic = MAGIC('T','E','X',0), .has_layout = 1, .serial = serial++};
    f->t.d = (nvn_texdesc){.target = target, .format = format, .width = w, .height = h, .depth = depth, .levels = levels, .samples = 1};
    nvn_tex_layout(&f->t.d, &f->t.L);
    f->bpb = (unsigned)nvn_fmt_bpb(format, &bw, &bh); f->bw = (unsigned)bw; f->bh = (unsigned)bh;
    f->d3 = target == NVN_TEXTURE_TARGET_3D; f->levels = levels;
    f->layers = target == NVN_TEXTURE_TARGET_2D_ARRAY || target == NVN_TEXTURE_TARGET_CUBEMAP_ARRAY ? depth : target == NVN_TEXTURE_TARGET_CUBEMAP ? 6 : target == NVN_TEXTURE_TARGET_1D_ARRAY ? h : 1;   // a 1D array's height counts its layers
    unsigned n = levels * f->layers; f->at = calloc(n, sizeof *f->at); f->len = calloc(n, sizeof *f->len); f->lo = calloc(n, 8); f->hi = calloc(n, 8); f->written = calloc(n, 1);
    for (unsigned l = 0; l < levels; l++) for (unsigned a = 0; a < f->layers; a++) {
        unsigned lw, lh, lz; size_t pitch, rows; geom(f, l, &lw, &lh, &lz, &pitch, &rows);
        unsigned i = img(f, l, a); f->at[i] = f->bytes; f->len[i] = pitch * rows * lz; f->bytes += f->len[i];
        f->lo[i] = a * f->t.L.layer_size + nvn_tex_level_offset(&f->t.d, l);
        f->hi[i] = a * f->t.L.layer_size + (l + 1 < levels ? nvn_tex_level_offset(&f->t.d, l + 1) : f->t.L.layer_size);
    }
    size_t pg = (size_t)getpagesize(); f->poolsize = (f->t.L.size + source_offset + pg + pg - 1) & ~(pg - 1);
    if (posix_memalign(&f->mem, pg, f->poolsize)) abort();
    memset(f->mem, 0, f->poolsize);
    f->pool = (pool_t){.magic = MAGIC('P','O','O','L'), .mem = f->mem, .size = f->poolsize, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    f->t.pool = &f->pool; f->t.mem = (uint8_t *)f->mem + source_offset;
    mtl_pool_add(f->mem, f->poolsize); nvn_dirty_add_range(f->mem, f->poolsize);
    f->expected = malloc(f->bytes);
    return f;
}
static void drop(fix_t *f) {
    mtl_tex_release(&f->t); mtl_drain(); mtl_alias_drop_pool(&f->pool); nvn_dirty_remove_range(f->mem); mtl_pool_del(f->mem); mtl_drain();
    free(f->mem); free(f->expected); free(f->at); free(f->len); free(f->lo); free(f->hi); free(f->written); free(f);
}
// The game writes one image: new bytes in the reference, swizzled into the storage, its pages counted as written
static void write_image(fix_t *f, unsigned l, unsigned a) {
    unsigned i = img(f, l, a), w, h, z; size_t pitch, rows; geom(f, l, &w, &h, &z, &pitch, &rows);
    uint8_t *p = f->expected + f->at[i]; unsigned k = ++f->fill;
    for (size_t b = 0; b < f->len[i]; b++) p[b] = (uint8_t)(b * 131u + (b >> 8) * 17u + a * 29u + l * 71u + k * 83u);
    dm_guest_write_prepare((uint8_t *)f->t.mem + f->lo[i], f->hi[i] - f->lo[i]);
    CHECK(!nvn_swizzle(&f->t.d, l, a, p, (uint32_t)pitch, f->t.mem), "reference swizzle succeeds");
    f->written[i] = 1;
}
typedef struct { fix_t *f; unsigned l, a; } wr_t;
static void *wr_main(void *p) { wr_t *w = p; write_image(w->f, w->l, w->a); return NULL; }
static void elsewhere(fix_t *f, unsigned l, unsigned a) { wr_t w = {f, l, a}; pthread_t th; pthread_create(&th, NULL, wr_main, &w); pthread_join(th, NULL); }
static void *beside_main(void *p) { fix_t *f = p; dm_guest_write_prepare(f->mem, 16); memset(f->mem, 0x5a, 16); return NULL; }
static id<MTLTexture> by_id(int tid) { os_unfair_lock_lock(&g_rmu); id<MTLTexture> v = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu); return v; }
// The images a look reads from guest memory after those writes: every one with a byte in a host page a written image has a byte in
static size_t expect_read(fix_t *f, unsigned *count) {
    uintptr_t pg = (uintptr_t)getpagesize(), base = (uintptr_t)f->t.mem; size_t n = 0; unsigned c = 0, ni = f->levels * f->layers;
    for (unsigned i = 0; i < ni; i++) { int hit = 0;
        for (unsigned j = 0; j < ni && !hit; j++) hit = f->written[j] && ((base + f->lo[i]) & ~(pg - 1)) <= ((base + f->hi[j] - 1) & ~(pg - 1)) && ((base + f->lo[j]) & ~(pg - 1)) <= ((base + f->hi[i] - 1) & ~(pg - 1));
        if (hit) { n += f->len[i]; c++; } }
    memset(f->written, 0, ni); *count = c;
    return n;
}
static int content_ok_from(fix_t *f, id<MTLTexture> image, unsigned base) {
    if (!image) return 0;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:f->bytes + 512 options:MTLResourceStorageModeShared]; if (!rb) return 0;
    memset(rb.contents, 0xcd, rb.length);
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> ce = [cb blitCommandEncoder];
    for (unsigned l = base; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) {
        unsigned w, h, z; size_t pitch, rows; geom(f, l, &w, &h, &z, &pitch, &rows);
        [ce copyFromTexture:image sourceSlice:a sourceLevel:l - base sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, z) toBuffer:rb destinationOffset:256 + f->at[img(f, l, a)] destinationBytesPerRow:pitch destinationBytesPerImage:pitch * rows];
    }
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return 0;
    int sh = rb_packed_shift(f->t.d.format);   // Metal's order of a packed 16-bit format, back to the guest's
    if (sh) for (unsigned l = base; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) { unsigned w, h, z; size_t pitch, rows; geom(f, l, &w, &h, &z, &pitch, &rows);
        rb_swap_rows((uint8_t *)rb.contents + 256 + f->at[img(f, l, a)], pitch, rows, z, pitch, pitch * rows, sh); }
    size_t first = f->at[img(f, base, 0)];
    int ok = !memcmp((uint8_t *)rb.contents + 256 + first, f->expected + first, f->bytes - first);
    if (!ok) for (unsigned i = img(f, base, 0); i < f->levels * f->layers; i++) if (memcmp((uint8_t *)rb.contents + 256 + f->at[i], f->expected + f->at[i], f->len[i])) fprintf(stderr, "  %s: level %u layer %u differs\n", g_case, i / f->layers, i % f->layers);
    return ok;
}
static int content_ok(fix_t *f, id<MTLTexture> image) { return content_ok_from(f, image, 0); }
// One look in a submission of its own. whole: every image is expected read from guest memory
static id<MTLTexture> look(fix_t *f, int whole, const char *what) {
    unsigned n; size_t want = expect_read(f, &n); uint64_t b0 = mtl_upload_bytes(), r0 = g_pkg_reuploads;
    mtl_sub_begin(); id<MTLTexture> image = tex_mtl_full(&f->t); finish();
    char label[160];
    snprintf(label, sizeof label, "%s: resolves", what); CHECK(image != nil, label);
    snprintf(label, sizeof label, "%s: read %llu bytes from guest memory, expected %zu of %zu", what, (unsigned long long)(mtl_upload_bytes() - b0), whole ? f->bytes : want, f->bytes);
    CHECK(mtl_upload_bytes() - b0 == (whole ? f->bytes : want), label);
    if (!whole) { snprintf(label, sizeof label, "%s: fewer than all images written", what); CHECK(n < f->levels * f->layers, label); }
    snprintf(label, sizeof label, "%s: counted as one re-upload", what); CHECK(g_pkg_reuploads == r0 + 1 || (whole && g_pkg_reuploads == r0), label);
    snprintf(label, sizeof label, "%s: every image holds the reference", what); CHECK(image && content_ok(f, image), label);
    return image;
}
static void run(const char *name, int target, NVNformat format, unsigned w, unsigned h, unsigned depth, unsigned levels, size_t source_offset, int direct) {
    g_case = name; g_direct_upload_on = direct;
    fix_t *f = make(target, format, w, h, depth, levels, source_offset);
    unsigned last = f->layers - 1, mid = f->layers / 2, top = levels - 1;
    for (unsigned l = 0; l < levels; l++) for (unsigned a = 0; a < f->layers; a++) write_image(f, l, a);
    id<MTLTexture> first = look(f, 1, "first upload");
    write_image(f, 0, mid);
    id<MTLTexture> second = look(f, 0, "one image written");
    CHECK(second != first, "the texture in-flight draws read is not written");
    CHECK(tex_mtl_full(&f->t) == second, "unchanged storage keeps its texture");
    // The spare is the first texture: it lacks the image written before this one
    write_image(f, top, last);
    id<MTLTexture> third = look(f, 0, "another image written");
    CHECK(third == first, "the idle spare is written");
    if (f->layers > 1) { write_image(f, 0, 0); write_image(f, top, mid); look(f, 0, "two images written"); }
    // Two looks in one submission: the second texture's copies read the first's, which the same batch uploads
    mtl_sub_begin();
    write_image(f, 0, last); unsigned n; expect_read(f, &n); id<MTLTexture> a = tex_mtl_full(&f->t);
    write_image(f, top, 0); expect_read(f, &n); id<MTLTexture> b = tex_mtl_full(&f->t);
    finish();
    CHECK(a && b && a != b, "a look after another write in the same submission takes another texture");
    CHECK(content_ok(f, b), "two re-uploads in one submission: every image holds the reference");
    // A write by another thread while the submit thread replays a submission races it: the submission keeps the texture of its first look, and the next one reads the pages
    for (unsigned l = 0; l < levels; l++) for (unsigned y = 0; y < f->layers; y++) write_image(f, l, y);
    look(f, 1, "before the racing write");
    mtl_sub_begin(); id<MTLTexture> kept = tex_mtl_full(&f->t); uint64_t r0 = g_pkg_reuploads;
    elsewhere(f, 0, mid);
    CHECK(tex_mtl_full(&f->t) == kept && g_pkg_reuploads == r0, "a write by another thread during a submission leaves the submission its texture");
    write_image(f, top, last);
    expect_read(f, &n); id<MTLTexture> own = tex_mtl_full(&f->t);
    CHECK(own != kept && g_pkg_reuploads == r0 + 1, "a write by the submit thread is looked for at the next use");
    finish();
    CHECK(content_ok(f, own), "and that look reads the other thread's write too");
    mtl_sub_begin(); kept = tex_mtl_full(&f->t); elsewhere(f, 0, 0); CHECK(tex_mtl_full(&f->t) == kept, "the submission keeps its texture again"); finish();
    look(f, 0, "the next submission after a racing write");
    elsewhere(f, top, mid); r0 = g_pkg_reuploads; expect_read(f, &n);
    id<MTLTexture> out = tex_mtl_full(&f->t);
    CHECK(g_pkg_reuploads == r0 + 1 && content_ok(f, out), "outside a submission every look reads the pages");
    // A racing write to the data beside it, in a host page they share, is no write to it: the texture stays, and the next submission starts no write generation for it
    if ((uint8_t *)f->t.mem != (uint8_t *)f->mem) {
        mtl_sub_begin(); kept = tex_mtl_full(&f->t); r0 = g_pkg_reuploads; uint64_t skips = g_pkg_edge_skips;
        pthread_t th; pthread_create(&th, NULL, beside_main, f); pthread_join(th, NULL);
        CHECK(tex_mtl_full(&f->t) == kept && g_pkg_reuploads == r0 && g_pkg_edge_skips == skips + 1 && !g_pkg_kept, "a racing write beside the texture leaves it clean");
        finish();
    }
    // The same through a texture ID, whose view is remembered by write generation: no page anywhere is written after the racing write, and the next submission reads it all the same
    view_t rrr1 = {0}; rrr1.set_swizzle = 1; rrr1.swz[0] = rrr1.swz[1] = rrr1.swz[2] = MTLTextureSwizzleRed; rrr1.swz[3] = MTLTextureSwizzleOne;
    mtl_tex_init(&f->t); mtl_reg_tex(9, &f->t, &rrr1);   // a live object: its ID keeps its view from one submission to the next
    mtl_sub_begin(); id<MTLTexture> v1 = by_id(9); elsewhere(f, 0, mid); id<MTLTexture> v2 = by_id(9); finish();
    CHECK(v1.parentTexture && g_treg[9].view && v2 == v1, "a texture ID keeps its view through the submission of a racing write");
    expect_read(f, &n); r0 = g_pkg_reuploads;
    mtl_sub_begin(); id<MTLTexture> v3 = by_id(9); finish();
    CHECK(v3.parentTexture && v3.parentTexture != v1.parentTexture && g_pkg_reuploads == r0 + 1, "and takes a view of another texture in the next submission, with nothing else written since");
    CHECK(content_ok(f, v3.parentTexture), "which holds the written content");
    mtl_reg_tex(9, NULL, NULL);
    // A dropped batch is reported after later uploads were encoded: images copied since the last whole upload are not trusted
    NvPkg *pk = tex_get(f->t.serial);
    CHECK([pk isKindOfClass:[NvPkg class]] && pk->part, "the texture is known to hold copied images");
    atomic_fetch_add(&g_up_lost_gen, 1);
    look(f, 1, "after a dropped batch");
    CHECK(!pk->part, "a whole upload holds no copied image");
    write_image(f, 0, mid); look(f, 0, "one image written after the whole upload");
    for (unsigned l = 0; l < levels; l++) for (unsigned y = 0; y < f->layers; y++) write_image(f, l, y);
    look(f, 1, "every image written");
    drop(f);
}
// The cost on the texture this was found on, read whole against one layer's: a look a submission (the idle spare is written), and three, each after a write, as it was found
// (a texture made for each)
static void cost(void) {
    g_case = "cost"; g_direct_upload_on = 1;
    fix_t *f = make(NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_R16, 1800, 1380, 8, 1, 0);
    for (unsigned a = 0; a < 8; a++) write_image(f, 0, a);
    look(f, 1, "first upload");
    double ms[2][2][2] = {{{0}}}; unsigned n;
    for (int looks = 1; looks <= 3; looks += 2) for (int part = 0; part < 2; part++) for (int r = 0; r < 6; r++) {
        mtl_sub_begin(); uint64_t t0 = bp_now(), cpu = 0;
        for (int k = 0; k < looks; k++) {
            if (part) write_image(f, 0, (unsigned)(r + k) % 8); else for (unsigned a = 0; a < 8; a++) write_image(f, 0, a);
            expect_read(f, &n);
            uint64_t c0 = bp_now(); CHECK(tex_mtl_full(&f->t) != nil, "resolves"); cpu += bp_now() - c0;
        }
        finish(); uint64_t t2 = bp_now();
        if (r >= 2) { ms[looks / 2][part][0] += cpu / (4e6 * looks); ms[looks / 2][part][1] += (t2 - t0) / 4e6; }
    }
    CHECK(content_ok(f, tex_mtl_full(&f->t)), "every image holds the reference");
    for (int i = 0; i < 2; i++)
        printf("t_partial_upload: 1800x1380x8 R16 (%.1f MB), %d re-upload%s a submission: read whole %.2f ms each on the submit thread, %.1f ms a submission to completion; one layer written %.2f ms, %.1f ms\n",
               f->t.L.size / 1048576.0, 2 * i + 1, i ? "s" : "", ms[i][0][0], ms[i][0][1], ms[i][1][0], ms[i][1][1]);
    drop(f);
}
// Direct descriptor lookup needs no shader whitelist.

static id<MTLTexture> sampled_id(int tid) {
    os_unfair_lock_lock(&g_rmu); void *view = NULL; tex_fast_rid(tid, &view);
    id<MTLTexture> result = (__bridge id<MTLTexture>)view;
    os_unfair_lock_unlock(&g_rmu); return result;
}
static void first_sampled_mip(int no_cpu, unsigned format) {
    g_case = no_cpu ? "first sampled CPU_NO_ACCESS texture" : "first sampled mip-0 view";
    fix_t *f = make(NVN_TEXTURE_TARGET_2D_ARRAY, format, 1024, 1024, 3, 11, 0);
    for (unsigned l = 0; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) write_image(f, l, a);
    if (no_cpu) { f->t.has_layout = 0; f->pool.flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED; }
    mtl_tex_init(&f->t); mtl_reg_tex(23, &f->t, NULL);
    uint64_t bytes = mtl_upload_bytes();
    mtl_sub_begin(); id<MTLTexture> reduced = sampled_id(23); finish();
    int enabled = low_memory_on() && !no_cpu;
    CHECK(reduced.width == (enabled ? 512 : 1024), "first mip-0 normalized sample uses the selected size");
    CHECK(reduced.mipmapLevelCount == (unsigned)(11 - enabled), "descriptor levels match the uploaded mip range");
    CHECK(content_ok_from(f, reduced, enabled), "all layers and mips match guest data");
    if (enabled) {
        size_t skipped = f->len[0] * f->layers;
        CHECK(mtl_upload_bytes() - bytes == f->bytes - skipped, "mip 0 is omitted from the first upload");
        NvPkg *pk = tex_get(f->t.serial);
        CHECK(pk->mip_base == 1, "package records its reduced mip base");
        CHECK(g_treg[23].view_mip_base == 1, "cached descriptor records reduced base");
        mtl_sub_begin(); id<MTLTexture> full = by_id(23); finish();
        CHECK(full == reduced && full.width == 512 && full.mipmapLevelCount == 10, "unknown binding keeps the reduced allocation");
        CHECK(content_ok_from(f, full, 1), "unknown binding retains the uploaded guest mips");
        mtl_sub_begin(); CHECK(sampled_id(23) == reduced, "repeated sampling does not rebuild the texture");
        finish();
        write_image(f, 1, 0);
        mtl_sub_begin(); id<MTLTexture> refreshed = by_id(23); finish();
        CHECK(refreshed.width == 512 && content_ok_from(f, refreshed, 1), "CPU changes refresh lower mips without restoring the full copy");
        if (format == NVN_FORMAT_RGBA8) {
            mtl_sub_begin();
            p_clear_tex clear = {.tex = &f->t, .r = {0, 0, 0, 1024, 1024, 1}, .mask = 15, .c.f = {1, 0, 0, 1}};
            clear_tex(&clear); finish();
            for (size_t i = f->at[0]; i < f->at[0] + f->len[0]; i += 4) {
                f->expected[i] = f->expected[i + 3] = 255;
                f->expected[i + 1] = f->expected[i + 2] = 0;
            }
            mtl_sub_begin(); id<MTLTexture> rendered = by_id(23); finish();
            CHECK(rendered.width == 1024 && pk->mip_base == 0 && pk->gpu_written, "render-target clear restores the full uncompressed array");
            CHECK(content_ok(f, rendered), "render clear changes mip 0 and preserves every other layer and mip");
            mtl_sub_begin(); CHECK(sampled_id(23) == rendered, "rendered asset stays full sized on later ordinary sampling"); finish();
        }
    }
    mtl_reg_tex(23, NULL, NULL); drop(f);
}
static void copy_reduced_asset(void) {
    if (!low_memory_on()) return;
    g_case = "GPU copy restores a reduced array";
    fix_t *f = make(NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA_DXT1, 512, 512, 3, 4, 0);
    for (unsigned l = 0; l < f->levels; l++) for (unsigned a = 0; a < f->layers; a++) write_image(f, l, a);
    const size_t source = f->poolsize - getpagesize();
    CHECK(source >= f->t.L.size, "copy source lies outside the texture storage");
    uint8_t block[8] = {0, 0xf8, 0, 0, 0, 0, 0, 0};
    dm_guest_write_prepare((uint8_t *)f->mem + source, sizeof block); memcpy((uint8_t *)f->mem + source, block, sizeof block);
    mtl_tex_init(&f->t); mtl_reg_tex(24, &f->t, NULL);
    mtl_sub_begin(); CHECK(sampled_id(24).width == 256, "copy destination starts with a reduced sampled copy"); finish();
    mtl_sub_begin(); p_copy_b2t copy = {.tex = &f->t, .src = (uint64_t)f->mem + source, .r = {0, 0, 0, 4, 4, 1}};
    copy_b2t(&copy, sizeof copy); finish();
    NvPkg *pk = tex_get(f->t.serial);
    CHECK(pk->tex.width == 512 && pk->mip_base == 0 && pk->gpu_written, "GPU copy uses full dimensions and excludes later eviction");
    memcpy(f->expected, block, sizeof block);
    CHECK(content_ok(f, pk->tex), "the write reaches mip 0 and preserves neighboring data in every layer");
    mtl_reg_tex(24, NULL, NULL); drop(f);
}
static void low_memory_assets(void) {
    g_case = "low-memory packaged texture";
    fix_t *f = make(NVN_TEXTURE_TARGET_2D, NVN_FORMAT_BPTC_UNORM, 512, 512, 1, 4, 0);
    for (unsigned l = 0; l < f->levels; l++) write_image(f, l, 0);
    mtl_tex_init(&f->t);
    view_t coarse = {.set_levels = 1, .base_level = 1, .nlevels = f->levels - 1};
    mtl_reg_tex(21, &f->t, &coarse);
    uint64_t bytes = mtl_upload_bytes();
    mtl_sub_begin(); id<MTLTexture> view = by_id(21); finish();
    NvPkg *pk = tex_get(f->t.serial);
    int enabled = low_memory_on();
    CHECK(view.width == 256 && view.mipmapLevelCount == 3, "view keeps its NVN dimensions and mip count");
    CHECK(pk->mip_base == (unsigned)enabled, "only low-memory uploads may omit mip 0");
    CHECK(mtl_upload_bytes() - bytes == f->bytes - (enabled ? f->len[0] : 0), "reads precisely the uploaded mips");
    CHECK(content_ok_from(f, view, 1), "view reads the original guest levels 1 to 3");
    if (!enabled) {
        pkg_pressure_event(DISPATCH_MEMORYPRESSURE_CRITICAL);
        CHECK(!pkg_trim_ready(), "system pressure respects the low-memory switch");
        pkg_pressure_event(DISPATCH_MEMORYPRESSURE_NORMAL);
        mtl_reg_tex(21, NULL, NULL); drop(f); return;
    }

    // A copy or full-mip view must resolve the original texture on demand.
    mtl_sub_begin(); id<MTLTexture> full = tex_mtl_full(&f->t); finish();
    CHECK(full.width == 512 && full.mipmapLevelCount == 4 && !pk->mip_base, "a full-size lookup restores mip 0");
    CHECK(content_ok(f, full), "restored full texture matches guest bytes");
    CHECK(content_ok_from(f, by_id(21), 1), "old descriptor resolves on the replacement");
    tex_t alias = f->t; alias.serial += 1000000; mtl_tex_init(&alias);
    mtl_reg_tex(22, &alias, &coarse);
    CHECK(content_ok_from(f, by_id(22), 1), "a second serial can share the same guest storage");
    CHECK(tex_get(alias.serial) == pk, "aliases share one package");

    g_sub_serial += PKG_PURGE_IDLE - 1;
    pkg_trim_current(0, PKG_PURGE_IDLE, g_done, 1);
    CHECK(!pk->purgeable, "a recently used texture stays nonvolatile");
    g_sub_serial++;
    pkg_trim_current(0, PKG_PURGE_IDLE, g_fence - 1, 1);
    CHECK(!pk->purgeable, "in-flight render work prevents marking a texture volatile");
    pkg_trim_current(0, PKG_PURGE_IDLE, g_done, 1);
    CHECK(pk->purgeable && !g_treg[21].view && !g_treg[22].view, "idle copy goes volatile and both descriptor caches clear");

    [pk->tex setPurgeableState:MTLPurgeableStateEmpty];
    mtl_sub_begin(); view = by_id(22); finish();
    CHECK(!pk->purgeable && pk->tex != full, "a purged texture is uploaded again");
    CHECK(content_ok_from(f, view, 1), "alias rebuild preserves its original guest levels");
    g_treg[22].table_view = 1;
    g_sub_serial += PKG_PURGE_IDLE;
    pkg_trim_current(1, PKG_EVICT_IDLE_CRITICAL, g_done, 0);
    CHECK(pk->tex && !pk->purgeable, "a package in a cached bindless table is excluded");
    g_treg[22].table_view = 0;
    id<MTLTexture> old = pk->tex;
    const uint64_t ample_headroom = 2ull << 30;
    g_sub_serial = (g_sub_serial + PKG_EVICT_IDLE_CRITICAL) | 1;
    pkg_pressure_event(DISPATCH_MEMORYPRESSURE_CRITICAL);
    pkg_pressure_event(DISPATCH_MEMORYPRESSURE_NORMAL);
    CHECK(!pkg_trim_ready(), "normal system pressure clears an unserved request");
    pkg_pressure_event(DISPATCH_MEMORYPRESSURE_WARN);
    CHECK(pkg_trim_ready(), "warning can trigger a sweep between periodic checks");
    pkg_trim_cache_for(ample_headroom);
    CHECK(pk->tex == old && !pkg_trim_ready(), "one warning preserves recently used textures");
    pkg_pressure_event(DISPATCH_MEMORYPRESSURE_CRITICAL);
    mtl_sub_begin(); up_begin();
    CHECK(g_up_cb && !pkg_trim_ready(), "pressure sweep waits for the open upload batch");
    finish(); up_wait_zero(&g_up_pending, WS_OLDQ);
    CHECK(pkg_trim_ready(), "pending critical pressure survives waiting for uploads");
    pkg_trim_cache_for(ample_headroom);
    CHECK(!pk->tex && !g_treg[22].view, "critical system pressure evicts even with ample app headroom");
    mtl_sub_begin(); full = tex_mtl_full(&f->t); finish();
    CHECK(full && full != old && !pk->mip_base && content_ok(f, full), "full resolution is restored after eviction");

    g_sub_serial += PKG_PURGE_IDLE;
    pkg_pressure_event(DISPATCH_MEMORYPRESSURE_WARN);
    pkg_trim_cache_for(ample_headroom);
    CHECK(!pk->tex, "system warning evicts older textures even with ample app headroom");
    mtl_sub_begin(); full = tex_mtl_full(&f->t); finish();
    g_sub_serial += PKG_PURGE_IDLE;
    pkg_pressure_event(DISPATCH_MEMORYPRESSURE_NORMAL);
    up_wait_zero(&g_up_pending, WS_OLDQ); // pressure reclamation waits for the upload completion callbacks
    pkg_trim_cache_for(480ull << 20);
    CHECK(!pk->tex, "idle copies are reclaimed with 480 MiB headroom before the old 250 MiB threshold");
    mtl_sub_begin(); full = tex_mtl_full(&f->t); finish();
    CHECK(full && content_ok(f, full), "early reclamation rebuilds unchanged guest pixels");
    g_sub_serial += PKG_PURGE_IDLE;
    tex_gpu_wrote(&f->t);
    pkg_trim_current(1, PKG_EVICT_IDLE_CRITICAL, g_done, 0);
    CHECK(pk->tex == full && !pk->purgeable, "a package used for GPU writes is excluded");
    mtl_reg_tex(22, NULL, NULL); mtl_tex_release(&alias);
    mtl_reg_tex(21, NULL, NULL); drop(f);
}

static void shader_metadata_probe(const char *key) {
    g_case = "matching shader metadata reaches native reflection";
    shmap_read_once();
    CHECK(g_c1_full_valid && g_cb_ext.count, "matching optimization tables are accepted");
    NvShader *shader = shader_load(@(key), 1, 0);
    CHECK(shader && shader->fn, "matching shader loads without a sampled-mip whitelist");
    if (!shader) return;
}
int main(void) { @autoreleasepool {
    mtl_init();
    const char *metadata = getenv("DM_TEST_METADATA_SHADER");
    if (metadata) { shader_metadata_probe(metadata); printf("t_partial_upload metadata: %d checks, %d failed\n", checks, failed); return failed != 0; }
    for (int direct = 0; direct < 2; direct++) {
        run("R16 array", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_R16, 256, 192, 8, 1, 0, direct);
        run("R16 array beside other data", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_R16, 256, 192, 8, 1, 4096, direct);
        run("RGBA8 array with levels", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA8, 200, 120, 5, 6, 0, direct);
        run("RGBA16F array with levels", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA16F, 64, 64, 12, 4, 4096, direct);
        run("BC5 array", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGTC2_UNORM, 512, 256, 3, 1, 0, direct);
        run("BC7 array with levels", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_BPTC_UNORM, 256, 256, 3, 5, 4096, direct);
        run("BC7 2D with levels", NVN_TEXTURE_TARGET_2D, NVN_FORMAT_BPTC_UNORM, 1024, 512, 1, 8, 0, direct);
        run("RGBA8 cube with levels", NVN_TEXTURE_TARGET_CUBEMAP, NVN_FORMAT_RGBA8, 128, 128, 1, 5, 0, direct);
        run("RGBA8 cube array", NVN_TEXTURE_TARGET_CUBEMAP_ARRAY, NVN_FORMAT_RGBA8, 64, 64, 12, 3, 0, direct);
        run("RGBA8 3D with levels", NVN_TEXTURE_TARGET_3D, NVN_FORMAT_RGBA8, 64, 64, 32, 4, 0, direct);
        run("RGB565 array", NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGB565, 256, 128, 4, 1, 0, direct);
        // PRAGMATA's light-profile LUT: a 1D array is one row a layer; uploaded as height rows a layer, it was refused by validation and wrote past each slice without it
        run("R16F 1D array", NVN_TEXTURE_TARGET_1D_ARRAY, NVN_FORMAT_R16F, 512, 64, 1, 1, 0, direct);
        run("RGBA8 1D array with levels", NVN_TEXTURE_TARGET_1D_ARRAY, NVN_FORMAT_RGBA8, 256, 8, 1, 4, 4096, direct);
    }
    first_sampled_mip(0, NVN_FORMAT_RGBA_DXT1); first_sampled_mip(0, NVN_FORMAT_RGBA8); first_sampled_mip(1, NVN_FORMAT_RGBA_DXT1); copy_reduced_asset();
    low_memory_assets();
    cost();
    printf("t_partial_upload: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
