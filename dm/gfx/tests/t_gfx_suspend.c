// CPU-only lifecycle regression: the real NVN submit entry and graphics gate, with the prepare step (mtl_prepare) held by semaphores and the Metal replay and drain stubbed.
// Going to the background while the first submission prepares must not wait for it, and a second submission queued behind it must not hold the suspend either (docs/reference/nvn-objects.md,
// "Going to the background during the prepare step")
#include <pthread.h>
#include <stdatomic.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <time.h>

static int observed_mutex_lock(pthread_mutex_t *mutex);
#define pthread_mutex_lock observed_mutex_lock
#define mtl_prepare test_prepare
#define mtl_sub_begin test_sub_begin
#define mtl_sub_commit test_sub_commit
#define mtl_queue_activate test_queue_activate
#define mtl_set_queue_origin_lower_left test_queue_origin
#define mtl_sub_index test_sub_index
#define mtl_exec_rest test_exec_rest
#define mtl_exec test_exec
#define mtl_set_frame test_set_frame
#define mtl_drain test_drain
#define mtl_gpu_ms test_gpu_ms
#define mtl_snap_on test_snap_on
#define mtl_link_active test_link_active
#define mtl_probe_ramp_on test_probe_ramp_on
#define mtl_link_stalled test_link_stalled
#define mtl_presented_time test_presented_time
#include "../nvn/hle_nvn.c"
#undef pthread_mutex_lock
#undef mtl_prepare
#undef mtl_sub_begin
#undef mtl_sub_commit
#undef mtl_queue_activate
#undef mtl_set_queue_origin_lower_left
#undef mtl_sub_index
#undef mtl_exec_rest
#undef mtl_exec
#undef mtl_set_frame
#undef mtl_drain
#undef mtl_gpu_ms
#undef mtl_snap_on
#undef mtl_link_active
#undef mtl_probe_ramp_on
#undef mtl_link_stalled
#undef mtl_presented_time

module_t *g_mod; int g_nmod;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void svc_thread_dump(void) {}
static uint64_t test_clock;
uint64_t now_ns(void) { return test_clock ? test_clock : clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }   // the host's clock (hle_os.c: Mach absolute time), which Metal's timestamps are on

static int gpu_reads, screen_reads;
double test_gpu_ms(uint64_t frame) { (void)frame; gpu_reads++; return 1000; }   // stale pre-suspend work, never a reason to reject recovery
int test_snap_on(void) { return 1; }
int test_link_active(void) { return 1; }
int test_probe_ramp_on(void) { return 0; }
int test_link_stalled(void) { return 0; }
double test_presented_time(uint64_t frame) { (void)frame; screen_reads++; return -1; }

static dispatch_semaphore_t preparing, second_waiting, finish_prepare, prepared, suspended, returned, committed;
static __thread int second_submit;
static _Atomic int prepares, commits, drains;
static int inflight_in_prepare, host_work_in_prepare, inflight_at_serial_wait, host_work_at_serial_wait;
static int observed_mutex_lock(pthread_mutex_t *mutex) {
    if (mutex == &g_sub_mu && second_submit) {   // reached only when the lock is contended (dm_host_mutex_lock tries first)
        pthread_mutex_lock(&g_susp_mu);
        inflight_at_serial_wait = g_inflight_api; host_work_at_serial_wait = dm_host_work;
        pthread_mutex_unlock(&g_susp_mu);
        dispatch_semaphore_signal(second_waiting);
    }
    return pthread_mutex_lock(mutex);
}
void test_prepare(void) {   // the first submission's prepare step
    if (atomic_fetch_add(&prepares, 1)) return;
    pthread_mutex_lock(&g_susp_mu);
    inflight_in_prepare = g_inflight_api; host_work_in_prepare = dm_host_work;
    pthread_mutex_unlock(&g_susp_mu);
    dispatch_semaphore_signal(preparing);
    dispatch_semaphore_wait(finish_prepare, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_signal(prepared);
}
void test_sub_begin(void) {}
uint64_t test_sub_commit(void) { atomic_fetch_add(&commits, 1); dispatch_semaphore_signal(committed); return 0; }
void test_queue_activate(uint64_t serial) { (void)serial; }
void test_queue_origin(int on) { (void)on; }
void test_sub_index(const uint64_t *handles, int count) { (void)handles; (void)count; }
void test_exec_rest(const uint64_t *handles, int count) { (void)handles; (void)count; }
void test_exec(const uint8_t *commands) { (void)commands; }
void test_set_frame(uint64_t frame) { (void)frame; }
void test_drain(void) { atomic_fetch_add(&drains, 1); }

static NVNqueue queues[2];
static const op_hdr work[] __attribute__((aligned(8))) = {{OP_BEGIN, 8}};
static uint64_t work_list;   // its control list: one piece (nvn_obj.h ctl_e)
static void *submit(void *which) {
    second_submit = which != NULL;
    work_list = ctl_e(CTL_CHUNK, work, sizeof work) | CTL_LAST;
    NVNcommandHandle handle = (uintptr_t)&work_list;
    h_nvnQueueSubmitCommands(&queues[second_submit], 1, &handle);
    dispatch_semaphore_signal(returned);
    return NULL;
}
static void *suspend_graphics(void *unused) {
    (void)unused; dm_gfx_suspend(1); dispatch_semaphore_signal(suspended); return NULL;
}
static int checks, failures;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failures += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static int reached(dispatch_semaphore_t semaphore, const char *name) {
    int ok = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    CHECK(name, ok); return ok;
}
static void *enter_graphics(void *signal) {
    dm_gfx_enter(); dispatch_semaphore_signal((dispatch_semaphore_t)signal); dm_gfx_leave(); return NULL;
}
static void overlapping_holds(void) {
    for (int settings_first = 0; settings_first < 2; settings_first++) {
        uint64_t epoch = atomic_load(&g_fstep_resume_epoch);
        dispatch_semaphore_t entered = dispatch_semaphore_create(0); pthread_t worker;
        dm_gfx_suspend_for(3, 1); dm_gfx_suspend(1);
        pthread_create(&worker, NULL, enter_graphics, (void *)entered);
        CHECK("both holds stop graphics", dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0);
        if (settings_first) dm_gfx_suspend_for(3, 0); else dm_gfx_suspend(0);
        CHECK("releasing one owner leaves graphics paused", dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0);
        CHECK("partial resume does not reset frame pacing", atomic_load(&g_fstep_resume_epoch) == epoch);
        if (settings_first) dm_gfx_suspend(0); else dm_gfx_suspend_for(3, 0);
        reached(entered, "graphics resumes after the last owner releases"); pthread_join(worker, NULL);
        CHECK("last release resets frame pacing once", atomic_load(&g_fstep_resume_epoch) == epoch + 1);
    }
    dm_gfx_suspend_for(3, 1); dm_gfx_suspend_for(3, 1); dm_gfx_suspend_for(3, 0);
    CHECK("repeated settings notifications do not leak a hold", g_susp == 0 && g_susp_reasons == 0);
}

int main(void) {
    overlapping_holds();
    atomic_store(&drains, 0);
    preparing = dispatch_semaphore_create(0); second_waiting = dispatch_semaphore_create(0);
    finish_prepare = dispatch_semaphore_create(0); prepared = dispatch_semaphore_create(0);
    suspended = dispatch_semaphore_create(0); returned = dispatch_semaphore_create(0);
    committed = dispatch_semaphore_create(0);
    NVNqueueBuilder qb = {0}; h_nvnQueueBuilderSetDefaults(&qb);
    h_nvnQueueInitialize(&queues[0], &qb); h_nvnQueueInitialize(&queues[1], &qb);
    pthread_t first, second, background;
    pthread_create(&first, NULL, submit, NULL);
    if (!reached(preparing, "the first submission prepares")) return 1;
    CHECK("the prepare step runs outside the graphics gate", inflight_in_prepare == 0);
    CHECK("the prepare step is host work for the guest scheduler", host_work_in_prepare > 0);
    pthread_create(&second, NULL, submit, (void *)1);
    if (!reached(second_waiting, "a second submission waits for the submit lock")) return 1;
    CHECK("a queued submission is not in-flight graphics work", inflight_at_serial_wait == 0);
    CHECK("a contended submit lock is host work for the guest scheduler", host_work_at_serial_wait > 0);
    if (failures) return 1;   // the suspend below would wait forever
    pthread_create(&background, NULL, suspend_graphics, NULL);
    if (!reached(suspended, "suspend completes while the prepare step holds the submit lock")) return 1;
    pthread_join(background, NULL);
    CHECK("suspend drains graphics once", atomic_load(&drains) == 1);
    dispatch_semaphore_signal(finish_prepare);
    if (!reached(prepared, "the prepare step finishes in the background")) return 1;
    // Submit now owns a queued continuation and may return before GPU replay.
    // Suspension constrains replay, not whether the guest has enqueued work.
    CHECK("queued work stays outside the GPU while suspended", dispatch_semaphore_wait(committed, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0);
    CHECK("no submission commits while graphics are suspended", atomic_load(&commits) == 0);
    dm_gfx_suspend(0);
    if (!reached(returned, "a submission returns after resume") || !reached(returned, "both submissions return after resume")) return 1;
    pthread_join(first, NULL); pthread_join(second, NULL);
    if (!reached(committed, "first queued submission commits after resume") || !reached(committed, "second queued submission commits after resume")) return 1;
    CHECK("both submissions commit", atomic_load(&commits) == 2);
    h_nvnQueueFinish(&queues[0]); h_nvnQueueFinish(&queues[1]);
    CHECK("graphics entries are balanced", g_inflight_api == 0);

    // An unencoded wait must not make suspend wait for a future producer.
    // Releasing that event in the background must still respect the closed gate.
    _Atomic uint32_t word = 0;
    struct { op_hdr wait; volatile uint32_t *word; uint32_t mode, value; op_hdr begin; } parked __attribute__((aligned(8))) = {
        {OP_WAIT_EVENT, 24}, (volatile uint32_t *)&word, 0, 1, {OP_BEGIN, 8}
    };
    static uint64_t parked_list; parked_list = ctl_e(CTL_CHUNK, &parked, sizeof parked) | CTL_LAST;
    NVNcommandHandle parked_handle = (uintptr_t)&parked_list;
    h_nvnQueueSubmitCommands(&queues[0], 1, &parked_handle);
    pthread_create(&background, NULL, suspend_graphics, NULL);
    if (!reached(suspended, "suspend returns with an unresolved queue event")) return 1;
    pthread_join(background, NULL);
    nvn_event_publish((volatile uint32_t *)&word, NVN_EVENT_SIGNAL_MODE_WRITE, 1);
    CHECK("an event release cannot submit GPU work in the background", dispatch_semaphore_wait(committed, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC)) != 0);
    dm_gfx_suspend(0);
    if (!reached(committed, "the released continuation commits after resume")) return 1;
    h_nvnQueueFinish(&queues[0]);
    CHECK("exactly the three intended command prefixes committed", atomic_load(&commits) == 3);
    CHECK("resume leaves the graphics gate balanced", g_inflight_api == 0);
    h_nvnQueueFinalize(&queues[0]); h_nvnQueueFinalize(&queues[1]);
    // Force a known 30 fps hold with exhausted retry backoff and stale frame timing, then resume through the real graphics gate.
    setenv("DM_FPS_HOLD", "on", 1);
    win_t window = {.presents = 100};
    test_clock = 10000000000ull; atomic_store(&g_frame, 100);
    fstep_tick(&window, 60);   // establish the pre-background timestamp / consume earlier lifecycle transitions
    g_fs = (nvn_fstep){.k = 2, .step = 2, .kmin = 1, .debt = 15, .late_run = 2, .screen = 2};
    g_fs.retry_hold[1] = FSTEP_RETRY_MAX;
    uint64_t epoch = atomic_load(&g_fstep_resume_epoch);
    dm_gfx_suspend(0);
    CHECK("a repeated active callback does not restart recovery", atomic_load(&g_fstep_resume_epoch) == epoch);
    dm_gfx_suspend(1); test_clock += 30000000000ull; dm_gfx_suspend(0);
    CHECK("a genuine background/foreground transition requests one recovery", atomic_load(&g_fstep_resume_epoch) == epoch + 1);
    g_fs_start = test_clock - 29000000000ull; g_fs_wait = 1000000000ull;
    gpu_reads = screen_reads = 0; window.presents++;
    fstep_tick(&window, 60);
    CHECK("foreground recovery immediately probes 60 from 30", g_fs.k == 1 && g_fs.fallback == 2 && g_fs.probe == 1);
    CHECK("the paused interval adds no game-time debt or late-frame verdict", g_fs.debt == 0 && g_fs.late == 0 && g_fs.late_run == 0);
    CHECK("recovery starts with all grace frames and fresh retry timing", g_fs.grace == FSTEP_GRACE && g_fs.retry_hold[1] == FSTEP_HOLD0 && g_fs.retry_since[1] == 0);
    CHECK("pre-background GPU timestamps are excluded", gpu_reads == 0);
    test_clock += 16666667; window.presents++; fstep_tick(&window, 60);
    CHECK("the next frame consumes recovery once without resetting grace", g_fs.grace == FSTEP_GRACE - 1 && g_fs.probes == 1);
    CHECK("the next frame has no suspended-time debt", fabs(g_fs.debt) < .01);
    CHECK("pre-background presentation snapshots are excluded", screen_reads == 0);
    for (int i = 0; i < 9; i++) { test_clock += 16666667; window.presents++; fstep_tick(&window, 60); }
    CHECK("presentation feedback resumes after its delayed snapshots are fresh", screen_reads == 2);
    printf("graphics suspend: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
