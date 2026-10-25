#define DM_TEST_HOOKS 1
#include "../botw_touch_actions.h"
#include "../hle_botw_touch_actions.c"
#include <assert.h>
#include <stdio.h>

module_t g_mod[MAX_MOD];
int g_nmod;
static int g_hud_active, g_action_notifications;
static uint64_t (*g_result_filter)(const uint64_t *regs);
int gate_obs_present(int id) { return id == OBS_BOTW_SPRINT_QUERY; }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { (void)id; (void)fn; }
void gate_obs_result_set(int id, uint64_t (*fn)(const uint64_t *)) { assert(id == OBS_BOTW_SPRINT_QUERY); g_result_filter = fn; }
uint64_t dm_guest_frame(void) { return 0; }
int dm_botw_touch_hud_active(void) { return g_hud_active; }
int dm_botw_touch_hud_available(void) { return g_hud_active; }
void front_botw_touch_action_changed(void) { g_action_notifications++; }

static void setup(void) {
    memset(g_mod, 0, sizeof g_mod);
    g_nmod = 1;
    strcpy(g_mod[0].name, "main");
    strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_hud_active = 1;
    g_action_notifications = 0;
    dm_botw_touch_actions_test_clear();
    dm_botw_touch_actions_test_enable(1);
    g_result_filter = NULL;
    dm_botw_touch_actions_install();
    assert(g_result_filter);
}

int main(void) {
    setup();
    uint64_t other = 0, virtual = 0;
    assert(dm_botw_touch_actions_available());
    uint64_t regs[31] = {0};
    regs[0] = 0x15;
    assert(g_result_filter(regs) == 0x15); // no sprint intent preserves the native result exactly
    dm_botw_touch_sprint_request(1);
    assert(dm_botw_touch_sprint_requested());
    regs[0] = 0;
    assert(g_result_filter(regs) == 1); // only this native B-query result receives touch intent
    regs[0] = 0x15;
    assert(g_result_filter(regs) == 0x15); // native result stays unchanged when already true
    g_hud_active = 0;
    assert(!dm_botw_touch_sprint_requested());
    dm_botw_touch_sprint_request(1);
    assert(!dm_botw_touch_sprint_requested());
    regs[0] = 0x15;
    assert(g_result_filter(regs) == 0x15); // HUD/controller mode-off leaves the query untouched
    g_hud_active = 1;
    other = DM_BTN_A; virtual = DM_BTN_X;
    g_hud_active = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 41);
    assert(other == DM_BTN_A && virtual == DM_BTN_X); // inactive mode leaves Npad contributions untouched
    g_hud_active = 1;
    other = virtual = 0;

    virtual = DM_BTN_R;
    dm_botw_touch_cancel_trigger(DM_BTN_R);
    dm_botw_touch_actions_apply(&other, &virtual, 42);
    assert((other | virtual) == (DM_BTN_R | DM_BTN_B));
    assert(!dm_botw_touch_cancel_complete(DM_BTN_R));
    other = 0; virtual = DM_BTN_R;
    dm_botw_touch_actions_apply(&other, &virtual, 42); // duplicate native reads in the same frame do not ack
    assert((other | virtual) == (DM_BTN_R | DM_BTN_B));
    assert(!dm_botw_touch_cancel_complete(DM_BTN_R));
    other = DM_BTN_R | DM_BTN_A; virtual = DM_BTN_R;
    dm_botw_touch_actions_apply(&other, &virtual, 43);
    assert((other | virtual) == (DM_BTN_R | DM_BTN_A | DM_BTN_B)); // ack state still contains B and held R
    assert(dm_botw_touch_cancel_complete(DM_BTN_R));
    assert(g_action_notifications == 1);
    other = 0; virtual = DM_BTN_R;
    dm_botw_touch_actions_apply(&other, &virtual, 43); // delayed UI callback: old virtual R remains held
    assert(virtual == 0 && other == 0); // virtual R stays suppressed, no second throw event
    other = DM_BTN_R; virtual = DM_BTN_R;
    dm_botw_touch_actions_apply(&other, &virtual, 44); // physical/manual R is independent
    assert((other & DM_BTN_R) && !(virtual & DM_BTN_R));
    assert(!(other & DM_BTN_B)); // synthetic B ended after acknowledgement
    assert(dm_botw_touch_cancel_complete(DM_BTN_R)); // sticky until reset

    dm_botw_touch_actions_reset();
    assert(!dm_botw_touch_cancel_complete(DM_BTN_R));
    other = 0; virtual = 0; // finger lifted before first provider read
    dm_botw_touch_cancel_trigger(DM_BTN_ZR);
    dm_botw_touch_actions_apply(&other, &virtual, 44);
    assert(other == (DM_BTN_ZR | DM_BTN_B));
    assert(!dm_botw_touch_cancel_complete(DM_BTN_ZR));
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 44); // duplicate read cannot ack
    assert(other == (DM_BTN_ZR | DM_BTN_B));
    assert(!dm_botw_touch_cancel_complete(DM_BTN_ZR));
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 45);
    assert(other == (DM_BTN_ZR | DM_BTN_B));
    assert(dm_botw_touch_cancel_complete(DM_BTN_ZR));

    dm_botw_touch_actions_reset();
    dm_botw_touch_cancel_trigger(DM_BTN_R);
    dm_botw_touch_cancel_trigger(DM_BTN_ZR); // concurrent second request coalesces, it is not lost
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 50);
    assert(other == (DM_BTN_R | DM_BTN_ZR | DM_BTN_B));
    assert(!dm_botw_touch_cancel_complete(DM_BTN_R) && !dm_botw_touch_cancel_complete(DM_BTN_ZR));
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 51);
    assert(other == (DM_BTN_R | DM_BTN_ZR | DM_BTN_B));
    assert(dm_botw_touch_cancel_complete(DM_BTN_R) && dm_botw_touch_cancel_complete(DM_BTN_ZR));
    assert(g_action_notifications == 3); // one wake per completed cancel cycle

    dm_botw_touch_actions_reset();
    dm_botw_touch_cancel_trigger(DM_BTN_R);
    other = 0; virtual = DM_BTN_R;
    dm_botw_touch_actions_apply(&other, &virtual, 60);
    assert((other | virtual) == (DM_BTN_R | DM_BTN_B));
    dm_botw_touch_cancel_trigger(DM_BTN_ZR); // request arrives before the first cycle's later-frame ack
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 60);
    assert(other == (DM_BTN_R | DM_BTN_ZR | DM_BTN_B));
    assert(!dm_botw_touch_cancel_complete(DM_BTN_R) && !dm_botw_touch_cancel_complete(DM_BTN_ZR));
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 61);
    assert(other == (DM_BTN_R | DM_BTN_ZR | DM_BTN_B));
    assert(dm_botw_touch_cancel_complete(DM_BTN_R) && dm_botw_touch_cancel_complete(DM_BTN_ZR));
    assert(g_action_notifications == 4);

    dm_botw_touch_cancel_trigger(DM_BTN_ZR); // another request must not erase a sticky R acknowledgement
    assert(dm_botw_touch_cancel_complete(DM_BTN_R) && !dm_botw_touch_cancel_complete(DM_BTN_ZR));
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 62);
    other = 0; virtual = 0;
    dm_botw_touch_actions_apply(&other, &virtual, 63);
    assert(dm_botw_touch_cancel_complete(DM_BTN_R) && dm_botw_touch_cancel_complete(DM_BTN_ZR));
    assert(g_action_notifications == 5);

    dm_botw_touch_cancel_trigger(DM_BTN_L);
    assert(!dm_botw_touch_cancel_complete(DM_BTN_L));
    dm_botw_touch_actions_test_clear();
    puts("t_botw_touch_actions: touch-mode sprint gating and frame-acknowledged R/ZR cancel sequencing passed");
}
