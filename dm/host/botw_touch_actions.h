#pragma once
#include <stdint.h>

// BOTW 1.9 touch-only action requests. These are virtual frontend intents;
// physical controller state and the ordinary virtual button/latch paths stay separate.
void dm_botw_touch_actions_install(void);
int dm_botw_touch_actions_available(void);
void dm_botw_touch_cancel_trigger(uint64_t trigger_bit); // DM_BTN_R or DM_BTN_ZR
int dm_botw_touch_cancel_complete(uint64_t trigger_bit);
void dm_botw_touch_actions_reset(void);
// Optional category buttons use layout IDs 16..19; L uses ID 6.
// Equipment modes: inventory, hold, tap. Rune modes: native, hold/release, sticky.
void dm_botw_touch_button_begin(int control, int mode);
void dm_botw_touch_button_end(int control, int cancelled);
void dm_botw_touch_switch_cancel(void);
// Accept the native quick-strip selection and release its opening direction.
void dm_botw_touch_switch_selected(void);
int dm_botw_touch_switch_active(void);
int dm_botw_touch_switch_cancel_visible(void);

// HID integration: contributes shortcut holds/pulses and accepted R/ZR cancel
// bits plus B independently
// of current virtual-button lifetime. Completion needs a returned state in a
// later guest frame; only delayed virtual-origin trigger bits are filtered.
void dm_botw_touch_actions_apply(uint64_t *other_buttons, uint64_t *virtual_buttons, uint64_t frame);

#ifdef DM_TEST_HOOKS
void dm_botw_touch_actions_test_enable(int enabled);
void dm_botw_touch_actions_test_clear(void);
#endif
