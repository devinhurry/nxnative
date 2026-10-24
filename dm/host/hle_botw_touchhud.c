// BOTW 1.9.0: relocate native touch HUD panes in the iOS virtual 3D layout.
// Build-checked Pane::Calculate probes preserve native pane state and apply
// translations only to freshly composed global matrices.
#include "hle.h"
#include "front.h"
#include <math.h>
#include <stdatomic.h>
#include <TargetConditionals.h>

enum { BOTW_TOUCH_PANE_NAME = 0xb8, BOTW_TOUCH_PARENT = 0x18, BOTW_TOUCH_FLAGS = 0x58,
       BOTW_TOUCH_POSITION = 0x30, BOTW_TOUCH_SCALE = 0x48, BOTW_TOUCH_SIZE = 0x50,
       BOTW_TOUCH_MATRIX = 0x70, BOTW_TOUCH_DIRTY = 0x10 };
// MainScreen's authored Pa_Sensor_00 extends 93 px left of the collapsed map
// scissor at its base pose. The canvas edge is 7 px inside that union; add a
// 20 px content inset so the full visible bundle stays within the canvas.
enum { BOTW_TOUCH_SENSOR_LEFT_MARGIN = 27 };
static const char BOTW_BUILD[] = "cd57b23fa4bbad65803d9788c01821ee";
static pthread_mutex_t g_touchhud_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int active, home_valid, delta_valid, map_rect_valid;
    float x, y, home_x, home_y, map_dx, map_dy, map_rect[4];
} g_touchhud;
static _Atomic int g_touchhud_active;
static _Atomic(uintptr_t) g_touchhud_pane;
static _Atomic int g_touchhud_available;
static _Atomic int g_touchhud_map_collapsed;
static module_t *g_touchhud_main;

int dm_botw_touch_hud_available(void) { return atomic_load_explicit(&g_touchhud_available, memory_order_acquire); }

void dm_botw_touch_hud_publish(int active, float center_x, float center_y) {
    if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
        if (!isfinite(center_x) || !isfinite(center_y)) active = 0;
        if (center_x < 0 || center_x > 1 || center_y < 0 || center_y > 1) active = 0;
        pthread_mutex_lock(&g_touchhud_mu);
        g_touchhud.active = !!active;
        g_touchhud.x = center_x;
        g_touchhud.y = center_y;
        atomic_store_explicit(&g_touchhud_active, g_touchhud.active, memory_order_release);
        if (!g_touchhud.active && g_touchhud.map_rect_valid) {
            g_touchhud.map_rect_valid = 0;
            front_botw_touch_hud_map_region(0, 0, 0, 0, 0);
        }
        pthread_mutex_unlock(&g_touchhud_mu);
    }
}

// A tap consumes the published rectangle immediately. The next native
// collapsed-map Calculate republishes its live bounds; if Slate suspends that
// subtree, no stale front-end hit region survives the transition.
void dm_botw_touch_hud_map_tapped(void) {
    if (strcmp(DM_GAME_ID, "01007EF00011E000")) return;
    pthread_mutex_lock(&g_touchhud_mu);
    g_touchhud.map_rect_valid = 0;
    pthread_mutex_unlock(&g_touchhud_mu);
    front_botw_touch_hud_map_region(0, 0, 0, 0, 0);
}

static int pane_named(const uint8_t *pane, const char *name) {
    return pane && !strncmp((const char *)pane + BOTW_TOUCH_PANE_NAME, name, 16);
}

// A name alone is not sufficient: MainScreen also has an N_Pos_00 for hearts.
// Verify the asset's unique three-pane ancestry before retaining this pointer.
static int main_shortcut_equipment(uint8_t *pane) {
    if (!pane_named(pane, "N_MainAll_00")) return 0;
    uint8_t *all = *(uint8_t **)(pane + BOTW_TOUCH_PARENT);
    uint8_t *root = all ? *(uint8_t **)(all + BOTW_TOUCH_PARENT) : NULL;
    return pane_named(all, "N_All_00") && pane_named(root, "RootPane");
}

static uint8_t *pane_parent(uint8_t *pane) { return pane ? *(uint8_t **)(pane + BOTW_TOUCH_PARENT) : NULL; }
static int pane_visible(uint8_t *pane) { return pane && (pane[BOTW_TOUCH_FLAGS] & 1); }
static int visible_to_root(uint8_t *pane) {
    for (uint8_t *p = pane; p; p = pane_parent(p)) {
        if (!pane_visible(p)) return 0;
        if (pane_named(p, "RootPane")) return 1;
    }
    return 0;
}
static int map_layout_root(uint8_t *pane) {
    return pane_named(pane, "RootPane");
}
static int map_mini_root(uint8_t *pane) {
    uint8_t *pos = pane_parent(pane), *inout = pane_parent(pos), *born = pane_parent(inout), *root = pane_parent(born);
    return pane_named(pane, "N_MiniMap_00") && pane_named(pos, "N_MiniMapPos_00") &&
           pane_named(inout, "N_InOut_00") && pane_named(born, "N_Born_00") && map_layout_root(root);
}
static int map_sensor_root(uint8_t *pane) {
    uint8_t *inout = pane_parent(pane), *born = pane_parent(inout), *root = pane_parent(born);
    return pane_named(pane, "N_MiniMap_01") && pane_named(inout, "N_InOut_00") &&
           pane_named(born, "N_Born_00") && map_layout_root(root);
}
static int map_scissor_root(uint8_t *pane) {
    uint8_t *map = pane_parent(pane);
    return pane_named(pane, "N_Scissor_00") && map_mini_root(map);
}
static int main_environment_pane(uint8_t *pane) {
    uint8_t *all = pane_parent(pane), *root = pane_parent(all);
    if (!pane_named(all, "N_All_00") || !pane_named(root, "RootPane")) return 0;
    const char *names[] = {"Pa_Sensor_00", "Pa_SoundGauge_00", "Pa_TempMeter_00", "Pa_Weather_00", "Pa_Time_00"};
    for (int i = 0; i < (int)(sizeof names / sizeof names[0]); i++) if (pane_named(pane, names[i])) return 1;
    return 0;
}

static void invalidate_map_rect(void) {
    int notify = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    if (g_touchhud.map_rect_valid) { g_touchhud.map_rect_valid = 0; notify = 1; }
    pthread_mutex_unlock(&g_touchhud_mu);
    if (notify) front_botw_touch_hud_map_region(0, 0, 0, 0, 0);
}

static int touchhud_delta_valid(void) {
    pthread_mutex_lock(&g_touchhud_mu); int valid = g_touchhud.delta_valid; pthread_mutex_unlock(&g_touchhud_mu);
    return valid;
}

static int transform_bounds(uint8_t *pane, float *left, float *bottom, float *right, float *top) {
    float w, h, m[12];
    memcpy(&w, pane + BOTW_TOUCH_SIZE, sizeof w); memcpy(&h, pane + BOTW_TOUCH_SIZE + 4, sizeof h);
    memcpy(m, pane + BOTW_TOUCH_MATRIX, sizeof m);
    if (!isfinite(w) || !isfinite(h) || w <= 0 || h <= 0) return 0;
    float xs[4] = {-w * .5f, w * .5f, -w * .5f, w * .5f};
    float ys[4] = {-h * .5f, -h * .5f, h * .5f, h * .5f};
    *left = *bottom = INFINITY; *right = *top = -INFINITY;
    for (int i = 0; i < 4; i++) {
        float x = m[0] * xs[i] + m[1] * ys[i] + m[3];
        float y = m[4] * xs[i] + m[5] * ys[i] + m[7];
        if (!isfinite(x) || !isfinite(y)) return 0;
        if (x < *left) *left = x; if (x > *right) *right = x;
        if (y < *bottom) *bottom = y; if (y > *top) *top = y;
    }
    return *right > *left && *top > *bottom;
}

static void publish_map_rect(uint8_t *pane) {
    float left, bottom, right, top;
    if (!atomic_load_explicit(&g_touchhud_active, memory_order_acquire) ||
        !atomic_load_explicit(&g_touchhud_map_collapsed, memory_order_acquire) ||
        !visible_to_root(pane) || !transform_bounds(pane, &left, &bottom, &right, &top)) {
        invalidate_map_rect();
        return;
    }
    float x0 = fmaxf(0, (left + 640.0f) / 1280.0f);
    float x1 = fminf(1, (right + 640.0f) / 1280.0f);
    float y0 = fmaxf(0, (360.0f - top) / 720.0f);
    float y1 = fminf(1, (360.0f - bottom) / 720.0f);
    if (x1 <= x0 || y1 <= y0) { invalidate_map_rect(); return; }
    int changed = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    float *r = g_touchhud.map_rect;
    if (!g_touchhud.map_rect_valid || fabsf(r[0] - x0) > .002f || fabsf(r[1] - y0) > .002f ||
        fabsf(r[2] - (x1 - x0)) > .002f || fabsf(r[3] - (y1 - y0)) > .002f) {
        r[0] = x0; r[1] = y0; r[2] = x1 - x0; r[3] = y1 - y0;
        g_touchhud.map_rect_valid = 1; changed = 1;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    if (changed) front_botw_touch_hud_map_region(1, x0, y0, x1 - x0, y1 - y0);
}

static int current_map_collapsed(uint8_t *pane) {
    if (!atomic_load_explicit(&g_touchhud_active, memory_order_acquire) || !map_mini_root(pane)) return 0;
    uint8_t *root = NULL;
    for (uint8_t *p = pane; p; p = pane_parent(p)) {
        if (!pane_visible(p)) return 0;
        if (pane_named(p, "RootPane")) { root = p; break; }
    }
    if (!root) return 0;
    float sx, sy, x, y;
    memcpy(&sx, pane + BOTW_TOUCH_SCALE, sizeof sx); memcpy(&sy, pane + BOTW_TOUCH_SCALE + 4, sizeof sy);
    memcpy(&x, pane + BOTW_TOUCH_POSITION, sizeof x); memcpy(&y, pane + BOTW_TOUCH_POSITION + 4, sizeof y);
    return isfinite(sx) && isfinite(sy) && isfinite(x) && isfinite(y) &&
           fabsf(sx - 0.4f) < 0.025f && fabsf(sy - 0.4f) < 0.025f &&
           fabsf(x - 410.0f) < 1.0f && fabsf(y + 216.0f) < 1.0f;
}

static void botw_touchhud_pane(const uint64_t *regs) {
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[0];
    if (!pane) return;
    if (map_mini_root(pane)) {
        int collapsed = current_map_collapsed(pane);
        atomic_store_explicit(&g_touchhud_map_collapsed, collapsed, memory_order_release);
        if (!collapsed) invalidate_map_rect();
        pthread_mutex_lock(&g_touchhud_mu); int delta_valid = g_touchhud.delta_valid; pthread_mutex_unlock(&g_touchhud_mu);
        if (atomic_load_explicit(&g_touchhud_active, memory_order_acquire) || delta_valid)
            pane[BOTW_TOUCH_FLAGS] |= BOTW_TOUCH_DIRTY;
        return;
    }
    if (map_sensor_root(pane) || map_scissor_root(pane) || main_environment_pane(pane)) {
        int delta_valid = touchhud_delta_valid();
        if (atomic_load_explicit(&g_touchhud_active, memory_order_acquire) || atomic_load_explicit(&g_touchhud_map_collapsed, memory_order_acquire) || delta_valid)
            pane[BOTW_TOUCH_FLAGS] |= BOTW_TOUCH_DIRTY;
        return;
    }
    uintptr_t target = atomic_load_explicit(&g_touchhud_pane, memory_order_acquire);
    int match = 0;
    if ((uintptr_t)pane == target && target) {
        match = main_shortcut_equipment(pane);
        if (match) {
            // Only mark the global matrix dirty. Bit 0 carries native visibility
            // semantics and is deliberately left untouched. Hidden panes keep the
            // pending dirty state until their next visible calculation.
            pane[BOTW_TOUCH_FLAGS] |= BOTW_TOUCH_DIRTY;
            return;
        }
        atomic_compare_exchange_strong_explicit(&g_touchhud_pane, &target, 0, memory_order_acq_rel, memory_order_acquire);
    }
    if (!atomic_load_explicit(&g_touchhud_active, memory_order_acquire)) return;
    if (!match) match = main_shortcut_equipment(pane);
    if (!match) return;
    target = atomic_exchange_explicit(&g_touchhud_pane, (uintptr_t)pane, memory_order_acq_rel);
    pane[BOTW_TOUCH_FLAGS] |= BOTW_TOUCH_DIRTY;
    if (target != (uintptr_t)pane) LOG("BOTW touch HUD: MainShortCut N_MainAll_00 pane matched at %p", (void *)pane);
}

static void botw_touchhud_matrix(const uint64_t *regs) {
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[19];
    if (!pane) return;
    int active = atomic_load_explicit(&g_touchhud_active, memory_order_acquire);
    int collapsed = atomic_load_explicit(&g_touchhud_map_collapsed, memory_order_acquire);
    if ((uintptr_t)pane == atomic_load_explicit(&g_touchhud_pane, memory_order_acquire)) {
        float tx, ty, x, y;
        memcpy(&tx, pane + BOTW_TOUCH_MATRIX + 0x0c, sizeof tx);
        memcpy(&ty, pane + BOTW_TOUCH_MATRIX + 0x1c, sizeof ty);
        pthread_mutex_lock(&g_touchhud_mu);
        g_touchhud.home_x = tx; g_touchhud.home_y = ty; g_touchhud.home_valid = 1;
        x = g_touchhud.x; y = g_touchhud.y;
        pthread_mutex_unlock(&g_touchhud_mu);
        if (active) {
            // Preserve the animated N_Pos_00 parent delta by translating the
            // freshly composed equipment matrix to the iOS virtual D-pad.
            float dx = x * 1280.0f - 640.0f + 554.0f;
            float dy = 360.0f - y * 720.0f - 246.0f;
            tx += dx; ty += dy;
            memcpy(pane + BOTW_TOUCH_MATRIX + 0x0c, &tx, sizeof tx);
            memcpy(pane + BOTW_TOUCH_MATRIX + 0x1c, &ty, sizeof ty);
        }
        return;
    }
    if (!map_scissor_root(pane)) {
        if (!map_sensor_root(pane) && !main_environment_pane(pane)) return;
        pthread_mutex_lock(&g_touchhud_mu);
        int apply = active && collapsed && g_touchhud.delta_valid;
        float dx = g_touchhud.map_dx, dy = g_touchhud.map_dy;
        pthread_mutex_unlock(&g_touchhud_mu);
        if (apply) {
            float tx, ty;
            memcpy(&tx, pane + BOTW_TOUCH_MATRIX + 0x0c, sizeof tx);
            memcpy(&ty, pane + BOTW_TOUCH_MATRIX + 0x1c, sizeof ty);
            tx += dx; ty += dy;
            memcpy(pane + BOTW_TOUCH_MATRIX + 0x0c, &tx, sizeof tx);
            memcpy(pane + BOTW_TOUCH_MATRIX + 0x1c, &ty, sizeof ty);
        }
        return;
    }

    // Do not trust a cached mode across a suspended expanded Slate layout.
    // The scissor callback is a fresh, live Pane calculation, so validate its
    // current MiniMap pose and ancestor visibility before publishing a hitbox.
    collapsed = current_map_collapsed(pane_parent(pane));
    atomic_store_explicit(&g_touchhud_map_collapsed, collapsed, memory_order_release);

    if (!active || !collapsed || !pane_visible(pane)) { invalidate_map_rect(); return; }
    float left, bottom, right, top;
    pthread_mutex_lock(&g_touchhud_mu);
    int home_valid = g_touchhud.home_valid;
    float home_x = g_touchhud.home_x, home_y = g_touchhud.home_y;
    pthread_mutex_unlock(&g_touchhud_mu);
    if (!home_valid || !transform_bounds(pane, &left, &bottom, &right, &top)) { invalidate_map_rect(); return; }

    // N_MainAll_00's original position plus its authored cross-guide offset
    // identifies the old loadout corner. Pa_Sensor_00 extends 93 px left of
    // the map clip, so place the combined cluster's left/top bounds there.
    // The shared live translation keeps the authored sizes and animation.
    float target_left = home_x - 45.0f + BOTW_TOUCH_SENSOR_LEFT_MARGIN;
    float target_top = home_y + 36.0f;
    float dx = target_left - left, dy = target_top - top;
    pthread_mutex_lock(&g_touchhud_mu);
    g_touchhud.map_dx = dx; g_touchhud.map_dy = dy; g_touchhud.delta_valid = 1;
    pthread_mutex_unlock(&g_touchhud_mu);
    float tx, ty;
    memcpy(&tx, pane + BOTW_TOUCH_MATRIX + 0x0c, sizeof tx);
    memcpy(&ty, pane + BOTW_TOUCH_MATRIX + 0x1c, sizeof ty);
    tx += dx; ty += dy;
    memcpy(pane + BOTW_TOUCH_MATRIX + 0x0c, &tx, sizeof tx);
    memcpy(pane + BOTW_TOUCH_MATRIX + 0x1c, &ty, sizeof ty);
    publish_map_rect(pane);
}

void dm_botw_touch_hud_install(void) {
#if !TARGET_OS_IPHONE && !defined(DM_TEST_HOOKS)
    return; // this virtual-control relocation is an iOS-only feature
#else
    if (strcmp(DM_GAME_ID, "01007EF00011E000")) return;
    if (strcmp(dm_main_build(), BOTW_BUILD)) {
        LOG("BOTW touch HUD: disabled for main build %s (requires %s)", dm_main_build(), BOTW_BUILD);
        return;
    }
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_touchhud_main = &g_mod[i];
    if (!g_touchhud_main || !gate_obs_present(OBS_BOTW_TOUCH_PANE) || !gate_obs_present(OBS_BOTW_TOUCH_MATRIX))
        die("[RED] BOTW touch HUD: pane calculation gates missing; rewrite main with the current patches.py");
    gate_obs_set(OBS_BOTW_TOUCH_PANE, botw_touchhud_pane);
    gate_obs_set(OBS_BOTW_TOUCH_MATRIX, botw_touchhud_matrix);
    atomic_store_explicit(&g_touchhud_available, 1, memory_order_release);
    front_botw_touch_hud_mode_changed();
    LOG("BOTW touch HUD: MainShortCut pane probes installed for build %s", BOTW_BUILD);
#endif
}

#ifdef DM_TEST_HOOKS
void dm_botw_touchhud_test_pane(const uint64_t *regs) { botw_touchhud_pane(regs); }
void dm_botw_touchhud_test_matrix(const uint64_t *regs) { botw_touchhud_matrix(regs); }
void dm_botw_touchhud_test_clear(void) { atomic_store(&g_touchhud_pane, 0); memset(&g_touchhud, 0, sizeof g_touchhud); atomic_store(&g_touchhud_active, 0); atomic_store(&g_touchhud_available, 0); }
#endif
