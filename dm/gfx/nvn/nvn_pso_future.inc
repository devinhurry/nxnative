// Asynchronous pipeline archive lookup and compilation on worker threads.
// Archived bases must resolve before drawing. Cold/pending builds may skip their draws while workers are available;
// an encoder can take a queued build itself if no worker started. Cache publication stays submit-thread owned.
@interface PsoFuture : NSObject { @public
    pso_key key; MTLRenderPipelineDescriptor *desc; int off, may_skip, pending;
    NSString *row, *context; id<MTLRenderPipelineState> ps; NSError *error;
    dispatch_group_t ready; _Atomic int state;   // 0 queued, 1 running, 2 ready (release publishes ps and error)
} @end
@implementation PsoFuture @end
static NSMutableArray<PsoFuture *> *g_pso_futures;
static NSMutableArray<PsoFuture *> *g_pso_future_queue;
static pthread_mutex_t g_pso_future_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_pso_future_cv = PTHREAD_COND_INITIALIZER;
static _Atomic int g_pso_future_workers;
static int g_pso_future_started;
static _Atomic uint64_t g_pfu_issued, g_pfu_ready, g_pfu_waited, g_pfu_wait_ns, g_pfu_own, g_pfu_fallback, g_pfu_failed, g_pfu_skipped;

static int pso_future_on(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("DM_PSO_FUTURE"); pso4_init();
        on = rec_on() && !(e && !strcmp(e, "0"));
        if (on) { g_pso_future_class = PsoFuture.class; MLOG("pipeline futures: archived bases are fetched; cold compiles may skip draws (DM_PSO_FUTURE=0 disables)"); }
    }
    return on;
}
// Size the pool from active CPUs, or an explicit 1..8 override.
static int pso_workers(void) {
    static int n;
    if (!n) {
        int cpus = 4; size_t size = sizeof cpus;
        if (sysctlbyname("hw.activecpu", &cpus, &size, NULL, 0) || cpus < 1) cpus = 4;
        const char *e = getenv("DM_PSO_WORKERS"); int configured = e ? atoi(e) : 0;
        n = configured > 0 ? MIN(configured, 8) : MIN(MAX(cpus, 4), 10) - 2;
    }
    return n;
}
static int pso_future_run(PsoFuture *f);
static void *pso_future_main(void *arg) {
    (void)arg; pthread_setname_np("dm-pso-fetch"); pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    for (;;) { @autoreleasepool {
        pthread_mutex_lock(&g_pso_future_mu);
        while (!g_pso_future_queue.count) pthread_cond_wait(&g_pso_future_cv, &g_pso_future_mu);
        PsoFuture *f = g_pso_future_queue[0]; [g_pso_future_queue removeObjectAtIndex:0];
        pthread_mutex_unlock(&g_pso_future_mu);
        (void)pso_future_run(f);
    } }
    return NULL;
}
static void pso_future_start_locked(void) {
    if (g_pso_future_started) return;
    g_pso_future_started = 1;
    for (int i = 0, n = pso_workers(); i < n; i++) {
        pthread_t thread; pthread_attr_t attributes; pthread_attr_init(&attributes);
        pthread_attr_setstacksize(&attributes, 1024u * 1024u); pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
        int error = pthread_create(&thread, &attributes, pso_future_main, NULL); pthread_attr_destroy(&attributes);
        if (error) { MLOG("[RED] pipeline futures: worker %d could not start (%d); the encode thread builds what no worker takes", i + 1, error); break; }
        g_pso_future_workers++;
    }
}
static int pso_future_run(PsoFuture *f) {
    int queued = 0;
    if (!atomic_compare_exchange_strong(&f->state, &queued, 1)) return 0;
    pthread_mutex_lock(&g_pso_future_mu); [g_pso_future_queue removeObjectIdenticalTo:f]; pthread_mutex_unlock(&g_pso_future_mu);
    @autoreleasepool {
        NSError *e = nil; id<MTLRenderPipelineState> ps = f->pending ? pso_pend_take(&f->key) : pso_build_ex(f->desc, f->off, &e, 0);
        if (!ps) { g_pfu_fallback++; ps = pso_build(f->desc, f->off, &e); }
        f->ps = ps; f->error = e; f->desc = nil;
        if (!ps) g_pfu_failed++;
        atomic_store_explicit(&f->state, 2, memory_order_release); dispatch_group_leave(f->ready);
    }
    return 1;
}
static id<MTLRenderPipelineState> pso_future_resolve(id future) {
    PsoFuture *f = future;
    if (atomic_load_explicit(&f->state, memory_order_acquire) == 2) g_pfu_ready++;
    else {
        uint64_t t = bp_now();
        if (pso_future_run(f)) g_pfu_own++;   // not running yet: encode it here, avoiding queue head-of-line waits
        else dispatch_group_wait(f->ready, DISPATCH_TIME_FOREVER);
        g_pfu_waited++; g_pfu_wait_ns += bp_now() - t;
    }
    return f->ps;
}
static id<MTLRenderPipelineState> pso_future_bind(id future) {
    PsoFuture *f = future;
    // Skip a cold build only when a real worker can finish it.
    // An archive fetch, or a failed worker start, must still resolve and render.
    if (f->may_skip && atomic_load(&g_pso_future_workers) > 0 && atomic_load_explicit(&f->state, memory_order_acquire) != 2) {
        g_pfu_skipped++; return nil;
    }
    return pso_future_resolve(f);
}
static void pso_future_collect(void) {
    for (NSUInteger i = g_pso_futures.count; i > 0; i--) {
        PsoFuture *f = g_pso_futures[i - 1];
        if (atomic_load_explicit(&f->state, memory_order_acquire) != 2) continue;
        if (hm_get_id(&g_pso, &f->key) == f) {
            if (f->ps) {
                hm_put_id(&g_pso, &f->key, f->ps);
                if (f->row) { pso_record("R\t%s\n", f->row.UTF8String); pso_user_record("R\t%s\n", f->row.UTF8String); }
            } else {
                hm_rel(nvn_hm_del(&g_pso, &f->key)); hm_put_id(&g_pso_fail, &f->key, NSNull.null);
                MLOG("[RED] failed to create render pipeline (%s): %s", f->context.UTF8String, f->error.localizedDescription.UTF8String);
            }
        }
        [g_pso_futures removeObjectAtIndex:i - 1];
    }
}
static int pso_future_wanted(MTLRenderPipelineDescriptor *d, int off) {
    if (!pso_ds_valid((uint32_t)d.depthAttachmentPixelFormat, (uint32_t)d.stencilAttachmentPixelFormat) || [d.label isEqualToString:PSO_WHOLE]) return 0;
    pbase_key bk; pbase_key_of(d, off, &bk);
    os_unfair_lock_lock(&g_pbase_lock);
    int known = hm_get_id(&g_pbase, &bk) != nil || hm_get_id(&g_pbase_miss, &bk) != nil;
    os_unfair_lock_unlock(&g_pbase_lock);
    if (known) return 0;   // cached bases specialize synchronously; known misses retain the hybrid path
    MTL4RenderPipelineDescriptor *base = pso_desc4(d, d.rasterizationEnabled, off);
    uint64_t key = base ? arch_key(base) : 0;
    return key && nvn_hm_get(&g_arch_ix, &key) != NULL;   // index immutable after pso4_init; no speculative archive search
}
static id pso_future_submit(const pso_key *k, NvShader *vs, NvShader *fs, MTLRenderPipelineDescriptor *d, int may_skip, int pending, int record) {
    PsoFuture *f = [PsoFuture new]; f->key = *k; f->desc = d; f->off = !k->border; f->may_skip = may_skip; f->pending = pending;
    if (record) {
        pso_skey sk; char hex[sizeof sk * 2 + 1];
        pso_skey_from(k, vs, fs, g_pso_lmap != NULL, g_pso_lmap ? &g_pso_fz : NULL, &sk); pso_skey_hex(&sk, hex); f->row = @(hex);
    }
    f->context = [NSString stringWithFormat:@"vertex %s fragment %s", vs->key, fs ? fs->key : "-"];
    f->ready = dispatch_group_create(); dispatch_group_enter(f->ready);
    if (!g_pso_futures) g_pso_futures = [NSMutableArray array];
    [g_pso_futures addObject:f]; hm_put_id(&g_pso, k, f); g_pfu_issued++;
    pthread_mutex_lock(&g_pso_future_mu);
    if (!g_pso_future_queue) g_pso_future_queue = [NSMutableArray array];
    pso_future_start_locked(); [g_pso_future_queue addObject:f]; pthread_cond_signal(&g_pso_future_cv);
    pthread_mutex_unlock(&g_pso_future_mu);
    return f;
}
static id pso_future_issue(const pso_key *k, NvShader *vs, NvShader *fs) {
    if (!g_comp4 || !g_arch_ix.n) return nil;
    pthread_mutex_lock(&g_pp_mu); int pending = pso_pend_find(k) >= 0; pthread_mutex_unlock(&g_pp_mu);
    if (pending) return nil;
    MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0);
    if (!pso_future_wanted(d, !k->border)) return nil;
    return pso_future_submit(k, vs, fs, d, 0, 0, 1);
}
static void pso_future_line(char *out, size_t size) {
    static uint64_t previous[8]; uint64_t now[8] = {g_pfu_issued, g_pfu_ready, g_pfu_waited, g_pfu_wait_ns, g_pfu_own, g_pfu_fallback, g_pfu_failed, g_pfu_skipped}, d[8];
    for (int i = 0; i < 8; i++) d[i] = now[i] - previous[i];
    size_t n = strlen(out);
    if (now[0] && n < size) snprintf(out + n, size - n, "; pipeline futures issued %llu, ready %llu, waited %llu / %.1f ms, taken by encoder %llu, fallback %llu, failed %llu, unready cold bindings skipped %llu",
        (unsigned long long)d[0], (unsigned long long)d[1], (unsigned long long)d[2], d[3] / 1e6, (unsigned long long)d[4], (unsigned long long)d[5], (unsigned long long)d[6], (unsigned long long)d[7]);
    memcpy(previous, now, sizeof now);
}
