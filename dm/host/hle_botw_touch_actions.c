// BOTW 1.9 touch-only category, quick-switch and drag-cancel input sequencing.
#include "botw_touch_actions.h"
#include "dm.h"
#include "dm_input.h"
#include "botw_touch_menu.h"
#include "front.h"
#include "hle.h"
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>

enum { CANCEL_IDLE, CANCEL_REQUESTED, CANCEL_WAIT_FRAME };
static const char BOTW_TOUCH_ACTION_BUILD[] = "cd57b23fa4bbad65803d9788c01821ee";
static pthread_mutex_t g_actions_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_actions_ready, g_cancel_phase;
static uint64_t g_cancel_pending, g_cancel_complete, g_cancel_frame, g_suppressed_virtual_triggers;
static _Atomic int g_actions_test_ready;
static int touch_mode_active(void);
static int g_switch_control=-1, g_switch_sticky, g_switch_started, g_rune_mode;
static uint64_t g_switch_bit, g_pulse_bits, g_pulse_frame=UINT64_MAX;
static uint64_t g_aim_triggers;
static uint64_t g_suppressed_virtual_switch;
static double g_rune_down;
static double action_time(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t);
    return t.tv_sec+t.tv_nsec*1e-9;
}

static void pulse_locked(uint64_t bits) { g_pulse_bits|=bits; g_pulse_frame=UINT64_MAX; }

void dm_botw_touch_button_begin(int control,int mode) {
    if (!touch_mode_active() || !dm_botw_touch_controls_visible()) return;
    if ((control==16 || control==17 || control==18) && (mode==0 || control==18)) {
        int bow=dm_botw_touch_bow_active();
        dm_botw_touch_menu_open_category(control==18 ? 5 : control==16 ? (bow ? 1 : 0) : (bow ? 1 : 2));
        return;
    }
    pthread_mutex_lock(&g_actions_mu);
    if (control==19) pulse_locked(DM_BTN_DOWN);
    else if (control==6) {
        g_rune_mode=mode; g_rune_down=action_time();
        g_switch_control=6; g_switch_started=0; g_switch_sticky=0; g_switch_bit=0;
    } else if ((control==16 || control==17) && mode>=1 && mode<=2) {
        if (g_switch_control==control && g_switch_sticky) { g_switch_control=-1; g_switch_bit=0; g_switch_sticky=0; }
        else {
            g_switch_control=control; g_switch_bit=control==16 ? DM_BTN_RIGHT : DM_BTN_LEFT;
            g_switch_sticky=mode==2; g_switch_started=1;
        }
    }
    pthread_mutex_unlock(&g_actions_mu);
    front_botw_touch_action_changed();
}
void dm_botw_touch_button_end(int control,int cancelled) {
    pthread_mutex_lock(&g_actions_mu);
    if (g_switch_control==control) {
        if (control==6 && !g_switch_started && !cancelled) pulse_locked(DM_BTN_L);
        if (cancelled || !g_switch_sticky) { g_switch_control=-1; g_switch_bit=0; g_switch_sticky=0; }
    }
    pthread_mutex_unlock(&g_actions_mu);
    front_botw_touch_action_changed();
}
void dm_botw_touch_switch_cancel(void) {
    pthread_mutex_lock(&g_actions_mu);
    uint64_t aim=g_aim_triggers;
    if (g_switch_control>=0) pulse_locked(DM_BTN_B|g_switch_bit);
    g_switch_control=-1; g_switch_bit=0; g_switch_sticky=0;
    g_aim_triggers=0;
    pthread_mutex_unlock(&g_actions_mu);
    if (aim&DM_BTN_R) dm_botw_touch_cancel_trigger(DM_BTN_R);
    if (aim&DM_BTN_ZR) dm_botw_touch_cancel_trigger(DM_BTN_ZR);
    front_botw_touch_action_changed();
}
void dm_botw_touch_switch_selected(void) {
    pthread_mutex_lock(&g_actions_mu);
    g_suppressed_virtual_switch=DM_BTN_UP|DM_BTN_LEFT|DM_BTN_RIGHT;
    g_switch_control=-1; g_switch_bit=0; g_switch_sticky=g_switch_started=0;
    pthread_mutex_unlock(&g_actions_mu);
    front_botw_touch_action_changed();
}
int dm_botw_touch_switch_active(void) {
    pthread_mutex_lock(&g_actions_mu);
    int active=g_switch_control>=0 && g_switch_started;
    pthread_mutex_unlock(&g_actions_mu);
    return active;
}
int dm_botw_touch_switch_cancel_visible(void) {
    pthread_mutex_lock(&g_actions_mu);
    int visible=(g_switch_sticky && g_switch_started) || g_aim_triggers;
    pthread_mutex_unlock(&g_actions_mu);
    return visible;
}

static int actions_ready(void) {
    if (strcmp(DM_GAME_ID, "01007EF00011E000") || strcmp(dm_main_build(), BOTW_TOUCH_ACTION_BUILD)) return 0;
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_actions_test_ready, memory_order_acquire)) return 1;
#endif
    pthread_mutex_lock(&g_actions_mu);
    int ready = g_actions_ready;
    pthread_mutex_unlock(&g_actions_mu);
    return ready;
}

static int touch_mode_active(void) {
    return actions_ready() && dm_botw_touch_hud_active();
}

void dm_botw_touch_actions_install(void) {
    if (strcmp(DM_GAME_ID, "01007EF00011E000")) return;
    if (strcmp(dm_main_build(), BOTW_TOUCH_ACTION_BUILD)) {
        LOG("BOTW touch actions: disabled for main build %s (requires %s)", dm_main_build(), BOTW_TOUCH_ACTION_BUILD);
        return;
    }
    if (!dm_botw_touch_hud_available()) return;
    pthread_mutex_lock(&g_actions_mu);
    g_actions_ready = 1;
    pthread_mutex_unlock(&g_actions_mu);
    LOG("BOTW touch actions: category shortcuts, quick switching and R/ZR cancel enabled for build %s", BOTW_TOUCH_ACTION_BUILD);
}

int dm_botw_touch_actions_available(void) { return actions_ready(); }

static int valid_trigger(uint64_t bit) { return bit == DM_BTN_R || bit == DM_BTN_ZR; }

void dm_botw_touch_cancel_trigger(uint64_t trigger_bit) {
    if (!valid_trigger(trigger_bit) || !touch_mode_active()) return;
    pthread_mutex_lock(&g_actions_mu);
    g_suppressed_virtual_triggers &= ~trigger_bit;
    g_cancel_complete &= ~trigger_bit;
    g_cancel_pending |= trigger_bit;
    // Any newly accepted bit is delivered together with all outstanding bits;
    // restarting the guest-frame pair guarantees each bit receives B+trigger.
    g_cancel_frame = 0;
    g_cancel_phase = CANCEL_REQUESTED;
    pthread_mutex_unlock(&g_actions_mu);
}

int dm_botw_touch_cancel_complete(uint64_t trigger_bit) {
    if (!valid_trigger(trigger_bit) || !actions_ready()) return 0;
    pthread_mutex_lock(&g_actions_mu);
    int complete = !!(g_cancel_complete & trigger_bit);
    pthread_mutex_unlock(&g_actions_mu);
    return complete;
}

void dm_botw_touch_actions_reset(void) {
    pthread_mutex_lock(&g_actions_mu);
    g_cancel_pending = 0;
    g_cancel_complete = 0;
    g_cancel_frame = 0;
    g_cancel_phase = CANCEL_IDLE;
    g_suppressed_virtual_triggers = 0;
    g_switch_control=-1; g_switch_sticky=g_switch_started=g_rune_mode=0;
    g_switch_bit=g_pulse_bits=0; g_pulse_frame=UINT64_MAX;
    g_aim_triggers=g_suppressed_virtual_switch=0;
    pthread_mutex_unlock(&g_actions_mu);
}

void dm_botw_touch_actions_apply(uint64_t *other_buttons, uint64_t *virtual_buttons, uint64_t frame) {
    if (!other_buttons || !virtual_buttons) return;
    if (!touch_mode_active()) return;
    int notify = 0;
    pthread_mutex_lock(&g_actions_mu);
    g_suppressed_virtual_switch &= *virtual_buttons;
    *virtual_buttons &= ~g_suppressed_virtual_switch;
    if (g_switch_control>=0 && ((*other_buttons|*virtual_buttons)&DM_BTN_B)) {
        pulse_locked(DM_BTN_B|g_switch_bit);
        g_switch_control=-1; g_switch_bit=0; g_switch_sticky=0; notify=1;
    }
    if (g_switch_control==6 && !g_switch_started && action_time()-g_rune_down>=.20) {
        g_switch_started=1; g_switch_bit=DM_BTN_UP; g_switch_sticky=g_rune_mode==2; notify=1;
    }
    *other_buttons|=g_switch_bit;
    if (g_pulse_bits) {
        if (g_pulse_frame==UINT64_MAX) g_pulse_frame=frame;
        if (frame<=g_pulse_frame+1) *other_buttons|=g_pulse_bits;
        else g_pulse_bits=0;
    }
    // Acknowledgement can reach UIKit/AppKit after this getter has run again.
    // Suppress only the virtual-origin trigger contribution until its source
    // releases; physical buttons and the independent virtual edge latch remain.
    g_suppressed_virtual_triggers &= *virtual_buttons;
    *virtual_buttons &= ~g_suppressed_virtual_triggers;
    uint64_t aim=*virtual_buttons & (DM_BTN_R|DM_BTN_ZR) & ~g_cancel_pending;
    if (g_aim_triggers!=aim) { g_aim_triggers=aim; notify=1; }
    if (g_cancel_phase == CANCEL_REQUESTED) {
        g_cancel_frame = frame;
        g_cancel_phase = CANCEL_WAIT_FRAME;
    }
    if (g_cancel_phase == CANCEL_WAIT_FRAME) {
        *other_buttons |= DM_BTN_B | g_cancel_pending;
        if (frame > g_cancel_frame) {
            // This later returned Npad state contains B and every accepted
            // trigger. Per-bit sticky acknowledgements wake the front end.
            g_cancel_complete |= g_cancel_pending;
            g_suppressed_virtual_triggers |= g_cancel_pending;
            g_cancel_pending = 0;
            g_cancel_phase = CANCEL_IDLE;
            notify = 1;
        }
    }
    pthread_mutex_unlock(&g_actions_mu);
    if (notify) front_botw_touch_action_changed();
}

#ifdef DM_TEST_HOOKS
void dm_botw_touch_actions_test_enable(int enabled) { atomic_store_explicit(&g_actions_test_ready, !!enabled, memory_order_release); }
void dm_botw_touch_actions_test_clear(void) {
    dm_botw_touch_actions_reset();
    pthread_mutex_lock(&g_actions_mu); g_actions_ready = 0; pthread_mutex_unlock(&g_actions_mu);
    atomic_store_explicit(&g_actions_test_ready, 0, memory_order_release);
}
#endif
