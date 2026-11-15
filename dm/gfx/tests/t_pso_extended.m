// Reuse the existing synthetic shaders and child-process helpers. No game files.
#define main pso_prewarm_test_main
#include "t_pso_prewarm.m"
#undef main

// A naming migration must preserve both archive contents and their timestamps.
static NSDictionary *archive_snapshot(NSString *dir) {
    NSMutableDictionary *snapshot = [NSMutableDictionary dictionary];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![@[@"mtl4a", @"keys"] containsObject:name.pathExtension]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        snapshot[name] = @{@"state": extended_file_state(path), @"hash": extended_hash([NSData dataWithContentsOfFile:path])};
    }
    return snapshot;
}

// A small ordinary warm list must not discard the wider extended preparation
// when unrelated gameplay files push its archive tier over the compact limit.
static int compact_child(NSString *mode) {
    mtl_init(); shmap_load(); pso4_init();
    NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
    if ([mode isEqual:@"append"]) {
        for (unsigned i = 8; i < 16; i++) {
            pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 128;
            EXPECT("gameplay pipeline created", 1, pso_build(desc_of(&k, vs, fs), !k.border, nil) != nil);
            arch_flush_wait();
        }
        return failed != 0;
    }
    while (atomic_load(&g_warm_running)) usleep(1000);
    arch_flush_wait(); if (g_arch_q) dispatch_sync(g_arch_q, ^{});
    NSData *json = [NSData dataWithContentsOfFile:[g_arch_dir stringByAppendingPathComponent:@"extended.json"]];
    NSDictionary *record = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    EXPECT("completed preparation survives the whole startup", 1,
           extended_record_matches(record, extended_identity([NSData dataWithContentsOfFile:extended_path()])));
    if ([mode hasSuffix:@"reuse"]) EXPECT("no prepared base recompiled at startup", 0, g_pb_built);
    if ([mode isEqual:@"compact-reuse"] || [mode isEqual:@"background-reuse"]) {
        EXPECT("unrelated archives still compacted", 1, g_compacted > 0);
        EXPECT("unrelated old files removed", 2, mtl4a(g_arch_dir).count);
    }
    uint64_t built = g_pb_built;
    for (unsigned i = 0; i < 7; i++) {
        pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 128;
        EXPECT("every extended pipeline remains usable", 1, pso_build(desc_of(&k, vs, fs), !k.border, nil) != nil);
    }
    EXPECT("no extended base lost to compaction", built, g_pb_built);
    return failed != 0;
}
static void compact_cycles(NSString *root, NvShader *vs, NvShader *fs) {
    NSString *archive = [root stringByAppendingPathComponent:@"compact-archive"], *path = [root stringByAppendingPathComponent:@"compact-list.tsv"];
    NSString *manifest = [root stringByAppendingPathComponent:@"compact-warm.tsv"];
    NSMutableString *list = [NSMutableString string], *warm = [NSMutableString string];
    for (unsigned i = 0; i < 9; i++) {
        pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 128; NSString *row = row_of(&k);
        if (i < 7) [list appendString:row];
        if (!i || i == 8) [warm appendString:row];
    }
    put(path, list); put(manifest, warm);
    NSMutableDictionary *env = [@{@"DM_PSO_ARCHIVE": archive, @"DM_PSO_EXTENDED": path,
        @"DM_PSO_MANIFEST": manifest, @"DM_PSO_PREPARE": @"1", @"DM_PSO_PREPARE_THREADS": @"2"} mutableCopy];
    int (^run)(NSString *) = ^int(NSString *mode) {
        return run_self(@[@"--compact", root, mode], env, [root stringByAppendingFormat:@"/compact-%@.log", mode]);
    };
    EXPECT("compaction fixture prepared", 0, run(@"cold"));
    NSString *stamp = [archive stringByAppendingPathComponent:@"extended.json"];
    NSData *record = [NSData dataWithContentsOfFile:stamp];
    NSDictionary *inventory = [NSJSONSerialization JSONObjectWithData:record options:0 error:nil][@"files"];
    NSDictionary *snapshot = archive_snapshot(archive);
    for (int round = 0; round < 3; round++) {
        env[@"DM_PSO_EXTENDED"] = @"off"; env[@"DM_PSO_MANIFEST"] = @"off";
        EXPECT("small gameplay archives accumulated", 0, run(@"append"));
        EXPECT("archive tier reaches compaction threshold", 9, mtl4a(archive).count);
        env[@"DM_PSO_EXTENDED"] = path; env[@"DM_PSO_MANIFEST"] = manifest;
        if (round == 1) EXPECT("legacy record used during compaction", 1,
            [NSFileManager.defaultManager moveItemAtPath:stamp toPath:[archive stringByAppendingPathComponent:@"baked.json"] error:nil]);
        env[@"DM_PSO_PREPARE"] = round == 2 ? @"0" : @"1";
        EXPECT("compacting startup retains the completed preparation", 0, run(round == 2 ? @"background-reuse" : @"compact-reuse"));
        env[@"DM_PSO_PREPARE"] = @"1";
        EXPECT("following process skips extended preparation", 0, run(@"after-reuse"));
        EXPECT("completion record preserved byte for byte", 1, [record isEqual:[NSData dataWithContentsOfFile:stamp]]);
        NSDictionary *after = archive_snapshot(archive);
        for (NSString *name in inventory) EXPECT("protected archive and index bytes and mtimes preserved", 1, [snapshot[name] isEqual:after[name]]);
        NSString *log = slurp([root stringByAppendingPathComponent:@"compact-after-reuse.log"]);
        EXPECT("following startup did not traverse the extended list", 1, [log containsString:@"completion record matches; nothing to build"]);
    }
}

static int extended_child(NSString *mode) {
    g_arch_period_max = 64;   // cross serializer periods as well as memory batches
    mtl_init(); shmap_load();
    NSString *stamp = [g_arch_dir stringByAppendingPathComponent:@"extended.json"];
    if ([mode isEqual:@"invalid"] || [mode isEqual:@"failure"] || [mode isEqual:@"write-failure"] || [mode isEqual:@"stamp-failure"] || [mode isEqual:@"disabled"]) {
        BOOL directory = NO; BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:stamp isDirectory:&directory];
        EXPECT("no false completion record", 0, exists && !directory);
        if ([mode isEqual:@"write-failure"]) {
            EXPECT("invalid archive disables capture", 0, g_arch_cap);
            NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
            pso_key k = key_at(vs, fs, 0); NSError *error = nil;
            EXPECT("normal pipeline creation survives invalid archive", 1, pso_build(desc_of(&k, vs, fs), !k.border, &error) != nil);
        }
        EXPECT("temporary objects released after failure", 0, g_extended_pbase.n + g_extended_pending.n + g_extended_fn4.count);
        return failed != 0;
    }
    EXPECT("completion record exists", 1, [NSFileManager.defaultManager fileExistsAtPath:stamp]);
    EXPECT("render objects not adopted", 0, g_pso.n);
    EXPECT("base objects not adopted", 0, g_pbase.n);
    EXPECT("extended preparation base cache released", 0, g_extended_pbase.n + g_extended_pending.n + g_extended_miss.n);
    EXPECT("extended preparation function maps released", 0, g_extended_fn4.count + g_extended_fn_dev.count + g_extended_fn_off.count);
    EXPECT("extended preparation shader dictionary released", 0, g_warm_dict.count);
    if ([mode isEqual:@"cold"] || [mode isEqual:@"repair"]) EXPECT("missing bases compiled", 1, g_pb_built + atomic_load(&g_cps_built) > 0);
    if ([mode hasSuffix:@"reuse"] || [mode isEqual:@"refresh"]) {
        EXPECT("existing bases not recompiled", 0, g_pb_built);
        EXPECT("existing compute pipelines not recompiled", 0, atomic_load(&g_cps_built));
    }
    NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
    EXPECT("normal shader loading after preparation", 1, vs && fs);
    uint64_t built = g_pb_built, hits = g_pb_archived;
    for (unsigned i = 0; i < 129; i++) {
        pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 1024;
        NSError *error = nil;
        EXPECT("prepared descriptor usable by a normal draw", 1, pso_build(desc_of(&k, vs, fs), !k.border, &error) != nil);
    }
    pso_key amp = key_at(vs, fs, 0); amp.stream[0].stride = 1024; amp.fsfn = AMP_MARK;
    MTLRenderPipelineDescriptor *ad = desc_of(&amp, vs, fs);
    EXPECT("amplified row restores the real descriptor", 2, ad.maxVertexAmplificationCount);
    EXPECT("amplified pipeline found in archive", 1, pso_build(ad, !amp.border, nil) != nil);
    EXPECT("draw path did not compile a prepared base", 0, g_pb_built - built);
    EXPECT("draw path found every prepared base", 130, g_pb_archived - hits);
    NvShader *cs = shader_load(@"warm-cs", 5, 0);
    uint64_t csbuilt = atomic_load(&g_cps_built), cshits = atomic_load(&g_cps_run);
    EXPECT("prepared compute pipeline usable", 1, cps_new_b(cs->fn, 1, nil) != nil);
    EXPECT("compute path did not recompile", csbuilt, atomic_load(&g_cps_built));
    EXPECT("compute path found device archive", cshits + 1, atomic_load(&g_cps_run));
    printf("t_pso_extended child %s: %d checks, %d failed\n", mode.UTF8String, checks, failed);
    return failed != 0;
}
int main(int argc, char **argv) { @autoreleasepool {
    alarm(240);
    if (argc == 4 && !strcmp(argv[1], "--extended")) return extended_child(@(argv[3]));
    if (argc == 4 && !strcmp(argv[1], "--compact")) return compact_child(@(argv[3]));
    if (argc == 3 && !strcmp(argv[1], "--validate")) {
        setenv("DM_PSO_EXTENDED", "off", 1); setenv("DM_PSO_MANIFEST", "off", 1);
        mtl_init(); shmap_load();
        NSString *text = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil];
        EXPECT("supplied list is compatible with the current shader map and key parser", 1, extended_valid(text));
        printf("t_pso_extended validation: %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s/t_pso_extended.XXXXXX", getenv("TMPDIR") ?: "/tmp"); if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s", DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    if (!fixtures(msl, tables)) { fprintf(stderr, "t_pso_extended: Metal compiler unavailable\n"); return 1; }
    put([msl stringByAppendingPathComponent:@"inputs.tsv"], @"game\t01007EF00011E000\ninputs\tfixture-v1\n");
    put([tables stringByAppendingPathComponent:@"pso_manifest.tsv"], @"# No live-cache warm-up in this test\n");
    setenv("DM_MSL_DIR", [root stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_NVN_SHMAP", [tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_EXTENDED", "off", 1); setenv("DM_PSO_ARCHIVE", "off", 1);
    setenv("DM_PSO_MTL4", "1", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_BUNDLE", "off", 1);
    mtl_init(); shmap_load();
    NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
    pso4_init();
    if (!vs || !fs || !g_comp4) { fprintf(stderr, "t_pso_extended: required Metal 4 fixture unavailable\n"); return 1; }
    EXPECT("valid shader stage accepted", 1, extended_valid(@"S\twarm-vs\t0\n"));
    EXPECT("wrong shader stage rejected", 0, extended_valid(@"S\twarm-vs\t1\n"));
    EXPECT("non-numeric shader stage rejected", 0, extended_valid(@"S\twarm-vs\tnonsense\n"));
    NSMutableString *list = [NSMutableString stringWithString:@"# Two batches, a duplicate, and a compute pipeline\nC\twarm-cs\n"];
    for (unsigned i = 0; i < 129; i++) { pso_key k = key_at(vs, fs, 4 * i); k.stream[0].stride = 1024; [list appendString:row_of(&k)]; }
    pso_key k = key_at(vs, fs, 0); k.stream[0].stride = 1024; [list appendString:row_of(&k)];
    pso_key amp = k; amp.fsfn = AMP_MARK; pso_fz_desc afz = {.kind = 2};
    pso_skey ask; char ahex[sizeof ask * 2 + 1];
    pso_skey_from(&amp, vs, fs, 0, &afz, &ask); pso_skey_hex(&ask, ahex);
    [list appendFormat:@"R\t%s\n", ahex];
    NSString *path = [tables stringByAppendingPathComponent:@"pso_bake.tsv"], *archive = [root stringByAppendingPathComponent:@"archive"];
    put(path, list);
    NSMutableDictionary *env = [@{@"DM_PSO_ARCHIVE": archive, @"DM_PSO_EXTENDED": path, @"DM_PSO_PREPARE": @"1", @"DM_PSO_PREPARE_THREADS": @"2"} mutableCopy];
    int (^run)(NSString *) = ^int(NSString *mode) {
        return run_self(@[@"--extended", root, mode], env, [root stringByAppendingFormat:@"/%@.log", mode]);
    };
    EXPECT("cold startup preparation, release and draw lookup", 0, run(@"cold"));
    EXPECT("next process reuses the completed preparation", 0, run(@"reuse"));
    NSString *warmlog = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"reuse.log"] encoding:NSUTF8StringEncoding error:nil];
    EXPECT("completion check skips preparation", 1, [warmlog containsString:@"completion record matches; nothing to build"]);
    NSDictionary *snapshot = archive_snapshot(archive);
    NSString *stamp = [archive stringByAppendingPathComponent:@"extended.json"];
    NSString *legacy = [archive stringByAppendingPathComponent:@"baked.json"];
    NSData *record = [NSData dataWithContentsOfFile:stamp];
    EXPECT("legacy completion fixture ready", 1, [NSFileManager.defaultManager moveItemAtPath:stamp toPath:legacy error:nil]);
    // The old runtime variable and old list name still work. The new variable
    // is absent here, as it would be in an existing user's configuration.
    unsetenv("DM_PSO_EXTENDED");
    [env removeObjectForKey:@"DM_PSO_EXTENDED"]; env[@"DM_PSO_BAKE"] = path;
    EXPECT("legacy record reused without compilation", 0, run(@"legacy-reuse"));
    EXPECT("legacy completion record retained byte for byte", 1, [record isEqual:[NSData dataWithContentsOfFile:legacy]]);
    EXPECT("new completion record preserves the old identity", 1, [record isEqual:[NSData dataWithContentsOfFile:stamp]]);
    EXPECT("migration preserves archive bytes and mtimes", 1, [snapshot isEqual:archive_snapshot(archive)]);
    NSString *renamed = [tables stringByAppendingPathComponent:@"pso_extended.tsv"];
    EXPECT("same list renamed without changing contents", 1, [NSFileManager.defaultManager moveItemAtPath:path toPath:renamed error:nil]);
    path = renamed;
    env[@"DM_PSO_EXTENDED"] = path; env[@"DM_PSO_BAKE"] = @"off";
    EXPECT("renamed list reuses all existing pipelines", 0, run(@"renamed-reuse"));
    EXPECT("renaming preserves archive bytes and mtimes", 1, [snapshot isEqual:archive_snapshot(archive)]);
    EXPECT("renaming preserves completion record bytes", 1, [record isEqual:[NSData dataWithContentsOfFile:stamp]]);
    compact_cycles(root, vs, fs);

    // Default discovery prefers the new name, falls back to the old name, and
    // never lets a legacy variable override an explicit new value or opt-out.
    unsetenv("DM_PSO_BAKE");
    EXPECT("new default list discovered", 1, [extended_path() isEqualToString:path]);
    setenv("DM_PSO_BAKE", path.UTF8String, 1); setenv("DM_PSO_EXTENDED", "off", 1);
    EXPECT("new opt-out takes precedence over legacy variable", 1, extended_path() == nil);
    setenv("DM_PSO_EXTENDED", "/missing/extended-list.tsv", 1);
    EXPECT("explicit missing path does not fall back", 1, extended_path() == nil);
    unsetenv("DM_PSO_EXTENDED"); unsetenv("DM_PSO_BAKE");
    NSString *legacyList = [tables stringByAppendingPathComponent:@"pso_bake.tsv"];
    EXPECT("legacy filename fixture ready", 1, [NSFileManager.defaultManager moveItemAtPath:path toPath:legacyList error:nil]);
    EXPECT("legacy default list discovered", 1, [extended_path() isEqualToString:legacyList]);
    EXPECT("restore canonical list", 1, [NSFileManager.defaultManager moveItemAtPath:legacyList toPath:path error:nil]);
    NSArray *files = mtl4a(archive);
    EXPECT("multiple batches produced archives", 1, files.count >= 2);
    if (files.count) [NSFileManager.defaultManager removeItemAtPath:[archive stringByAppendingPathComponent:files[0]] error:nil];
    EXPECT("missing archive repaired at next start", 0, run(@"repair"));
    EXPECT("missing archive reason logged", 1, [slurp([root stringByAppendingPathComponent:@"repair.log"]) containsString:@"recorded file is missing:"]);
    put([msl stringByAppendingPathComponent:@"inputs.tsv"], @"game\t01007EF00011E000\ninputs\tfixture-v2\n");
    EXPECT("changed library-generation stamp rechecks the list", 0, run(@"refresh"));
    NSString *refresh = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"refresh.log"] encoding:NSUTF8StringEncoding error:nil];
    EXPECT("changed generation did not skip", 0, [refresh containsString:@"completion record matches; nothing to build"]);
    EXPECT("changed generation reason logged", 1, [refresh containsString:@"identity changed: inputs"]);
    NSString *refresh2 = [root stringByAppendingPathComponent:@"archive/extended.json"];
    [NSFileManager.defaultManager removeItemAtPath:refresh2 error:nil];
    EXPECT("existing captures reused after an interrupted completion write", 0, run(@"refresh"));
    [list appendString:@"# changed list identity\n"]; put(path, list);
    EXPECT("changed list rechecked without recompiling known bases", 0, run(@"refresh"));
    EXPECT("changed list reason logged", 1, [slurp([root stringByAppendingPathComponent:@"refresh.log"]) containsString:@"identity changed: list"]);
    NSString *stampbad = [root stringByAppendingPathComponent:@"stamp-failure-archive"];
    [NSFileManager.defaultManager createDirectoryAtPath:[stampbad stringByAppendingPathComponent:@"extended.json"] withIntermediateDirectories:YES attributes:nil error:nil];
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
    env[@"DM_PSO_EXTENDED"] = @"off";
    EXPECT("explicit opt-out leaves no completion record", 0, run(@"disabled"));
    printf("t_pso_extended: %d checks, %d failed; evidence %s\n", checks, failed, root.UTF8String);
    return failed != 0;
} }
