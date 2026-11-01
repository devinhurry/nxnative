// Settings and background pauses share the real guest clock without releasing
// one another. Host graphics work can finish while guest counter reads wait.
#include "../hle_os.c"
#include <assert.h>
#include <dispatch/dispatch.h>

__thread _Atomic int dm_host_work;
module_t *g_mod; int g_nmod;
void *guest_sym(const char *name) { (void)name; return NULL; }
void *module_sym(module_t *m, const char *name) { (void)m; (void)name; return NULL; }
void crash_watch_frame(void) {}
void dm_guest_clock_advanced(void) {}

static dispatch_semaphore_t reading, returned;
static void *read_clock(void *unused) {
    (void)unused;
    dispatch_semaphore_signal(reading);
    guest_clock_read_wait();
    dispatch_semaphore_signal(returned);
    return NULL;
}

int main(void) {
    alarm(10);
    unsetenv("DM_DETCLOCK");
    reading = dispatch_semaphore_create(0); returned = dispatch_semaphore_create(0);
    uint64_t wall = now_ns(), before = guest_ns();
    guest_clock_freeze_for(3, 1);
    uint64_t frozen = guest_ns();
    pthread_t reader;
    assert(!pthread_create(&reader, NULL, read_clock, NULL));
    assert(!dispatch_semaphore_wait(reading, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    assert(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)));
    assert(guest_ns() == frozen);
    dm_host_work = 1; guest_clock_read_wait(); dm_host_work = 0;
    guest_clock_freeze_for(1, 1);
    guest_clock_freeze_for(3, 0);
    assert(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)));
    assert(guest_ns() == frozen);
    guest_clock_freeze_for(3, 1);
    guest_clock_freeze_for(1, 0);
    assert(dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)));
    guest_clock_freeze_for(3, 0);
    assert(!dispatch_semaphore_wait(returned, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
    pthread_join(reader, NULL);
    assert(guest_ns() >= before && guest_ns() - before < now_ns() - wall);
    puts("guest clock: settings/background ownership, blocked reads, host work and continuous resume passed");
    return 0;
}
