// Exercise the real guest clock: settings and lifecycle own independent holds.
#include "../hle_os.c"
#include <dispatch/dispatch.h>
#include <assert.h>
#include <unistd.h>

module_t *g_mod; int g_nmod;
__thread _Atomic int dm_host_work;
void crash_watch_frame(void) {}
int dm_sdk_ounce(void) { return 0; }
void dm_guest_clock_advanced(void) {}
void *guest_sym(const char *name) { (void)name; return NULL; }
void *module_sym(module_t *module, const char *name) { (void)module; (void)name; return NULL; }
static dispatch_semaphore_t read_done;
static void *read_clock(void *unused) {
    (void)unused; guest_clock_read_wait(); dispatch_semaphore_signal(read_done); return NULL;
}
int main(void) {
    alarm(10);
    for (int settings_first = 0; settings_first < 2; settings_first++) {
        guest_clock_freeze_for(3, 1);
        uint64_t frozen = guest_ns(); usleep(1000); assert(guest_ns() == frozen);
        // A drain already inside host graphics must finish instead of deadlocking.
        dm_host_work = 1; guest_clock_read_wait(); dm_host_work = 0;
        read_done = dispatch_semaphore_create(0); pthread_t reader;
        pthread_create(&reader, NULL, read_clock, NULL);
        assert(dispatch_semaphore_wait(read_done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0);
        guest_clock_freeze_for(1, 1);
        guest_clock_freeze_for(settings_first ? 3 : 1, 0);
        assert(dispatch_semaphore_wait(read_done, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC)) != 0);
        guest_clock_freeze_for(settings_first ? 1 : 3, 0);
        assert(!dispatch_semaphore_wait(read_done, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
        pthread_join(reader, NULL);
        assert(guest_ns() >= frozen && guest_ns() - frozen < 20000000);
    }
    // Existing testing and keyboard freezes keep their nonblocking clock semantics.
    guest_clock_freeze_for(0, 1); guest_clock_read_wait(); guest_clock_freeze_for(0, 0);
    guest_clock_freeze_for(2, 1); guest_clock_read_wait(); guest_clock_freeze_for(2, 0);
    puts("settings clock: frozen time, blocking reads, host bypass, both release orders and legacy freezes passed");
    return 0;
}
