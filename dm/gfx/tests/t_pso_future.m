// Production pipeline lookup + deferred bind, with a gated archive to prove that translation can continue before archive retrieval completes.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, name) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", name); } } while (0)
static void wait_for(dispatch_semaphore_t s) { if (dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) abort(); }

@interface FixtureFunction : NSObject { @public MTLFunctionType type; } @end
@implementation FixtureFunction
- (NSDictionary *)functionConstantsDictionary { return @{}; }
- (MTLFunctionType)functionType { return type; }
@end
@interface FixtureLibrary : NSObject @end
@implementation FixtureLibrary
- (id)newFunctionWithName:(NSString *)name { FixtureFunction *f = [FixtureFunction new]; f->type = [name isEqualToString:@"vs"] ? MTLFunctionTypeVertex : MTLFunctionTypeFragment; return f; }
@end
@interface FixturePipeline : NSObject { @public MTLColorWriteMask mask; } @end
@implementation FixturePipeline
- (MTL4RenderPipelineDescriptor *)newRenderPipelineDescriptorForSpecialization { return [MTL4RenderPipelineDescriptor new]; }
@end
@interface FixtureCompiler : NSObject { @public int fail; } @end
@implementation FixtureCompiler
- (id)newRenderPipelineStateWithDescriptor:(id)d compilerTaskOptions:(id)o error:(NSError **)e {
    (void)d; (void)o;
    if (fail) { if (e) *e = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]; return nil; }
    return [FixturePipeline new];
}
- (id)newRenderPipelineStateBySpecializationWithDescriptor:(id)d pipeline:(id)p error:(NSError **)e {
    FixturePipeline *result = [self newRenderPipelineStateWithDescriptor:d compilerTaskOptions:p error:e];
    if (result) result->mask = ((MTL4RenderPipelineDescriptor *)d).colorAttachments[0].writeMask; return result;
}
@end
@interface FixtureArchive : NSObject { @public dispatch_semaphore_t entered, release; int hold, miss; _Atomic int calls; } @end
@implementation FixtureArchive
- (id)newRenderPipelineStateWithDescriptor:(id)d error:(NSError **)e {
    (void)d; (void)e; calls++;
    if (hold) { dispatch_semaphore_signal(entered); wait_for(release); }
    return miss ? nil : [FixturePipeline new];
}
@end
@interface FixtureEncoder : NSObject { @public id bound; int draws; } @end
@implementation FixtureEncoder
- (void)setRenderPipelineState:(id)p { bound = p; }
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n { (void)p; (void)v; (void)n; draws++; }
@end
static NvProg *program(void) {
    id<MTLLibrary> lib = lib_tag((id)[FixtureLibrary new], @"future-fixture");
    NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[1] = [NvShader new];
    strcpy(p->sh[0]->key, "future-vs"); strcpy(p->sh[1]->key, "future-fs"); p->sh[1]->stage = 1;
    p->sh[0]->fn = fn4_note([lib newFunctionWithName:@"vs"], lib, @"vs", nil);
    p->sh[1]->fn = fn4_note([lib newFunctionWithName:@"fs"], lib, @"fs", nil);
    return p;
}
typedef struct { NvProg *program; dispatch_semaphore_t done; id result; } request;
static void *request_main(void *arg) { @autoreleasepool { request *r = arg; r->result = pso_get_(r->program, nil); dispatch_semaphore_signal(r->done); } return NULL; }
static void drop_pipeline(const pso_key *k, MTLRenderPipelineDescriptor *d) {
    void *p = nvn_hm_del(&g_pso, k); if (p) hm_rel(p); p = nvn_hm_del(&g_pso_fail, k); if (p) hm_rel(p);
    pbase_key b; pbase_key_of(d, !k->border, &b);
    p = nvn_hm_del(&g_pbase, &b); if (p) hm_rel(p); p = nvn_hm_del(&g_pbase_miss, &b); if (p) hm_rel(p);
}
static int gpu_check(void) {
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1);
    setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MTL4", "1", 1); setenv("DM_NVN_PREDICT", "0", 1); setenv("DM_NVN_ENC_THREAD", "1", 1);
    mtl_init(); pso4_init(); CHECK(g_comp4 != nil, "Metal 4 compiler is available"); if (!g_comp4) return 1;
    NSError *error = nil;
    id<MTLLibrary> lib = lib_tag([g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n[[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[n],.25,1); }\n"
        "fragment float4 f() { return float4(1,0,0,1); }\n" options:nil error:&error], @"future-real-gpu-fixture");
    CHECK(lib != nil, "GPU fixture shaders compile"); if (!lib) return 1;
    NvProg *pr = [NvProg new]; pr->sh[0] = [NvShader new]; pr->sh[1] = [NvShader new];
    strcpy(pr->sh[0]->key, "gpu-future-vs"); strcpy(pr->sh[1]->key, "gpu-future-fs"); pr->sh[1]->stage = 1;
    pr->sh[0]->fn = fn4_note([lib newFunctionWithName:@"v"], lib, @"v", nil); pr->sh[1]->fn = fn4_note([lib newFunctionWithName:@"f"], lib, @"f", nil);
    state_reset(); memset(&R, 0, sizeof R);
    tex_t target = {.magic = MAGIC('T','E','X',0), .serial = 990101};
    target.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    R.has_rt = R.has_sc = 1; R.sc = (p_scissor){0,0,8,8}; R.rt.n = 1; R.rt.color[0] = &target; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0,0,1,1);
    mtl_sub_begin(); id<MTL4RenderCommandEncoder> enc = rp_begin_ex(0); CHECK(enc != nil, "production render pass opens"); if (!enc) return 1;
    pso_key key; pso_key_fill(&key, pr->sh[0], pr->sh[1], g_pass.cfmt, g_pass.dfmt, g_pass.sfmt, g_pass.samples, 0);
    MTLRenderPipelineDescriptor *d = pso_desc(&key, pr->sh[0], pr->sh[1], nil, 0); MTL4RenderPipelineDescriptor *base = pso_desc4(d, 1, !key.border);
    ArchEpoch *epoch = ep_new(); CHECK(epoch != nil, "fixture serializer is available"); if (!epoch) return 1;
    id seed = [epoch->comp newRenderPipelineStateWithDescriptor:base compilerTaskOptions:nil error:&error];
    CHECK(seed != nil, "archive base compiles"); if (!seed) return 1;
    char path[] = "/tmp/t_pso_future_gpu.XXXXXX"; int fd = mkstemp(path); if (fd < 0) abort(); close(fd); unlink(path);
    CHECK([epoch->ser serializeAsArchiveAndFlushToURL:[NSURL fileURLWithPath:@(path)] error:&error], "real archive is serialized");
    id<MTL4Archive> archive = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:@(path)] error:&error]; CHECK(archive != nil, "real archive opens"); if (!archive) return 1;
    uint64_t ak = arch_key(base); g_arch_ixf = @[archive]; nvn_hm_put(&g_arch_ix, &ak, (__bridge void *)archive);
    uint64_t archived = g_pb_archived, built = g_pb_built;
    id ps = pso_get_(pr, nil); CHECK(object_getClass(ps) == PsoFuture.class, "production draw requests an indexed archive future");
    enc_r_pso(enc, ps); enc_r_viewport(enc, (MTLViewport){0,0,8,8,0,1}); enc_r_scissor(enc, (MTLScissorRect){0,0,8,8});
    enc_r_cull(enc, MTLCullModeNone); enc_r_draw(enc, MTLPrimitiveTypeTriangle, 0, 3);
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "future draw completes with Metal validation");
    CHECK(g_pb_archived == archived + 1 && g_pb_built == built, "pipeline base comes from the archive without compilation");
    CHECK(object_getClass(hm_get_id(&g_pso, &key)) != PsoFuture.class, "submission collects the real pipeline");
    id<MTLBuffer> bytes = [g_dev newBufferWithLength:8 * 256 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:tex_mtl(&target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(8,8,1)
        toBuffer:bytes destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:8 * 256];
    [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; CHECK(cb.status == MTLCommandBufferStatusCompleted, "GPU pixel readback completes");
    int red = 1; for (unsigned y = 0; y < 8; y++) for (unsigned x = 0; x < 8; x++) {
        const uint8_t *p = (uint8_t *)bytes.contents + y * 256 + x * 4; red &= p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255;
    }
    CHECK(red, "all 64 pixels are literal red through the archived future pipeline"); unlink(path);
    printf("PSO_FUTURE GPU checks=%d failed=%d\n", checks, failed); return failed != 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "--gpu")) return gpu_check();
    alarm(30); int sync = argc > 1 && !strcmp(argv[1], "--sync");
    setenv("DM_PSO_FUTURE", sync ? "0" : "1", 1); setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1);
    char path[] = "/tmp/t_pso_future.XXXXXX"; int fd = mkstemp(path); if (fd < 0) abort(); close(fd); setenv("DM_PSO_RECORD", path, 1);
    pso4_init(); FixtureCompiler *compiler = [FixtureCompiler new]; g_comp4 = (id)compiler; g_rec = 1;
    state_reset(); g_pass.cfmt[0] = MTLPixelFormatRGBA8Unorm; g_pass.samples = 1;
    NvProg *pr = program(); pso_key key; pso_key_fill(&key, pr->sh[0], pr->sh[1], g_pass.cfmt, 0, 0, 1, 0);
    MTLRenderPipelineDescriptor *d = pso_desc(&key, pr->sh[0], pr->sh[1], nil, 0);
    uint64_t ak = arch_key(pso_desc4(d, 1, !key.border)); CHECK(ak != 0, "fixture has the production archive key");
    FixtureArchive *archive = [FixtureArchive new]; archive->hold = 1; archive->entered = dispatch_semaphore_create(0); archive->release = dispatch_semaphore_create(0);
    g_arch_ixf = @[(id)archive]; nvn_hm_put(&g_arch_ix, &ak, (__bridge void *)archive);
    request r = {pr, dispatch_semaphore_create(0), nil}; pthread_t th;
    if (pthread_create(&th, NULL, request_main, &r)) abort(); wait_for(archive->entered);
    int returned = dispatch_semaphore_wait(r.done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) == 0;
    CHECK(returned == !sync, "future lookup returns while archive is held; synchronous lookup waits");
    CHECK(archive->calls == 1, "one archive lookup for the key");
    dispatch_semaphore_signal(archive->release); if (!returned) wait_for(r.done); pthread_join(th, NULL);
    FixtureEncoder *enc = [FixtureEncoder new]; g_rx_enc = enc;
    if (!sync) {
        CHECK(object_getClass(r.result) == PsoFuture.class, "pipeline lookup returns a deferred result");
        CHECK(pso_get_(pr, nil) == r.result && archive->calls == 1, "repeated draw shares the same future");
        rec_t bind = {.op = RO_R_PSO_FUTURE, .nobj = 1}; bind.a[0] = rec_obj(r.result); rec_exec(&bind);
        pso_future_collect();
        CHECK(object_getClass(hm_get_id(&g_pso, &key)) == FixturePipeline.class, "collection promotes the real pipeline into the cache");
        NSString *records = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
        CHECK([records containsString:@"R\t"], "successful future is recorded for the next prewarm");
    } else { rec_t bind = {.op = RO_R_PSO, .nobj = 1}; bind.a[0] = rec_obj(r.result); rec_exec(&bind); }
    rec_t draw = {.op = RO_R_DRAW}; draw.a[0] = MTLPrimitiveTypeTriangle; draw.a[2] = 3; rec_exec(&draw);
    CHECK(enc->draws == 1 && object_getClass(enc->bound) == FixturePipeline.class, "deferred encoder binds the real result and preserves the draw");
    archive->hold = 0;
    if (!sync) {
        // Both workers are busy with other work. The encoder can take a queued future without waiting for either queue.
        dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
        dispatch_queue_t q[PSO_FUTURE_WORKERS];
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) { q[i] = pso_future_queue(); dispatch_async(q[i], ^{ dispatch_semaphore_signal(entered); wait_for(release); }); }
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) wait_for(entered);
        drop_pipeline(&key, d); uint64_t own = g_pfu_own;
        id future = pso_get_(pr, nil); CHECK(object_getClass(future) == PsoFuture.class, "queued request has a future");
        CHECK(pso_future_resolve(future) != nil && g_pfu_own == own + 1, "encoder steals its queued request");
        int calls = archive->calls;
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) dispatch_semaphore_signal(release);
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) dispatch_sync(q[i], ^{});
        CHECK(archive->calls == calls, "the late worker does not build a stolen request again"); pso_future_collect();
        // An index can outlive usable binaries: retain the normal compiler fallback and cache a failure without issuing any draw with the old pipeline.
        drop_pipeline(&key, d); archive->miss = 1; uint64_t fallback = g_pfu_fallback;
        future = pso_get_(pr, nil); CHECK(pso_future_resolve(future) != nil && g_pfu_fallback == fallback + 1, "stale archive entry falls back to compilation"); pso_future_collect();
        drop_pipeline(&key, d); compiler->fail = 1;
        future = pso_get_(pr, nil); rec_t bind = {.op = RO_R_PSO_FUTURE, .nobj = 1}; bind.a[0] = rec_obj(future); rec_exec(&bind);
        rec_exec(&draw); CHECK(enc->draws == 1, "failed future never draws with the previous pipeline"); pso_future_collect();
        CHECK(hm_get_id(&g_pso_fail, &key) && pso_get_(pr, nil) == nil, "failed future is cached and not retried");
        bind.op = RO_R_PSO; bind.a[0] = rec_obj([FixturePipeline new]); rec_exec(&bind); rec_exec(&draw);
        CHECK(enc->draws == 2, "a later valid pipeline restores draws");
        compiler->fail = 0; archive->miss = 0; drop_pipeline(&key, d);
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) { q[i] = pso_future_queue(); dispatch_async(q[i], ^{ dispatch_semaphore_signal(entered); wait_for(release); }); }
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) wait_for(entered);
        int admitted = 0;
        for (unsigned i = 0; i < PSO_FUTURE_MAX; i++) { pso_key variant = key; variant.chmask = i; admitted += pso_future_issue(&variant, pr->sh[0], pr->sh[1]) != nil; }
        CHECK(admitted == PSO_FUTURE_MAX && g_pso_futures.count == PSO_FUTURE_MAX, "a blocked burst stays within the pending descriptor limit");
        pso_key extra = key; extra.chmask = PSO_FUTURE_MAX;
        CHECK(pso_future_issue(&extra, pr->sh[0], pr->sh[1]) == nil, "a full future queue retains the original synchronous fallback");
        int lookups = archive->calls; uint64_t compiled = g_pb_built, specialized = g_pb_spec;
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) dispatch_semaphore_signal(release);
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) dispatch_sync(q[i], ^{});
        pso_future_collect(); CHECK(g_pso_futures.count == 0, "the completed burst releases pending descriptors");
        CHECK(archive->calls == lookups + 1 && g_pb_built == compiled && g_pb_spec == specialized + PSO_FUTURE_MAX, "parallel color configurations share one archived base without compilation");
        pso_key none = key, all = key; none.chmask = 0; all.chmask = 15;
        FixturePipeline *no_writes = hm_get_id(&g_pso, &none), *all_writes = hm_get_id(&g_pso, &all);
        CHECK(no_writes->mask == MTLColorWriteMaskNone && all_writes->mask == MTLColorWriteMaskAll, "shared bases retain each pipeline's distinct color write mask");
        // Collection must not hide a backlog of dispatch blocks behind stalled workers.
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) { q[i] = pso_future_queue(); dispatch_async(q[i], ^{ dispatch_semaphore_signal(entered); wait_for(release); }); }
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) wait_for(entered);
        __weak id collected = nil; admitted = 0;
        for (unsigned i = 0; i < PSO_FUTURE_MAX; i++) @autoreleasepool {   // each collected result's submission pool has ended, while both queues remain held
            pso_key variant = key; variant.chmask = 128 + i; drop_pipeline(&variant, d);
            id item = pso_future_issue(&variant, pr->sh[0], pr->sh[1]); if (!item) break; admitted++; collected = item;
            (void)pso_future_resolve(item); pso_future_collect(); item = nil;
        }
        CHECK(admitted == PSO_FUTURE_MAX && !collected, "late queued blocks do not retain stolen and collected futures");
        extra.chmask = 256;
        CHECK(g_pso_future_jobs == PSO_FUTURE_MAX && pso_future_issue(&extra, pr->sh[0], pr->sh[1]) == nil, "the dispatch backlog also has a hard limit");
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) dispatch_semaphore_signal(release);
        for (int i = 0; i < PSO_FUTURE_WORKERS; i++) dispatch_sync(q[i], ^{});
        CHECK(g_pso_future_jobs == 0, "retired dispatch blocks restore admission capacity");
        drop_pipeline(&key, d); nvn_hm_del(&g_arch_ix, &ak); uint64_t issued = g_pfu_issued;
        CHECK(object_getClass(pso_get_(pr, nil)) == FixturePipeline.class && g_pfu_issued == issued, "an unindexed pipeline keeps the original lookup path");
    }
    unlink(path); printf("PSO_FUTURE mode=%s checks=%d failed=%d submit_returned_before_archive=%d\n", sync ? "sync" : "future", checks, failed, returned);
    return failed != 0;
} }
