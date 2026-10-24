// BOTW 1.9.0: move the gameplay equipment/rune guide subtree to the iOS
// virtual 3D D-pad. The build-checked Pane::Calculate probes only touch the
// unique MainShortCut N_MainAll_00 pane; its native parent animation remains
// in the freshly composed global matrix.
#include "hle.h"
#include "front.h"
#include <math.h>
#include <stdatomic.h>
#include <TargetConditionals.h>

enum { BOTW_TOUCH_PANE_NAME = 0xb8, BOTW_TOUCH_PARENT = 0x18, BOTW_TOUCH_FLAGS = 0x58,
       BOTW_TOUCH_MATRIX = 0x70, BOTW_TOUCH_DIRTY = 0x10 };
static const char BOTW_BUILD[] = "cd57b23fa4bbad65803d9788c01821ee";
static pthread_mutex_t g_touchhud_mu = PTHREAD_MUTEX_INITIALIZER;
static struct { int active; float x, y; } g_touchhud;
static _Atomic int g_touchhud_active;
static _Atomic(uintptr_t) g_touchhud_pane;
static _Atomic int g_touchhud_available;
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
        pthread_mutex_unlock(&g_touchhud_mu);
    }
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

static void botw_touchhud_pane(const uint64_t *regs) {
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[0];
    if (!pane) return;
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
    if (!pane || (uintptr_t)pane != atomic_load_explicit(&g_touchhud_pane, memory_order_acquire)) return;
    pthread_mutex_lock(&g_touchhud_mu);
    int active = g_touchhud.active;
    float x = g_touchhud.x, y = g_touchhud.y;
    pthread_mutex_unlock(&g_touchhud_mu);
    if (!active) return; // the freshly composed native matrix is the restoration

    // MainShortCut_00.bflyt is a centered 1280x720 layout. Its cross-guide
    // pane sits at (-45,+36) below N_MainAll_00, whose base position is
    // (-509,+210); therefore the guide centre is (-554,+246). Preserve the
    // animated N_Pos_00 parent delta by applying target-minus-base to the
    // freshly composed matrix, rather than writing the pane's local position.
    float dx = x * 1280.0f - 640.0f + 554.0f;
    float dy = 360.0f - y * 720.0f - 246.0f;
    float tx, ty;
    memcpy(&tx, pane + BOTW_TOUCH_MATRIX + 0x0c, sizeof tx); // row 0, translation lane
    memcpy(&ty, pane + BOTW_TOUCH_MATRIX + 0x1c, sizeof ty); // row 1, translation lane
    tx += dx; ty += dy;
    memcpy(pane + BOTW_TOUCH_MATRIX + 0x0c, &tx, sizeof tx);
    memcpy(pane + BOTW_TOUCH_MATRIX + 0x1c, &ty, sizeof ty);
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
