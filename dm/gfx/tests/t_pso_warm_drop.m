// Disposable foreground preparation must not retain its objects or disturb
// live/prefetched objects; existing archives must still serve the first draw.
#define main pso_prewarm_test_main
#include "t_pso_prewarm.m"
#undef main

static void draw_after_prepare(id<MTLRenderPipelineState> pipeline) {
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget; desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:desc];
    float vertices[24] = {-1,-1,0,1, 0,0,0,0, 3,-1,0,1, 0,0,0,0, -1,3,0,1, 0,0,0,0};
    id<MTLBuffer> vb = [g_dev newBufferWithBytes:vertices length:sizeof vertices options:MTLResourceStorageModeShared];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = [queue commandBuffer]; id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline]; [encoder setVertexBuffer:vb offset:0 atIndex:VB_SLOT(0)];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [encoder endEncoding];
    [command commit]; [command waitUntilCompleted];
    EXPECT("first draw completed", MTLCommandBufferStatusCompleted, command.status);
    uint8_t pixel[4] = {0}; [target getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    EXPECT("first draw has the prepared shader's colour", 1, pixel[0] >= 127 && pixel[0] <= 129 && pixel[1] >= 63 && pixel[1] <= 65 && pixel[2] == 255);
}

static int prepare_child(NSString *root, NSString *mode) {
    int drop = [mode containsString:@"drop"];
    mtl_init(); shmap_read_once(); pso4_init();
    if (!g_comp4) { fprintf(stderr,"t_pso_warm_drop: no Metal 4 compiler\n"); return 1; }
    NvShader *vs = shader_get(@"warm-vs",0), *fs = shader_get(@"warm-fs",1);
    EXPECT("live shaders loaded", 1, vs && fs); if (!vs || !fs) return 1;
    pso_key live_key = key_at(vs,fs,24);
    id<MTLRenderPipelineState> live_pipeline = pso_build(desc_of(&live_key,vs,fs),1,nil);
    EXPECT("live pipeline created", 1, live_pipeline != nil); if (!live_pipeline) return 1;
    hm_put_id(&g_pso,&live_key,live_pipeline);
    unsigned live_bases = g_pbase.n; NSUInteger live_functions = g_fn4.count;
    WarmItem *prefetch = [WarmItem new]; prefetch->kind = 0; prefetch->key = @"warm-vs"; prefetch->shader = vs; warm_enqueue(prefetch);
    shmap_load();
    while (atomic_load(&g_warm_running)) usleep(1000);
    arch_flush_wait();
    EXPECT("foreground mode ends", 0, g_warm_drop_active);
    EXPECT("live shader identity unchanged", 1, g_shcache[@"warm-vs"] == vs && g_shcache[@"warm-fs"] == fs);
    EXPECT("live pipeline identity unchanged", 1, hm_get_id(&g_pso,&live_key) == live_pipeline);
    EXPECT("live function descriptors retained", 1, g_fn4.count >= live_functions);
    if (drop) {
        EXPECT("no disposable base published to live cache", live_bases, g_pbase.n);
        EXPECT("only the unrelated prefetch item is queued", 1, g_warm_items.count);
        EXPECT("private bases cleared", 0, g_extended_pbase.n + g_extended_miss.n + g_extended_pending.n);
        EXPECT("private functions cleared", 1, !g_extended_fn4 && !g_extended_fn_dev && !g_extended_fn_off);
        EXPECT("temporary shaders cleared", 1, !g_warm_dict && !g_warm_loads);
        EXPECT("temporary mode did not reach the submit thread", 0, prepare_isolated());
    } else EXPECT("normal and background prewarm still publish objects", 1, g_warm_items.count > 1);
    warm_claim();
    EXPECT("prefetched shader remains usable", 1, g_shcache[@"warm-vs"] == vs);
    EXPECT("compute cache follows the selected mode", !drop, g_cps.n != 0);
    uint64_t built = g_pb_built;
    pso_key wanted = key_at(vs,fs,0);
    id<MTLRenderPipelineState> pipeline = pso_build(desc_of(&wanted,vs,fs),1,nil);
    EXPECT("demand pipeline available after preparation", 1, pipeline != nil);
    if ([mode isEqual:@"reuse-drop"]) {
        EXPECT("existing archive prevented all base compiles", 0, g_pb_built);
        EXPECT("first draw did not recompile a base", built, g_pb_built);
    }
    if (pipeline) draw_after_prepare(pipeline);
    if ([mode isEqual:@"extended-drop"]) EXPECT("extended preparation record retained", 1,
        [NSFileManager.defaultManager fileExistsAtPath:[arch_extended_dir() stringByAppendingPathComponent:@"extended.json"]]);
    printf("t_pso_warm_drop %s: %d checks, %d failed\n",mode.UTF8String,checks,failed);
    (void)root; return failed != 0;
}

int main(int argc, char **argv) { @autoreleasepool {
    alarm(180);
    unsetenv("DM_SAVE"); unsetenv("DM_PSO_USER"); unsetenv("DM_PSO_RECORD");
    setenv("DM_PSO_STANDIN","0",1); setenv("DM_PSO_PREBUILD","0",1); setenv("DM_NVN_PREDICT","0",1);
    if (argc == 4 && !strcmp(argv[1],"--case")) return prepare_child(@(argv[2]),@(argv[3]));
    char tmp[PATH_MAX]; snprintf(tmp,sizeof tmp,"%s/t_pso_warm_drop.XXXXXX",getenv("TMPDIR") ?: "/tmp"); if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s",DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    if (!fixtures(msl,tables)) { fprintf(stderr,"t_pso_warm_drop: no Metal compiler; not run\n"); return 1; }
    put([msl stringByAppendingPathComponent:@"inputs.tsv"],@"game\t01007EF00011E000\ninputs\twarm-drop-fixture\n");
    setenv("DM_MSL_DIR",[root stringByAppendingPathComponent:@"msl"].UTF8String,1);
    setenv("DM_NVN_SHMAP",[tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String,1);
    setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_EXTENDED","off",1); setenv("DM_PSO_ARCHIVE","off",1); unsetenv("DM_PSO_WARM_DROP");
    mtl_init(); shmap_load();
    NvShader *vs = shader_load(@"warm-vs",0,0), *fs = shader_load(@"warm-fs",1,0);
    if (!vs || !fs) return 1;
    NSMutableString *rows = [NSMutableString stringWithString:@"S\twarm-vs\t0\nS\twarm-fs\t1\nC\twarm-cs\n"];
    for (unsigned i=0;i<2;i++) { pso_key k = key_at(vs,fs,i*4); [rows appendString:row_of(&k)]; }
    NSString *manifest = [tables stringByAppendingPathComponent:@"pso_manifest.tsv"]; put(manifest,rows);
    NSString *archive = [root stringByAppendingPathComponent:@"archive"];
    for (NSString *mode in @[@"default",@"off",@"cold-drop",@"reuse-drop",@"background",@"extended-drop"]) {
        NSMutableDictionary *env = [@{@"DM_PSO_ARCHIVE": archive, @"DM_PSO_MANIFEST": manifest,
            @"DM_PSO_EXTENDED": @"off", @"DM_PSO_PREPARE": @"1", @"DM_PSO_PREPARE_THREADS": @"2"} mutableCopy];
        if (![mode isEqual:@"default"]) env[@"DM_PSO_WARM_DROP"] = [mode isEqual:@"off"] ? @"0" : @"1";
        if ([mode isEqual:@"cold-drop"] || [mode isEqual:@"extended-drop"]) env[@"DM_PSO_ARCHIVE"] = [root stringByAppendingPathComponent:mode];
        if ([mode isEqual:@"background"]) env[@"DM_PSO_PREPARE"] = @"0";
        if ([mode isEqual:@"extended-drop"]) env[@"DM_PSO_EXTENDED"] = manifest;
        NSString *log = [root stringByAppendingFormat:@"/%@.log",mode];
        int status = run_self(@[@"--case",root,mode],env,log);
        EXPECT(mode.UTF8String,0,status);
        NSString *text = slurp(log);
        EXPECT("release log follows foreground selection",[mode containsString:@"drop"],[text containsString:@"pipeline prepare: dropped temporary objects"]);
        if (status) fprintf(stderr,"%s\n",text.UTF8String);
    }
    printf("t_pso_warm_drop: %d checks, %d failed; logs %s\n",checks,failed,root.UTF8String);
    if (!failed) [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    return failed != 0;
} }
