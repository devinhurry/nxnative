// Feedback snapshots and their per-draw argument substitution include separate texture slots; a snapshot is reused until the game's next barrier,
// and a draw that only samples an attachment nothing in its pass has written reads it directly.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
static NvProg *barrier_writer;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static id<MTLTexture> target(tex_t *t, uint64_t serial) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=serial};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8,
        .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:d];
    CHECK(texture != nil, "render target created");
    res_add(texture); mtl_tex_init(t); serial_put(serial, texture);
    return texture;
}
static void clear(MTLClearColor color) {
    R.clear_c[0] = 1; R.cc[0] = color;
    CHECK(rp_begin() != nil, "production render pass opens");
}
static void sample(NvShader *fs, id<MTLRenderPipelineState> pipeline) {
    clear(MTLClearColorMake(0, 0, 0, 1));
    enc_r_pso(g_enc, pipeline);
    enc_r_viewport(g_enc, (MTLViewport){0, 0, 4, 4, 0, 1});
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc, fs, 1, 0), "production fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    rp_end();
}
static void readback(id<MTLTexture> t, id<MTLBuffer> b, unsigned offset) {
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(4, 4, 1), b, offset, 256, 1024);
}
static void pixels(id<MTLBuffer> b, unsigned offset, const uint8_t want[4], const char *label) {
    int valid = 1;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++)
        valid &= !memcmp((const uint8_t *)b.contents + offset + y * 256 + x * 4, want, 4);
    CHECK(valid, label);
}
static void slot_case(NvProg *pr, id<MTLRenderPipelineState> pipeline, int slot, int index) {
    int before = failed, tid = 600 + index;
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = slot;
    tex_t source, output;
    id<MTLTexture> original = target(&source, 99700 + index * 2);
    id<MTLTexture> destination = target(&output, 99701 + index * 2);
    mtl_reg_tex(tid, &source, NULL);
    id<MTLBuffer> result = [g_dev newBufferWithLength:2048 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][slot] = tid;
    clear(MTLClearColorMake(1, 0, 0, 1));
    fb_prepare(pr);
    CHECK(!g_enc, "snapshot closes the preceding render pass");
    CHECK(g_fb_n == 1, "feedback attachment receives a snapshot");
    CHECK(g_fb_n == 1 && g_fb_src[0] == original && g_fb_use[0] != original,
          "snapshot substitutes a distinct texture for the registered source");
    rp_end();
    // Overwrite the attachment after the snapshot, then render the sampled value
    // into a distinct target. This makes a missing snapshot fail deterministically
    // even on GPUs that happen to tolerate sampling an attached render target.
    clear(MTLClearColorMake(0, 1, 0, 1)); rp_end();
    R.rt.color[0] = &output;
    sample(fs, pipeline);
    uint64_t bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(g_fb_n == 1 && bound == g_fb_rid[0] && bound != original.gpuResourceID._impl,
          "production argument buffer contains the snapshot resource ID");
    readback(destination, result, 0);
    // With a different attachment the following draw restores the original binding.
    fb_prepare(pr);
    CHECK(g_fb_n == 0, "following draw needs no snapshot");
    sample(fs, pipeline);
    bound = *(uint64_t *)((uint8_t *)fs->ab_buf.contents + fs->ab_off);
    CHECK(bound == original.gpuResourceID._impl, "following draw restores the original resource ID");
    readback(destination, result, 1024);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    pixels(result, 0, (const uint8_t[]){255, 0, 0, 255}, "first draw reads the red pre-overwrite snapshot");
    pixels(result, 1024, (const uint8_t[]){0, 255, 0, 255}, "following draw reads the green original attachment");
    printf("feedback slot %d: %s\n", slot, before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source); mtl_tex_release(&output);
}
// The rule without a listed shader: copy once, reuse until a barrier, end the pass when an earlier draw of it read the attachment directly.
static void reuse_case(NvProg *pr) {
    int before = failed, tid = 650; NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = 0;
    tex_t source; target(&source, 99790);
    mtl_reg_tex(tid, &source, NULL);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][0] = tid;
    S.chmask.mask = 0; clear(MTLClearColorMake(1, 0, 0, 1));
    uint64_t copies = g_fb_count;
    fb_prepare(pr);
    CHECK(g_fb_n == 0 && g_enc, "a draw that writes nothing reads an unwritten attachment directly");
    S.chmask.mask = 0xffffffffu;
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 1, "a writing draw takes a snapshot");
    id<MTLTexture> first = g_fb_use[0];
    clear(MTLClearColorMake(0, 1, 0, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && g_enc && g_fb_count == copies + 1 && g_fb_use[0] == first, "the next writing draw reuses the snapshot without ending the pass");
    S.chmask.mask = 0; rp_end(); clear(MTLClearColorMake(0, 1, 0, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 0 && g_enc, "a reading draw first in a pass reads directly");
    S.chmask.mask = 0xffffffffu;
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 1, "a writing draw after a direct read ends the pass and reuses the snapshot");
    g_fb_bar++;
    clear(MTLClearColorMake(0, 0, 1, 1));
    fb_prepare(pr);
    CHECK(g_fb_n == 1 && !g_enc && g_fb_count == copies + 2, "a game barrier makes the next writing draw take a fresh snapshot");
    rp_end();
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completed");
    CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    printf("feedback reuse: %s\n", before == failed ? "PASS" : "FAIL");
    mtl_tex_release(&source);
}
// Write-mask store elision must preserve the source for a later snapshot.
// A barrier still refreshes it: red if untouched, green after a real write.
static void barrier_case(NvProg *pr, int mode) {
    int tid = 680 + mode; tex_t source; target(&source, 99800 + mode);
    mtl_reg_tex(tid, &source, NULL);
    prog_t program = {.serial = 99810 + mode}; serial_put(program.serial, pr);
    id<MTLBuffer> result = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source;
    S.prog = &program; S.tex[1][0] = tid; S.chmask.mask = UINT32_MAX;
    pr->sh[1]->rf.b[0].reg = 0;
    clear(MTLClearColorMake(1, 0, 0, 1)); rp_end();
    uint64_t copies = g_fb_count;
    fb_prepare(pr);
    CHECK(g_fb_count == copies + 1, "initial feedback snapshot copied");
    S.chmask.mask = 0;
    p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
    draw_(&draw, NULL);
    CHECK(g_enc != nil, "read-only attachment draw keeps its render pass open");
    if (mode == 1) {
        struct { op_hdr h; p_clear_color c; op_hdr end; } code = {
            {OP_CLEAR_COLOR, sizeof(op_hdr) + sizeof(p_clear_color)}, {.index=0, .mask=15, .rgba={0, 1, 0, 1}}, {OP_END, sizeof(op_hdr)}};
        mtl_exec((const uint8_t *)&code);
    } else if (mode == 2) { rp_end(); draw_(&draw, NULL); }
    else if (mode == 3) {
        prog_t writer = {.serial = 99820}; serial_put(writer.serial, barrier_writer);
        S.prog = &writer; S.chmask.mask = UINT32_MAX; draw_(&draw, NULL); S.prog = &program;
    }
    struct { op_hdr h; int32_t bits, pad; op_hdr end; } barrier = {
        {OP_BARRIER, 16}, NVN_BARRIER_ORDER_FRAGMENTS_BIT | NVN_BARRIER_INVALIDATE_TEXTURE_BIT, 0, {OP_END, sizeof(op_hdr)}};
    mtl_exec((const uint8_t *)&barrier);
    S.chmask.mask = UINT32_MAX;
    fb_prepare(pr);
    CHECK(g_fb_n == 1, "feedback snapshot remains bound after the barrier");
    CHECK(g_fb_count == copies + 2, "barrier refreshes the feedback snapshot");
    readback(g_fb_use[0], result, 0);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "barrier proof GPU submission completes");
    CHECK(!mtl_last_commit_error(), "barrier proof has no GPU error");
    pixels(result, 0, mode == 1 || mode == 3 ? (const uint8_t[]){0, 255, 0, 255} : (const uint8_t[]){255, 0, 0, 255}, "barrier snapshot contains the literal current color");
    mtl_tex_release(&source);
}
// A later format view must preserve the frozen snapshot, even after the
// attachment itself changed. Swizzling alone must not disable compression.
static void view_case(NvProg *pr, id<MTLRenderPipelineState> pipeline) {
    tex_t source, output; target(&source, 99880); id<MTLTexture> destination = target(&output, 99881);
    int tid = 710; mtl_reg_tex(tid, &source, NULL);
    NvShader *fs = pr->sh[1]; fs->rf.b[0].reg = 0;
    id<MTLBuffer> result = [g_dev newBufferWithLength:3072 options:MTLResourceStorageModeShared]; res_add(result);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &source; S.tex[1][0] = tid;
    clear(MTLClearColorMake(1, 0, 0, 1)); fb_prepare(pr);
    CHECK(g_fb_n == 1, "view fixture has a production snapshot");
    CHECK(!!(g_fb_use[0].usage & MTLTextureUsagePixelFormatView) == !pass_reuse_on(), "ordinary snapshot only requests shader-read usage");
    id<MTLTexture> srgb = [g_fb_use[0] newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    CHECK(srgb != nil, "linear/sRGB view works without general format-view usage");
    clear(MTLClearColorMake(0, 1, 0, 1)); rp_end();
    view_t swizzle = {.set_swizzle=1, .swz={NVN_SWZ_B, NVN_SWZ_G, NVN_SWZ_R, NVN_SWZ_A}};
    mtl_reg_tex(tid + 1, &source, &swizzle); S.tex[1][0] = tid + 1;
    fb_prepare(pr);
    CHECK(!!(g_fb_use[0].usage & MTLTextureUsagePixelFormatView) == !pass_reuse_on(), "swizzled snapshot keeps minimal usage");
    R.rt.color[0] = &output; sample(fs, pipeline); readback(destination, result, 0);
    uint64_t copies = g_fb_count;
    view_t reinterpret = {.set_format=1, .format=NVN_FORMAT_RGBA8UI};
    mtl_reg_tex(tid + 2, &source, &reinterpret); R.rt.color[0] = &source; S.tex[1][0] = tid + 2;
    fb_prepare(pr);
    id<MTLTexture> integer = g_fb_n == 1 ? g_fb_use[0] : nil;
    CHECK(integer && (integer.usage & MTLTextureUsagePixelFormatView), "required reinterpretation upgrades the cached snapshot");
    CHECK(g_fb_count == copies + (pass_reuse_on() ? 1 : 0), "format-view usage upgrade is one copy, not a source refresh");
    CHECK(integer.pixelFormat == MTLPixelFormatRGBA8Uint, "integer format view is supported after upgrade"); readback(integer, result, 1024);
    g_fb_bar++; R.rt.color[0] = &source; S.tex[1][0] = tid;
    fb_prepare(pr); readback(g_fb_use[0], result, 2048);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "format-view GPU submission completes");
    CHECK(!mtl_last_commit_error(), "format-view fixture has no GPU error");
    pixels(result, 0, (const uint8_t[]){0, 0, 255, 255}, "swizzled shader reads the old red snapshot as blue");
    pixels(result, 1024, (const uint8_t[]){255, 0, 0, 255}, "usage upgrade preserves red rather than recopying the green attachment");
    pixels(result, 2048, (const uint8_t[]){0, 255, 0, 255}, "a real barrier refreshes to the green source");
    mtl_tex_release(&source); mtl_tex_release(&output);
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1);
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A {texture2d<float, access::read> source[[id(0)]];};\n"
        "fragment float4 f(float4 p[[position]], constant A&a[[buffer(0)]]) {return a.source.read(uint2(p.xy));}\n"
        "fragment float4 green() {return float4(0,1,0,1);}\n"
        options:nil error:&error];
    CHECK(lib != nil, "synthetic shader compiles");
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; pr->sh[1] = fs;
    fs->stage = 1; strcpy(fs->key, "0123456789abcdef"); fs->fn = [lib newFunctionWithName:@"f"];
    fs->ae = [fs->fn newArgumentEncoderWithBufferIndex:0]; fs->arg_len = fs->ae.encodedLength;
    fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .aid=0, .dtt=MTLTextureType2D};
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"v"]; d.fragmentFunction = fs->fn;
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:d error:&error];
    CHECK(pipeline != nil, "synthetic render pipeline compiles");
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    const int slots[] = {0, 128, 255};
    for (int i = 0; i < 3; i++) slot_case(pr, pipeline, slots[i], i);
    reuse_case(pr);
    pr->sh[0] = [NvShader new]; pr->sh[0]->fn = [lib newFunctionWithName:@"v"];
    pr->sh[1]->rf.color_known = 1; pr->sh[1]->rf.color_mask = 1;
    barrier_writer = [NvProg new]; barrier_writer->sh[0] = pr->sh[0]; barrier_writer->sh[1] = [NvShader new];
    barrier_writer->sh[1]->fn = [lib newFunctionWithName:@"green"]; barrier_writer->sh[1]->stage = 1;
    barrier_writer->sh[1]->rf.color_known = 1; barrier_writer->sh[1]->rf.color_mask = 1;
    for (int mode = 0; mode < 4; mode++) barrier_case(pr, mode);
    view_case(pr, pipeline);
    printf("feedback snapshot: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
