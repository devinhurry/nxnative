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

    // Use the collapsed field-map's live centered scissor (440x288 after its
    // native 0.4 scale), then carry the same translation to its guide sibling
    // and the five environment panes in MainScreen.
    uint8_t map_root[0x100] = {0}, born[0x100] = {0}, inout[0x100] = {0};
    uint8_t pos[0x100] = {0}, mini[0x100] = {0}, scissor[0x100] = {0}, sensor[0x100] = {0};
    pane_name(map_root, "RootPane"); pane_name(born, "N_Born_00"); pane_name(inout, "N_InOut_00");
    pane_name(pos, "N_MiniMapPos_00"); pane_name(mini, "N_MiniMap_00");
    pane_name(scissor, "N_Scissor_00"); pane_name(sensor, "N_MiniMap_01");
    set_pane_parent(born, map_root); set_pane_parent(inout, born); set_pane_parent(pos, inout);
    set_pane_parent(mini, pos); set_pane_parent(scissor, mini); set_pane_parent(sensor, inout);
    map_root[BOTW_TOUCH_FLAGS] = born[BOTW_TOUCH_FLAGS] = inout[BOTW_TOUCH_FLAGS] = 1;
    pos[BOTW_TOUCH_FLAGS] = mini[BOTW_TOUCH_FLAGS] = scissor[BOTW_TOUCH_FLAGS] = sensor[BOTW_TOUCH_FLAGS] = 1;
    float collapsed = 0.4f, map_x = 410, map_y = -216;
    memcpy(mini + BOTW_TOUCH_SCALE, &collapsed, sizeof collapsed);
    memcpy(mini + BOTW_TOUCH_SCALE + 4, &collapsed, sizeof collapsed);
    memcpy(mini + BOTW_TOUCH_POSITION, &map_x, sizeof map_x);
    memcpy(mini + BOTW_TOUCH_POSITION + 4, &map_y, sizeof map_y);
    calculate_entry(mini);
    pane_size(scissor, 1100, 720); scaled_matrix(scissor, 0.4f, 414, -216);
    calculate_entry(scissor); calculated_matrix(scissor);
    expect_translation(scissor, -307, 102);
    assert(map_region_valid);
    assert(fabsf(map_region[0] - 0.08828125f) < 0.001f && fabsf(map_region[1] - 0.1583333f) < 0.001f);
    assert(fabsf(map_region[2] - 0.34375f) < 0.001f && fabsf(map_region[3] - 0.4f) < 0.001f);
    int map_events_before_tap = map_region_events;
    dm_botw_touch_hud_map_tapped();
    assert(!map_region_valid && map_region_events == map_events_before_tap + 1);
    // No scissor calculation arrives while Slate is expanded. The first
    // fresh collapsed calculation must republish unchanged bounds.
    float expanded = 1, zero = 0;
    memcpy(mini + BOTW_TOUCH_SCALE, &expanded, sizeof expanded);
    memcpy(mini + BOTW_TOUCH_SCALE + 4, &expanded, sizeof expanded);
    memcpy(mini + BOTW_TOUCH_POSITION, &zero, sizeof zero);
    memcpy(mini + BOTW_TOUCH_POSITION + 4, &zero, sizeof zero);
    calculate_entry(mini);
    assert(!map_region_valid);
    memcpy(mini + BOTW_TOUCH_SCALE, &collapsed, sizeof collapsed);
    memcpy(mini + BOTW_TOUCH_SCALE + 4, &collapsed, sizeof collapsed);
    memcpy(mini + BOTW_TOUCH_POSITION, &map_x, sizeof map_x);
    memcpy(mini + BOTW_TOUCH_POSITION + 4, &map_y, sizeof map_y);
    calculate_entry(mini);
    calculate_entry(scissor); scaled_matrix(scissor, 0.4f, 414, -216); calculated_matrix(scissor);
    assert(map_region_valid && map_region_events == map_events_before_tap + 2);
    matrix_translation(sensor, 30, 40); calculate_entry(sensor); calculated_matrix(sensor);
    expect_translation(sensor, -691, 358);

    uint8_t env_all[0x100] = {0}, env_root[0x100] = {0}, weather[0x100] = {0}, status[0x100] = {0};
    pane_name(env_all, "N_All_00"); pane_name(env_root, "RootPane");
    pane_name(weather, "Pa_Weather_00"); pane_name(status, "Pa_Sensor_00");
    set_pane_parent(env_all, env_root); set_pane_parent(weather, env_all); set_pane_parent(status, env_all);
    matrix_translation(weather, 392, -182); calculate_entry(weather); calculated_matrix(weather);
    expect_translation(weather, -329, 136);
    pane_size(status, 582, 78.2f); matrix_translation(status, 392, -182);
    calculate_entry(status); calculated_matrix(status);
    expect_translation(status, -329, 136);
    assert(fabsf((-329.0f - 582.0f * 0.5f) - (-620.0f)) < 0.001f);

    // Expanded/native Slate pose remains in place and releases map ownership.
    memcpy(mini + BOTW_TOUCH_SCALE, &expanded, sizeof expanded);
    memcpy(mini + BOTW_TOUCH_SCALE + 4, &expanded, sizeof expanded);
    memcpy(mini + BOTW_TOUCH_POSITION, &zero, sizeof zero);
    memcpy(mini + BOTW_TOUCH_POSITION + 4, &zero, sizeof zero);
    // Deliberately skip the parent entry callback: fresh scissor calculation
    // must reject an expanded map even if the prior collapsed flag was stale.
    matrix_translation(scissor, 100, 200); calculate_entry(scissor); calculated_matrix(scissor);
    assert(!map_region_valid);
    expect_translation(scissor, 100, 200);

    // Controller connect / non-3D mode publishes inactive and restores a fresh native matrix.
    dm_botw_touch_hud_publish(0, 0.25f, 0.75f);
    matrix_translation(target2, -509, 210);
    calculate_entry(target2);
    assert(target2[BOTW_TOUCH_FLAGS] & BOTW_TOUCH_DIRTY);
    calculated_matrix(target2);
    expect_translation(target2, -509, 210);

    // Same-name N_Pos panes elsewhere (including MainScreen's hearts branch) do not match.
    uint8_t other_root[0x100] = {0}, other_all[0x100] = {0}, other[0x100] = {0};
    pane_name(other_root, "RootPane"); pane_name(other_all, "N_All_00"); pane_name(other, "N_Pos_00");
    set_pane_parent(other_all, other_root); set_pane_parent(other, other_all);
    other[BOTW_TOUCH_FLAGS] = 0;
    calculate_entry(other);
    assert(other[BOTW_TOUCH_FLAGS] == 0);

    puts("t_botw_touchhud: build gate, pane ancestry, transient transforms, map bounds, environment alignment, expanded-state fallback, and inactive restoration passed");
}
