#include "../hle.h"
#include "../launcher_settings.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

uint8_t *dm_fps_state;
static uint8_t state_page[0x40];
static int opmode, fps_apply_count, fps_lock_target, haptics_refresh_count, touch_refresh_count;
static int framegen_mode, framegen_available = 1;
int dm_fg_set_mode(int mode) { if (!framegen_available) return 0; framegen_mode = mode; return 1; }
void dm_set_opmode(int value) { opmode = value; }
void dm_fps_state_apply(void) { fps_apply_count++; }
void dm_fps_lock_setting_changed(int target) { fps_lock_target = target; }
void dm_haptics_apple_settings_changed(void) { haptics_refresh_count++; }
void front_refresh_touch_settings(void) { touch_refresh_count++; }

int main(void) {
    unsetenv("DM_DYNAMIC_RESOLUTION");
    assert(dm_launcher_setting_is_live("missing") == -1);
    assert(dm_launcher_setting_is_live("DM_DYNAMIC_RESOLUTION") == 0);
    assert(dm_launcher_setting_apply("DM_DYNAMIC_RESOLUTION", "1") == 0);
    assert(getenv("DM_DYNAMIC_RESOLUTION") == NULL); // restart-only keys are not applied via env alone
    assert(dm_launcher_setting_apply("DM_OPMODE", "2") == -1);
    assert(dm_launcher_setting_apply("DM_OPMODE", "0") == 1 && opmode == 0);
    assert(!strcmp(getenv("DM_OPMODE"), "0"));

    assert(dm_launcher_setting_is_live("DM_RENDER_SCALE") == 0);
    dm_fps_state = state_page;
    assert(dm_launcher_setting_is_live("DM_RENDER_SCALE") == 1);
    assert(dm_launcher_setting_apply("DM_RENDER_SCALE", "0.75") == 1 && fps_apply_count == 1);
    assert(dm_launcher_setting_apply("DM_RENDER_SCALE", "2") == -1 && fps_apply_count == 1);
    assert(dm_launcher_setting_apply("DM_FPS_TARGET", "60") == 1 && fps_apply_count == 2 && fps_lock_target == 60);
    if (*DM_GAME_FRAMEGEN_SCENE) {
        assert(dm_launcher_setting_is_live("DM_FRAMEGEN") == 1);
        for (int rate = 30; rate <= 60; rate += 30) {
            const char *value = rate == 30 ? "30" : "60";
            assert(dm_launcher_setting_apply("DM_FRAMEGEN", value) == 1 && framegen_mode == rate);
            assert(!strcmp(getenv("DM_FRAMEGEN"), value));
            assert(dm_launcher_setting_apply("DM_FRAMEGEN", "0") == 1 && framegen_mode == 0);
        }
        assert(dm_launcher_setting_apply("DM_FRAMEGEN", "40") == -1);
        framegen_available = 0;
        assert(dm_launcher_setting_apply("DM_FRAMEGEN", "60") == -1 && !strcmp(getenv("DM_FRAMEGEN"), "0"));
    } else assert(dm_launcher_setting_is_live("DM_FRAMEGEN") == 0);
    assert(dm_launcher_setting_is_live("DM_NVN_PASS_REUSE") == 0);
    assert(dm_launcher_setting_apply("DM_RUMBLE_GAIN", "2.5") == 1 && haptics_refresh_count == 1);
    assert(dm_launcher_setting_apply("DM_RUMBLE_GAIN", "nan") == -1 && haptics_refresh_count == 1);
    assert(dm_launcher_setting_is_live("DM_PRESENT_UPSCALE") == 0);
    if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
        assert(dm_launcher_setting_is_live("DM_BOTW_MOVE_CURVE") == 1);
        assert(dm_launcher_setting_apply("DM_BOTW_MOVE_CURVE", "0.5") == 1 && touch_refresh_count == 1);
        assert(dm_launcher_setting_apply("DM_BOTW_MOVE_DEADZONE", "0.7") == -1 && touch_refresh_count == 1);
    }
    return 0;
}
