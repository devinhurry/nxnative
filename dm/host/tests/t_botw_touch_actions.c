#define DM_TEST_HOOKS 1
#include "../botw_touch_actions.h"
#include "../hle.h"
// Trigger-cancel fixtures exercise BOTW independently of CI's host profile.
#undef DM_GAME_ID
#define DM_GAME_ID "01007EF00011E000"
#include "../hle_botw_touch_actions.c"
#include <assert.h>
#include <stdio.h>

static module_t test_modules[8];
module_t *g_mod = test_modules;
int g_nmod;
static int g_hud_active, g_action_notifications;
static int g_bow, g_category=-1;
int dm_botw_touch_controls_visible(void) { return g_hud_active; }
int dm_botw_touch_bow_active(void) { return g_bow; }
void dm_botw_touch_menu_open_category(int category) { g_category=category; }
uint64_t dm_guest_frame(void) { return 0; }
int dm_botw_touch_hud_active(void) { return g_hud_active; }
int dm_botw_touch_hud_available(void) { return g_hud_active; }
void front_botw_touch_action_changed(void) { g_action_notifications++; }

static void setup(void) {
    memset(g_mod, 0, sizeof test_modules);
    g_nmod = 1;
    strcpy(g_mod[0].name, "main");
    strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_hud_active = 1;
    g_action_notifications = 0;
    dm_botw_touch_actions_test_clear();
    dm_botw_touch_actions_install();
    assert(dm_botw_touch_actions_available()); // cancellation needs no native Dash observation
}

int main(void) {
    setup();
    dm_botw_touch_button_begin(16,0); assert(g_category==0);
    g_bow=1; dm_botw_touch_button_begin(16,0); assert(g_category==1);
    dm_botw_touch_button_begin(17,0); assert(g_category==1);
    g_bow=0; dm_botw_touch_button_begin(17,0); assert(g_category==2);
    dm_botw_touch_button_begin(18,0); assert(g_category==5);
    uint64_t test_buttons=0,test_virtual=0;
    for (int control=16;control<=17;control++) {
        dm_botw_touch_actions_reset();
        dm_botw_touch_button_begin(control,2); dm_botw_touch_button_end(control,0);
        uint64_t direction=control==16 ? DM_BTN_RIGHT : DM_BTN_LEFT;
        for (uint64_t frame=1;frame<10;frame++) {
            test_buttons=0;
            dm_botw_touch_actions_apply(&test_buttons,&test_virtual,frame);
            assert(test_buttons==direction && dm_botw_touch_switch_cancel_visible());
        }
        dm_botw_touch_switch_cancel(); assert(!dm_botw_touch_switch_cancel_visible());
        test_buttons=0; dm_botw_touch_actions_apply(&test_buttons,&test_virtual,10);
        assert(test_buttons==(direction|DM_BTN_B));
        test_buttons=0; dm_botw_touch_actions_apply(&test_buttons,&test_virtual,12); assert(!test_buttons);
    }
    dm_botw_touch_button_begin(17,1); assert(!dm_botw_touch_switch_cancel_visible());
    dm_botw_touch_button_end(17,0); test_buttons=0;
    dm_botw_touch_actions_apply(&test_buttons,&test_virtual,3); assert(!test_buttons);
    dm_botw_touch_button_begin(6,2); g_rune_down-=1; test_buttons=0;
    dm_botw_touch_actions_apply(&test_buttons,&test_virtual,4); assert(test_buttons==DM_BTN_UP);
    dm_botw_touch_button_end(6,0); assert(dm_botw_touch_switch_cancel_visible());
    dm_botw_touch_switch_cancel(); assert(!dm_botw_touch_switch_cancel_visible());
    dm_botw_touch_actions_reset();
    g_action_notifications=0;
    uint64_t other = 0, virtual = 0;
    assert(dm_botw_touch_actions_available());
    dm_botw_touch_actions_apply(&other, &virtual, 40);
    assert(!other && !virtual); // ordinary movement never contributes B
    other = DM_BTN_B;
    dm_botw_touch_actions_apply(&other, &virtual, 40);
    assert(other == DM_BTN_B); // the normal button keeps its native behavior
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
    puts("t_botw_touch_actions: native button preservation and frame-acknowledged R/ZR cancel sequencing passed");
}
