// Optional first-start bake. Descriptions use the normal prewarm parser and
// compiler; each batch owns its function/base caches and keeps no draw objects.
static NSString *bake_path(void) {
    if (g_pre_tool) return nil;   // the standalone tool controls its own lists
    const char *e = getenv("DM_PSO_BAKE");
    if (e && (!strcmp(e, "off") || !strcmp(e, "0"))) return nil;
    NSString *p = e && *e ? @(e) : [g_shmap_path.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pso_bake.tsv"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}
static NSString *bake_hash(NSData *data) {
    if (!data) return nil;
    uint8_t hash[CC_SHA256_DIGEST_LENGTH]; char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + i * 2, 3, "%02x", hash[i]);
    return @(hex);
}
static NSDictionary *bake_identity(NSData *list) {
    NSString *inputs = bake_hash(msl_data([g_msl_dir stringByAppendingPathComponent:@"inputs.tsv"]));
    NSString *map = bake_hash([NSData dataWithContentsOfFile:g_shmap_path]);
    if (!inputs || !map) return nil;   // no trusted generation to reuse next time
    return @{@"schema": @1, @"chain": @DMSH_CHAIN, @"inputs": inputs, @"map": map,
             @"list": bake_hash(list), @"gpu": g_dev.architecture.name ?: @"unknown",
             @"os": arch_os_build(), @"depth": @(atomic_load(&g_depth_zero))};
}
static NSDictionary *bake_file_state(NSString *path) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) || !S_ISREG(st.st_mode)) return nil;
    return @{@"bytes": @(st.st_size), @"seconds": @(st.st_mtimespec.tv_sec), @"nanos": @(st.st_mtimespec.tv_nsec)};
}
static NSDictionary *bake_files(void) {
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:g_arch_dir error:nil]) {
        if (![name.pathExtension isEqualToString:@"mtl4a"]) continue;
        NSString *path = [g_arch_dir stringByAppendingPathComponent:name];
        NSDictionary *state = bake_file_state(path);
        if (state) files[name] = state;
        NSString *keys = arch_keys_path(path);
        if ((state = bake_file_state(keys))) files[keys.lastPathComponent] = state;
    }
    return files;
}
static int bake_record_matches(NSDictionary *record, NSDictionary *identity) {
    if (!identity || ![record isKindOfClass:NSDictionary.class] || ![record[@"identity"] isEqual:identity]) return 0;
    NSDictionary *files = record[@"files"];
    if (![files isKindOfClass:NSDictionary.class] || !files.count) return 0;
    int archives = 0;
    for (NSString *name in files) {
        if (![name isKindOfClass:NSString.class] || ![name isEqualToString:name.lastPathComponent]) return 0;
        NSString *path = [g_arch_dir stringByAppendingPathComponent:name];
        if (![files[name] isEqual:bake_file_state(path)]) return 0;
        if ([name.pathExtension isEqualToString:@"mtl4a"]) {
            if (!arch_file_ok(path)) return 0;
            archives++;
        }
    }
    return archives > 0;
}
// Validate before warm_parse's deliberately permissive old-version handling:
// skipped or malformed rows must not turn an incomplete bake into a success.
static int bake_valid(NSString *text) {
    if (!text.length) return 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *c = [line componentsSeparatedByString:@"\t"];
        if (([c[0] isEqual:@"S"] && c.count == 3) || ([c[0] isEqual:@"C"] && c.count == 2)) {
            NSString *stage = warm_map_stage(c[1]);
            if (!stage || ([c[0] isEqual:@"C"] && ![stage isEqual:@"compute"])) return 0;
            if ([c[0] isEqual:@"S"]) {
                int n = c[2].intValue; NSArray *names = @[@"vertex", @"pixel", @"geometry", @"task", @"mesh", @"compute"];
                if (n < 0 || n >= (int)names.count || ![c[2] isEqual:[NSString stringWithFormat:@"%d", n]] || ![stage isEqual:names[n]]) return 0;
            }
        } else if ([c[0] isEqual:@"R"] && c.count == 2) {
            pso_skey sk;
            if (pso_skey_parse(c[1].UTF8String, &sk) || (sk.fz && sk.fz_desc.kind != 1 && (sk.fz_desc.kind != 2 || sk.merged)) || sk.k.vs || sk.k.fs || sk.k.fsfn || sk.vs_stage != 0 ||
                (sk.fs[0] && sk.fs_stage != 1) || !pso_ds_valid(sk.k.dfmt, sk.k.sfmt) ||
                ![warm_map_stage(warm_key(sk.vs, sizeof sk.vs)) isEqual:@"vertex"] ||
                (sk.fs[0] && ![warm_map_stage(warm_key(sk.fs, sizeof sk.fs)) isEqual:@"pixel"])) return 0;
        } else return 0;
    }
    return 1;
}
static void bake_clear_batch(void) {
    // Workers have joined and captures have been flushed before releasing any
    // descriptors. Normal renderer/prefetch caches are separate and untouched.
    nvn_hm_clear(&g_bake_pbase, hm_rel); nvn_hm_clear(&g_bake_miss, hm_rel); nvn_hm_clear(&g_bake_pending, hm_rel);
    g_warm_dict = nil; g_warm_loads = nil;
    g_bake_fn_off = nil; g_bake_fn_dev = nil; g_bake_fn4 = nil;
}
static int bake_open_new(NSMutableSet<NSString *> *opened) {
    NSMutableArray *run = [g_arch_run mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *indexed = [g_arch_ixf mutableCopy] ?: [NSMutableArray array];
    NSMutableArray *plain = [g_arch4 mutableCopy] ?: [NSMutableArray array];
    int ok = 1;
    arch_open_begin();
    for (NSString *name in bake_files()) {
        if ([opened containsObject:name] || ![name.pathExtension isEqualToString:@"mtl4a"]) continue;
        NSString *path = [g_arch_dir stringByAppendingPathComponent:name];
        id<MTL4Archive> archive = arch_file_ok(path) ? [g_dev newArchiveWithURL:[NSURL fileURLWithPath:path] error:nil] : nil;
        if (!archive) { MLOG("[RED] pipeline bake: cannot open %s; no completion record", name.UTF8String); ok = 0; continue; }
        int complete = 0; NSData *keys = arch_keys_read(arch_keys_path(path), &complete);
        if (keys) {
            const uint64_t *kv = keys.bytes;
            for (NSUInteger i = 0; i < keys.length / sizeof *kv; i++) nvn_hm_put(&g_arch_ix, &kv[i], (__bridge void *)archive);
        }
        [run addObject:archive]; [opened addObject:name];
        if (keys && complete) [indexed addObject:archive]; else [plain addObject:archive];
    }
    arch_open_end();
    g_arch_run = run; g_arch_ixf = indexed; g_arch4 = plain;
    return ok;
}
static int bake_start(void) {
    NSString *path = bake_path();
    if (!path) return 0;
    if (!g_comp4 || !arch_capturing() || !g_arch_dir) {
        MLOG("[RED] pipeline bake: no Metal 4 compiler or writable archive; normal rendering continues"); return -1;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSDictionary *identity = bake_identity(data);
    NSString *stamp = [g_arch_dir stringByAppendingPathComponent:@"baked.json"];
    NSData *old = [NSData dataWithContentsOfFile:stamp];
    NSDictionary *record = old ? [NSJSONSerialization JSONObjectWithData:old options:0 error:nil] : nil;
    if (bake_record_matches(record, identity)) { MLOG("pipeline bake: completion record matches; nothing to build"); return 0; }
    int valid = 0; @autoreleasepool { valid = bake_valid(text); }
    if (!identity || !valid) { MLOG("[RED] pipeline bake: invalid list or missing shader-generation stamp: %s", path.UTF8String); return -1; }
    // Keep the old record until a successful atomic replacement. Its identity or
    // file check failed, so it cannot hide an interrupted or failed retry.
    data = nil; text = nil;
    warm_load_begin(); long lines = 0; NSArray<WarmTask *> *tasks;
    @autoreleasepool {
        tasks = warm_parse(@[path], &lines);
        if (![identity[@"list"] isEqual:bake_hash([NSData dataWithContentsOfFile:path])]) {
            bake_clear_batch(); MLOG("[RED] pipeline bake: list changed while reading; retry next start"); return -1;
        }
    }
    NSMutableArray<WarmTask *> *pending = [NSMutableArray array]; long total = 0;
    for (WarmTask *t in tasks) {
        if (!t->kind) continue;   // shaders load with their pipelines, never into the live cache
        if (t->kind == 2) { [pending addObject:t]; total++; continue; }
        for (NSUInteger i = 0; i < t->rs.count; i += 128) {
            WarmTask *part = [WarmTask new]; part->kind = t->kind; part->vkey = t->vkey; part->fkey = t->fkey;
            part->rs = [[t->rs subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)128, t->rs.count - i))] mutableCopy];
            [pending addObject:part]; total += part->rs.count;
        }
    }
    tasks = nil;
    if (!total) { bake_clear_batch(); MLOG("[RED] pipeline bake: no pipeline rows"); return -1; }
    long done0 = g_warm_done; uint64_t r0 = g_warm_rps, c0 = g_warm_cps, t0 = bp_now();
    int fail0 = atomic_load(&g_pre_warm_failed), write0 = atomic_load(&g_arch_write_errors), ok = 1;
    MLOG("pipeline bake: %ld pipeline descriptions before the first frame; temporary objects released in batches", total);
    NSMutableSet *opened = [NSMutableSet setWithArray:bake_files().allKeys];
    NSUInteger next = 0;
    while (next < pending.count && ok && arch_capturing()) {
        @autoreleasepool {
            NSMutableArray<WarmTask *> *batch = [NSMutableArray array]; long count = 0;
            while (next < pending.count) {
                WarmTask *t = pending[next]; long n = t->kind == 2 ? 1 : (long)t->rs.count;
                if (batch.count && count + n > 128) break;
                [batch addObject:t]; count += n; next++;
            }
            warm_load_begin();
            __block _Atomic NSUInteger cursor = 0; dispatch_group_t group = dispatch_group_create();
            int workers = MIN(prepare_workers(), (int)batch.count);
            for (int w = 0; w < workers; w++) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                g_bake_thread = 1;
                for (;;) { NSUInteger i = atomic_fetch_add(&cursor, 1); if (i >= batch.count) break; warm_task(batch[i]); }
                g_bake_thread = 0;
            });
            while (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)))
                front_progress("Preparing pipeline cache", g_warm_done - done0, total);
            arch_harvest_wait(DISPATCH_TIME_FOREVER);
            if (next == pending.count || atomic_load(&g_arch_new) >= 1000) arch_flush_wait();
            else if (g_arch_pending) dispatch_group_wait(g_arch_pending, DISPATCH_TIME_FOREVER);
            ok = bake_open_new(opened) && atomic_load(&g_arch_write_errors) == write0 && atomic_load(&g_pre_warm_failed) == fail0;
            bake_clear_batch();
        }
    }
    front_progress(NULL, total, total);
    ok = ok && next == pending.count && arch_capturing();
    NSDictionary *files = bake_files();
    if (ok && files.count) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"identity": identity, @"files": files, @"pipelines": @(total)} options:NSJSONWritingPrettyPrinted error:nil];
        ok = json && [json writeToFile:stamp options:NSDataWritingAtomic error:nil];
    } else ok = 0;
    MLOG("%spipeline bake: %llu render / %llu compute in %.1f s; completion record %s", ok ? "" : "[RED] ",
         (unsigned long long)(g_warm_rps - r0), (unsigned long long)(g_warm_cps - c0), (bp_now() - t0) / 1e9, ok ? "written" : "not written; retry next start");
    g_warm_done = done0; g_warm_rps = r0; g_warm_cps = c0;
    return ok ? 1 : -1;
}
