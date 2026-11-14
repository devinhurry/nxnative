// A pipeline known to the archive index, retrieved while the submit thread prepares later draws. Only deferred encoders consume a future; the cache and user list stay
// submit-thread owned. Unknown bases keep the hybrid / compilation path. Two queues bound archive work; an encoder can take a still-queued job instead of waiting behind it.
enum { PSO_FUTURE_MAX = 64, PSO_FUTURE_WORKERS = 2 };
@interface PsoFuture : NSObject { @public
    pso_key key; MTLRenderPipelineDescriptor *desc; int off;
    NSString *row, *context; id<MTLRenderPipelineState> ps; NSError *error;
    dispatch_group_t ready; _Atomic int state;   // 0 queued, 1 running, 2 ready (release publishes ps and error)
} @end
@implementation PsoFuture @end
static NSMutableArray<PsoFuture *> *g_pso_futures;
static _Atomic unsigned g_pso_future_jobs;   // includes stolen jobs whose queued blocks have not retired yet
static _Atomic uint64_t g_pfu_issued, g_pfu_ready, g_pfu_waited, g_pfu_wait_ns, g_pfu_own, g_pfu_fallback, g_pfu_failed;

static int pso_future_on(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("DM_PSO_FUTURE"); pso4_init();
        on = rec_on() && g_comp4 && !(e && !strcmp(e, "0"));
        if (on) { g_pso_future_class = PsoFuture.class; MLOG("pipeline futures: indexed archive pipelines retrieved on at most %d workers (DM_PSO_FUTURE=0 disables)", PSO_FUTURE_WORKERS); }
    }
    return on;
}
static dispatch_queue_t pso_future_queue(void) {
    static dispatch_queue_t queues[PSO_FUTURE_WORKERS]; static dispatch_once_t once; static unsigned next;
    dispatch_once(&once, ^{ for (int i = 0; i < PSO_FUTURE_WORKERS; i++)
        queues[i] = dispatch_queue_create("dm.nvn.pso-archive", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0)); });
    return queues[next++ % PSO_FUTURE_WORKERS];   // submit thread only
}
static int pso_future_run(PsoFuture *f) {
    int queued = 0;
    if (!atomic_compare_exchange_strong(&f->state, &queued, 1)) return 0;
    @autoreleasepool {
        NSError *e = nil; id<MTLRenderPipelineState> ps = pso_build_ex(f->desc, f->off, &e, 0);
        if (!ps) { g_pfu_fallback++; ps = pso_build(f->desc, f->off, &e); }   // stale index or another worker owns the base: wait / compile through the existing path
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
static void pso_future_collect(void) {
    for (NSUInteger i = g_pso_futures.count; i > 0; i--) {
        PsoFuture *f = g_pso_futures[i - 1];
        if (atomic_load_explicit(&f->state, memory_order_acquire) != 2) continue;
        if (hm_get_id(&g_pso, &f->key) == f) {
            if (f->ps) {
                hm_put_id(&g_pso, &f->key, f->ps);
                pso_record("R\t%s\n", f->row.UTF8String); pso_user_record("R\t%s\n", f->row.UTF8String);
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
static id pso_future_issue(const pso_key *k, NvShader *vs, NvShader *fs) {
    if (!g_arch_ix.n) return nil;
    if (atomic_load_explicit(&g_pso_future_jobs, memory_order_relaxed) >= PSO_FUTURE_MAX) return nil;
    if (g_pso_futures.count >= PSO_FUTURE_MAX) { pso_future_collect(); if (g_pso_futures.count >= PSO_FUTURE_MAX) return nil; }
    pthread_mutex_lock(&g_pp_mu); int pending = pso_pend_find(k) >= 0; pthread_mutex_unlock(&g_pp_mu);
    if (pending) return nil;   // an existing prediction / hybrid build owns this key
    MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0); int off = !k->border;
    if (!pso_future_wanted(d, off)) return nil;
    PsoFuture *f = [PsoFuture new]; f->key = *k; f->desc = d; f->off = off;
    pso_skey sk; char hex[sizeof sk * 2 + 1]; pso_skey_from(k, vs, fs, 0, NULL, &sk); pso_skey_hex(&sk, hex);
    f->row = @(hex); f->context = [NSString stringWithFormat:@"vertex %s fragment %s", vs->key, fs ? fs->key : "-"];
    f->ready = dispatch_group_create(); dispatch_group_enter(f->ready);
    if (!g_pso_futures) g_pso_futures = [NSMutableArray array];
    [g_pso_futures addObject:f]; hm_put_id(&g_pso, k, f); g_pfu_issued++;
    __weak PsoFuture *queued = f;   // a stolen, collected job must not retain its pipeline behind a busy worker
    atomic_fetch_add_explicit(&g_pso_future_jobs, 1, memory_order_relaxed);
    dispatch_async(pso_future_queue(), ^{ @autoreleasepool { PsoFuture *job = queued; if (job) (void)pso_future_run(job); }
        atomic_fetch_sub_explicit(&g_pso_future_jobs, 1, memory_order_relaxed); });
    return f;
}
static void pso_future_line(char *out, size_t size) {
    static uint64_t previous[7]; uint64_t now[7] = {g_pfu_issued, g_pfu_ready, g_pfu_waited, g_pfu_wait_ns, g_pfu_own, g_pfu_fallback, g_pfu_failed}, d[7];
    for (int i = 0; i < 7; i++) d[i] = now[i] - previous[i];
    size_t n = strlen(out);
    if (now[0] && n < size) snprintf(out + n, size - n, "; archive futures issued %llu, ready %llu, waited %llu / %.1f ms, taken by encoder %llu, fallback %llu, failed %llu",
        (unsigned long long)d[0], (unsigned long long)d[1], (unsigned long long)d[2], d[3] / 1e6, (unsigned long long)d[4], (unsigned long long)d[5], (unsigned long long)d[6]);
    memcpy(previous, now, sizeof now);
}
