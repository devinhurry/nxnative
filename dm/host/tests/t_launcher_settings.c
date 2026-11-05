#include "../hle.h"
#include "../launcher_settings.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint8_t *dm_fps_state;
int dm_fps_realtime;
static uint8_t state_page[0x40];
static int opmode, fps_apply_count, fps_lock_target, haptics_refresh_count, touch_refresh_count;
static int framegen_mode, framegen_available = 1;
static int fps_visibility_refresh_count;
static char motion_source[16];
static int motion_refresh_count;
static int filter_refresh_count;
static unsigned clock_pauses, graphics_pauses, audio_pauses;
void guest_clock_freeze_for(int reason, int on) { if (on) clock_pauses |= 1u << reason; else clock_pauses &= ~(1u << reason); }
void dm_gfx_suspend_for(int reason, int on) { if (on) graphics_pauses |= 1u << reason; else graphics_pauses &= ~(1u << reason); }
void dm_audio_suspend_for(int reason, int on) { if (on) audio_pauses |= 1u << reason; else audio_pauses &= ~(1u << reason); }
int dm_fg_set_mode(int mode) { if (mode && !framegen_available) return 0; framegen_mode = mode; return 1; }
void dm_set_opmode(int value) { opmode = value; }
void dm_fps_state_apply(void) { fps_apply_count++; }
void dm_fps_lock_setting_changed(int target) { fps_lock_target = target; }
void dm_haptics_apple_settings_changed(void) { haptics_refresh_count++; }
void front_refresh_touch_settings(void) { touch_refresh_count++; }
void front_refresh_fps_settings(void) { fps_visibility_refresh_count++; }
void dm_motion_source_set(const char *value) { strcpy(motion_source,value); motion_refresh_count++; }
void dm_present_filter_settings_changed(void) { filter_refresh_count++; }

int main(void) {
    dm_launcher_settings_pause(1);
    dm_launcher_settings_pause(1);
    assert(clock_pauses == (1u << 3) && graphics_pauses == (1u << DM_SUSPEND_SETTINGS) && audio_pauses == graphics_pauses);
    clock_pauses |= 1u << 1; graphics_pauses |= 1u << DM_SUSPEND_LIFECYCLE; audio_pauses |= 1u << DM_SUSPEND_LIFECYCLE;
    dm_launcher_settings_pause(0);
    dm_launcher_settings_pause(0);
    assert(clock_pauses == (1u << 1) && graphics_pauses == (1u << DM_SUSPEND_LIFECYCLE) && audio_pauses == graphics_pauses);
    clock_pauses = graphics_pauses = audio_pauses = 0;
    unsetenv("DM_DYNAMIC_RESOLUTION");
    assert(dm_launcher_setting_is_live("missing") == -1);
    assert(dm_launcher_setting_is_live("DM_DYNAMIC_RESOLUTION") == 0);
    assert(dm_launcher_setting_apply("DM_DYNAMIC_RESOLUTION", "1") == 0);
    assert(getenv("DM_DYNAMIC_RESOLUTION") == NULL); // restart-only keys are not applied via env alone
    assert(dm_launcher_setting_apply("DM_OPMODE", "2") == -1);
    assert(dm_launcher_setting_apply("DM_OPMODE", "0") == 1 && opmode == 0);
    const char *opmode_env = getenv("DM_OPMODE");
    assert(opmode_env && !strcmp(opmode_env, "0"));
    assert(dm_launcher_setting_is_live("DM_MOTION_SOURCE") == 1);
    const char *sources[]={"auto","off","controller","device"};
    for (int i=0;i<4;i++) {
        assert(dm_launcher_setting_apply("DM_MOTION_SOURCE",sources[i])==1);
        assert(!strcmp(motion_source,sources[i]) && motion_refresh_count==i+1);
    }
    assert(dm_launcher_setting_apply("DM_MOTION_SOURCE","phone")==-1 && motion_refresh_count==4);
    assert(dm_launcher_setting_is_live("DM_PRESENT_FILTER") == 1);
    assert(dm_launcher_setting_is_live("DM_PRESENT_FILTER_STRENGTH") == 1);
    const char *filters[] = {"off", "vivid", "cinematic", "warm", "cool"};
    for (int i = 0; i < 5; i++) {
        assert(dm_launcher_setting_apply("DM_PRESENT_FILTER", filters[i]) == 1);
        assert(!strcmp(getenv("DM_PRESENT_FILTER"), filters[i]) && filter_refresh_count == i + 1);
    }
    for (const char **p = (const char *[]){"0", "0.5", "1", NULL}; *p; p++)
        assert(dm_launcher_setting_apply("DM_PRESENT_FILTER_STRENGTH", *p) == 1);
    assert(filter_refresh_count == 8);
    assert(dm_launcher_setting_apply("DM_PRESENT_FILTER", "crt") == -1);
    for (const char **p = (const char *[]){"", "nan", "inf", "-0.01", "1.01", "0.5oops", NULL}; *p; p++)
        assert(dm_launcher_setting_apply("DM_PRESENT_FILTER_STRENGTH", *p) == -1);
    assert(!strcmp(getenv("DM_PRESENT_FILTER"), "cool") && !strcmp(getenv("DM_PRESENT_FILTER_STRENGTH"), "1") && filter_refresh_count == 8);
    assert(haptics_refresh_count == 0 && touch_refresh_count == 0);

    assert(dm_launcher_setting_is_live("DM_RENDER_SCALE") == 0);
    dm_fps_state = state_page;
    assert(dm_launcher_setting_is_live("DM_RENDER_SCALE") == 1);
    assert(dm_launcher_setting_apply("DM_RENDER_SCALE", "0.75") == 1 && fps_apply_count == 1);
    assert(dm_launcher_setting_apply("DM_RENDER_SCALE", "2") == -1 && fps_apply_count == 1);
    assert(dm_launcher_setting_apply("DM_FPS_TARGET", "60") == 1 && fps_apply_count == 2 && fps_lock_target == 60);
    if (*DM_GAME_FRAMEGEN_SCENE) {
        assert(dm_launcher_setting_is_live("DM_FRAMEGEN") == 1);
        for (int rate = 20; rate <= 60; rate += 5) {
            char value[16]; snprintf(value,sizeof value,"%d",rate);
            assert(dm_launcher_setting_apply("DM_FRAMEGEN", value) == 1 && framegen_mode == rate);
            assert(!strcmp(getenv("DM_FRAMEGEN"), value));
            assert(dm_launcher_setting_apply("DM_FRAMEGEN", "0") == 1 && framegen_mode == 0);
        }
        assert(dm_launcher_setting_apply("DM_FRAMEGEN", "45.5") == -1);
        framegen_available = 0;
        assert(dm_launcher_setting_apply("DM_FRAMEGEN", "60") == -1 && !strcmp(getenv("DM_FRAMEGEN"), "0"));
    } else assert(dm_launcher_setting_is_live("DM_FRAMEGEN") == 0);
    assert(dm_launcher_setting_apply("DM_FPS_TARGET","40")==-1); // no verified fractional step
    dm_fps_realtime=1;
    for (int rate=20;rate<=120;rate+=5) {
        char value[16]; snprintf(value,sizeof value,"%d",rate);
        assert(dm_launcher_setting_apply("DM_FPS_TARGET",value)==1 && fps_lock_target==rate);
        if (*DM_GAME_FRAMEGEN_SCENE && rate>60) {
            assert(framegen_mode==0 && !strcmp(getenv("DM_FRAMEGEN"),"0"));
            assert(dm_launcher_setting_apply("DM_FRAMEGEN","30")==-1);
        }
    }
    for (const char **p=(const char *[]){"19","125","31","30.5","2e1","nan",NULL};*p;p++)
        assert(dm_launcher_setting_apply("DM_FPS_TARGET",*p)==-1);
    dm_fps_realtime=0;
    assert(dm_launcher_setting_is_live("DM_NVN_PASS_REUSE") == 0);
    assert(dm_launcher_setting_apply("DM_RUMBLE_GAIN", "2.5") == 1 && haptics_refresh_count == 1);
    assert(dm_launcher_setting_apply("DM_RUMBLE_GAIN", "nan") == -1 && haptics_refresh_count == 1);
#if TARGET_OS_IPHONE
    assert(dm_launcher_setting_is_live("DM_SHOW_FPS") == 1);
    assert(dm_launcher_setting_apply("DM_SHOW_FPS", "1") == 1 && fps_visibility_refresh_count == 1);
    assert(!strcmp(getenv("DM_SHOW_FPS"), "1"));
    assert(dm_launcher_setting_apply("DM_SHOW_FPS", "0") == 1 && fps_visibility_refresh_count == 2);
    assert(!strcmp(getenv("DM_SHOW_FPS"), "0"));
    assert(dm_launcher_setting_apply("DM_SHOW_FPS", "2") == -1 && fps_visibility_refresh_count == 2);
    assert(haptics_refresh_count == 1 && touch_refresh_count == 0);
#else
    assert(dm_launcher_setting_is_live("DM_SHOW_FPS") == 0);
#endif
    assert(dm_launcher_setting_is_live("DM_PRESENT_UPSCALE") == 0);
    if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
        assert(dm_launcher_setting_is_live("DM_BOTW_MOVE_CURVE") == 1);
        assert(dm_launcher_setting_apply("DM_BOTW_MOVE_CURVE", "0.5") == 1 && touch_refresh_count == 1);
        assert(dm_launcher_setting_apply("DM_BOTW_MOVE_DEADZONE", "0.7") == -1 && touch_refresh_count == 1);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_A_X_PT", "-35.5") == 1 && touch_refresh_count == 2);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_B_SIZE_PT", "75") == 1 && touch_refresh_count == 3);
        assert(dm_launcher_setting_apply("DM_BOTW_PORTRAIT_PAD_Y_Y_PT", "120") == 1 && touch_refresh_count == 4);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_A_X_PT", "1800") == 1 && touch_refresh_count == 5);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_L_ANCHOR", "2") == 1 && touch_refresh_count == 6);
        assert(dm_launcher_setting_apply("DM_BOTW_PORTRAIT_PAD_A_ANCHOR", "1") == 1 && touch_refresh_count == 7);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_L_ANCHOR", "1.5") == -1 && touch_refresh_count == 7);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_L_ANCHOR", "3") == -1 && touch_refresh_count == 7);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_A_X_PT", "10001") == -1 && touch_refresh_count == 7);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_B_SIZE_PT", "19") == -1 && touch_refresh_count == 7);
        assert(dm_launcher_setting_apply("DM_BOTW_PAD_B_SIZE_PT", "nan") == -1 && touch_refresh_count == 7);
        assert(dm_launcher_setting_is_live("DM_BOTW_PAD_FACE_X") == -1);
        const char *appearance[]={"FILL_GRAY","FILL_ALPHA","STROKE_GRAY","STROKE_ALPHA","ICON_ALPHA"};
        for (int portrait=0;portrait<2;portrait++) {
            const char *cancel=portrait ? "DM_BOTW_PORTRAIT_PAD_CANCEL_ENABLED" : "DM_BOTW_PAD_CANCEL_ENABLED";
            assert(dm_launcher_setting_is_live(cancel)==1);
            assert(dm_launcher_setting_apply(cancel,"0")==1 && !strcmp(getenv(cancel),"0"));
            assert(dm_launcher_setting_apply(cancel,"1")==1);
            assert(dm_launcher_setting_apply(cancel,"2")==-1);
            unsetenv(cancel);
            const char *icon=portrait ? "DM_BOTW_PORTRAIT_PAD_L_ICON_MODE" : "DM_BOTW_PAD_L_ICON_MODE";
            assert(dm_launcher_setting_is_live(icon)==1);
            assert(dm_launcher_setting_apply(icon,"1")==1);
            assert(dm_launcher_setting_apply(icon,"0")==1);
            assert(dm_launcher_setting_apply(icon,"2")==-1);
            assert(dm_launcher_setting_apply(icon,"0.5")==-1);
            unsetenv(icon);
            const char *show=portrait ? "DM_BOTW_PORTRAIT_PAD_DPAD_SHOW_BUTTONS" : "DM_BOTW_PAD_DPAD_SHOW_BUTTONS";
            assert(dm_launcher_setting_is_live(show)==-1);
            assert(dm_launcher_setting_apply(show,"1")==-1);
            const char *key=portrait ? "DM_BOTW_PORTRAIT_PAD_ZL_HIT_PT" : "DM_BOTW_PAD_ZL_HIT_PT";
            assert(dm_launcher_setting_is_live(key)==1);
            assert(dm_launcher_setting_apply(key,"80")==1 && !strcmp(getenv(key),"80"));
            assert(dm_launcher_setting_apply(key,"19.9")==-1 && !strcmp(getenv(key),"80"));
            assert(dm_launcher_setting_apply(key,"480.1")==-1);
            assert(dm_launcher_setting_apply(key,"nan")==-1);
            unsetenv(key);
        }
        for (int portrait=0;portrait<2;portrait++) for (int i=0;i<5;i++) {
            char key[80]; snprintf(key,sizeof key,"DM_BOTW_%sPAD_%s",portrait ? "PORTRAIT_" : "",appearance[i]);
            assert(dm_launcher_setting_is_live(key)==1);
            assert(dm_launcher_setting_apply(key,"0.63")==1 && !strcmp(getenv(key),"0.63"));
            assert(dm_launcher_setting_apply(key,"1.01")==-1 && !strcmp(getenv(key),"0.63"));
            assert(dm_launcher_setting_apply(key,"-0.01")==-1);
            assert(dm_launcher_setting_apply(key,"nan")==-1);
            unsetenv(key);
        }
    }
    return 0;
}
