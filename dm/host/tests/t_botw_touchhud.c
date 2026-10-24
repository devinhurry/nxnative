#define DM_TEST_HOOKS
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../hle_botw_touchhud.c"

module_t g_mod[MAX_MOD]; int g_nmod;
static void (*test_gates[OBS_MAX])(const uint64_t *);
static int map_region_valid;
static int map_region_events;
static float map_region[4];
int gate_obs_present(int id) { return id == OBS_BOTW_TOUCH_PANE || id == OBS_BOTW_TOUCH_MATRIX; }
void gate_obs_set(int id, void (*fn)(const uint64_t *)) { assert(id > 0 && id < OBS_MAX); test_gates[id] = fn; }
void front_botw_touch_hud_mode_changed(void) {}
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

    // Controller connect / non-3D mode publishes inactive and restores a fresh native matrix.
    dm_botw_touch_hud_publish(0, 0.25f, 0.75f);
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
