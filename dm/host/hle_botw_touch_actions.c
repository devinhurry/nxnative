// BOTW 1.9 touch-only R/ZR drag-cancel input sequencing.
#include "botw_touch_actions.h"
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include <pthread.h>
#include <stdatomic.h>

enum { CANCEL_IDLE, CANCEL_REQUESTED, CANCEL_WAIT_FRAME };
static const char BOTW_TOUCH_ACTION_BUILD[] = "cd57b23fa4bbad65803d9788c01821ee";
static pthread_mutex_t g_actions_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_actions_ready, g_cancel_phase;
static uint64_t g_cancel_pending, g_cancel_complete, g_cancel_frame, g_suppressed_virtual_triggers;
static _Atomic int g_actions_test_ready;

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
    LOG("BOTW touch actions: R/ZR cancel enabled for build %s", BOTW_TOUCH_ACTION_BUILD);
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
    pthread_mutex_unlock(&g_actions_mu);
}

void dm_botw_touch_actions_apply(uint64_t *other_buttons, uint64_t *virtual_buttons, uint64_t frame) {
    if (!other_buttons || !virtual_buttons) return;
    if (!touch_mode_active()) return;
    int notify = 0;
    pthread_mutex_lock(&g_actions_mu);
    // Acknowledgement can reach UIKit/AppKit after this getter has run again.
    // Suppress only the virtual-origin trigger contribution until its source
    // releases; physical buttons and the independent virtual edge latch remain.
    g_suppressed_virtual_triggers &= *virtual_buttons;
    *virtual_buttons &= ~g_suppressed_virtual_triggers;
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
