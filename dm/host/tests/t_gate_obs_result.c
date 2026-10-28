#include "../dm.h"
#include <assert.h>
#include <stdio.h>

// Link only hle.c's gate functions; dead stripping keeps import resolution out
// of this focused test while exercising the actual observation dispatcher.
#include "../hle.c"

static int observed;
static void observe(const uint64_t *regs) {
    observed++;
    assert(regs[0] == 0x20 && regs[1] == 0x31 && regs[2] == 0x42);
}
static uint64_t filter_x0(const uint64_t *regs) {
    assert(regs[0] == 0x20 && regs[1] == 0x31 && regs[2] == 0x42);
    return regs[0] | 1;
}

static void observe_parameter(uint64_t *regs, int param) {
    assert(param == 7);
    regs[1] = 0x99;   // SDK allocator observers may update saved registers.
}

void guest_clock_read_wait(void) { assert(!"unexpected clock gate"); }
uint64_t guest_ns(void) { assert(!"unexpected clock gate"); return 0; }
uint64_t svc_dispatch(int num, uint64_t *regs, uint64_t orig_addr) {
    (void)num; (void)regs; (void)orig_addr; assert(!"unexpected SVC gate"); return 0;
}
void thr_svc_enter(uint64_t *regs, uint64_t orig) { (void)regs; (void)orig; assert(!"unexpected SVC gate"); }
void thr_svc_leave(void) { assert(!"unexpected SVC gate"); }
void dm_spin_wait(uint64_t ret_addr, uint64_t orig) { (void)ret_addr; (void)orig; assert(!"unexpected spin gate"); }

int main(void) {
    uint64_t regs[31] = {0};
    regs[0] = 0x20; regs[1] = 0x31; regs[2] = 0x42;
    gate_register(0x1000, "obs", 1, 0);
    gate_obs_read_set(1, observe);
    gate_dispatch(0x1000, regs);
    assert(observed == 1 && regs[0] == 0x20 && regs[1] == 0x31 && regs[2] == 0x42);

    gate_register(0x2000, "obs", 2, 0);
    gate_obs_read_set(2, observe);
    gate_obs_result_set(2, filter_x0);
    gate_dispatch(0x2000, regs);
    assert(observed == 2 && regs[0] == 0x21 && regs[1] == 0x31 && regs[2] == 0x42);
    assert(OBS_ASPECT_PROJECTION > OBS_STDALLOC_INIT && OBS_ASPECT_WORLD_PROJECTION < OBS_BOTW_LOOK_VECTOR);
    gate_register(0x3000, "obs", (7 << 8) | OBS_STDALLOC_INIT, 0);
    gate_obs_set(OBS_STDALLOC_INIT, observe_parameter);
    assert(gate_obs_present(OBS_STDALLOC_INIT));
    gate_dispatch(0x3000, regs);
    assert(regs[0] == 0x21 && regs[1] == 0x99 && regs[2] == 0x42);
    puts("t_gate_obs_result: observers preserve registers; explicit filters change x0 only");
}
