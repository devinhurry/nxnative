// Reuse the existing synthetic shaders and child-process helpers. No game files.
#define main pso_prewarm_test_main
#include "t_pso_prewarm.m"
#undef main

static int bake_child(NSString *mode) {
    g_arch_period_max = 64;   // cross serializer periods as well as memory batches
    mtl_init(); shmap_load();
    NSString *stamp = [g_arch_dir stringByAppendingPathComponent:@"baked.json"];
    if ([mode isEqual:@"invalid"] || [mode isEqual:@"failure"] || [mode isEqual:@"write-failure"] || [mode isEqual:@"stamp-failure"] || [mode isEqual:@"disabled"]) {
        BOOL directory = NO; BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:stamp isDirectory:&directory];
        EXPECT("no false completion record", 0, exists && !directory);
        if ([mode isEqual:@"write-failure"]) {
            EXPECT("invalid archive disables capture", 0, g_arch_cap);
            NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
            pso_key k = key_at(vs, fs, 0); NSError *error = nil;
            EXPECT("normal pipeline creation survives invalid archive", 1, pso_build(desc_of(&k, vs, fs), !k.border, &error) != nil);
        }
        EXPECT("temporary objects released after failure", 0, g_bake_pbase.n + g_bake_pending.n + g_bake_fn4.count);
        return failed != 0;
    }
    EXPECT("completion record exists", 1, [NSFileManager.defaultManager fileExistsAtPath:stamp]);
    EXPECT("render objects not adopted", 0, g_pso.n);
    EXPECT("base objects not adopted", 0, g_pbase.n);
    EXPECT("bake base cache released", 0, g_bake_pbase.n + g_bake_pending.n + g_bake_miss.n);
    EXPECT("bake function maps released", 0, g_bake_fn4.count + g_bake_fn_dev.count + g_bake_fn_off.count);
    EXPECT("bake shader dictionary released", 0, g_warm_dict.count);
    if ([mode isEqual:@"cold"] || [mode isEqual:@"repair"]) EXPECT("missing bases compiled", 1, g_pb_built + atomic_load(&g_cps_built) > 0);
    if ([mode isEqual:@"reuse"] || [mode isEqual:@"refresh"]) EXPECT("existing bases not recompiled", 0, g_pb_built);
    NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
    EXPECT("normal shader loading after bake", 1, vs && fs);
    uint64_t built = g_pb_built, hits = g_pb_archived;
    for (unsigned i = 0; i < 129; i++) {
        pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 1024;
        NSError *error = nil;
        EXPECT("baked descriptor usable by a normal draw", 1, pso_build(desc_of(&k, vs, fs), !k.border, &error) != nil);
    }
    pso_key amp = key_at(vs, fs, 0); amp.stream[0].stride = 1024; amp.fsfn = AMP_MARK;
    MTLRenderPipelineDescriptor *ad = desc_of(&amp, vs, fs);
    EXPECT("amplified row restores the real descriptor", 2, ad.maxVertexAmplificationCount);
    EXPECT("amplified pipeline found in archive", 1, pso_build(ad, !amp.border, nil) != nil);
    EXPECT("draw path did not compile a baked base", 0, g_pb_built - built);
    EXPECT("draw path found every baked base", 130, g_pb_archived - hits);
    NvShader *cs = shader_load(@"warm-cs", 5, 0);
    uint64_t csbuilt = atomic_load(&g_cps_built), cshits = atomic_load(&g_cps_run);
    EXPECT("baked compute pipeline usable", 1, cps_new_b(cs->fn, 1, nil) != nil);
    EXPECT("compute path did not recompile", csbuilt, atomic_load(&g_cps_built));
    EXPECT("compute path found device archive", cshits + 1, atomic_load(&g_cps_run));
    printf("t_pso_bake child %s: %d checks, %d failed\n", mode.UTF8String, checks, failed);
    return failed != 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    alarm(240);
    if (argc == 4 && !strcmp(argv[1], "--bake")) return bake_child(@(argv[3]));
    if (argc == 3 && !strcmp(argv[1], "--validate")) {
        setenv("DM_PSO_BAKE", "off", 1); setenv("DM_PSO_MANIFEST", "off", 1);
        mtl_init(); shmap_load();
        NSString *text = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil];
        EXPECT("supplied list is compatible with the current shader map and key parser", 1, bake_valid(text));
        printf("t_pso_bake validation: %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s/t_pso_bake.XXXXXX", getenv("TMPDIR") ?: "/tmp"); if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s", DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    if (!fixtures(msl, tables)) { fprintf(stderr, "t_pso_bake: Metal compiler unavailable\n"); return 1; }
    put([msl stringByAppendingPathComponent:@"inputs.tsv"], @"game\t01007EF00011E000\ninputs\tfixture-v1\n");
    put([tables stringByAppendingPathComponent:@"pso_manifest.tsv"], @"# No live-cache warm-up in this test\n");
    setenv("DM_MSL_DIR", [root stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_NVN_SHMAP", [tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_BAKE", "off", 1); setenv("DM_PSO_ARCHIVE", "off", 1);
    setenv("DM_PSO_MTL4", "1", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_BUNDLE", "off", 1);
    mtl_init(); shmap_load();
    NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
    pso4_init();
    if (!vs || !fs || !g_comp4) { fprintf(stderr, "t_pso_bake: required Metal 4 fixture unavailable\n"); return 1; }
    EXPECT("valid shader stage accepted", 1, bake_valid(@"S\twarm-vs\t0\n"));
    EXPECT("wrong shader stage rejected", 0, bake_valid(@"S\twarm-vs\t1\n"));
    EXPECT("non-numeric shader stage rejected", 0, bake_valid(@"S\twarm-vs\tnonsense\n"));
    NSMutableString *list = [NSMutableString stringWithString:@"# Two batches, a duplicate, and a compute pipeline\nC\twarm-cs\n"];
    for (unsigned i = 0; i < 129; i++) { pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 1024; [list appendString:row_of(&k)]; }
    pso_key k = key_at(vs, fs, 0); k.stream[0].stride = 1024; [list appendString:row_of(&k)];
    pso_key amp = k; amp.fsfn = AMP_MARK; pso_fz_desc afz = {.kind = 2};
    pso_skey ask; char ahex[sizeof ask * 2 + 1];
    pso_skey_from(&amp, vs, fs, 0, &afz, &ask); pso_skey_hex(&ask, ahex);
    [list appendFormat:@"R\t%s\n", ahex];
    NSString *path = [tables stringByAppendingPathComponent:@"pso_bake.tsv"], *archive = [root stringByAppendingPathComponent:@"archive"];
    put(path, list);
    NSMutableDictionary *env = [@{@"DM_PSO_ARCHIVE": archive, @"DM_PSO_BAKE": path, @"DM_PSO_PREPARE": @"1", @"DM_PSO_PREPARE_THREADS": @"2", @"DM_PSO_COMPACT": @"off"} mutableCopy];
    int (^run)(NSString *) = ^int(NSString *mode) {
        return run_self(@[@"--bake", root, mode], env, [root stringByAppendingFormat:@"/%@.log", mode]);
    };
    EXPECT("cold startup bake, release and draw lookup", 0, run(@"cold"));
    EXPECT("next process reuses the completed bake", 0, run(@"reuse"));
    NSString *warmlog = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"reuse.log"] encoding:NSUTF8StringEncoding error:nil];
    EXPECT("completion check skips preparation", 1, [warmlog containsString:@"completion record matches; nothing to build"]);
    NSArray *files = mtl4a(archive);
    EXPECT("multiple batches produced archives", 1, files.count >= 2);
    if (files.count) [NSFileManager.defaultManager removeItemAtPath:[archive stringByAppendingPathComponent:files[0]] error:nil];
    EXPECT("missing archive repaired at next start", 0, run(@"repair"));
    put([msl stringByAppendingPathComponent:@"inputs.tsv"], @"game\t01007EF00011E000\ninputs\tfixture-v2\n");
    EXPECT("changed library-generation stamp rechecks the list", 0, run(@"refresh"));
    NSString *refresh = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"refresh.log"] encoding:NSUTF8StringEncoding error:nil];
    EXPECT("changed generation did not skip", 0, [refresh containsString:@"completion record matches; nothing to build"]);
    NSString *refresh2 = [root stringByAppendingPathComponent:@"archive/baked.json"];
    [NSFileManager.defaultManager removeItemAtPath:refresh2 error:nil];
    EXPECT("existing captures reused after an interrupted completion write", 0, run(@"refresh"));
    [list appendString:@"# changed list identity\n"]; put(path, list);
    EXPECT("changed list rechecked without recompiling known bases", 0, run(@"refresh"));
    NSString *stampbad = [root stringByAppendingPathComponent:@"stamp-failure-archive"];
    [NSFileManager.defaultManager createDirectoryAtPath:[stampbad stringByAppendingPathComponent:@"baked.json"] withIntermediateDirectories:YES attributes:nil error:nil];
    env[@"DM_PSO_ARCHIVE"] = stampbad;
    EXPECT("completion write failure is not accepted", 0, run(@"stamp-failure"));
    NSString *blocked = [root stringByAppendingPathComponent:@"blocked-archive"]; put(blocked, @"not a directory");
    env[@"DM_PSO_ARCHIVE"] = blocked;
    EXPECT("archive write failure gets no completion record", 0, run(@"write-failure"));
    NSString *bad = [root stringByAppendingPathComponent:@"bad-archive"];
    env[@"DM_PSO_ARCHIVE"] = bad; put(path, @"R\tnot-a-key\n");
    EXPECT("malformed list gets no completion record", 0, run(@"invalid"));
    put(path, list);
    put([msl stringByAppendingPathComponent:@"warm-fs.json"], [NSString stringWithFormat:@"{\"chain\":\"%s\",\"route\":\"B\",\"entry\":\"missing\",\"bindings\":[]}", DMSH_CHAIN]);
    EXPECT("compile/load failure gets no completion record", 0, run(@"failure"));
    env[@"DM_PSO_BAKE"] = @"off";
    EXPECT("explicit opt-out leaves no completion record", 0, run(@"disabled"));
    printf("t_pso_bake: %d checks, %d failed; evidence %s\n", checks, failed, root.UTF8String);
    return failed != 0;
} }
