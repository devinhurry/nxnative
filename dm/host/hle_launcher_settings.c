// Live launcher settings are applied through the same state owners used by
// the game and front end. Environment variables alone are not live state.
#include "hle.h"
#include "launcher_settings.h"
#include "hle_haptics.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <TargetConditionals.h>

// Each front end refreshes its own virtual controls on the UI thread.
void front_refresh_touch_settings(void);

static int known_key(const char *key) {
    static const char *const keys[] = {
        "DM_FPS_TARGET", "DM_DYNAMIC_RESOLUTION", "DM_RENDER_SCALE", "DM_OPMODE",
        "DM_PRESENT_UPSCALE", "DM_LANG", "DM_FULLSCREEN", "DM_SHOW_FPS",
        "DM_TOUCH_HAPTICS", "DM_RUMBLE", "DM_RUMBLE_GAIN", "DM_RUMBLE_MIN",
        "DM_BOTW_MOVE_DEADZONE", "DM_BOTW_MOVE_CURVE", "DM_BOTW_MOVE_FULL", "DM_BOTW_MOVE_SIZE",
        "DM_BOTW_PAD_FACE_X", "DM_BOTW_PAD_FACE_Y", "DM_BOTW_PAD_FACE_SCALE",
        "DM_BOTW_PAD_STICK_X", "DM_BOTW_PAD_STICK_Y", "DM_BOTW_PAD_ZL_X", "DM_BOTW_PAD_ZL_Y", "DM_BOTW_PAD_ZL_SCALE",
        "DM_BOTW_PAD_L_X", "DM_BOTW_PAD_L_Y", "DM_BOTW_PAD_L_SCALE", "DM_BOTW_PAD_R_X", "DM_BOTW_PAD_R_Y", "DM_BOTW_PAD_R_SCALE",
        "DM_BOTW_PAD_ZR_X", "DM_BOTW_PAD_ZR_Y", "DM_BOTW_PAD_ZR_SCALE", "DM_BOTW_PAD_DPAD_X", "DM_BOTW_PAD_DPAD_Y", "DM_BOTW_PAD_DPAD_SCALE",
        "DM_BOTW_PAD_FACE_GAP", "DM_BOTW_PAD_BADGES", "DM_BOTW_PORTRAIT",
        "DM_BOTW_PORTRAIT_MOVE_DEADZONE", "DM_BOTW_PORTRAIT_MOVE_CURVE", "DM_BOTW_PORTRAIT_MOVE_FULL", "DM_BOTW_PORTRAIT_MOVE_SIZE",
        "DM_BOTW_PORTRAIT_PAD_A_X", "DM_BOTW_PORTRAIT_PAD_A_Y", "DM_BOTW_PORTRAIT_PAD_A_SCALE",
        "DM_BOTW_PORTRAIT_PAD_B_X", "DM_BOTW_PORTRAIT_PAD_B_Y", "DM_BOTW_PORTRAIT_PAD_B_SCALE",
        "DM_BOTW_PORTRAIT_PAD_X_X", "DM_BOTW_PORTRAIT_PAD_X_Y", "DM_BOTW_PORTRAIT_PAD_X_SCALE",
        "DM_BOTW_PORTRAIT_PAD_Y_X", "DM_BOTW_PORTRAIT_PAD_Y_Y", "DM_BOTW_PORTRAIT_PAD_Y_SCALE",
        "DM_BOTW_PORTRAIT_PAD_STICK_X", "DM_BOTW_PORTRAIT_PAD_STICK_Y",
        "DM_BOTW_PORTRAIT_PAD_ZL_X", "DM_BOTW_PORTRAIT_PAD_ZL_Y", "DM_BOTW_PORTRAIT_PAD_ZL_SCALE",
        "DM_BOTW_PORTRAIT_PAD_L_X", "DM_BOTW_PORTRAIT_PAD_L_Y", "DM_BOTW_PORTRAIT_PAD_L_SCALE",
        "DM_BOTW_PORTRAIT_PAD_R_X", "DM_BOTW_PORTRAIT_PAD_R_Y", "DM_BOTW_PORTRAIT_PAD_R_SCALE",
        "DM_BOTW_PORTRAIT_PAD_ZR_X", "DM_BOTW_PORTRAIT_PAD_ZR_Y", "DM_BOTW_PORTRAIT_PAD_ZR_SCALE",
        "DM_BOTW_PORTRAIT_PAD_DPAD_X", "DM_BOTW_PORTRAIT_PAD_DPAD_Y", "DM_BOTW_PORTRAIT_PAD_DPAD_SCALE",
        "DM_BOTW_PORTRAIT_PAD_BADGES", "DM_LOW_MEMORY", "DM_PRESENT_SNAP", "DM_PSO_MTL4",
        "DM_PSO_PREBUILD", "DM_NVN_ENC_THREAD", "DM_FPS_HOLD", "DM_METAL_HUD",
        "DM_NVN_FB_SNAP", "DM_THERMAL_CAP"
    };
    if (!key) return 0;
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) if (!strcmp(key, keys[i])) return 1;
    return 0;
}

static int botw_key(const char *key) { return !strncmp(key, "DM_BOTW_", 8); }

static int parse_number(const char *s, float *out) {
    if (!s || !*s) return 0;
    char *end = NULL;
    float v = strtof(s, &end);
    if (end == s || *end || !isfinite(v)) return 0;
    *out = v;
    return 1;
}

static int value_valid(const char *key, const char *value) {
    float v;
    if (!value || !*value) return 0;
    if (!strcmp(key, "DM_FPS_TARGET")) return !strcmp(value, "30") || !strcmp(value, "60");
    if (!strcmp(key, "DM_OPMODE")) return !strcmp(value, "0") || !strcmp(value, "1");
    if (!strcmp(key, "DM_RUMBLE") || !strcmp(key, "DM_TOUCH_HAPTICS") || !strcmp(key, "DM_SHOW_FPS") ||
        !strcmp(key, "DM_DYNAMIC_RESOLUTION") || !strcmp(key, "DM_BOTW_PORTRAIT") ||
        !strcmp(key, "DM_BOTW_PAD_BADGES") || !strcmp(key, "DM_BOTW_PORTRAIT_PAD_BADGES"))
        return !strcmp(value, "0") || !strcmp(value, "1");
    if (!strcmp(key, "DM_RENDER_SCALE")) return parse_number(value, &v) && v >= .5f && v <= 1.f;
    if (!strcmp(key, "DM_RUMBLE_GAIN")) return parse_number(value, &v) && v >= 0 && v <= 3;
    if (!strcmp(key, "DM_RUMBLE_MIN")) return parse_number(value, &v) && v >= 0 && v <= .9f;
    if (!botw_key(key)) return strlen(value) < 128 && strspn(value, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") == strlen(value);
    if (!parse_number(value, &v)) return 0;
    if (strstr(key, "MOVE_DEADZONE")) return v >= 0 && v <= .3f;
    if (strstr(key, "MOVE_CURVE")) return v >= .3f && v <= 2.f;
    if (strstr(key, "MOVE_FULL")) return v >= .35f && v <= 1.f;
    if (strstr(key, "MOVE_SIZE")) return v >= .6f && v <= 1.5f;
    if (strstr(key, "_SCALE")) return v >= .5f && v <= 1.5f;
    if (strstr(key, "FACE_GAP")) return v >= .5f && v <= 1.5f;
    return v >= -.5f && v <= .5f;
}

int dm_launcher_setting_is_live(const char *key) {
    if (!known_key(key)) return -1;
    if (!strcmp(key, "DM_OPMODE")) return 1;
    if ((!strcmp(key, "DM_FPS_TARGET") || !strcmp(key, "DM_RENDER_SCALE")) && dm_fps_state) return 1;
    if (botw_key(key) && !strcmp(DM_GAME_ID, "01007EF00011E000")) return 1;
#if TARGET_OS_IPHONE
    if (!strcmp(key, "DM_TOUCH_HAPTICS")) return 1;
#endif
    if (!strcmp(key, "DM_RUMBLE") || !strcmp(key, "DM_RUMBLE_GAIN") || !strcmp(key, "DM_RUMBLE_MIN")) return 1;
    return 0;
}

int dm_launcher_setting_apply(const char *key, const char *value) {
    int live = dm_launcher_setting_is_live(key);
    if (live < 0 || !value_valid(key, value)) return -1;
    if (!live) return 0;
    if (setenv(key, value, 1)) return -1;
    if (!strcmp(key, "DM_OPMODE")) dm_set_opmode(atoi(value));
    else if (!strcmp(key, "DM_FPS_TARGET")) {
        dm_fps_lock_setting_changed(atoi(value));
        dm_fps_state_apply();
    }
    else if (!strcmp(key, "DM_RENDER_SCALE")) dm_fps_state_apply();
    else if (botw_key(key) || !strcmp(key, "DM_TOUCH_HAPTICS")) {
        front_refresh_touch_settings();
    }
    else dm_haptics_apple_settings_changed();
    return 1;
}
