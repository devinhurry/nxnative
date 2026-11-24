// Actual NVN source frames renew the lease. The compute worker never owns a drawable.
enum { NATIVE30_IDLE_MIN_STEPS = 512, NATIVE30_IDLE_MAX_STEPS = 16384 };
enum { NATIVE30_IDLE_ALLOCATION, NATIVE30_IDLE_ENCODER, NATIVE30_IDLE_EXECUTION, NATIVE30_IDLE_FAILURE_KINDS };
static _Atomic uint64_t g_native30_idle_until, g_native30_idle_completed;
static _Atomic uint64_t g_native30_idle_epoch, g_native30_idle_gpu_ns, g_native30_idle_max_ns;
static _Atomic uint64_t g_native30_idle_frames, g_native30_idle_active_frames;
static _Atomic uint64_t g_native30_idle_starts, g_native30_idle_stops, g_native30_idle_cancelled;
static _Atomic uint64_t g_native30_idle_failures, g_native30_idle_retry_at;
static _Atomic unsigned g_native30_idle_failure_streak;
static _Atomic uint32_t g_native30_idle_steps = 8192;
static _Atomic int g_native30_idle_started, g_native30_idle_suspended, g_native30_idle_busy;
static dispatch_queue_t g_native30_idle_worker;
static dispatch_source_t g_native30_idle_event;
static dispatch_group_t g_native30_idle_work;
static MTLSharedEventListener *g_native30_snap_listener;
#ifdef NVN_NATIVE30_IDLE_TEST
static _Atomic int g_native30_idle_test_error, g_native30_idle_test_failures;
#endif

static int native30_idle_enabled(void) {
#if TARGET_OS_IPHONE || defined(NVN_NATIVE30_IDLE_TEST)
    static dispatch_once_t once;
    static int enabled;
    dispatch_once(&once, ^{
        const char *value = getenv("DM_NATIVE_30_GPU_KEEPALIVE");
        enabled = !value || !strcmp(value, "1");
    });
    return enabled;
#else
    return 0;
#endif
}
static void native30_idle_yield(void) {
    if (atomic_load_explicit(&g_native30_idle_until, memory_order_relaxed))
        atomic_fetch_add(&g_native30_idle_epoch, 1);
}
static void native30_idle_wake(void) {
    uint64_t until = atomic_load(&g_native30_idle_until);
    if (!until) return;
    if (bp_now() < until) dispatch_source_merge_data(g_native30_idle_event, 1);
    else if (atomic_compare_exchange_strong(&g_native30_idle_until, &until, 0) && ws_on())
        atomic_fetch_add(&g_native30_idle_stops, 1);
}
static void native30_idle_stop(void) {
    if (atomic_exchange(&g_native30_idle_until, 0)) {
        atomic_fetch_add(&g_native30_idle_epoch, 1);
        if (ws_on()) atomic_fetch_add(&g_native30_idle_stops, 1);
    }
}
static int native30_idle_drain(void) {
    if (!atomic_load(&g_native30_idle_started)) return 1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    // Include worker queueing in the deadline. A late notification owns its
    // semaphore, and the outstanding GPU resources stay alive after timeout.
    dispatch_async(g_native30_idle_worker, ^{
        dispatch_group_notify(g_native30_idle_work, g_native30_idle_worker, ^{
            dispatch_semaphore_signal(done);
        });
    });
    int completed = !dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC));
    static _Atomic int warned;
    if (!completed && !atomic_exchange(&warned, 1))
        MLOG("[gpu-keepalive] drain exceeded 100 ms; pending work retained until completion");
    return completed;
}
static void native30_idle_failed(NSError *error, int kind) {
    atomic_fetch_add(&g_native30_idle_failures, 1);
    unsigned streak = atomic_fetch_add(&g_native30_idle_failure_streak, 1) + 1;
    if (streak >= 3) atomic_store(&g_native30_idle_retry_at, bp_now() + 2 * NSEC_PER_SEC);
    native30_idle_stop();
    int temporary = atomic_load(&g_native30_idle_suspended) || atomic_load(&g_present_discard) ||
        gpu_err_has(error, MTLCommandBufferErrorDomain, MTLCommandBufferErrorNotPermitted, 0) ||
        gpu_err_has(error, MTL4CommandQueueErrorDomain, MTL4CommandQueueErrorNotPermitted, 0);
    static const char *const reason[] = {"resource allocation", "compute encoder creation", "GPU execution"};
    static _Atomic int reported[2][NATIVE30_IDLE_FAILURE_KINDS];
    if (!atomic_exchange(&reported[temporary][kind], 1))
        MLOG("%s[gpu-keepalive] %s failed%s: %s%s; fresh-frame retry, with 2 s backoff after 3 consecutive failures",
             temporary ? "" : "[RED] ", reason[kind], temporary ? " during suspension or access denial" : "",
             error.description.UTF8String ?: "no Metal error was returned",
             kind == NATIVE30_IDLE_EXECUTION && !temporary ? "; may be collateral to another command buffer's failure" : "");
}
static int native30_idle_gap(void) {
    if (atomic_load(&g_seg_inflight) || atomic_load(&g_up_pending) || atomic_load(&g_native30_idle_suspended) ||
        atomic_load(&g_present_discard) || atomic_load(&g_gpu_lost) ||
        bp_now() >= atomic_load(&g_native30_idle_until) ||
        bp_now() < atomic_load(&g_native30_idle_retry_at) || mtl_framegen_enabled()) return 0;
    uint64_t snap = atomic_load(&g_snap_v);
    if (snap && g_snap_ev.signaledValue < snap) return 0;
    pthread_mutex_lock(&g_pq_mu);
    int display_idle = !g_pq_inflight;
    pthread_mutex_unlock(&g_pq_mu);
    return display_idle;
}
static void native30_idle_run(void) {
    // One finite dispatch at a time. CPU writes during a running Metal kernel
    // have no visibility guarantee; game submissions cancel further dispatches.
    static id<MTLComputePipelineState> pipeline;
    static id<MTLCommandQueue> queue;
    static id<MTLBuffer> result;
    static _Atomic int unavailable;
    if (atomic_load(&unavailable) || atomic_load(&g_native30_idle_busy) || !native30_idle_gap()) return;
    uint64_t epoch = atomic_load(&g_native30_idle_epoch);
    if (!pipeline) {
        NSError *error = nil;
        id<MTLFunction> fn = [host_lib("native30_idle", &error) newFunctionWithName:@"native30_idle"];
        if (fn) pipeline = [g_dev newComputePipelineStateWithFunction:fn error:&error];
        if (!pipeline) {
            atomic_store(&unavailable, 1);
            atomic_fetch_add(&g_native30_idle_failures, 1);
            native30_idle_stop();
            MLOG("[gpu-keepalive] native 30 unavailable: %s", error.localizedDescription.UTF8String ?: "Metal pipeline");
            return;
        }
    }
    if (!queue) {
        queue = [g_dev newCommandQueueWithMaxCommandBufferCount:1];
        queue.label = @"Native 30 GPU keep-alive";
    }
    if (!result) result = [g_dev newBufferWithLength:32 * sizeof(uint32_t) options:MTLResourceStorageModePrivate];
    if (!queue || !result) { native30_idle_failed(nil, NATIVE30_IDLE_ALLOCATION); return; }
    @autoreleasepool {
        uint32_t steps = atomic_load(&g_native30_idle_steps);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        if (!cb) { native30_idle_failed(nil, NATIVE30_IDLE_ALLOCATION); return; }
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        if (!enc) { native30_idle_failed(nil, NATIVE30_IDLE_ENCODER); return; }
        [enc setComputePipelineState:pipeline];
        [enc setBuffer:result offset:0 atIndex:0];
        [enc setBytes:&steps length:sizeof(steps) atIndex:1];
        [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        [enc endEncoding];
        if (epoch != atomic_load(&g_native30_idle_epoch)) {
            if (ws_on()) atomic_fetch_add(&g_native30_idle_cancelled, 1);
            return;
        }
        if (!native30_idle_gap()) return;
        // Game work may arrive between this check and commit. That can overlap
        // this one finite pulse; 0.75 ms is a target, not a time guarantee.
        [cb addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            int failed = completed.status != MTLCommandBufferStatusCompleted;
            NSError *error = completed.error;
#ifdef NVN_NATIVE30_IDLE_TEST
            int injected = atomic_exchange(&g_native30_idle_test_error, 0);
            if (injected) { error = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:injected userInfo:nil]; failed = 1; }
#endif
            if (failed) {
                native30_idle_failed(error, NATIVE30_IDLE_EXECUTION);
            } else {
                atomic_store(&g_native30_idle_failure_streak, 0);
                atomic_store(&g_native30_idle_retry_at, 0);
                static _Atomic int announced;
                if (!atomic_exchange(&announced, 1))
                    MLOG("[gpu-keepalive] native 30 active: first pulse completed; target 0.75 ms, at most %u iterations", NATIVE30_IDLE_MAX_STEPS);
                atomic_fetch_add(&g_native30_idle_completed, 1);
                double ms = (completed.GPUEndTime - completed.GPUStartTime) * 1000.;
                if (ms > 0) {
                    uint64_t ns = (uint64_t)(ms * 1e6), max = atomic_load(&g_native30_idle_max_ns);
                    atomic_fetch_add(&g_native30_idle_gpu_ns, ns);
                    while (ns > max && !atomic_compare_exchange_weak(&g_native30_idle_max_ns, &max, ns)) {}
                }
                if (ms > .01) {
                    double scale = fmax(.5, fmin(2., .75 / ms));
                    atomic_store(&g_native30_idle_steps, (uint32_t)fmax(NATIVE30_IDLE_MIN_STEPS, fmin(NATIVE30_IDLE_MAX_STEPS, steps * scale)));
                }
            }
            atomic_store(&g_native30_idle_busy, 0);
            dispatch_group_leave(g_native30_idle_work);
            if (failed) gpu_lost_check(error, "keep-alive");
            else native30_idle_wake();
#ifdef NVN_NATIVE30_IDLE_TEST
            if (injected) atomic_fetch_add(&g_native30_idle_test_failures, 1);
#endif
        }];
        dispatch_group_enter(g_native30_idle_work);
        atomic_store(&g_native30_idle_busy, 1);
        [cb commit];
    }
}
static void native30_idle_frame(unsigned *hold, double game_gpu_ms) {
    // One expensive frame turns it on. Keep it while it helps a moderately
    // loaded scene, then release after 30 light source frames (e.g. a menu).
    uint64_t until = atomic_load(&g_native30_idle_until);
    if (bp_now() >= until) {
        if (until) native30_idle_stop();
        *hold = 0;
    }
    if (game_gpu_ms >= 20. || (*hold && game_gpu_ms >= 10.)) *hold = 30;
    else if (*hold) --*hold;
    int eligible = *hold && !atomic_load(&g_native30_idle_suspended) && !atomic_load(&g_present_discard) &&
        !atomic_load(&g_gpu_lost) && !mtl_framegen_enabled() && bp_now() >= atomic_load(&g_native30_idle_retry_at);
    if (ws_on()) {
        atomic_fetch_add(&g_native30_idle_frames, 1);
        if (eligible) atomic_fetch_add(&g_native30_idle_active_frames, 1);
    }
    if (!eligible) {
        native30_idle_stop();
        return;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_native30_idle_worker = dispatch_queue_create("dm.nvn.native30-idle", DISPATCH_QUEUE_SERIAL);
        g_native30_idle_work = dispatch_group_create();
        g_native30_snap_listener = [[MTLSharedEventListener alloc] initWithDispatchQueue:g_native30_idle_worker];
        g_native30_idle_event = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, g_native30_idle_worker);
        dispatch_source_set_event_handler(g_native30_idle_event, ^{ native30_idle_run(); });
        dispatch_activate(g_native30_idle_event);
        atomic_store(&g_native30_idle_started, 1);
    });
    uint64_t previous = atomic_exchange(&g_native30_idle_until, bp_now() + 100 * NSEC_PER_MSEC);
    if (!previous && ws_on()) atomic_fetch_add(&g_native30_idle_starts, 1);
    uint64_t snap = atomic_load(&g_snap_v);
    if (snap && g_snap_ev.signaledValue < snap) {
        [g_snap_ev notifyListener:g_native30_snap_listener atValue:snap block:^(id<MTLSharedEvent> event, uint64_t value) {
            native30_idle_wake();
        }];
    } else native30_idle_wake();
}
static void native30_idle_diag(uint64_t frame) {
    if (!ws_on() || !atomic_load(&g_native30_idle_started) || !frame || frame % 300) return;
    static uint64_t prev_frame, prev_active, prev_frames, prev_pulses, prev_gpu, prev_starts, prev_stops, prev_cancelled, prev_failures;
    uint64_t active = atomic_load(&g_native30_idle_active_frames), frames = atomic_load(&g_native30_idle_frames);
    uint64_t pulses = atomic_load(&g_native30_idle_completed), gpu = atomic_load(&g_native30_idle_gpu_ns);
    uint64_t starts = atomic_load(&g_native30_idle_starts), stops = atomic_load(&g_native30_idle_stops);
    uint64_t cancelled = atomic_load(&g_native30_idle_cancelled), max = atomic_exchange(&g_native30_idle_max_ns, 0);
    uint64_t failures = atomic_load(&g_native30_idle_failures), retry = atomic_load(&g_native30_idle_retry_at), now = bp_now();
    MLOG("[gpu-keepalive] frames %llu-%llu: armed %llu/%llu; completed pulses %llu; GPU total %.3f ms / max pulse %.3f ms; starts %llu / stops %llu; cancelled before submit %llu; failures %llu / streak %u / retry in %.3f ms; steps %u",
         (unsigned long long)prev_frame, (unsigned long long)frame, (unsigned long long)(active - prev_active),
         (unsigned long long)(frames - prev_frames), (unsigned long long)(pulses - prev_pulses), (gpu - prev_gpu) / 1e6, max / 1e6,
         (unsigned long long)(starts - prev_starts), (unsigned long long)(stops - prev_stops),
         (unsigned long long)(cancelled - prev_cancelled), (unsigned long long)(failures - prev_failures),
         atomic_load(&g_native30_idle_failure_streak), retry > now ? (retry - now) / 1e6 : 0., atomic_load(&g_native30_idle_steps));
    prev_frame = frame; prev_active = active; prev_frames = frames; prev_pulses = pulses; prev_gpu = gpu;
    prev_starts = starts; prev_stops = stops; prev_cancelled = cancelled;
    prev_failures = failures;
}
