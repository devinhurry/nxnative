#pragma once
#include <stdint.h>

// BOTW 1.9 touch-only action requests. These are virtual frontend intents;
// physical controller state and the ordinary virtual button/latch paths stay separate.
void dm_botw_touch_actions_install(void);
int dm_botw_touch_actions_available(void);
void dm_botw_touch_cancel_trigger(uint64_t trigger_bit); // DM_BTN_R or DM_BTN_ZR
int dm_botw_touch_cancel_complete(uint64_t trigger_bit);
void dm_botw_touch_actions_reset(void);

// HID integration: contributes accepted R/ZR cancel bits plus B independently
// of current virtual-button lifetime. Completion needs a returned state in a
// later guest frame; only delayed virtual-origin trigger bits are filtered.
void dm_botw_touch_actions_apply(uint64_t *other_buttons, uint64_t *virtual_buttons, uint64_t frame);

#ifdef DM_TEST_HOOKS
void dm_botw_touch_actions_test_enable(int enabled);
void dm_botw_touch_actions_test_clear(void);
#endif
