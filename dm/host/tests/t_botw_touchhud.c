#define DM_TEST_HOOKS
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../botw_touch_actions.h"
#include "../botw_touch_menu.h"
#include "../hle_botw_touchhud.c"

static module_t test_modules[8];
module_t *g_mod = test_modules; int g_nmod;
static void (*test_gates[OBS_MAX])(const uint64_t *);
static int map_region_valid;
static int map_region_events;
static int actions_reset_count;
static int aspect_pane_calls;
static int aspect_native = 1;
static float map_region[4];
int gate_obs_present(int id) { return id == OBS_BOTW_TOUCH_PANE || id == OBS_BOTW_TOUCH_MATRIX || id == OBS_BOTW_UI_DRAW || id == OBS_BOTW_UI_DRAW_END; }
void gate_obs_read_set(int id, void (*fn)(const uint64_t *)) { assert(id > 0 && id < OBS_MAX); test_gates[id] = fn; }
void front_botw_touch_hud_mode_changed(void) {}
int dm_aspect_native(void) { return aspect_native; }
static float hud_offset[2];
float dm_aspect_hud_offset(int right) { return hud_offset[!!right]; }
void dm_aspect_ui_pane(uint8_t *pane) { if (pane) aspect_pane_calls++; }
void front_botw_rune_icon_changed(void) {}
void dm_botw_touch_actions_reset(void) { actions_reset_count++; }
void dm_botw_touch_menu_pane(const uint64_t *regs, int after_matrix) { (void)regs; (void)after_matrix; }
void dm_botw_touch_menu_reset(void) {}
void front_botw_touch_hud_map_region(int valid, float x, float y, float width, float height) {
    map_region_events++;
    map_region_valid = valid; map_region[0] = x; map_region[1] = y; map_region[2] = width; map_region[3] = height;
}

static void pane_name(uint8_t *p, const char *s) { strncpy((char *)p + BOTW_TOUCH_PANE_NAME, s, 15); }
static void set_pane_parent(uint8_t *p, uint8_t *parent) { memcpy(p + BOTW_TOUCH_PARENT, &parent, sizeof parent); }
static void matrix_translation(uint8_t *p, float x, float y) {
    memset(p + BOTW_TOUCH_MATRIX, 0, 48);
    float one = 1;
    memcpy(p + BOTW_TOUCH_MATRIX, &one, sizeof one);
    memcpy(p + BOTW_TOUCH_MATRIX + 0x14, &one, sizeof one);
    memcpy(p + BOTW_TOUCH_MATRIX + 0x0c, &x, sizeof x);
    memcpy(p + BOTW_TOUCH_MATRIX + 0x1c, &y, sizeof y);
}
static void expect_translation(uint8_t *p, float x, float y) {
    float actual_x, actual_y;
    memcpy(&actual_x, p + BOTW_TOUCH_MATRIX + 0x0c, sizeof actual_x);
    memcpy(&actual_y, p + BOTW_TOUCH_MATRIX + 0x1c, sizeof actual_y);
    assert(fabsf(actual_x - x) < 0.001f);
    assert(fabsf(actual_y - y) < 0.001f);
}
static void calculate_entry(uint8_t *p) { uint64_t r[31] = {0}; r[0] = (uintptr_t)p; dm_botw_touchhud_test_pane(r); }
static void calculated_matrix(uint8_t *p) { uint64_t r[31] = {0}; r[19] = (uintptr_t)p; dm_botw_touchhud_test_matrix(r); }
static void pane_size(uint8_t *p, float w, float h) {
    memcpy(p + BOTW_TOUCH_SIZE, &w, sizeof w); memcpy(p + BOTW_TOUCH_SIZE + 4, &h, sizeof h);
}
static void scaled_matrix(uint8_t *p, float scale, float x, float y) {
    memset(p + BOTW_TOUCH_MATRIX, 0, 48);
    memcpy(p + BOTW_TOUCH_MATRIX, &scale, sizeof scale);
    memcpy(p + BOTW_TOUCH_MATRIX + 0x14, &scale, sizeof scale);
    memcpy(p + BOTW_TOUCH_MATRIX + 0x0c, &x, sizeof x);
    memcpy(p + BOTW_TOUCH_MATRIX + 0x1c, &y, sizeof y);
}

int main(void) {
    g_nmod = 1; strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    dm_botw_touch_hud_install();
    assert(dm_botw_touch_hud_available());
    assert(test_gates[OBS_BOTW_TOUCH_PANE] && test_gates[OBS_BOTW_TOUCH_MATRIX]);
    assert(actions_reset_count == 0);

    uint8_t root[0x100] = {0}, all[0x100] = {0}, target[0x100] = {0};
    pane_name(root, "RootPane"); pane_name(all, "N_All_00"); pane_name(target, "N_MainAll_00");
    set_pane_parent(all, root); set_pane_parent(target, all);
    target[BOTW_TOUCH_FLAGS] = 0x01; // local visibility/state bit is preserved
    dm_botw_touch_hud_publish(1, 0.5f, 0.5f);
    calculate_entry(target);
    assert(target[BOTW_TOUCH_FLAGS] == 0x11);

    // This delta maps the root (-509,+210) and child cross-guide (-45,+36) to canvas centre.
    matrix_translation(target, -509, 210);
    calculated_matrix(target);
    expect_translation(target, 45, -36);
    // Recomposition starts from the native matrix each time, so repeat frames do not accumulate.
    matrix_translation(target, -509, 210);
    calculate_entry(target);
    calculated_matrix(target);
    expect_translation(target, 45, -36);

    // A geometry move updates the offset; the input position is normalized on the centered 16:9 canvas.
    dm_botw_touch_hud_publish(1, 0.25f, 0.75f);
    matrix_translation(target, -509, 210);
    calculate_entry(target);
    calculated_matrix(target);
    expect_translation(target, -275, -216);

    // A resized D-pad scales its native equipment artwork about the touch center.
    g_touch_layout.control[12].scale = 1.25f;
    matrix_translation(target, -509, 210);
    calculate_entry(target);
    calculated_matrix(target);
    expect_translation(target, -263.75f, -225);
    float basis; memcpy(&basis, target + BOTW_TOUCH_MATRIX, sizeof basis);
    assert(fabsf(basis - 1.25f) < .001f);
    dm_botw_touch_hud_publish(0, .25f, .75f);
    assert(actions_reset_count == 1);
    matrix_translation(target, -509, 210);
    calculate_entry(target);
    calculated_matrix(target);
    expect_translation(target, -509, 210);
    memcpy(&basis, target + BOTW_TOUCH_MATRIX, sizeof basis);
    assert(basis == 1);
    g_touch_layout.control[12].scale = 1;

    // A recreated MainShortCut layout with a new pane address replaces the retained target.
    uint8_t root2[0x100] = {0}, all2[0x100] = {0}, target2[0x100] = {0};
    pane_name(root2, "RootPane"); pane_name(all2, "N_All_00"); pane_name(target2, "N_MainAll_00");
    set_pane_parent(all2, root2); set_pane_parent(target2, all2);
    dm_botw_touch_hud_publish(1, 0.5f, 0.5f);
    matrix_translation(target2, -509, 210);
    calculate_entry(target2);
    calculated_matrix(target2);
    expect_translation(target2, 45, -36);

    // Match the runtime AppMap tree: a visible N_InOut_00 / N_Cut_00
    // viewport (166x166 collapsed, 1500x720 expanded) contains a 192x192
    // capture pane. N_Cut_01 is its sibling marker/compass subtree.
    uint8_t map_root[0x100] = {0}, map_inout[0x100] = {0}, cut[0x100] = {0};
    uint8_t capture[0x100] = {0}, cut_sibling[0x100] = {0};
    pane_name(map_root, "RootPane"); pane_name(map_inout, "N_InOut_00");
    pane_name(cut, "N_Cut_00"); pane_name(capture, "N_Capture_00"); pane_name(cut_sibling, "N_Cut_01");
    set_pane_parent(map_inout, map_root); set_pane_parent(cut, map_inout);
    set_pane_parent(capture, cut); set_pane_parent(cut_sibling, map_inout);
    map_root[BOTW_TOUCH_FLAGS] = map_inout[BOTW_TOUCH_FLAGS] = cut[BOTW_TOUCH_FLAGS] =
        capture[BOTW_TOUCH_FLAGS] = cut_sibling[BOTW_TOUCH_FLAGS] = 1;
    map_root[BOTW_TOUCH_FLAGS+1] = map_inout[BOTW_TOUCH_FLAGS+1] = cut[BOTW_TOUCH_FLAGS+1] =
        capture[BOTW_TOUCH_FLAGS+1] = cut_sibling[BOTW_TOUCH_FLAGS+1] = 255;
    pane_size(cut, 166, 166); pane_size(capture, 192, 192); pane_size(cut_sibling, 210, 328);
    scaled_matrix(cut, 1, 510, -240); scaled_matrix(cut_sibling, 1, 510, -240);
    calculate_entry(cut); calculated_matrix(cut);
    assert(!map_region_valid); // wait until the full live cluster geometry is known
    expect_translation(cut, 510, -240);
    calculate_entry(cut_sibling); calculated_matrix(cut_sibling);
    expect_translation(cut_sibling, 510, -240);

    uint8_t env_all[0x100] = {0}, env_root[0x100] = {0}, weather[0x100] = {0}, status[0x100] = {0};
    pane_name(env_all, "N_All_00"); pane_name(env_root, "RootPane");
    pane_name(weather, "Pa_Weather_00"); pane_name(status, "Pa_Sensor_00");
    set_pane_parent(env_all, env_root); set_pane_parent(weather, env_all); set_pane_parent(status, env_all);
    env_root[BOTW_TOUCH_FLAGS] = env_all[BOTW_TOUCH_FLAGS] = weather[BOTW_TOUCH_FLAGS] = status[BOTW_TOUCH_FLAGS] = 1;
    matrix_translation(weather, 392, -182); calculate_entry(weather); calculated_matrix(weather);
    expect_translation(weather, 392, -182);
    pane_size(status, 582, 78.2f); matrix_translation(status, 392, -182);
    calculate_entry(status); calculated_matrix(status);
    expect_translation(status, 392, -182);
    // N_Cut_00 is the viewport. Sibling N_Cut_01 and Pa_Sensor_00 have wider
    // transparent bounds, so they move with the map without setting its edge.
    scaled_matrix(cut, 1, 510, -240); calculate_entry(cut); calculated_matrix(cut);
    assert(map_region_valid && fabsf(map_region[2] - 166.0f / 1280.0f) < .001f);
    assert(fabsf(map_region[1] - 20.0f / 720.0f) < .001f);
    expect_translation(cut, 473, 257);
    scaled_matrix(cut_sibling, 1, 510, -240); calculate_entry(cut_sibling); calculated_matrix(cut_sibling);
    expect_translation(cut_sibling, 473, 257);
    matrix_translation(status, 392, -182); calculate_entry(status); calculated_matrix(status);
    expect_translation(status, 355, 315);
    assert(fabsf((315.0f - 257.0f) - 58.0f) < .001f); // gauges retain their native offset from the map
    assert(355.0f + 280.0f * .5f < 640.0f); // linked gauge content fits; Pa_Sensor's extra width is padding
    assert(fabsf((473.0f + 166.0f * .5f) - 556.0f) < .001f);
    // A wider safe HUD canvas moves the whole touch map cluster and publishes
    // its hit bounds in that same canvas, independently of centered menus.
    hud_offset[0]=76; hud_offset[1]=96;
    scaled_matrix(cut,1,510,-240); calculate_entry(cut); calculated_matrix(cut);
    expect_translation(cut,569,257);
    assert(fabsf(map_region[0]-(486.f+640+76)/1452)<.001f && fabsf(map_region[2]-166.f/1452)<.001f);
    matrix_translation(status,392,-182); calculate_entry(status); calculated_matrix(status);
    expect_translation(status,451,315);
    hud_offset[0]=hud_offset[1]=0;
    scaled_matrix(cut,1,510,-240); calculate_entry(cut); calculated_matrix(cut);
    expect_translation(cut,473,257);
    int map_events_before_tap = map_region_events;
    dm_botw_touch_hud_map_tapped();
    assert(!map_region_valid && map_region_events == map_events_before_tap + 1);

    // Expanded Slate invalidates the hit region and leaves its large viewport
    // at the native position. Returning to collapsed republishes the live hit.
    pane_size(cut, 1500, 720); scaled_matrix(cut, 1, 0, 0);
    calculate_entry(cut); calculated_matrix(cut);
    assert(!map_region_valid); expect_translation(cut, 0, 0);
    pane_size(cut, 166, 166); scaled_matrix(cut, 1, 510, -240);
    calculate_entry(cut); calculated_matrix(cut);
    assert(!map_region_valid); expect_translation(cut, 510, -240);
    scaled_matrix(cut_sibling, 1, 510, -240); calculate_entry(cut_sibling); calculated_matrix(cut_sibling);
    matrix_translation(status, 392, -182); calculate_entry(status); calculated_matrix(status);
    scaled_matrix(cut, 1, 510, -240); calculate_entry(cut); calculated_matrix(cut);
    assert(map_region_valid && map_region_events == map_events_before_tap + 2);
    assert(fabsf(map_region[1] - 20.0f / 720.0f) < .001f);
    expect_translation(cut, 473, 257);

    // Shrines hide N_InOut_00 with alpha zero while its visible bit stays set.
    map_inout[BOTW_TOUCH_FLAGS+1] = 0;
    calculate_entry(map_inout);
    assert(!map_region_valid && atomic_load(&g_touchhud_map_collapsed));
    matrix_translation(status,392,-182); calculate_entry(status); calculated_matrix(status);
    expect_translation(status,355,315); // environment HUD retains its touch-mode position
    map_inout[BOTW_TOUCH_FLAGS+1] = 255;
    calculate_entry(cut);
    scaled_matrix(cut_sibling,1,510,-240); calculate_entry(cut_sibling); calculated_matrix(cut_sibling);
    matrix_translation(status,392,-182); calculate_entry(status); calculated_matrix(status);
    scaled_matrix(cut,1,510,-240); calculate_entry(cut); calculated_matrix(cut);
    assert(map_region_valid);

    // Reestablish a live collapsed hit region, then hide AppMap's RootPane.
    // A child traversal is skipped under a hidden root, so its own Calculate
    // entry must invalidate the stale hit region.
    map_inout[BOTW_TOUCH_FLAGS] = 0;
    calculate_entry(map_inout);
    assert(!map_region_valid);
    map_inout[BOTW_TOUCH_FLAGS] = 1;
    calculate_entry(cut); // refresh the collapsed-state identity before child matrix callbacks
    calculate_entry(cut_sibling); calculated_matrix(cut_sibling);
    matrix_translation(status, 392, -182); calculate_entry(status); calculated_matrix(status);
    scaled_matrix(cut, 1, 510, -240); calculate_entry(cut); calculated_matrix(cut);
    assert(map_region_valid);
    map_root[BOTW_TOUCH_FLAGS] = 0;
    calculate_entry(map_root);
    assert(!map_region_valid);
    map_root[BOTW_TOUCH_FLAGS] = 1;

    // The current rune comes from the P_Icon_00 capture picture in the
    // MainShortCut / MainU / Pa_IconNow component, not the static category icon.
    uint8_t rune_root[0x100] = {0}, rune_all[0x100] = {0}, rune_mainall[0x100] = {0}, rune_pos[0x100] = {0};
    uint8_t rune_mainu[0x100] = {0}, rune_pamainu[0x100] = {0}, rune_innerall[0x100] = {0}, rune_now[0x100] = {0};
    uint8_t rune_picload[0x100] = {0}, rune_icon[0x100] = {0};
    uint8_t guide_main[0x100] = {0};
    uint8_t guide_cross[0x100] = {0}, guide_icon[0x100] = {0};
    pane_name(rune_root, "RootPane"); pane_name(rune_all, "N_All_00"); pane_name(rune_mainall, "N_MainAll_00");
    pane_name(rune_mainu, "N_MainU_00"); pane_name(rune_pamainu, "Pa_MainU_00"); pane_name(rune_pos, "N_Pos_00");
    pane_name(rune_innerall, "N_All_00"); pane_name(rune_now, "Pa_IconNow_00"); pane_name(rune_picload, "N_PicLoad_00");
    pane_name(rune_icon, "P_Icon_00");
    pane_name(guide_main, "N_MainGuide_00"); pane_name(guide_cross, "Pa_IconCross_00");
    pane_name(guide_icon, "P_GuideIcon_00");
    set_pane_parent(rune_all, rune_root); set_pane_parent(rune_mainall, rune_all); set_pane_parent(rune_pos, rune_mainall);
    set_pane_parent(rune_mainu, rune_pos); set_pane_parent(rune_pamainu, rune_mainu); set_pane_parent(rune_innerall, rune_pamainu);
    set_pane_parent(rune_now, rune_innerall); set_pane_parent(rune_picload, rune_now); set_pane_parent(rune_icon, rune_picload);
    set_pane_parent(guide_main, rune_pos); set_pane_parent(guide_cross, guide_main); set_pane_parent(guide_icon, guide_cross);
    rune_root[BOTW_TOUCH_FLAGS] = rune_all[BOTW_TOUCH_FLAGS] = rune_mainall[BOTW_TOUCH_FLAGS] = rune_pos[BOTW_TOUCH_FLAGS] = 1;
    rune_mainu[BOTW_TOUCH_FLAGS] = rune_pamainu[BOTW_TOUCH_FLAGS] = rune_innerall[BOTW_TOUCH_FLAGS] = rune_now[BOTW_TOUCH_FLAGS] = 1;
    rune_picload[BOTW_TOUCH_FLAGS] = rune_icon[BOTW_TOUCH_FLAGS] = 1;
    guide_main[BOTW_TOUCH_FLAGS] = 1;
    guide_cross[BOTW_TOUCH_FLAGS] = guide_icon[BOTW_TOUCH_FLAGS] = 1;
    uint8_t *rune_chain[] = {rune_root,rune_all,rune_mainall,rune_pos,rune_mainu,rune_pamainu,rune_innerall,rune_now,rune_picload,rune_icon};
    for (unsigned i=0;i<sizeof rune_chain/sizeof *rune_chain;i++) rune_chain[i][BOTW_TOUCH_FLAGS+1] = 255;
    pane_size(rune_icon, 100, 80); matrix_translation(rune_icon, 100, 200);
    calculate_entry(rune_icon); calculated_matrix(rune_icon);
    pane_size(guide_icon, 46, 46); matrix_translation(guide_icon, 83, 167);
    calculate_entry(guide_icon); calculated_matrix(guide_icon);
    uint64_t rune_token, animated_token;
    assert(dm_botw_rune_icon_capture_token(&rune_token));
    matrix_translation(rune_icon, 101, 201); calculate_entry(rune_icon); calculated_matrix(rune_icon);
    assert(dm_botw_rune_icon_capture_token(&animated_token) && animated_token == rune_token);
    uint8_t alpha_pixels[20] = {255, 229, 137, 0, 200, 101, 50, 128, 17, 80, 240, 255,
                                239, 103, 66, 85, 0xee, 0xee, 0xee, 0xee};
    dm_botw_rune_icon_premultiply_rgba(alpha_pixels, 4, 1, 20);
    assert(alpha_pixels[0] == 0 && alpha_pixels[1] == 0 && alpha_pixels[2] == 0 && alpha_pixels[3] == 0);
    assert(alpha_pixels[4] == 100 && alpha_pixels[5] == 51 && alpha_pixels[6] == 25 && alpha_pixels[7] == 128);
    assert(alpha_pixels[8] == 17 && alpha_pixels[9] == 80 && alpha_pixels[10] == 240 && alpha_pixels[11] == 255);
    assert(alpha_pixels[12] == 80 && alpha_pixels[13] == 34 && alpha_pixels[14] == 22 && alpha_pixels[15] == 85);
    assert(alpha_pixels[16] == 0xee); // row padding is untouched
    uint8_t rune_pixels[DM_BOTW_RUNE_ICON_SIDE * DM_BOTW_RUNE_ICON_SIDE * 4]; memset(rune_pixels, 7, sizeof rune_pixels);
    dm_botw_rune_icon_publish(animated_token, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    dm_botw_rune_icon_state rune_state; assert(dm_botw_rune_icon_snapshot(&rune_state));
    assert(rune_state.valid && rune_state.width == 64 && rune_state.height == 64 && rune_state.rgba[0] == 7);
    uint8_t rune_icon2[0x100] = {0}; pane_name(rune_icon2, "P_Icon_00");
    set_pane_parent(rune_icon2, rune_picload); pane_size(rune_icon2, 100, 80); matrix_translation(rune_icon2, 100, 200);
    rune_icon2[BOTW_TOUCH_FLAGS] = 1; rune_icon2[BOTW_TOUCH_FLAGS+1] = 255;
    calculate_entry(rune_icon2); calculated_matrix(rune_icon2);
    uint64_t rune_token2;
    assert(dm_botw_rune_icon_capture_token(&rune_token2) && rune_token2 != rune_token);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    dm_botw_rune_icon_publish(rune_token, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    dm_botw_rune_icon_publish(rune_token2, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && rune_state.valid);
    uint8_t unrelated_hidden_root[0x100] = {0}; pane_name(unrelated_hidden_root, "RootPane");
    calculate_entry(unrelated_hidden_root); // unrelated hidden layout root must not clear the live icon
    uint64_t still_valid_token;
    assert(dm_botw_rune_icon_capture_token(&still_valid_token) && still_valid_token == rune_token2);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && rune_state.valid);
    dm_botw_rune_icon_draw_begin(rune_icon2); assert(dm_botw_rune_icon_drawing());
    dm_botw_rune_icon_draw_end(); assert(!dm_botw_rune_icon_drawing());
    dm_botw_rune_icon_draw_begin(guide_icon); assert(!dm_botw_rune_icon_drawing());
    // Mounted gameplay may fade only the rune while leaving equipment visible.
    rune_now[BOTW_TOUCH_FLAGS+1] = 0;
    calculate_entry(rune_now);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    dm_botw_rune_icon_draw_begin(rune_icon2); assert(!dm_botw_rune_icon_drawing());
    rune_now[BOTW_TOUCH_FLAGS+1] = 255;
    calculate_entry(rune_icon2); calculated_matrix(rune_icon2);
    assert(dm_botw_rune_icon_capture_token(&rune_token2));
    dm_botw_rune_icon_publish(rune_token2, rune_pixels, 64, 64, 256);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && rune_state.valid);
    uint8_t transparent_rune[sizeof rune_pixels] = {0};
    dm_botw_rune_icon_publish(rune_token2, transparent_rune, 64, 64, 256);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    dm_botw_rune_icon_publish(rune_token2, rune_pixels, 64, 64, 256);
    rune_now[BOTW_TOUCH_FLAGS] = 0;
    calculate_entry(rune_now); // clear before hidden ancestors can skip the child's matrix callback
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    assert(!dm_botw_rune_icon_capture_token(&still_valid_token));
    dm_botw_rune_icon_clear();
    dm_botw_rune_icon_publish(rune_token2, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid && rune_state.rgba[0] == 0);

    // Controller connect / non-3D mode publishes inactive and restores a fresh native matrix.
    dm_botw_touch_hud_publish(0, 0.25f, 0.75f);
    assert(actions_reset_count == 2);
    dm_botw_touch_hud_publish(0, 0.25f, 0.75f);
    assert(actions_reset_count == 2); // repeated inactive publications do not reset on every Npad poll
    dm_botw_touch_hud_publish(1, 0.5f, 0.5f);
    dm_botw_touch_hud_publish(0, 0.5f, 0.5f);
    assert(actions_reset_count == 3); // each active-to-inactive transition clears once
    matrix_translation(target2, -509, 210);
    calculate_entry(target2);
    assert(target2[BOTW_TOUCH_FLAGS] & BOTW_TOUCH_DIRTY);
    calculated_matrix(target2);
    expect_translation(target2, -509, 210);
    // A hidden cut still matches by identity, so it invalidates the hitbox;
    // restoring a previously translated pane also marks it dirty only as needed.
    cut[BOTW_TOUCH_FLAGS] = 0;
    pane_size(cut, 166, 166); matrix_translation(cut, 510, -240);
    calculate_entry(cut); calculated_matrix(cut);
    assert(!map_region_valid);
    expect_translation(cut, 510, -240);

    // Same-name N_Pos panes elsewhere (including MainScreen's hearts branch) do not match.
    uint8_t other_root[0x100] = {0}, other_all[0x100] = {0}, other[0x100] = {0};
    pane_name(other_root, "RootPane"); pane_name(other_all, "N_All_00"); pane_name(other, "N_Pos_00");
    set_pane_parent(other_all, other_root); set_pane_parent(other, other_all);
    other[BOTW_TOUCH_FLAGS] = 0;
    calculate_entry(other);
    assert(other[BOTW_TOUCH_FLAGS] == 0);

    // The shared pane hook still services widescreen backgrounds without an
    // installed touch HUD (ordinary Mac/controller mode).
    dm_botw_touchhud_test_clear();
    int calls = aspect_pane_calls;
    calculate_entry(other);
    assert(aspect_pane_calls == calls + 1);
    assert(!dm_botw_touch_hud_available() && !dm_botw_touch_hud_active());

    // Rune DrawSelf observation remains installed when widescreen is off.
    aspect_native = 0;
    dm_botw_touch_hud_install();
    assert(test_gates[OBS_BOTW_UI_DRAW] && test_gates[OBS_BOTW_UI_DRAW_END]);
    uint64_t draw_regs[31] = {0};
    test_gates[OBS_BOTW_UI_DRAW](draw_regs);
    assert(!dm_botw_rune_icon_drawing());
    test_gates[OBS_BOTW_UI_DRAW_END](draw_regs);

    puts("t_botw_touchhud: build gate, pane ancestry, transient transforms, map bounds, environment alignment, expanded-state fallback, and inactive restoration passed");
}
