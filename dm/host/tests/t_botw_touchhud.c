#define DM_TEST_HOOKS
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../botw_touch_actions.h"
#include "../hle_botw_touchhud.c"

module_t g_mod[MAX_MOD]; int g_nmod;
static void (*test_gates[OBS_MAX])(const uint64_t *);
static int map_region_valid;
static int map_region_events;
static int actions_reset_count;
static float map_region[4];
int gate_obs_present(int id) { return id == OBS_BOTW_TOUCH_PANE || id == OBS_BOTW_TOUCH_MATRIX; }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { assert(id > 0 && id < OBS_MAX); test_gates[id] = fn; }
void front_botw_touch_hud_mode_changed(void) {}
void front_botw_rune_icon_changed(void) {}
void dm_botw_touch_actions_reset(void) { actions_reset_count++; }
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
    // Anchor the shared cluster to the visible viewport's top edge. N_Cut_01
    // is 328 px tall around the 166 px circle, so its upper padding does not
    // push the visible circle away from the 20 px canvas inset.
    scaled_matrix(cut, 1, 510, -240); calculate_entry(cut); calculated_matrix(cut);
    assert(map_region_valid && fabsf(map_region[2] - 166.0f / 1280.0f) < .001f);
    assert(fabsf(map_region[1] - 20.0f / 720.0f) < .001f);
    expect_translation(cut, 443, 257);
    scaled_matrix(cut_sibling, 1, 510, -240); calculate_entry(cut_sibling); calculated_matrix(cut_sibling);
    expect_translation(cut_sibling, 443, 257);
    matrix_translation(status, 392, -182); calculate_entry(status); calculated_matrix(status);
    expect_translation(status, 325, 315);
    assert(fabsf((315.0f - 257.0f) - 58.0f) < .001f); // gauges retain their native offset from the map
    assert(fabsf((325.0f + 582.0f * .5f) - 616.0f) < .001f);
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
    expect_translation(cut, 443, 257);

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
    pane_name(rune_root, "RootPane"); pane_name(rune_all, "N_All_00"); pane_name(rune_mainall, "N_MainAll_00");
    pane_name(rune_mainu, "N_MainU_00"); pane_name(rune_pamainu, "Pa_MainU_00"); pane_name(rune_pos, "N_Pos_00");
    pane_name(rune_innerall, "N_All_00"); pane_name(rune_now, "Pa_IconNow_00"); pane_name(rune_picload, "N_PicLoad_00");
    pane_name(rune_icon, "P_Icon_00");
    set_pane_parent(rune_all, rune_root); set_pane_parent(rune_mainall, rune_all); set_pane_parent(rune_pos, rune_mainall);
    set_pane_parent(rune_mainu, rune_pos); set_pane_parent(rune_pamainu, rune_mainu); set_pane_parent(rune_innerall, rune_pamainu);
    set_pane_parent(rune_now, rune_innerall); set_pane_parent(rune_picload, rune_now); set_pane_parent(rune_icon, rune_picload);
    rune_root[BOTW_TOUCH_FLAGS] = rune_all[BOTW_TOUCH_FLAGS] = rune_mainall[BOTW_TOUCH_FLAGS] = rune_pos[BOTW_TOUCH_FLAGS] = 1;
    rune_mainu[BOTW_TOUCH_FLAGS] = rune_pamainu[BOTW_TOUCH_FLAGS] = rune_innerall[BOTW_TOUCH_FLAGS] = rune_now[BOTW_TOUCH_FLAGS] = 1;
    rune_picload[BOTW_TOUCH_FLAGS] = rune_icon[BOTW_TOUCH_FLAGS] = 1;
    pane_size(rune_icon, 100, 80); matrix_translation(rune_icon, 100, 200);
    calculate_entry(rune_icon); calculated_matrix(rune_icon);
    float rune_rect[4]; uint64_t rune_token;
    assert(dm_botw_rune_icon_crop(rune_rect, &rune_token));
    assert(fabsf(rune_rect[0] - 690) < .001f && fabsf(rune_rect[1] - 120) < .001f);
    assert(fabsf(rune_rect[2] - 100) < .001f && fabsf(rune_rect[3] - 80) < .001f);
    matrix_translation(rune_icon, 101, 201); calculate_entry(rune_icon); calculated_matrix(rune_icon);
    float animated_rect[4]; uint64_t animated_token;
    assert(dm_botw_rune_icon_crop(animated_rect, &animated_token) && animated_token == rune_token);
    assert(fabsf(animated_rect[0] - rune_rect[0] - 1) < .001f && fabsf(animated_rect[1] - rune_rect[1] + 1) < .001f);
    uint8_t rune_pixels[DM_BOTW_RUNE_ICON_SIDE * DM_BOTW_RUNE_ICON_SIDE * 4]; memset(rune_pixels, 7, sizeof rune_pixels);
    dm_botw_rune_icon_publish(animated_token, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    dm_botw_rune_icon_state rune_state; assert(dm_botw_rune_icon_snapshot(&rune_state));
    assert(rune_state.valid && rune_state.width == 64 && rune_state.height == 64 && rune_state.rgba[0] == 7);
    uint8_t rune_icon2[0x100] = {0}; pane_name(rune_icon2, "P_Icon_00");
    set_pane_parent(rune_icon2, rune_picload); pane_size(rune_icon2, 100, 80); matrix_translation(rune_icon2, 100, 200);
    rune_icon2[BOTW_TOUCH_FLAGS] = 1;
    calculate_entry(rune_icon2); calculated_matrix(rune_icon2);
    float rune_rect2[4]; uint64_t rune_token2;
    assert(dm_botw_rune_icon_crop(rune_rect2, &rune_token2) && rune_token2 != rune_token);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    dm_botw_rune_icon_publish(rune_token, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    dm_botw_rune_icon_publish(rune_token2, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && rune_state.valid);
    uint8_t unrelated_hidden_root[0x100] = {0}; pane_name(unrelated_hidden_root, "RootPane");
    calculate_entry(unrelated_hidden_root); // unrelated hidden layout root must not clear the live icon
    float still_valid_rect[4]; uint64_t still_valid_token;
    assert(dm_botw_rune_icon_crop(still_valid_rect, &still_valid_token) && still_valid_token == rune_token2);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && rune_state.valid);
    rune_now[BOTW_TOUCH_FLAGS] = 0;
    calculate_entry(rune_now); // clear before hidden ancestors can skip the child's matrix callback
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid);
    assert(!dm_botw_rune_icon_crop(still_valid_rect, &still_valid_token));
    dm_botw_rune_icon_clear();
    dm_botw_rune_icon_publish(rune_token2, rune_pixels, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_SIDE, DM_BOTW_RUNE_ICON_STRIDE);
    assert(dm_botw_rune_icon_snapshot(&rune_state) && !rune_state.valid && rune_state.rgba[0] == 0);

    // Controller connect / non-3D mode publishes inactive and restores a fresh native matrix.
    dm_botw_touch_hud_publish(0, 0.25f, 0.75f);
    assert(actions_reset_count == 1);
    dm_botw_touch_hud_publish(0, 0.25f, 0.75f);
    assert(actions_reset_count == 1); // repeated inactive publications do not reset on every Npad poll
    dm_botw_touch_hud_publish(1, 0.5f, 0.5f);
    dm_botw_touch_hud_publish(0, 0.5f, 0.5f);
    assert(actions_reset_count == 2); // each active-to-inactive transition clears once
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

    puts("t_botw_touchhud: build gate, pane ancestry, transient transforms, map bounds, environment alignment, expanded-state fallback, and inactive restoration passed");
}
