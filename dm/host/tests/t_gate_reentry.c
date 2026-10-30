// Reproduce an observation callback calling guest code that enters another
// observation and an SVC. Exercise real assembly, without game files or a GPU.
#include "../dm.h"
#include <assert.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../hle.c"
static _Atomic int mapped_stacks, created_stacks;
static void *counted_mmap(void *at, size_t size, int prot, int flags, int fd, off_t offset) {
    void *p = mmap(at, size, prot, flags, fd, offset);
    if (p != MAP_FAILED) { atomic_fetch_add(&mapped_stacks, 1); atomic_fetch_add(&created_stacks, 1); }
    return p;
}
static int counted_munmap(void *at, size_t size) {
    int r = munmap(at, size);
    if (!r) atomic_fetch_sub(&mapped_stacks, 1);
    return r;
}
#define mmap counted_mmap
#define munmap counted_munmap
#include "../thread.c"
#undef mmap
#undef munmap

pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;
extern uint64_t test_gate_observe(void *stub, uint64_t value);
extern uint64_t test_gate_svc(void *stub, uint64_t value);
extern const uint8_t test_gate_observe_ret[], test_gate_svc_ret[];
static _Thread_local int observations, calls;
static _Thread_local int unsafe_nested;

void guest_clock_read_wait(void) { assert(!"unexpected clock gate"); }
uint64_t guest_ns(void) { assert(!"unexpected clock gate"); return 0; }
void thr_svc_enter(uint64_t *regs, uint64_t orig) { (void)regs; assert(orig == 0x9000); }
void thr_svc_leave(void) {}
void dm_spin_wait(uint64_t ret, uint64_t orig) { (void)ret; (void)orig; assert(!"unexpected spin gate"); }
uint64_t svc_dispatch(int number, uint64_t *regs, uint64_t orig) {
    assert(number == 1 && orig == 0x9000 && regs[0] >= 0x100);
    if (unsafe_nested) test_gate_svc(pthread_getspecific(g_keygate), 0x100);
    calls++;
    return regs[0] += 0x40;
}

static void observe(const uint64_t *regs) {
    uint64_t saved[100];
    memcpy(saved, regs, sizeof saved);
    observations++;
    assert(regs[0] <= 3 && ((uintptr_t)regs & 15) == 0 && (regs[99] & 15) == 0);
    void *stub = pthread_getspecific(g_keygate);
    assert(test_gate_svc(stub, 0x100 + regs[0]) == 0x140 + regs[0]);
    if (regs[0] < 3) assert(test_gate_observe(stub, regs[0] + 1) == 0xabc0 + regs[0] + 1);
    assert(!memcmp(saved, regs, sizeof saved)); // Includes all Q registers and saved guest SP.
}
static uint64_t result(const uint64_t *regs) { return 0xabc0 + regs[0]; }
static void abort_exit(int sig) { (void)sig; _exit(77); }

static void *run(void *unused) {
    (void)unused;
    guest_gate_stack(0); // Test guest code uses its normal pthread stack.
    unsigned slot = ((gate_slot *)pthread_getspecific(g_keygslot))->slot;
    uint64_t top = dm_gate_top[slot];
    for (int i = 0; i < 20; i++) {
        assert(test_gate_observe(pthread_getspecific(g_keygate), 0) == 0xabc0);
        assert(dm_gate_top[slot] == top);
    }
    assert(observations == 80 && calls == 80);
    // Unlike the production guest main, this test returns on its original
    // pthread stack, so it can also release the mapped base gate stack.
    assert(!counted_munmap((void *)(uintptr_t)(top - GATE_STACK_SIZE - 16384), GATE_STACK_SIZE + 16384));
    return NULL;
}

int main(void) {
    signal(SIGABRT, abort_exit);
    assert(!pthread_key_create(&g_key18, NULL) && !pthread_key_create(&g_keytls, NULL) &&
           !pthread_key_create(&g_keytlr, NULL) && !pthread_key_create(&g_keygate, NULL));
    gate_register((uintptr_t)test_gate_observe_ret, "obs", 1, 0);
    gate_register((uintptr_t)test_gate_svc_ret, "svc", 1, 0x9000);
    gate_obs_read_set(1, observe); gate_obs_result_set(1, result);
    pthread_t a, b;
    assert(!pthread_create(&a, NULL, run, NULL) && !pthread_create(&b, NULL, run, NULL));
    assert(!pthread_join(a, NULL) && !pthread_join(b, NULL));
    assert(atomic_load(&mapped_stacks) == 0); // Auxiliary mappings are released at thread exit.
    assert(atomic_load(&created_stacks) <= 12); // Repeated calls reuse depth-specific stacks.
    int errors[2];
    assert(!pipe(errors));
    pid_t pid = fork();
    assert(pid >= 0);
    if (!pid) {
        close(errors[0]);
        assert(dup2(errors[1], STDERR_FILENO) == STDERR_FILENO);
        close(errors[1]);
        guest_gate_stack(0);
        unsafe_nested = 1;
        test_gate_svc(pthread_getspecific(g_keygate), 0x100);
        _exit(1);
    }
    close(errors[1]);
    int status = 0;
    assert(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 77);
    char message[512];
    ssize_t n = read(errors[0], message, sizeof message - 1);
    assert(n > 0); message[n] = 0; close(errors[0]);
    assert(strstr(message, "SVC gate entered on its own gate stack"));
    puts("t_gate_reentry: nested observer/SVC calls preserve parent frames, registers, guest stack and per-thread gate state");
}
