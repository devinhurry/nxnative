// BOTW 1.9.0: relocate native touch HUD panes in the iOS virtual 3D layout.
// Build-checked Pane::Calculate probes preserve native pane state and apply
// translations only to freshly composed global matrices.
#include "hle.h"
#include "front.h"
#include "botw_rune_icon.h"
#include "botw_touch_actions.h"
#include "botw_touch_menu.h"
#include "touchpad_geometry.h"
#include <math.h>
#include <stdatomic.h>
#include <TargetConditionals.h>

enum { BOTW_TOUCH_PANE_NAME = 0xb8, BOTW_TOUCH_PARENT = 0x18, BOTW_TOUCH_FLAGS = 0x58,
       BOTW_TOUCH_POSITION = 0x30, BOTW_TOUCH_SCALE = 0x48, BOTW_TOUCH_SIZE = 0x50,
       BOTW_TOUCH_MATRIX = 0x70, BOTW_TOUCH_DIRTY = 0x10 };
static const char BOTW_BUILD[] = "cd57b23fa4bbad65803d9788c01821ee";
static pthread_mutex_t g_touchhud_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int active, home_valid, delta_valid, map_rect_valid;
    float x, y, home_x, home_y, map_dx, map_dy, map_rect[4];
    int cut_bounds_valid, sibling_bounds_valid, sensor_bounds_valid;
    float cut_right, cut_top;
    int rune_crop_valid;
    float rune_crop[4];
    int rune_guide_known, rune_exclusion_valid;
    float rune_exclusion[4];
    uint64_t rune_token;
    uintptr_t rune_pane;
    uintptr_t rune_chain[10];
    uintptr_t rune_exclusion_root;
    uintptr_t rune_guide_chain[7];
} g_touchhud;
static dm_botw_rune_icon_state g_rune_icon;
static _Atomic int g_touchhud_active;
static _Atomic(uintptr_t) g_touchhud_pane;
static _Atomic int g_touchhud_available;
static _Atomic int g_touchhud_map_collapsed;
static _Atomic(uintptr_t) g_touchhud_map_root;
static module_t *g_touchhud_main;
static uint8_t *pane_parent(uint8_t *pane);
static int visible_to_root(uint8_t *pane);
static int transform_bounds(uint8_t *pane, float *left, float *bottom, float *right, float *top);

int dm_botw_touch_hud_available(void) { return atomic_load_explicit(&g_touchhud_available, memory_order_acquire); }

int dm_botw_touch_hud_active(void) {
    if (strcmp(DM_GAME_ID, "01007EF00011E000") || !dm_botw_touch_hud_available() ||
        strcmp(dm_main_build(), BOTW_BUILD)) return 0;
    return atomic_load_explicit(&g_touchhud_active, memory_order_acquire);
}

void dm_botw_touch_hud_publish(int active, float center_x, float center_y) {
    if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
        if (!isfinite(center_x) || !isfinite(center_y)) active = 0;
        if (center_x < 0 || center_x > 1 || center_y < 0 || center_y > 1) active = 0;
        int became_inactive;
        pthread_mutex_lock(&g_touchhud_mu);
        became_inactive = g_touchhud.active && !active;
        g_touchhud.active = !!active;
        g_touchhud.x = center_x;
        g_touchhud.y = center_y;
        atomic_store_explicit(&g_touchhud_active, g_touchhud.active, memory_order_release);
        if (!g_touchhud.active && g_touchhud.map_rect_valid) {
            g_touchhud.map_rect_valid = 0;
            front_botw_touch_hud_map_region(0, 0, 0, 0, 0);
        }
        pthread_mutex_unlock(&g_touchhud_mu);
        if (became_inactive) {
            dm_botw_touch_actions_reset();
            dm_botw_touch_menu_reset();
        }
        if (!active) dm_botw_rune_icon_clear();
    }
}

int dm_botw_rune_icon_snapshot(dm_botw_rune_icon_state *out) {
    if (!out) return 0;
    pthread_mutex_lock(&g_touchhud_mu);
    *out = g_rune_icon;
    pthread_mutex_unlock(&g_touchhud_mu);
    return 1;
}

int dm_botw_rune_icon_crop(float rect[4], float exclusion[4], uint64_t *token) {
    if (!rect || !exclusion || !token) return 0;
    pthread_mutex_lock(&g_touchhud_mu);
    int valid = g_touchhud.active && g_touchhud.rune_crop_valid && g_touchhud.rune_guide_known &&
                g_touchhud.rune_chain[9] && g_touchhud.rune_exclusion_root == g_touchhud.rune_chain[9];
    if (valid) {
        memcpy(rect, g_touchhud.rune_crop, sizeof g_touchhud.rune_crop);
        if (g_touchhud.rune_exclusion_valid) memcpy(exclusion, g_touchhud.rune_exclusion, sizeof g_touchhud.rune_exclusion);
        else memset(exclusion, 0, sizeof g_touchhud.rune_exclusion);
        *token = g_touchhud.rune_token;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    return valid;
}

void dm_botw_rune_icon_clear(void) {
    int changed = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    if (g_touchhud.rune_crop_valid || g_touchhud.rune_guide_known || g_touchhud.rune_exclusion_valid ||
        g_rune_icon.valid || g_touchhud.rune_pane) {
        g_touchhud.rune_crop_valid = 0;
        g_touchhud.rune_guide_known = g_touchhud.rune_exclusion_valid = 0;
        g_touchhud.rune_exclusion_root = 0;
        g_touchhud.rune_token++;
        g_touchhud.rune_pane = 0;
        memset(g_touchhud.rune_chain, 0, sizeof g_touchhud.rune_chain);
        memset(g_touchhud.rune_guide_chain, 0, sizeof g_touchhud.rune_guide_chain);
        if (g_rune_icon.valid) g_rune_icon.generation++;
        g_rune_icon.valid = 0;
        g_rune_icon.width = g_rune_icon.height = g_rune_icon.stride = 0;
        memset(g_rune_icon.rgba, 0, sizeof g_rune_icon.rgba);
        changed = 1;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    if (changed) front_botw_rune_icon_changed();
}

static int rune_icon_clear_pixels_locked(void) {
    if (!g_rune_icon.valid) return 0;
    g_rune_icon.generation++;
    g_rune_icon.valid = 0;
    g_rune_icon.width = g_rune_icon.height = g_rune_icon.stride = 0;
    memset(g_rune_icon.rgba, 0, sizeof g_rune_icon.rgba);
    return 1;
}

void dm_botw_rune_icon_publish(uint64_t token, const uint8_t *rgba,
                               uint32_t width, uint32_t height, uint32_t stride) {
    if (!rgba || width != DM_BOTW_RUNE_ICON_SIDE || height != DM_BOTW_RUNE_ICON_SIDE ||
        stride != DM_BOTW_RUNE_ICON_STRIDE) return;
    int changed = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    if (g_touchhud.active && g_touchhud.rune_crop_valid && token == g_touchhud.rune_token) {
        if (!g_rune_icon.valid || memcmp(g_rune_icon.rgba, rgba, sizeof g_rune_icon.rgba)) {
            memcpy(g_rune_icon.rgba, rgba, sizeof g_rune_icon.rgba);
            g_rune_icon.valid = 1;
            g_rune_icon.width = width;
            g_rune_icon.height = height;
            g_rune_icon.stride = stride;
            g_rune_icon.generation++;
            changed = 1;
        }
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    if (changed) front_botw_rune_icon_changed();
}

void dm_botw_rune_icon_premultiply_rgba(uint8_t *rgba, uint32_t width,
                                         uint32_t height, uint32_t stride) {
    if (!rgba || (uint64_t)stride < (uint64_t)width * 4u) return;
    for (uint32_t y = 0; y < height; y++) {
        uint8_t *row = rgba + (size_t)y * stride;
        for (uint32_t x = 0; x < width; x++) {
            uint8_t *p = row + (size_t)x * 4;
            unsigned alpha = p[3];
            p[0] = (uint8_t)((p[0] * alpha + 127u) / 255u);
            p[1] = (uint8_t)((p[1] * alpha + 127u) / 255u);
            p[2] = (uint8_t)((p[2] * alpha + 127u) / 255u);
        }
    }
}

void dm_botw_rune_icon_mask_guide(uint8_t *rgba, uint32_t width, uint32_t height,
                                  uint32_t stride, const float crop[4],
                                  const float exclusion[4], uint32_t image_x,
                                  uint32_t image_y, uint32_t image_width,
                                  uint32_t image_height) {
    if (!rgba || !crop || !exclusion || !image_width || !image_height ||
        (uint64_t)stride < (uint64_t)width * 4u || image_x > width || image_y > height ||
        image_width > width - image_x || image_height > height - image_y) return;
    for (uint32_t y = 0; y < image_height; y++) {
        double canvas_y = crop[1] + ((double)y + .5) * crop[3] / image_height;
        if (canvas_y < exclusion[1] || canvas_y >= exclusion[1] + exclusion[3]) continue;
        uint8_t *row = rgba + (size_t)(image_y + y) * stride + (size_t)image_x * 4;
        for (uint32_t x = 0; x < image_width; x++) {
            double canvas_x = crop[0] + ((double)x + .5) * crop[2] / image_width;
            if (canvas_x >= exclusion[0] && canvas_x < exclusion[0] + exclusion[2])
                memset(row + (size_t)x * 4, 0, 4);
        }
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
// The live gameplay AppMap does not use the authored MiniMapPos/Scissor
// ancestry. Its collapsed viewport is the 166x166 N_Cut_00 beneath the
// visible AppMap root; the capture texture inside it is 192x192. Slate expands
// this same cut to 1500x720. Match the live viewport and tree, not marker names.
static int map_cut_root(uint8_t *pane) {
    uint8_t *inout = pane_parent(pane), *root = pane_parent(inout);
    return pane_named(pane, "N_Cut_00") && pane_named(inout, "N_InOut_00") &&
           map_layout_root(root);
}
static int map_cut_visible(uint8_t *pane) { return visible_to_root(pane); }
static int map_hit_visible(uint8_t *pane) {
    for (uint8_t *p = pane; p; p = pane_parent(p)) {
        if (!pane_visible(p) || !p[BOTW_TOUCH_FLAGS + 1]) return 0;
        if (pane_named(p, "RootPane")) return 1;
    }
    return 0;
}
static int map_inout_root(uint8_t *pane) {
    uint8_t *root = pane_parent(pane);
    return pane_named(pane, "N_InOut_00") && map_layout_root(root) &&
           (uintptr_t)root == atomic_load(&g_touchhud_map_root);
}
static int map_cut_sibling(uint8_t *pane) {
    uint8_t *inout = pane_parent(pane), *root = pane_parent(inout);
    return pane_named(pane, "N_Cut_01") && pane_named(inout, "N_InOut_00") &&
           map_layout_root(root) && (uintptr_t)root == atomic_load(&g_touchhud_map_root);
}
static int map_ornament_root(uint8_t *pane) {
    uint8_t *root = pane_parent(pane);
    return pane_named(pane, "N_InOut_01") && map_layout_root(root) &&
           (uintptr_t)root == atomic_load(&g_touchhud_map_root);
}
static int main_environment_pane(uint8_t *pane) {
    uint8_t *all = pane_parent(pane), *root = pane_parent(all);
    if (!pane_named(all, "N_All_00") || !pane_named(root, "RootPane")) return 0;
    const char *names[] = {"Pa_Sensor_00", "Pa_SoundGauge_00", "Pa_TempMeter_00", "Pa_Weather_00", "Pa_Time_00"};
    for (int i = 0; i < (int)(sizeof names / sizeof names[0]); i++) if (pane_named(pane, names[i])) return 1;
    return 0;
}

static const char *const g_rune_chain_names[10] = {
    "P_Icon_00", "N_PicLoad_00", "Pa_IconNow_00", "N_All_00", "Pa_MainU_00",
    "N_MainU_00", "N_Pos_00", "N_MainAll_00", "N_All_00", "RootPane"
};
static const char *const g_rune_guide_chain_names[7] = {
    "P_GuideIcon_00", "Pa_IconCross_00", "N_MainGuide_00", "N_Pos_00",
    "N_MainAll_00", "N_All_00", "RootPane"
};
static int rune_guide_chain_collect(uint8_t *pane, uintptr_t chain[7], int require_visible) {
    uint8_t *p = pane;
    for (size_t i = 0; i < 7; i++) {
        if (!pane_named(p, g_rune_guide_chain_names[i]) || (require_visible && !pane_visible(p))) return 0;
        chain[i] = (uintptr_t)p;
        if (i + 1 < 7) p = pane_parent(p);
    }
    return 1;
}
static int rune_chain_collect(uint8_t *pane, uintptr_t chain[10], int require_visible) {
    uint8_t *p = pane;
    for (size_t i = 0; i < 10; i++) {
        if (!pane_named(p, g_rune_chain_names[i]) || (require_visible && !pane_visible(p))) return 0;
        chain[i] = (uintptr_t)p;
        if (i + 1 < 10) p = pane_parent(p);
    }
    return 1;
}
static int main_shortcut_rune_pane(uint8_t *pane) {
    uintptr_t chain[10]; return rune_chain_collect(pane, chain, 0);
}
static int main_shortcut_rune_guide_pane(uint8_t *pane) {
    uintptr_t chain[7]; return rune_guide_chain_collect(pane, chain, 0);
}
static int rune_chain_entry_hidden(uint8_t *pane) {
    int member = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    for (size_t i = 0; i < 10; i++) if (g_touchhud.rune_chain[i] && g_touchhud.rune_chain[i] == (uintptr_t)pane) {
        member = 1; break;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    return member && !pane_visible(pane);
}
static int rune_guide_chain_entry_hidden(uint8_t *pane) {
    int member = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    for (size_t i = 0; i < 7; i++) if (g_touchhud.rune_guide_chain[i] && g_touchhud.rune_guide_chain[i] == (uintptr_t)pane) {
        member = 1; break;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    return member && !pane_visible(pane);
}
static void rune_guide_record(uint8_t *pane) {
    uintptr_t chain[7] = {0};
    int chain_valid = atomic_load_explicit(&g_touchhud_active, memory_order_acquire) &&
                      rune_guide_chain_collect(pane, chain, 0);
    int visible = chain_valid;
    int hidden = 0;
    for (size_t i = 0; visible && i < 7; i++) {
        if (!pane_visible((uint8_t *)chain[i])) { visible = 0; hidden = 1; }
    }
    float rect[4] = {0};
    if (visible) {
        float left, bottom, right, top;
        visible = transform_bounds(pane, &left, &bottom, &right, &top);
        if (visible) {
            rect[0] = left + 640.0f;
            rect[1] = 360.0f - top;
            rect[2] = right - left;
            rect[3] = top - bottom;
            visible = isfinite(rect[0]) && isfinite(rect[1]) && isfinite(rect[2]) && isfinite(rect[3]) &&
                      rect[2] > 0 && rect[3] > 0;
        }
    } else if (chain_valid && !hidden) {
        // A visible guide with unusable geometry cannot safely describe an
        // exclusion region, so wait for its next valid matrix calculation.
        chain_valid = 0;
    }
    pthread_mutex_lock(&g_touchhud_mu);
    if (visible) {
        int chain_changed = memcmp(g_touchhud.rune_guide_chain, chain, sizeof chain) != 0;
        int root_changed = g_touchhud.rune_exclusion_root != chain[6];
        int was_known = g_touchhud.rune_guide_known;
        int was_excluded = g_touchhud.rune_exclusion_valid;
        g_touchhud.rune_exclusion_root = chain[6];
        g_touchhud.rune_guide_known = 1;
        int intersects = g_touchhud.rune_crop_valid && g_touchhud.rune_chain[9] == chain[6] &&
                         rect[0] < g_touchhud.rune_crop[0] + g_touchhud.rune_crop[2] &&
                         rect[0] + rect[2] > g_touchhud.rune_crop[0] &&
                         rect[1] < g_touchhud.rune_crop[1] + g_touchhud.rune_crop[3] &&
                         rect[1] + rect[3] > g_touchhud.rune_crop[1];
        int changed = root_changed || !was_known || was_excluded != intersects;
        g_touchhud.rune_exclusion_valid = intersects;
        if (intersects) memcpy(g_touchhud.rune_exclusion, rect, sizeof rect);
        memcpy(g_touchhud.rune_guide_chain, chain, sizeof chain);
        if (changed || chain_changed) {
            g_touchhud.rune_token++;
        }
    } else {
        int was_known = g_touchhud.rune_guide_known;
        int was_excluded = g_touchhud.rune_exclusion_valid;
        uintptr_t root = chain_valid ? chain[6] : 0;
        memset(g_touchhud.rune_guide_chain, 0, sizeof g_touchhud.rune_guide_chain);
        if (hidden && root) {
            memcpy(g_touchhud.rune_guide_chain, chain, sizeof chain);
            g_touchhud.rune_exclusion_root = root;
            g_touchhud.rune_guide_known = 1;
        } else {
            g_touchhud.rune_guide_known = 0;
            g_touchhud.rune_exclusion_root = 0;
        }
        g_touchhud.rune_exclusion_valid = 0;
        if (was_excluded || (was_known && !g_touchhud.rune_guide_known)) {
            g_touchhud.rune_token++;
        }
    }
    pthread_mutex_unlock(&g_touchhud_mu);
}
static void rune_guide_hide_entry(uint8_t *pane) {
    int member = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    for (size_t i = 0; i < 7; i++) if (g_touchhud.rune_guide_chain[i] == (uintptr_t)pane) {
        member = 1; break;
    }
    if (member && g_touchhud.rune_exclusion_valid) {
        g_touchhud.rune_exclusion_valid = 0;
        g_touchhud.rune_token++;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
}
static void rune_icon_record(uint8_t *pane) {
    uintptr_t chain[10];
    if (!atomic_load_explicit(&g_touchhud_active, memory_order_acquire) ||
        !rune_chain_collect(pane, chain, 1)) {
        dm_botw_rune_icon_clear();
        return;
    }
    float left, bottom, right, top;
    if (!transform_bounds(pane, &left, &bottom, &right, &top)) {
        dm_botw_rune_icon_clear();
        return;
    }
    float rect[4] = {left + 640.0f, 360.0f - top, right - left, top - bottom};
    int identity_changed = 0, bounds_changed = 0, notify = 0;
    pthread_mutex_lock(&g_touchhud_mu);
    identity_changed = g_touchhud.rune_pane != (uintptr_t)pane || !g_touchhud.rune_crop_valid;
    bounds_changed = !g_touchhud.rune_crop_valid ||
        fabsf(g_touchhud.rune_crop[0] - rect[0]) > .25f || fabsf(g_touchhud.rune_crop[1] - rect[1]) > .25f ||
        fabsf(g_touchhud.rune_crop[2] - rect[2]) > .25f || fabsf(g_touchhud.rune_crop[3] - rect[3]) > .25f;
    if (bounds_changed) {
        memcpy(g_touchhud.rune_crop, rect, sizeof rect);
        g_touchhud.rune_crop_valid = 1;
    }
    if (identity_changed) {
        // Tokens guard native pane lifetime/visibility, not its animated
        // matrix. The crop is refreshed every Calculate; bumping the token on
        // each small animation step would reject every asynchronous GPU copy.
        g_touchhud.rune_token++;
        g_touchhud.rune_pane = (uintptr_t)pane;
        memcpy(g_touchhud.rune_chain, chain, sizeof chain);
        if (g_touchhud.rune_exclusion_root != chain[9]) {
            g_touchhud.rune_guide_known = 0;
            g_touchhud.rune_exclusion_valid = 0;
            g_touchhud.rune_exclusion_root = 0;
            memset(g_touchhud.rune_guide_chain, 0, sizeof g_touchhud.rune_guide_chain);
        }
        notify = rune_icon_clear_pixels_locked();
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    if (identity_changed && notify) front_botw_rune_icon_changed();
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

// Keep the relocated viewport and the panes around it in one live cluster.
// N_Cut_00 bounds the visible minimap. Pa_Sensor_00 is 582 px wide, while its
// linked PaAppAllRadarGauge layout draws a centered 280 px capture/gauge; the
// pane's extra width is transparent padding and must not move this anchor.
static int touchhud_record_cluster_bounds(uint8_t *pane, int branch) {
    float left, bottom, right, top;
    if (!transform_bounds(pane, &left, &bottom, &right, &top)) return 0;
    pthread_mutex_lock(&g_touchhud_mu);
    if (branch == 0) { g_touchhud.cut_bounds_valid = 1; g_touchhud.cut_right = right; g_touchhud.cut_top = top; }
    if (branch == 1) g_touchhud.sibling_bounds_valid = 1;
    if (branch == 2) g_touchhud.sensor_bounds_valid = 1;
    int valid = g_touchhud.cut_bounds_valid && g_touchhud.sibling_bounds_valid && g_touchhud.sensor_bounds_valid;
    pthread_mutex_unlock(&g_touchhud_mu);
    return valid;
}
static int touchhud_update_cluster_delta(void) {
    pthread_mutex_lock(&g_touchhud_mu);
    int valid = g_touchhud.cut_bounds_valid && g_touchhud.sibling_bounds_valid && g_touchhud.sensor_bounds_valid;
    if (valid) {
        g_touchhud.map_dx = 640.0f - DM_TP_BOTW_MAP_RIGHT_INSET - g_touchhud.cut_right;
        g_touchhud.map_dy = DM_TP_BOTW_MAP_TOP - g_touchhud.cut_top;
        g_touchhud.delta_valid = 1;
    }
    pthread_mutex_unlock(&g_touchhud_mu);
    return valid;
}
static void touchhud_clear_cluster(void) {
    pthread_mutex_lock(&g_touchhud_mu);
    g_touchhud.cut_bounds_valid = g_touchhud.sibling_bounds_valid = g_touchhud.sensor_bounds_valid = 0;
    g_touchhud.delta_valid = 0;
    pthread_mutex_unlock(&g_touchhud_mu);
}

static void publish_map_rect(uint8_t *pane) {
    float left, bottom, right, top;
    if (!atomic_load_explicit(&g_touchhud_active, memory_order_acquire) ||
        !atomic_load_explicit(&g_touchhud_map_collapsed, memory_order_acquire) ||
        !map_hit_visible(pane) || !transform_bounds(pane, &left, &bottom, &right, &top)) {
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

static void botw_touchhud_pane(const uint64_t *regs) {
    dm_aspect_ui_pane((uint8_t *)(uintptr_t)regs[0]);
    if (!dm_botw_touch_hud_available()) return;
    dm_botw_touch_menu_pane(regs, 0);
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[0];
    if (!pane) return;
    // The child matrix hook may not run when a parent becomes hidden. Invalidate
    // the duplicate from the live pre-calculate callback while the chain is safe.
    if (atomic_load_explicit(&g_touchhud_active, memory_order_acquire) && rune_chain_entry_hidden(pane))
        dm_botw_rune_icon_clear();
    if (atomic_load_explicit(&g_touchhud_active, memory_order_acquire) && rune_guide_chain_entry_hidden(pane))
        rune_guide_hide_entry(pane);
    if (pane_named(pane, "RootPane") && (uintptr_t)pane == atomic_load(&g_touchhud_map_root) &&
        !pane_visible(pane)) {
        atomic_store_explicit(&g_touchhud_map_collapsed, 0, memory_order_release);
        touchhud_clear_cluster();
        invalidate_map_rect();
        return;
    }
    if (map_inout_root(pane) && !visible_to_root(pane)) {
        atomic_store_explicit(&g_touchhud_map_collapsed, 0, memory_order_release);
        touchhud_clear_cluster();
        invalidate_map_rect();
        return;
    }
    // Shrines fade only the map. Its collapsed layout still anchors the
    // visible environment HUD, while transparent map pixels cannot own taps.
    if ((map_inout_root(pane) || (pane_named(pane,"RootPane") &&
         (uintptr_t)pane == atomic_load(&g_touchhud_map_root))) && !map_hit_visible(pane))
        invalidate_map_rect();
    if (map_cut_root(pane) || map_cut_sibling(pane) || map_ornament_root(pane)) {
        int moved = touchhud_delta_valid();
        if (atomic_load_explicit(&g_touchhud_active, memory_order_acquire) || moved)
            pane[BOTW_TOUCH_FLAGS] |= BOTW_TOUCH_DIRTY;
        if (map_cut_root(pane)) {
            atomic_store(&g_touchhud_map_root, (uintptr_t)pane_parent(pane_parent(pane)));
            float w, h;
            memcpy(&w, pane + BOTW_TOUCH_SIZE, sizeof w);
            memcpy(&h, pane + BOTW_TOUCH_SIZE + 4, sizeof h);
            int collapsed = atomic_load_explicit(&g_touchhud_active, memory_order_acquire) && map_cut_visible(pane) &&
                            isfinite(w) && isfinite(h) && fabsf(w - 166.0f) < 2.0f && fabsf(h - 166.0f) < 2.0f;
            atomic_store_explicit(&g_touchhud_map_collapsed, collapsed, memory_order_release);
            if (!collapsed) {
                touchhud_clear_cluster();
                invalidate_map_rect();
            }
        }
        return;
    }
    if (main_environment_pane(pane)) {
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
    if (!dm_botw_touch_hud_available()) return;
    dm_botw_touch_menu_pane(regs, 1);
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[19];
    if (!pane) return;
    int active = atomic_load_explicit(&g_touchhud_active, memory_order_acquire);
    if (active && main_shortcut_rune_pane(pane)) {
        rune_icon_record(pane);
        return;
    }
    if (active && main_shortcut_rune_guide_pane(pane)) {
        rune_guide_record(pane);
        return;
    }
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
    if (map_cut_root(pane)) {
        float w, h;
        memcpy(&w, pane + BOTW_TOUCH_SIZE, sizeof w); memcpy(&h, pane + BOTW_TOUCH_SIZE + 4, sizeof h);
        collapsed = active && map_cut_visible(pane) && isfinite(w) && isfinite(h) &&
                    fabsf(w - 166.0f) < 2.0f && fabsf(h - 166.0f) < 2.0f;
        atomic_store_explicit(&g_touchhud_map_collapsed, collapsed, memory_order_release);
        if (!collapsed) {
            invalidate_map_rect();
            return;
        }
        if (!touchhud_record_cluster_bounds(pane, 0) || !touchhud_update_cluster_delta()) { invalidate_map_rect(); return; }
        pthread_mutex_lock(&g_touchhud_mu); float dx = g_touchhud.map_dx, dy = g_touchhud.map_dy; pthread_mutex_unlock(&g_touchhud_mu);
        float tx, ty; memcpy(&tx, pane + BOTW_TOUCH_MATRIX + 0x0c, 4); memcpy(&ty, pane + BOTW_TOUCH_MATRIX + 0x1c, 4);
        tx += dx; ty += dy; memcpy(pane + BOTW_TOUCH_MATRIX + 0x0c, &tx, 4); memcpy(pane + BOTW_TOUCH_MATRIX + 0x1c, &ty, 4);
        publish_map_rect(pane);
        return;
    }
    if (map_cut_sibling(pane) || map_ornament_root(pane) || main_environment_pane(pane)) {
        pthread_mutex_lock(&g_touchhud_mu);
        int apply = active && collapsed && g_touchhud.delta_valid;
        float dx = g_touchhud.map_dx, dy = g_touchhud.map_dy;
        pthread_mutex_unlock(&g_touchhud_mu);
        if (active && collapsed && map_cut_sibling(pane)) touchhud_record_cluster_bounds(pane, 1);
        if (active && collapsed && main_environment_pane(pane) && pane_named(pane, "Pa_Sensor_00") && visible_to_root(pane)) touchhud_record_cluster_bounds(pane, 2);
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
}

void dm_botw_touch_hud_install(void) {
    int touch = 1;
#if !TARGET_OS_IPHONE && !defined(DM_TEST_HOOKS)
    const char *preview = getenv("DM_TOUCH_PREVIEW");
    touch = preview && !strcmp(preview, "1");
#endif
    if (!touch && !dm_aspect_native()) return;
    if (strcmp(DM_GAME_ID, "01007EF00011E000")) return;
    if (strcmp(dm_main_build(), BOTW_BUILD)) {
        LOG("BOTW touch HUD: disabled for main build %s (requires %s)", dm_main_build(), BOTW_BUILD);
        return;
    }
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_touchhud_main = &g_mod[i];
    if (!g_touchhud_main || !gate_obs_present(OBS_BOTW_TOUCH_PANE) || !gate_obs_present(OBS_BOTW_TOUCH_MATRIX))
        die("[RED] BOTW touch HUD: pane calculation gates missing; rewrite main with the current patches.py");
    gate_obs_read_set(OBS_BOTW_TOUCH_PANE, botw_touchhud_pane);
    gate_obs_read_set(OBS_BOTW_TOUCH_MATRIX, botw_touchhud_matrix);
    atomic_store_explicit(&g_touchhud_available, touch, memory_order_release);
    if (touch) front_botw_touch_hud_mode_changed();
    LOG("BOTW UI: pane probes installed for build %s (touch HUD %s; native aspect %s)",
        BOTW_BUILD, touch ? "enabled" : "disabled", dm_aspect_native() ? "enabled" : "disabled");
}

#ifdef DM_TEST_HOOKS
void dm_botw_touchhud_test_pane(const uint64_t *regs) { botw_touchhud_pane(regs); }
void dm_botw_touchhud_test_matrix(const uint64_t *regs) { botw_touchhud_matrix(regs); }
void dm_botw_touchhud_test_clear(void) { atomic_store(&g_touchhud_pane, 0); memset(&g_touchhud, 0, sizeof g_touchhud); atomic_store(&g_touchhud_active, 0); atomic_store(&g_touchhud_available, 0); }
#endif
