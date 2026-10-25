// BOTW 1.9 inventory pane observation and native Npad touch-menu routing.
#include "dm.h"
#include "hle.h"
#include "front.h"
#include "botw_touch_menu.h"
#include "dm_input.h"
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>

enum { PANE_PARENT = 0x18, PANE_FLAGS = 0x58, PANE_MATRIX = 0x70, PANE_NAME = 0xb8,
       INVENTORY_PAGE_COUNT = 3,
       PANE_VISIBLE = 1, PANE_TRACE_SLOTS = 2048, PANE_PATH_DEPTH = 14 };
static const char BOTW_BUILD[] = "cd57b23fa4bbad65803d9788c01821ee";
typedef struct {
    uintptr_t pane;
    uint8_t visible, matrix_valid, logs, marker;
    float x, y;
} pane_trace_t;
static pane_trace_t g_panes[PANE_TRACE_SLOTS];
static pthread_mutex_t g_panes_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int g_trace;
static _Atomic int g_selector_hook_installed;
static struct {
    uintptr_t root, slide, item_area, cut, popup_root, selected_page_pane, category_slide;
    uintptr_t page_panes[INVENTORY_PAGE_COUNT];
    uintptr_t cursor_root, cursor_type, cursor_parent;
    uintptr_t footer_root, guide_instances[5];
    uint64_t frame, inventory_seen, clip_seen, popup_seen, popup_epoch;
    int inventory_visible, clip_valid, popup_visible;
    float clip[4];
    uint8_t slot_valid[INVENTORY_PAGE_COUNT][DM_BOTW_MENU_MAX_SLOTS];
    uint64_t slot_seen[INVENTORY_PAGE_COUNT][DM_BOTW_MENU_MAX_SLOTS];
    uintptr_t slot_panes[INVENTORY_PAGE_COUNT][DM_BOTW_MENU_MAX_SLOTS];
    float slots[INVENTORY_PAGE_COUNT][DM_BOTW_MENU_MAX_SLOTS][4];
    uint8_t category_valid[DM_BOTW_MENU_MAX_CATEGORIES];
    uint64_t category_seen[DM_BOTW_MENU_MAX_CATEGORIES];
    uintptr_t category_panes[DM_BOTW_MENU_MAX_CATEGORIES];
    float categories[DM_BOTW_MENU_MAX_CATEGORIES][4];
    uint8_t popup_row_valid[DM_BOTW_MENU_MAX_POPUP_ROWS];
    uint64_t popup_row_seen[DM_BOTW_MENU_MAX_POPUP_ROWS];
    uintptr_t popup_row_panes[DM_BOTW_MENU_MAX_POPUP_ROWS];
    float popup_rows[DM_BOTW_MENU_MAX_POPUP_ROWS][4];
    uint8_t guide_icon_valid[5], guide_text_valid[5];
    uint64_t guide_icon_seen[5];
    uint64_t guide_text_seen[5];
    uint16_t guide_icon_glyph[5];
    float guide_icons[5][4], guide_texts[5][4];
    float cursor_xy[4][2];
    uint8_t cursor_visible[4];
    uint64_t cursor_seen[4];
    uintptr_t header_root;
    uint8_t header_icon_valid[2], header_text_valid[2];
    uint64_t header_icon_seen[2], header_text_seen[2];
    uint16_t header_icon_glyph[2];
    float header_icons[2][4], header_texts[2][4];
} g_native_view;
static pthread_mutex_t g_native_view_mu = PTHREAD_MUTEX_INITIALIZER;
typedef struct {
    uintptr_t pane, parent, root;
    uint64_t seen;
    uint8_t valid;
    float rect[4];
} generic_hit_t;
static generic_hit_t g_generic_hits[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
static pthread_mutex_t g_generic_hits_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_menu_mu = PTHREAD_MUTEX_INITIALIZER;
static dm_botw_touch_menu_view g_view;
static int g_view_valid, g_pointer_down, g_pointer_dragged;
static int g_target_valid, g_target_popup, g_target_index, g_confirm_pending;
static int g_target_category, g_selector_ready;
static int g_target_generic;
static uintptr_t g_target_pane, g_target_owner_pane, g_target_entry, g_target_screen, g_target_root;
static uintptr_t g_requested_entry, g_selector_manager;
static uintptr_t g_selector_miss_pane, g_selector_bad_manager;
static uint64_t g_selector_miss_page, g_selector_miss_popup;
static uint64_t g_target_button_bits;
static int g_target_axis;
static int g_last_apply_valid, g_release_pending, g_axis_release_pending;
static float g_pointer_start[2], g_target_center[2];
static uint64_t g_last_apply_frame, g_last_action_frame, g_last_action_bits;
static uint64_t g_target_page_key, g_target_popup_key, g_apply_output_bits;
static uint64_t g_generic_eligible_frame;
static uintptr_t g_generic_eligible_entry, g_generic_eligible_screen, g_generic_eligible_root;
static int g_generic_eligible_group = -1;
static int g_apply_output_axis_valid, g_apply_output_rx;
static int g_active_notified;
typedef struct {
    uintptr_t manager, focus, screen, vtable, root;
    int group, input_active, inventory_screen, popup_active;
    int view_valid, generic_mode, generic_count, back_valid, inventory_visible;
} selector_trace_state_t;
static selector_trace_state_t g_selector_trace_states[16];
static unsigned g_selector_trace_next;
static pthread_mutex_t g_selector_trace_mu = PTHREAD_MUTEX_INITIALIZER;
static int point_in_rect(float x, float y, const float rect[4]);
static uint64_t menu_render_frame(void);
static uint64_t g_pointer_page_key, g_pointer_popup_key;
static void menu_clear_queue_locked(void);
#ifdef DM_TEST_HOOKS
static _Atomic int g_test_ready;
static _Atomic int g_test_native_ready;
static _Atomic uint64_t g_test_render_frame;
static uintptr_t g_test_category_commit_screen;
static unsigned g_test_category_commit_count;
static uintptr_t g_test_category_flag_screen;
static int g_test_category_flag_value;
static unsigned g_test_category_flag_count;
static uintptr_t g_test_category_refresh_screen;
static int32_t g_test_category_refresh_delta;
static unsigned g_test_category_refresh_count;
static int g_test_category_call_order[3];
static unsigned g_test_category_call_order_count;
static _Atomic int g_test_generic_selector;
static uintptr_t g_test_native_group_getter, g_test_native_screen_shown;
#endif

static void pane_name(const uint8_t *pane, char out[17]) {
    memcpy(out, pane + PANE_NAME, 16);
    out[16] = 0;
}

static int cursor_name(const char *name) {
    return strstr(name, "Cursor") != NULL || strstr(name, "cursor") != NULL;
}

static int cursor_asset_name(const char *name) {
    return !strcmp(name, "N_TypeA_00") || !strcmp(name, "N_LT_00") ||
           !strcmp(name, "N_RT_00") || !strcmp(name, "N_LD_00") ||
           !strcmp(name, "N_RD_00") || !strcmp(name, "N_Seek_00");
}

static int action_scope_name(const char *name) {
    return strstr(name, "Action") != NULL || strstr(name, "Popup") != NULL ||
           strstr(name, "Select") != NULL || strstr(name, "ItemMenu") != NULL;
}

static int relevant_chain(uint8_t *pane, char path[256], int *visible, int *has_slide,
                          int *has_item_area, int *has_slot) {
    size_t used = 0;
    int depth = 0, has_root = 0, has_state = 0, has_category_row = 0;
    int has_cursor = 0, has_cursor_asset = 0, has_action_scope = 0;
    *visible = 1; *has_slide = 0; *has_item_area = 0; *has_slot = 0;
    path[0] = 0;
    for (uint8_t *p = pane; p && depth++ < PANE_PATH_DEPTH;
         p = *(uint8_t **)(p + PANE_PARENT)) {
        char name[17]; pane_name(p, name);
        int n = snprintf(path + used, 256 - used, "%s%s[%c]", used ? " <- " : "", name,
                         (p[PANE_FLAGS] & PANE_VISIBLE) ? 'V' : '-');
        if (n > 0) used += (size_t)n < 256 - used ? (size_t)n : 255 - used;
        if (!(p[PANE_FLAGS] & PANE_VISIBLE)) *visible = 0;
        if (cursor_name(name)) has_cursor = 1;
        if (cursor_asset_name(name)) has_cursor_asset = 1;
        if (action_scope_name(name)) has_action_scope = 1;
        if (!strcmp(name, "N_Slide_01")) *has_slide = 1;
        if (!strcmp(name, "N_InOut_00")) *has_item_area = 1;
        if (!strncmp(name, "Pa_Btn_", 7)) *has_slot = 1;
        if (!strcmp(name, "RootPane")) has_root = 1;
        if (!strcmp(name, "N_State_00")) has_state = 1;
        if (!strcmp(name, "N_Cat_01") && *has_slide) has_category_row = 1;
        if (!strcmp(name, "RootPane")) break;
    }
    char name[17]; pane_name(pane, name);
    if (!has_root) return 0;
    // Keep the trace bounded to cursor subtrees and likely item-action
    // popup subtrees. Their exact runtime names vary across linked layouts,
    // so retain the whole live ancestry in each record for review.
    if (has_cursor || has_cursor_asset) return 1;
    if (*visible && (!strcmp(name, "B_Hit_00") || !strncmp(name, "Pa_Btn_", 7))) return 1;
    if (has_action_scope && (strstr(name, "B_Hit_") || !strncmp(name, "Pa_Btn_", 7)))
        return 1;
    if (!strcmp(name, "N_Check_00") && has_category_row && strstr(path, "Pa_CategoryS_")) return 1;
    // PauseMenuInfo owns the footer in a separate root from PauseMenu's
    // N_Slide. Trace the whole Pa_Guide subtree with ancestry so live indexes
    // can be distinguished from similarly named widgets in other layouts.
    if (!strncmp(name, "Pa_Guide_", 9) || !strncmp(name, "T_Guide_", 8) ||
        !strncmp(name, "T_Icon_", 7)) return 1;
    if (!strcmp(name, "P_ItemPointer_00")) return strstr(path, "N_SunLight_00") != NULL &&
        strstr(path, "N_Valid_01") != NULL && strstr(path, "N_Center_00") != NULL;
    if (!strncmp(name, "Pa_Btn_", 7)) return *has_slide && *has_item_area;
    if (!strcmp(name, "B_Hit_00")) return *has_slide && *has_item_area && *has_slot;
    if (!strncmp(name, "Pa_CategoryS_", 13)) return *has_slide && has_category_row &&
        strstr(path, "N_InOutGear_01") != NULL;
    if (!strcmp(name, "N_Cut_00") || !strcmp(name, "N_InOut_00"))
        return *has_slide && *has_item_area;
    if (!strcmp(name, "N_State_00") || !strcmp(name, "Pa_Gear_00"))
        return *has_slide && has_state;
    return 0;
}

static uint8_t *ancestor_named(uint8_t *pane, const char *wanted) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strcmp(name, wanted)) return pane;
        if (!strcmp(name, "RootPane")) break;
    }
    return NULL;
}

static int pane_chain_visible(uint8_t *pane) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        if (!(pane[PANE_FLAGS] & PANE_VISIBLE)) return 0;
        char name[17]; pane_name(pane, name);
        if (!strcmp(name, "RootPane")) return 1;
    }
    return 0;
}

static int pane_chain_alpha_visible(uint8_t *pane) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        if (!pane[0x59]) return 0;
        char name[17]; pane_name(pane, name);
        if (!strcmp(name, "RootPane")) return 1;
    }
    return 0;
}

static uint16_t pane_text_glyph(uint8_t *pane) {
    uintptr_t text = 0;
    memcpy(&text, pane + 0xe0, sizeof text);
    if (text < 0x10000) return 0;
    uint16_t glyph = 0;
    memcpy(&glyph, (const void *)text, sizeof glyph);
    return glyph;
}

static int pane_slot_index(uint8_t *pane) {
    uint8_t *button = NULL;
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strncmp(name, "Pa_Btn_", 7)) { button = pane; break; }
        if (!strcmp(name, "RootPane")) break;
    }
    if (!button) return -1;
    char name[17]; pane_name(button, name);
    char *end = NULL;
    long index = strtol(name + 7, &end, 10);
    return end && !*end && index >= 0 && index < DM_BOTW_MENU_MAX_SLOTS ? (int)index : -1;
}

static int pane_inventory_page_index(uint8_t *pane) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strncmp(name, "Pa_PagePorch_", 13)) {
            char *end = NULL;
            long index = strtol(name + 13, &end, 10);
            return end && !*end && index >= 0 && index < INVENTORY_PAGE_COUNT ? (int)index : -1;
        }
        if (!strcmp(name, "RootPane")) break;
    }
    return -1;
}

static int pane_category_index(uint8_t *pane) {
    uint8_t *category = NULL;
    // Category names carry the native index; accept only a complete numeric
    // suffix under the live gear-category row.
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char candidate[17]; pane_name(pane, candidate);
        if (!strncmp(candidate, "Pa_CategoryS_", 13)) { category = pane; break; }
        if (!strcmp(candidate, "RootPane")) break;
    }
    if (!category) return -1;
    char name[17]; pane_name(category, name);
    char *end = NULL;
    long index = strtol(name + 13, &end, 10);
    if (!end || *end || index < 0 || index >= DM_BOTW_MENU_MAX_CATEGORIES) return -1;
    return (int)index;
}

static int pane_button_index(uint8_t *pane, const char *prefix, int limit) {
    uint8_t *button = NULL;
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strncmp(name, prefix, strlen(prefix))) { button = pane; break; }
        if (!strcmp(name, "RootPane")) break;
    }
    if (!button) return -1;
    char name[17]; pane_name(button, name);
    char *end = NULL;
    long index = strtol(name + strlen(prefix), &end, 10);
    return end && !*end && index >= 0 && index < limit ? (int)index : -1;
}

static int pane_guide_index(uint8_t *pane) {
    return pane_button_index(pane, "Pa_Guide_", 5);
}

static uint8_t *ancestor_guide(uint8_t *pane, int index) {
    char wanted[17]; snprintf(wanted, sizeof wanted, "Pa_Guide_%02d", index);
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strcmp(name, wanted)) return pane;
        if (!strcmp(name, "RootPane")) break;
    }
    return NULL;
}

static void native_rect_from_pane(uint8_t *pane, float x, float y, float out[4]) {
    float w, h, m00, m01, m10, m11;
    memcpy(&w, pane + 0x50, sizeof w);
    memcpy(&h, pane + 0x54, sizeof h);
    memcpy(&m00, pane + PANE_MATRIX, 4); memcpy(&m01, pane + PANE_MATRIX + 4, 4);
    memcpy(&m10, pane + PANE_MATRIX + 0x10, 4); memcpy(&m11, pane + PANE_MATRIX + 0x14, 4);
    float bounds_w = fabsf(m00) * w + fabsf(m01) * h;
    float bounds_h = fabsf(m10) * w + fabsf(m11) * h;
    out[0] = (x - bounds_w * .5f + 640.0f) / 1280.0f;
    out[1] = (360.0f - y - bounds_h * .5f) / 720.0f;
    out[2] = bounds_w / 1280.0f;
    out[3] = bounds_h / 720.0f;
}

static void native_right_anchored_rect_from_pane(uint8_t *pane, float right, float y, float out[4]) {
    float w, h, m00, m01, m10, m11;
    memcpy(&w, pane + 0x50, sizeof w); memcpy(&h, pane + 0x54, sizeof h);
    memcpy(&m00, pane + PANE_MATRIX, 4); memcpy(&m01, pane + PANE_MATRIX + 4, 4);
    memcpy(&m10, pane + PANE_MATRIX + 0x10, 4); memcpy(&m11, pane + PANE_MATRIX + 0x14, 4);
    float bounds_w = fabsf(m00) * w + fabsf(m01) * h;
    float bounds_h = fabsf(m10) * w + fabsf(m11) * h;
    out[0] = (right - bounds_w + 640.0f) / 1280.0f;
    out[1] = (360.0f - y - bounds_h * .5f) / 720.0f;
    out[2] = bounds_w / 1280.0f;
    out[3] = bounds_h / 720.0f;
}

static void back_hit_rect(const float text[4], const float icon[4],
                          float nearest_left, float nearest_right, float out[4]) {
    if (!isfinite(nearest_left) && !isfinite(nearest_right) && !memcmp(text, icon, sizeof(float) * 4)) {
        memcpy(out, icon, sizeof(float) * 4);
        return;
    }
    float left = fminf(text[0], icon[0]);
    float top = fminf(text[1], icon[1]);
    float right = fmaxf(text[0] + text[2], icon[0] + icon[2]);
    float bottom = fmaxf(text[1] + text[3], icon[1] + icon[3]);
    float back_center = icon[0] + icon[2] * .5f;
    if (isfinite(nearest_left)) left = fmaxf(left, (nearest_left + back_center) * .5f);
    if (isfinite(nearest_right)) right = fminf(right, (nearest_right + back_center) * .5f);
    out[0] = left; out[1] = top;
    out[2] = fmaxf(0.0f, right - left); out[3] = bottom - top;
}

static float rect_clip_area(const float rect[4], const float clip[4]) {
    float left = fmaxf(rect[0], clip[0]);
    float top = fmaxf(rect[1], clip[1]);
    float right = fminf(rect[0] + rect[2], clip[0] + clip[2]);
    float bottom = fminf(rect[1] + rect[3], clip[1] + clip[3]);
    return fmaxf(0, right - left) * fmaxf(0, bottom - top);
}

static int rect_intersects_canvas(const float rect[4]) {
    return rect[2] > 0 && rect[3] > 0 && rect[0] < 1.0f && rect[1] < 1.0f &&
           rect[0] + rect[2] > 0.0f && rect[1] + rect[3] > 0.0f;
}

static void generic_hit_observe(uint8_t *pane, int after_matrix) {
    uintptr_t address = (uintptr_t)pane;
    uint8_t *parent = *(uint8_t **)(pane + PANE_PARENT);
    uint8_t *root = ancestor_named(pane, "RootPane");
    uint64_t frame = dm_guest_frame();
    pthread_mutex_lock(&g_generic_hits_mu);
    generic_hit_t *slot = NULL, *oldest = &g_generic_hits[0];
    for (int i = 0; i < DM_BOTW_MENU_MAX_GENERIC_TARGETS; i++) {
        generic_hit_t *candidate = &g_generic_hits[i];
        if (candidate->pane == address) { slot = candidate; break; }
        if (!candidate->pane && !slot) slot = candidate;
        if (candidate->seen < oldest->seen) oldest = candidate;
    }
    if (!slot) slot = oldest;
    if (!root || !pane_chain_visible(pane) || !pane_chain_alpha_visible(pane)) {
        if (slot->pane == address) memset(slot, 0, sizeof *slot);
        pthread_mutex_unlock(&g_generic_hits_mu);
        return;
    }
    // OBS34 runs before Pane::Calculate. A clean pane may skip its OBS35
    // post-matrix callback, so the pre-phase is not evidence that its cached
    // global matrix is invalid. Preserve only the exact same visible pane
    // ancestry and refresh its freshness; changed/hidden panes still fail
    // closed until a new post-matrix observation arrives.
    if (!after_matrix) {
        if (slot->pane == address) {
            if (slot->parent == (uintptr_t)parent && slot->root == (uintptr_t)root)
                slot->seen = frame;
            else
                memset(slot, 0, sizeof *slot);
        }
        pthread_mutex_unlock(&g_generic_hits_mu);
        return;
    }
    float x = 0, y = 0, rect[4];
    memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
    memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
    native_rect_from_pane(pane, x, y, rect);
    if (!rect_intersects_canvas(rect)) {
        if (slot->pane == address) memset(slot, 0, sizeof *slot);
        pthread_mutex_unlock(&g_generic_hits_mu);
        return;
    }
    slot->pane = address;
    slot->parent = (uintptr_t)parent;
    slot->root = (uintptr_t)root;
    slot->seen = frame;
    slot->valid = 1;
    memcpy(slot->rect, rect, sizeof rect);
    pthread_mutex_unlock(&g_generic_hits_mu);
}

static int generic_hit_snapshot(generic_hit_t out[DM_BOTW_MENU_MAX_GENERIC_TARGETS], uint64_t frame) {
    int count = 0;
    pthread_mutex_lock(&g_generic_hits_mu);
    for (int i = 0; i < DM_BOTW_MENU_MAX_GENERIC_TARGETS; i++) {
        const generic_hit_t *hit = &g_generic_hits[i];
        if (!hit->valid || frame < hit->seen || frame - hit->seen > 2) continue;
        out[count++] = *hit;
    }
    pthread_mutex_unlock(&g_generic_hits_mu);
    return count;
}

static dm_botw_touch_menu_view snapshot_native_view_locked(void) {
    uint64_t frame = g_native_view.frame;
    dm_botw_touch_menu_view view = {0};
    view.render_frame = frame;
    view.inventory_visible = g_native_view.inventory_visible && frame >= g_native_view.inventory_seen &&
                             frame - g_native_view.inventory_seen <= 2;
    view.page_key = 0;
    for (int i = 0; i < DM_BOTW_MENU_MAX_CATEGORIES; i++)
        if (g_native_view.category_valid[i] && frame >= g_native_view.category_seen[i] &&
            frame - g_native_view.category_seen[i] <= 2) {
            int at = view.category_count++;
            view.category_ids[at] = i;
            view.category_panes[at] = g_native_view.category_panes[i];
            memcpy(view.categories[at], g_native_view.categories[i], sizeof view.categories[at]);
        }
    view.popup_visible = g_native_view.popup_visible && frame >= g_native_view.popup_seen &&
                         frame - g_native_view.popup_seen <= 2;
    for (int i = 0; i < DM_BOTW_MENU_MAX_POPUP_ROWS; i++) if (g_native_view.popup_row_valid[i] &&
        frame >= g_native_view.popup_row_seen[i] && frame - g_native_view.popup_row_seen[i] <= 2) {
        int at = view.popup_count++;
        view.popup_row_panes[at] = g_native_view.popup_row_panes[i];
        memcpy(view.popup_rows[at], g_native_view.popup_rows[i], sizeof g_native_view.popup_rows[i]);
        while (at > 0 && view.popup_rows[at][1] < view.popup_rows[at - 1][1]) {
            float tmp[4]; memcpy(tmp, view.popup_rows[at], sizeof tmp);
            memcpy(view.popup_rows[at], view.popup_rows[at - 1], sizeof tmp);
            memcpy(view.popup_rows[at - 1], tmp, sizeof tmp);
            uintptr_t pane = view.popup_row_panes[at];
            view.popup_row_panes[at] = view.popup_row_panes[at - 1];
            view.popup_row_panes[at - 1] = pane;
            at--;
        }
    }
    view.popup_visible = view.popup_visible && view.popup_count > 0;
    view.popup_key = view.popup_visible ?
        ((uint64_t)g_native_view.popup_root ^ (g_native_view.popup_epoch * UINT64_C(0x9e3779b97f4a7c15))) : 0;
    // T_Icon_00 is the live native button glyph. In this build U+E041 is B,
    // U+E042 is X and U+E043 is Y. Guide indices are repacked by state, so
    // derive both Back and action prompts from glyph content, never position.
    // Include matching text and clamp between neighboring prompt midpoints.
    for (int i = 0; i < 5; i++) {
        if (!g_native_view.guide_icon_valid[i] || frame < g_native_view.guide_icon_seen[i] ||
            frame - g_native_view.guide_icon_seen[i] > 2) continue;
        uint16_t glyph = g_native_view.guide_icon_glyph[i];
        uint64_t button = glyph == 0xe042 ? DM_BTN_X : glyph == 0xe043 ? DM_BTN_Y : 0;
        int is_back = glyph == 0xe041;
        if (!button && !is_back) continue;
        if (!rect_intersects_canvas(g_native_view.guide_icons[i])) continue;
        float text[4];
        const float *text_rect = NULL;
        if (g_native_view.guide_text_valid[i] && frame >= g_native_view.guide_text_seen[i] &&
            frame - g_native_view.guide_text_seen[i] <= 2) {
            memcpy(text, g_native_view.guide_texts[i], sizeof text);
            text_rect = text;
        }
        float icon_center = g_native_view.guide_icons[i][0] + g_native_view.guide_icons[i][2] * .5f;
        float nearest_left = -INFINITY, nearest_right = INFINITY;
        for (int j = 0; j < 5; j++) {
            if (j == i || !g_native_view.guide_icon_valid[j] || frame < g_native_view.guide_icon_seen[j] ||
                frame - g_native_view.guide_icon_seen[j] > 2) continue;
            float center = g_native_view.guide_icons[j][0] + g_native_view.guide_icons[j][2] * .5f;
            if (center < icon_center && center > nearest_left) nearest_left = center;
            if (center > icon_center && center < nearest_right) nearest_right = center;
        }
        float hit[4];
        back_hit_rect(text_rect ? text_rect : g_native_view.guide_icons[i],
                      g_native_view.guide_icons[i], nearest_left, nearest_right, hit);
        if (!rect_intersects_canvas(hit)) continue;
        if (is_back) {
            view.back_valid = 1;
            memcpy(view.back, hit, sizeof view.back);
        } else if (view.footer_action_count < DM_BOTW_MENU_MAX_FOOTER_ACTIONS) {
            int at = view.footer_action_count++;
            view.footer_action_buttons[at] = button;
            memcpy(view.footer_actions[at], hit, sizeof view.footer_actions[at]);
        }
    }
    // PauseMenuInfo's top bar shares the footer's native root. Pair each
    // currently enabled ZL/ZR glyph with its matching live label; disabled
    // icons are rejected by alpha on their full ancestry chain.
    if (g_native_view.footer_root && g_native_view.header_root == g_native_view.footer_root) {
        for (int i = 0; i < 2; i++) {
            if (!g_native_view.header_icon_valid[i] || !g_native_view.header_text_valid[i] ||
                frame < g_native_view.header_icon_seen[i] || frame < g_native_view.header_text_seen[i] ||
                frame - g_native_view.header_icon_seen[i] > 2 ||
                frame - g_native_view.header_text_seen[i] > 2) continue;
            uint16_t glyph = g_native_view.header_icon_glyph[i];
            uint64_t button = i == 0 && glyph == 0xe044 ? DM_BTN_L :
                              i == 1 && glyph == 0xe045 ? DM_BTN_R : 0;
            if (!button || !rect_intersects_canvas(g_native_view.header_icons[i]) ||
                !rect_intersects_canvas(g_native_view.header_texts[i]) ||
                view.footer_action_count >= DM_BOTW_MENU_MAX_FOOTER_ACTIONS) continue;
            const float *icon = g_native_view.header_icons[i];
            const float *text = g_native_view.header_texts[i];
            float hit[4];
            float left = fminf(icon[0], text[0]), top = fminf(icon[1], text[1]);
            float right = fmaxf(icon[0] + icon[2], text[0] + text[2]);
            float bottom = fmaxf(icon[1] + icon[3], text[1] + text[3]);
            hit[0] = left; hit[1] = top; hit[2] = right - left; hit[3] = bottom - top;
            int at = view.footer_action_count++;
            view.footer_action_buttons[at] = button;
            memcpy(view.footer_actions[at], hit, sizeof hit);
        }
    }
    view.clip_valid = g_native_view.clip_valid && frame >= g_native_view.clip_seen &&
                      frame - g_native_view.clip_seen <= 2;
    if (view.clip_valid) memcpy(view.clip, g_native_view.clip, sizeof view.clip);
    if (g_native_view.cursor_visible[0] && g_native_view.cursor_visible[1] &&
        g_native_view.cursor_visible[2] && g_native_view.cursor_visible[3]) {
        float x = 0, y = 0;
        for (int i = 0; i < 4; i++) { x += g_native_view.cursor_xy[i][0]; y += g_native_view.cursor_xy[i][1]; }
        x *= .25f; y *= .25f;
        view.cursor[0] = (x + 640.0f) / 1280.0f;
        view.cursor[1] = (360.0f - y) / 720.0f;
        view.cursor_valid = (view.popup_visible || (view.inventory_visible && view.clip_valid)) &&
            frame >= g_native_view.cursor_seen[0] && frame - g_native_view.cursor_seen[0] <= 2 &&
            frame >= g_native_view.cursor_seen[1] && frame - g_native_view.cursor_seen[1] <= 2 &&
            frame >= g_native_view.cursor_seen[2] && frame - g_native_view.cursor_seen[2] <= 2 &&
            frame >= g_native_view.cursor_seen[3] && frame - g_native_view.cursor_seen[3] <= 2 &&
            (view.popup_visible || point_in_rect(view.cursor[0], view.cursor[1], view.clip));
    }
    // PauseMenu keeps three sibling inventory grids alive during the native
    // carousel transition. Their slot names repeat, so retain each page's
    // geometry independently and choose the page the native cursor actually
    // occupies. If the cursor is temporarily unavailable, use the page with
    // the greatest live area inside N_Cut instead of merging adjacent pages.
    int selected_page = -1;
    int exact_cursor_page = -1;
    float best_cursor_distance = INFINITY;
    float best_clip_area = 0;
    float page_clip_area[INVENTORY_PAGE_COUNT] = {0};
    if (view.inventory_visible && view.clip_valid) {
        for (int page = 0; page < INVENTORY_PAGE_COUNT; page++) {
            for (int i = 0; i < DM_BOTW_MENU_MAX_SLOTS; i++) {
                if (!g_native_view.slot_valid[page][i] || frame < g_native_view.slot_seen[page][i] ||
                    frame - g_native_view.slot_seen[page][i] > 2) continue;
                const float *rect = g_native_view.slots[page][i];
                page_clip_area[page] += rect_clip_area(rect, view.clip);
                if (view.cursor_valid) {
                    float cx = rect[0] + rect[2] * .5f;
                    float cy = rect[1] + rect[3] * .5f;
                    float dx = (view.cursor[0] - cx) * 1280.0f;
                    float dy = (view.cursor[1] - cy) * 720.0f;
                    float distance = dx * dx + dy * dy;
                    if (distance < best_cursor_distance) {
                        best_cursor_distance = distance;
                        exact_cursor_page = page;
                    }
                }
            }
            if (page_clip_area[page] > best_clip_area) {
                best_clip_area = page_clip_area[page];
                selected_page = page;
            }
        }
        // A popup has its own cursor position, and the inventory cursor can
        // sit between cells during carousel animation. Preserve the selected
        // page while its live slot geometry still intersects the owned clip.
        // Otherwise select only an exact native slot match; use clipped area
        // as the transition fallback rather than a loose distance threshold.
        if (view.popup_visible) {
            for (int page = 0; page < INVENTORY_PAGE_COUNT; page++)
                if (g_native_view.page_panes[page] == g_native_view.selected_page_pane &&
                    page_clip_area[page] > 0) selected_page = page;
        } else if (view.cursor_valid && best_cursor_distance <= 3.0f * 3.0f) {
            selected_page = exact_cursor_page;
        } else if (g_native_view.selected_page_pane) {
            for (int page = 0; page < INVENTORY_PAGE_COUNT; page++)
                if (g_native_view.page_panes[page] == g_native_view.selected_page_pane &&
                    page_clip_area[page] > 0) selected_page = page;
        }
    }
    if (selected_page >= 0) {
        g_native_view.selected_page_pane = g_native_view.page_panes[selected_page];
        view.page_key = (uint64_t)g_native_view.page_panes[selected_page];
        for (int i = 0; i < DM_BOTW_MENU_MAX_SLOTS; i++)
            if (g_native_view.slot_valid[selected_page][i] &&
                frame >= g_native_view.slot_seen[selected_page][i] &&
                frame - g_native_view.slot_seen[selected_page][i] <= 2)
                {
                    int at = view.slot_count++;
                    memcpy(view.slots[at], g_native_view.slots[selected_page][i], sizeof view.slots[0]);
                    view.slot_panes[at] = g_native_view.slot_panes[selected_page][i];
                }
    }
    return view;
}

static int cursor_corner_index(const char *name) {
    if (!strcmp(name, "N_LT_00")) return 0;
    if (!strcmp(name, "N_RT_00")) return 1;
    if (!strcmp(name, "N_LD_00")) return 2;
    if (!strcmp(name, "N_RD_00")) return 3;
    return -1;
}

static void observe_native_pane(uint8_t *pane, int after_matrix) {
    if (!pane) return;
    char name[17]; pane_name(pane, name);
    if (!strcmp(name, "B_Hit_00")) generic_hit_observe(pane, after_matrix);
    int corner = cursor_corner_index(name);
    int back_text = !strcmp(name, "T_Guide_00");
    int back_icon = !strcmp(name, "T_Icon_00");
    int header_icon = back_icon;
    int header_text = !strcmp(name, "T_LeftText_01") || !strcmp(name, "T_RightText_01");
    if (corner < 0 && !back_text && !back_icon && !header_text && strcmp(name, "B_Hit_00") && strcmp(name, "N_Cut_00") &&
        strcmp(name, "N_InOut_00") && strcmp(name, "N_Slide_01")) return;
    uint8_t *cursor_type = corner >= 0 ? *(uint8_t **)(pane + PANE_PARENT) : NULL;
    uint8_t *cursor_parent = cursor_type ? *(uint8_t **)(cursor_type + PANE_PARENT) : NULL;
    uint8_t *cursor_root = cursor_parent ? *(uint8_t **)(cursor_parent + PANE_PARENT) : NULL;
    char cursor_type_name[17] = {0}, cursor_parent_name[17] = {0}, cursor_root_name[17] = {0};
    if (cursor_type) pane_name(cursor_type, cursor_type_name);
    if (cursor_parent) pane_name(cursor_parent, cursor_parent_name);
    if (cursor_root) pane_name(cursor_root, cursor_root_name);
    if (corner >= 0 && cursor_type && cursor_parent && cursor_root &&
        !strcmp(cursor_type_name, "N_TypeA_00") &&
        !strcmp(cursor_parent_name, "Pa_Cursor_00") &&
        !strcmp(cursor_root_name, "RootPane")) {
        uint64_t frame = dm_guest_frame();
        pthread_mutex_lock(&g_native_view_mu);
        g_native_view.frame = frame;
        int candidate_visible = pane_chain_visible(pane);
        int same_cursor = g_native_view.cursor_root == (uintptr_t)cursor_root &&
                          g_native_view.cursor_type == (uintptr_t)cursor_type &&
                          g_native_view.cursor_parent == (uintptr_t)cursor_parent;
        int cursor_unused = !g_native_view.cursor_parent;
        int cursor_hidden = 1;
        for (int i = 0; i < 4; i++) if (g_native_view.cursor_visible[i] &&
            frame >= g_native_view.cursor_seen[i] && frame - g_native_view.cursor_seen[i] <= 2)
            cursor_hidden = 0;
        if (same_cursor || (candidate_visible && (cursor_unused || cursor_hidden))) {
            if (!same_cursor) {
                g_native_view.cursor_root = (uintptr_t)cursor_root;
                g_native_view.cursor_type = (uintptr_t)cursor_type;
                g_native_view.cursor_parent = (uintptr_t)cursor_parent;
                memset(g_native_view.cursor_visible, 0, sizeof g_native_view.cursor_visible);
            }
            g_native_view.cursor_visible[corner] = candidate_visible;
            if (candidate_visible && (after_matrix || g_native_view.cursor_seen[corner])) {
                memcpy(&g_native_view.cursor_xy[corner][0], pane + PANE_MATRIX + 0x0c, 4);
                memcpy(&g_native_view.cursor_xy[corner][1], pane + PANE_MATRIX + 0x1c, 4);
                g_native_view.cursor_seen[corner] = frame;
            } else if (!candidate_visible) {
                g_native_view.cursor_seen[corner] = 0;
            }
            dm_botw_touch_menu_view view = snapshot_native_view_locked();
            pthread_mutex_unlock(&g_native_view_mu);
            dm_botw_touch_menu_observe(&view);
            return;
        }
        pthread_mutex_unlock(&g_native_view_mu);
        return;
    }
    // The PauseMenuInfo top bar exposes native L/R action glyphs and their
    // live labels. Keep each pair tied to the exact button and RootPane; alpha on
    // N_Disable_00 makes unavailable actions disappear from the touch view.
    if ((header_icon || header_text) && ancestor_named(pane, "N_TitleBarUp_00")) {
        int side = -1;
        uint8_t *root = ancestor_named(pane, "RootPane");
        if (header_icon) {
            uint8_t *button = ancestor_named(pane, "Pa_BtnZL_00");
            if (button) side = 0;
            else if ((button = ancestor_named(pane, "Pa_BtnZR_00"))) side = 1;
            if (!button || ancestor_named(button, "RootPane") != root) side = -1;
        } else {
            char label_name[17]; pane_name(pane, label_name);
            if (!strcmp(label_name, "T_LeftText_01")) side = 0;
            else if (!strcmp(label_name, "T_RightText_01")) side = 1;
        }
        if (side >= 0 && root) {
                uint64_t frame = dm_guest_frame();
                pthread_mutex_lock(&g_native_view_mu);
                g_native_view.frame = frame;
                int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
                if (visible && g_native_view.header_root != (uintptr_t)root) {
                    g_native_view.header_root = (uintptr_t)root;
                    memset(g_native_view.header_icon_valid, 0, sizeof g_native_view.header_icon_valid);
                    memset(g_native_view.header_text_valid, 0, sizeof g_native_view.header_text_valid);
                    memset(g_native_view.header_icon_glyph, 0, sizeof g_native_view.header_icon_glyph);
                }
                if (g_native_view.header_root == (uintptr_t)root) {
                    if (header_icon) {
                        uint16_t glyph = visible ? pane_text_glyph(pane) : 0;
                        g_native_view.header_icon_valid[side] =
                            visible && glyph == (side ? 0xe045 : 0xe044);
                        g_native_view.header_icon_glyph[side] = g_native_view.header_icon_valid[side] ? glyph : 0;
                        if (g_native_view.header_icon_valid[side] &&
                            (after_matrix || g_native_view.header_icon_seen[side])) {
                            float x, y;
                            memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
                            memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                            native_rect_from_pane(pane, x, y, g_native_view.header_icons[side]);
                            g_native_view.header_icon_seen[side] = frame;
                        }
                    } else {
                        g_native_view.header_text_valid[side] = visible;
                        if (visible && (after_matrix || g_native_view.header_text_seen[side])) {
                            float x, y;
                            memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
                            memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                            native_rect_from_pane(pane, x, y, g_native_view.header_texts[side]);
                            g_native_view.header_text_seen[side] = frame;
                        }
                    }
                }
                dm_botw_touch_menu_view view = snapshot_native_view_locked();
                pthread_mutex_unlock(&g_native_view_mu);
                dm_botw_touch_menu_observe(&view);
                return;
        }
    }
    // The Switch inventory's category hit target is the 32x32 B_Hit_00
    // below Pa_CategoryS_N > N_Cat_01 > N_InOutGear_01 > N_Slide_01. Capture
    // its live global matrix directly; no screen-coordinate category map.
    if (!strcmp(name, "B_Hit_00")) {
        int category = pane_category_index(pane);
        uint8_t *category_row = ancestor_named(pane, "N_Cat_01");
        uint8_t *gear = ancestor_named(pane, "N_InOutGear_01");
        uint8_t *slide = ancestor_named(pane, "N_Slide_01");
        uint8_t *root = slide ? ancestor_named(slide, "RootPane") : NULL;
        if (category >= 0 && category_row && gear && slide && root &&
            ancestor_named(pane, "N_Invalid_00")) {
            uint64_t frame = dm_guest_frame();
            pthread_mutex_lock(&g_native_view_mu);
            g_native_view.frame = frame;
            // Only the body observer establishes the inventory owner. Ignore
            // same-name trees from other live roots before they can mutate the
            // category cache; an early category callback is observed again
            // after the body owner is established.
            if (g_native_view.root != (uintptr_t)root || g_native_view.slide != (uintptr_t)slide) {
                pthread_mutex_unlock(&g_native_view_mu);
                return;
            }
            int visible = pane_chain_visible(pane) && pane_chain_visible(category_row) &&
                          pane_chain_visible(gear) && pane_chain_visible(slide);
            if (visible && (after_matrix || g_native_view.category_valid[category])) {
                float x, y;
                memcpy(&x, pane + PANE_MATRIX + 0x0c, sizeof x);
                memcpy(&y, pane + PANE_MATRIX + 0x1c, sizeof y);
                native_rect_from_pane(pane, x, y, g_native_view.categories[category]);
                g_native_view.category_valid[category] =
                    rect_intersects_canvas(g_native_view.categories[category]);
                g_native_view.category_panes[category] = (uintptr_t)pane;
                g_native_view.category_seen[category] = frame;
            } else if (!visible) {
                g_native_view.category_valid[category] = 0;
                g_native_view.category_panes[category] = 0;
            }
            dm_botw_touch_menu_view view = snapshot_native_view_locked();
            pthread_mutex_unlock(&g_native_view_mu);
            dm_botw_touch_menu_observe(&view);
            return;
        }
    }
    int guide_index = pane_guide_index(pane);
    uint8_t *guide = (back_text || back_icon) && guide_index >= 0 ? ancestor_guide(pane, guide_index) : NULL;
    uint8_t *footer_root = guide ? ancestor_named(guide, "RootPane") : NULL;
    if ((back_text || back_icon) && guide_index >= 0 && guide_index <= 4 &&
        ancestor_named(pane, "N_TitleBarDown_0") &&
        ancestor_named(pane, "N_Align_00") && guide_index >= 0 &&
        ancestor_named(pane, "N_InOut_00") && footer_root &&
        (back_text || back_icon)) {
        uint64_t frame = dm_guest_frame();
        pthread_mutex_lock(&g_native_view_mu);
        g_native_view.frame = frame;
        int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
        int footer_owner = g_native_view.footer_root == (uintptr_t)footer_root;
        int footer_unused = !g_native_view.footer_root;
        int footer_hidden = 1;
        for (int i = 0; i < 5; i++) if (g_native_view.guide_icon_valid[i] &&
            frame >= g_native_view.guide_icon_seen[i] && frame - g_native_view.guide_icon_seen[i] <= 2)
            footer_hidden = 0;
        uint16_t candidate_glyph = back_icon && visible ? pane_text_glyph(pane) : 0;
        int recognized_glyph = candidate_glyph == 0xe041 || candidate_glyph == 0xe042 || candidate_glyph == 0xe043;
        if (visible && (footer_owner || ((footer_unused || footer_hidden) && recognized_glyph))) {
            if (!footer_owner) {
                g_native_view.footer_root = (uintptr_t)footer_root;
                memset(g_native_view.guide_icon_valid, 0, sizeof g_native_view.guide_icon_valid);
                memset(g_native_view.guide_text_valid, 0, sizeof g_native_view.guide_text_valid);
                memset(g_native_view.guide_instances, 0, sizeof g_native_view.guide_instances);
                memset(g_native_view.guide_icon_glyph, 0, sizeof g_native_view.guide_icon_glyph);
            }
            if (!g_native_view.guide_instances[guide_index] ||
                g_native_view.guide_instances[guide_index] == (uintptr_t)guide)
                g_native_view.guide_instances[guide_index] = (uintptr_t)guide;
        }
        footer_owner = g_native_view.footer_root == (uintptr_t)footer_root;
        if (footer_owner && back_text && g_native_view.guide_instances[guide_index] == (uintptr_t)guide) {
            g_native_view.guide_text_valid[guide_index] = visible;
            if (visible && (after_matrix || g_native_view.guide_text_seen[guide_index])) {
                float x, y; memcpy(&x, pane + PANE_MATRIX + 0x0c, 4); memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                native_right_anchored_rect_from_pane(pane, x, y, g_native_view.guide_texts[guide_index]);
                g_native_view.guide_text_seen[guide_index] = frame;
            }
        } else if (footer_owner && back_icon && g_native_view.guide_instances[guide_index] == (uintptr_t)guide) {
            g_native_view.guide_icon_valid[guide_index] = visible;
            g_native_view.guide_icon_glyph[guide_index] = visible ? candidate_glyph : 0;
            if (visible && (after_matrix || g_native_view.guide_icon_seen[guide_index])) {
                float x, y; memcpy(&x, pane + PANE_MATRIX + 0x0c, 4); memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                native_rect_from_pane(pane, x, y, g_native_view.guide_icons[guide_index]);
                g_native_view.guide_icon_seen[guide_index] = frame;
            }
        }
        dm_botw_touch_menu_view view = snapshot_native_view_locked();
        pthread_mutex_unlock(&g_native_view_mu);
        dm_botw_touch_menu_observe(&view);
        return;
    }
    // The item-action popup is a separate root subtree from the inventory
    // slide. Its live B_Hit rows are the native tap targets; global Y sorts
    // them into the same top-to-bottom order as D-pad navigation.
    if (!strcmp(name, "B_Hit_00") && !ancestor_named(pane, "N_Slide_01") &&
        ancestor_named(pane, "N_TypeBtn_01") && ancestor_named(pane, "N_InOut_00")) {
        int row = pane_button_index(pane, "Pa_Btn_", DM_BOTW_MENU_MAX_POPUP_ROWS);
        if (row < 0) return;
        uint8_t *root = ancestor_named(pane, "N_TypeBtn_01");
        uint64_t frame = dm_guest_frame();
        pthread_mutex_lock(&g_native_view_mu);
        g_native_view.frame = frame;
        int root_visible = pane_chain_visible(root);
        int owner_visible = g_native_view.popup_visible && g_native_view.popup_root != 0 &&
                            frame >= g_native_view.popup_seen && frame - g_native_view.popup_seen <= 2;
        int root_changed = g_native_view.popup_root != (uintptr_t)root;
        if (root_changed && (!root_visible || owner_visible)) {
            pthread_mutex_unlock(&g_native_view_mu);
            return;
        }
        if (root_changed) {
            g_native_view.popup_root = (uintptr_t)root;
            memset(g_native_view.popup_row_valid, 0, sizeof g_native_view.popup_row_valid);
        }
        g_native_view.popup_seen = frame;
        int row_visible = pane_chain_visible(pane);
        if (root_changed || g_native_view.popup_visible != root_visible) g_native_view.popup_epoch++;
        g_native_view.popup_visible = root_visible;
        if (row_visible && (after_matrix || g_native_view.popup_row_valid[row])) {
            float x, y;
            memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
            memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
            native_rect_from_pane(pane, x, y, g_native_view.popup_rows[row]);
            g_native_view.popup_row_valid[row] = 1;
            g_native_view.popup_row_panes[row] = (uintptr_t)pane;
            g_native_view.popup_row_seen[row] = frame;
        } else if (!row_visible) {
            g_native_view.popup_row_valid[row] = 0;
            g_native_view.popup_row_panes[row] = 0;
        }
        int any_visible_row = 0;
        for (int i = 0; i < DM_BOTW_MENU_MAX_POPUP_ROWS; i++)
            if (g_native_view.popup_row_valid[i] && frame >= g_native_view.popup_row_seen[i] &&
                frame - g_native_view.popup_row_seen[i] <= 2) any_visible_row = 1;
        int popup_open = root_visible && any_visible_row;
        if (!root_changed && g_native_view.popup_visible != popup_open) g_native_view.popup_epoch++;
        g_native_view.popup_visible = popup_open;
        dm_botw_touch_menu_view view = snapshot_native_view_locked();
        pthread_mutex_unlock(&g_native_view_mu);
        dm_botw_touch_menu_observe(&view);
        return;
    }
    uint8_t *slide = NULL, *area = NULL, *cut = NULL, *root = NULL;
    if (!strcmp(name, "N_Slide_01")) {
        slide = pane;
        root = ancestor_named(slide, "RootPane");
    } else if (!strcmp(name, "N_InOut_00")) {
        // The leaf name repeats inside each linked item fragment. Only the
        // actual PauseMenu area pointer can pass the owner check below.
        area = pane;
        slide = ancestor_named(area, "N_Slide_01");
        root = slide ? ancestor_named(slide, "RootPane") : NULL;
    } else {
        cut = ancestor_named(pane, "N_Cut_00");
        area = cut ? ancestor_named(cut, "N_InOut_00") : NULL;
        slide = area ? ancestor_named(area, "N_Slide_01") : NULL;
        root = slide ? ancestor_named(slide, "RootPane") : NULL;
    }
    if (!slide || !root || (!area && strcmp(name, "N_Slide_01"))) return;
    uint64_t frame = dm_guest_frame();
    int changed = 0;
    dm_botw_touch_menu_view view;
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.frame = frame;
    // The three native carousel pages share Pa_Btn_NN names. Keep their slot
    // geometry separate and establish the inventory owner only from a live
    // page branch below N_Cut_00 > N_InOut_00 > N_Slide_01.
    int slot = !strcmp(name, "B_Hit_00") ? pane_slot_index(pane) : -1;
    int page_index = slot >= 0 ? pane_inventory_page_index(pane) : -1;
    uint8_t *page = page_index >= 0 ? ancestor_named(pane, page_index == 0 ? "Pa_PagePorch_00" :
        page_index == 1 ? "Pa_PagePorch_01" : "Pa_PagePorch_02") : NULL;
    if (page && cut && area && pane_chain_visible(slide) && pane_chain_visible(area) &&
        pane_chain_visible(cut)) {
        int owner_changed = g_native_view.root != (uintptr_t)root ||
                            g_native_view.slide != (uintptr_t)slide ||
                            g_native_view.item_area != (uintptr_t)area ||
                            g_native_view.cut != (uintptr_t)cut;
        if (owner_changed) {
            g_native_view.root = (uintptr_t)root;
            g_native_view.slide = (uintptr_t)slide;
            g_native_view.item_area = (uintptr_t)area;
            g_native_view.cut = (uintptr_t)cut;
            g_native_view.category_slide = (uintptr_t)slide;
            memset(g_native_view.category_valid, 0, sizeof g_native_view.category_valid);
            g_native_view.selected_page_pane = 0;
            memset(g_native_view.page_panes, 0, sizeof g_native_view.page_panes);
            memset(g_native_view.slot_valid, 0, sizeof g_native_view.slot_valid);
            memset(g_native_view.cursor_visible, 0, sizeof g_native_view.cursor_visible);
            g_native_view.clip_valid = 0;
        }
    }
    if (g_native_view.root != (uintptr_t)root || g_native_view.slide != (uintptr_t)slide ||
        (area && g_native_view.item_area != (uintptr_t)area) ||
        (cut && g_native_view.cut != (uintptr_t)cut) ||
        (!strcmp(name, "N_InOut_00") && g_native_view.item_area != (uintptr_t)pane) ||
        (!strcmp(name, "N_Cut_00") && g_native_view.cut != (uintptr_t)pane)) {
        pthread_mutex_unlock(&g_native_view_mu);
        return;
    }
    if (!strcmp(name, "N_Slide_01")) {
        g_native_view.inventory_visible = pane_chain_visible(pane);
        g_native_view.inventory_seen = frame;
        if (!g_native_view.inventory_visible) {
            g_native_view.clip_valid = 0;
            memset(g_native_view.slot_valid, 0, sizeof g_native_view.slot_valid);
            memset(g_native_view.cursor_visible, 0, sizeof g_native_view.cursor_visible);
            if (g_native_view.category_slide == (uintptr_t)pane)
                memset(g_native_view.category_valid, 0, sizeof g_native_view.category_valid);
        }
        changed = 1;
    }
    if (area && !strcmp(name, "N_InOut_00")) {
        g_native_view.inventory_visible = pane_chain_visible(pane);
        g_native_view.inventory_seen = frame;
        if (!g_native_view.inventory_visible) {
            memset(g_native_view.slot_valid, 0, sizeof g_native_view.slot_valid);
            memset(g_native_view.cursor_visible, 0, sizeof g_native_view.cursor_visible);
            g_native_view.clip_valid = 0;
        }
        changed = 1;
    }
    if (!strcmp(name, "N_Cut_00") && !after_matrix && !pane_chain_visible(pane)) {
        g_native_view.clip_valid = 0;
        g_native_view.inventory_visible = 0;
        g_native_view.inventory_seen = frame;
        memset(g_native_view.slot_valid, 0, sizeof g_native_view.slot_valid);
        memset(g_native_view.cursor_visible, 0, sizeof g_native_view.cursor_visible);
        changed = 1;
    }
    if (!strcmp(name, "N_Cut_00") && pane_chain_visible(pane) &&
        (after_matrix || g_native_view.clip_valid)) {
        float x, y; memcpy(&x, pane + PANE_MATRIX + 0x0c, 4); memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
        float r[4]; native_rect_from_pane(pane, x, y, r);
        memcpy(g_native_view.clip, r, sizeof r);
        g_native_view.clip_valid = 1; g_native_view.clip_seen = frame;
        g_native_view.inventory_visible = 1; g_native_view.inventory_seen = frame;
        changed = 1;
    }
    if (page && slot >= 0) {
        int inventory_visible = pane_chain_visible(slide) && pane_chain_visible(area) && pane_chain_visible(cut);
        g_native_view.inventory_visible = inventory_visible;
        g_native_view.inventory_seen = frame;
        if (g_native_view.page_panes[page_index] != (uintptr_t)page) {
            g_native_view.page_panes[page_index] = (uintptr_t)page;
            memset(g_native_view.slot_valid[page_index], 0, sizeof g_native_view.slot_valid[page_index]);
        }
        if (inventory_visible && pane_chain_visible(pane) &&
            (after_matrix || g_native_view.slot_valid[page_index][slot])) {
            float x, y; memcpy(&x, pane + PANE_MATRIX + 0x0c, 4); memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
            native_rect_from_pane(pane, x, y, g_native_view.slots[page_index][slot]);
            g_native_view.slot_valid[page_index][slot] = 1; g_native_view.slot_seen[page_index][slot] = frame;
            g_native_view.slot_panes[page_index][slot] = (uintptr_t)pane;
        } else {
            g_native_view.slot_valid[page_index][slot] = 0;
            g_native_view.slot_panes[page_index][slot] = 0;
        }
        // A clip callback may precede the first slot callback. Bootstrap it
        // from the slot's live N_Cut ancestor so the grid starts complete.
        if (inventory_visible && !g_native_view.clip_valid && after_matrix) {
            float x, y; memcpy(&x, cut + PANE_MATRIX + 0x0c, 4); memcpy(&y, cut + PANE_MATRIX + 0x1c, 4);
            native_rect_from_pane(cut, x, y, g_native_view.clip);
            g_native_view.clip_valid = 1; g_native_view.clip_seen = frame;
        }
        changed = 1;
    }
    pthread_mutex_unlock(&g_native_view_mu);
    if (changed) {
        pthread_mutex_lock(&g_native_view_mu);
        view = snapshot_native_view_locked();
        pthread_mutex_unlock(&g_native_view_mu);
        dm_botw_touch_menu_observe(&view);
    }
}

static pane_trace_t *trace_slot(uintptr_t pane) {
    unsigned i = (unsigned)((pane >> 4) % PANE_TRACE_SLOTS);
    for (unsigned n = 0; n < PANE_TRACE_SLOTS; n++, i = (i + 1) % PANE_TRACE_SLOTS) {
        if (!g_panes[i].pane || g_panes[i].pane == pane) {
            if (!g_panes[i].pane) g_panes[i].pane = pane;
            return &g_panes[i];
        }
    }
    return NULL;
}

void dm_botw_touch_menu_pane(const uint64_t *regs, int after_matrix) {
    if (!regs) return;
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[after_matrix ? 19 : 0];
    if (!pane) return;
    int trace = atomic_load_explicit(&g_trace, memory_order_acquire);
    if (!strcmp(DM_GAME_ID, "01007EF00011E000") && !strcmp(dm_main_build(), BOTW_BUILD) &&
        (trace || dm_botw_touch_hud_active()))
        observe_native_pane(pane, after_matrix);
    if (!trace) return;
    char path[256]; int visible, has_slide, has_item_area, has_slot;
    if (!relevant_chain(pane, path, &visible, &has_slide, &has_item_area, &has_slot)) return;
    char name[17]; pane_name(pane, name);
    uint8_t flags = pane[PANE_FLAGS];
    uint8_t marker = pane[PANE_FLAGS + 1];
    float x = 0, y = 0, width = 0, height = 0;
    memcpy(&width, pane + 0x50, sizeof width);
    memcpy(&height, pane + 0x54, sizeof height);
    if (after_matrix) {
        memcpy(&x, pane + PANE_MATRIX + 0x0c, sizeof x);
        memcpy(&y, pane + PANE_MATRIX + 0x1c, sizeof y);
    }
    int emit = 0;
    pthread_mutex_lock(&g_panes_mu);
    pane_trace_t *s = trace_slot((uintptr_t)pane);
    if (s && s->logs < 64) {
        int moved = after_matrix && s->matrix_valid &&
                    (fabsf(x - s->x) > 2.0f || fabsf(y - s->y) > 2.0f);
        // Pane flags include transient animation/dirty bits that toggle on
        // every Calculate (e.g. 0x83 -> 0x03). Only trace stable visibility
        // changes and actual global-matrix changes.
        emit = !s->logs || s->visible != (uint8_t)visible ||
               (after_matrix && (!s->matrix_valid || moved)) ||
               ((!strcmp(name, "N_Check_00") || !strcmp(name, "T_Guide_00") ||
                 !strcmp(name, "T_Icon_00")) && s->marker != marker);
        if (emit) {
            s->logs++;
            s->visible = (uint8_t)visible;
            s->marker = marker;
            if (after_matrix) { s->x = x; s->y = y; s->matrix_valid = 1; }
        }
    }
    pthread_mutex_unlock(&g_panes_mu);
    if (emit) LOG("BOTW menu trace: %s pane=%p flags=%02x marker=%02x chainVisible=%d size=%.1fx%.1f matrix=%s(%.1f,%.1f) slide=%d itemArea=%d slot=%d path=%s",
                  name, pane, flags, marker, visible, width, height,
                  after_matrix ? "global" : "pending", x, y,
                  has_slide, has_item_area, has_slot, path);
}

void dm_botw_touch_menu_install(void) {
    if (strcmp(DM_GAME_ID, "01007EF00011E000") || strcmp(dm_main_build(), BOTW_BUILD)) return;
    if (!gate_obs_present(OBS_BOTW_TOUCH_PANE) || !gate_obs_present(OBS_BOTW_TOUCH_MATRIX) ||
        !gate_obs_present(OBS_BOTW_MENU_SELECT)) return;
    gate_obs_set(OBS_BOTW_MENU_SELECT, dm_botw_touch_menu_selector);
    atomic_store_explicit(&g_selector_hook_installed, 1, memory_order_release);
    const char *trace = getenv("DM_BOTW_MENU_TRACE");
    int tracing = trace && !strcmp(trace, "1");
    atomic_store_explicit(&g_trace, tracing, memory_order_release);
    if (atomic_load_explicit(&g_trace, memory_order_acquire))
        LOG("BOTW menu trace enabled on OBS34/35 pane observations and OBS37 native box-cursor selection");
}

static uint64_t menu_render_frame(void) {
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_ready, memory_order_acquire))
        return atomic_load_explicit(&g_test_render_frame, memory_order_acquire);
#endif
    return dm_guest_frame();
}

static int menu_view_fresh_locked(uint64_t frame) {
    return g_view_valid && frame >= g_view.render_frame && frame - g_view.render_frame <= 2;
}

static int menu_view_has_visible_region(const dm_botw_touch_menu_view *view) {
    if (view->generic_mode) {
        if (!view->back_valid) return 0;
        for (int i = 0; i < view->generic_count; i++)
            if (rect_intersects_canvas(view->generic_targets[i].rect)) return 1;
        return 0;
    }
    if (view->popup_visible) return 1;
    if (!view->clip_valid || view->clip[2] <= 0 || view->clip[3] <= 0) return 0;
    return view->clip[0] < 1.0f && view->clip[1] < 1.0f &&
           view->clip[0] + view->clip[2] > 0.0f && view->clip[1] + view->clip[3] > 0.0f;
}

static int menu_active_locked(uint64_t frame) {
    if (!g_view_valid || !menu_view_fresh_locked(frame) ||
        !menu_view_has_visible_region(&g_view))
        return 0;
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_ready, memory_order_acquire)) return 1;
#endif
    if (!atomic_load_explicit(&g_selector_hook_installed, memory_order_acquire) ||
        !dm_botw_touch_hud_active()) return 0;
    return g_view.generic_mode || (g_view.inventory_visible && g_view.back_valid);
}

static int selector_span_contains(uintptr_t start, size_t span, uintptr_t p, size_t n) {
    if (!start || !span || p < start || n > span) return 0;
    return p - start <= span - n;
}

static int selector_loaded_module_range(uintptr_t p, size_t n) {
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->loaded || !m->base) continue;
        uintptr_t base = (uintptr_t)m->base;
        if (selector_span_contains(base, m->size, p, n)) return 1;
        if (m->patch_off < 0 && m->patch_len) {
            uint64_t before = (uint64_t)(-(m->patch_off + 1)) + 1;
            if (base >= before && selector_span_contains(base - (uintptr_t)before,
                                                          (size_t)m->patch_len, p, n)) return 1;
        }
    }
    return 0;
}

static int selector_range(uintptr_t p, size_t n) {
    if (!p || !n || p > UINTPTR_MAX - (n - 1)) return 0;
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_native_ready, memory_order_acquire)) return p != 0;
#endif
    if (dm_guest_as_contains(p) && dm_guest_as_contains(p + n - 1)) return 1;
    return selector_loaded_module_range(p, n);
}

static uintptr_t selector_read_ptr(uintptr_t p, size_t off) {
    uintptr_t v = 0;
    if (p && p <= UINTPTR_MAX - off && selector_range(p + off, sizeof v))
        memcpy(&v, (const void *)(p + off), sizeof v);
    return v;
}

static int selector_pane_name(uintptr_t pane, char out[17]) {
    if (!pane || pane > UINTPTR_MAX - (PANE_NAME + 16)) return 0;
    if (!selector_range(pane + PANE_NAME, 16)) return 0;
    memcpy(out, (const void *)(pane + PANE_NAME), 16);
    out[16] = 0;
    return 1;
}

static uintptr_t selector_pane_parent(uintptr_t pane) {
    if (!pane || pane > UINTPTR_MAX - (PANE_PARENT + sizeof(uintptr_t)) ||
        !selector_range(pane + PANE_PARENT, sizeof(uintptr_t))) return 0;
    return selector_read_ptr(pane, PANE_PARENT);
}

static int selector_pane_visible_alpha(uintptr_t pane, uintptr_t *out_root) {
    uintptr_t root = 0;
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++) {
        if (!selector_range(pane, PANE_NAME + 16)) return 0;
        if (!( ((const uint8_t *)pane)[PANE_FLAGS] & PANE_VISIBLE) ||
             !((const uint8_t *)pane)[PANE_FLAGS + 1]) return 0;
        char name[17];
        memcpy(name, (const void *)(pane + PANE_NAME), 16); name[16] = 0;
        if (!strcmp(name, "RootPane")) { root = pane; break; }
        pane = selector_pane_parent(pane);
    }
    if (!root) return 0;
    if (out_root) *out_root = root;
    return 1;
}

static int selector_native_input_group(uintptr_t control, uintptr_t native_group_getter,
                                       int *out_group) {
    if (!control || !native_group_getter || !selector_range(control, 0x88)) return 0;
    // F57BA0 passes manager+0x20's +0x80 child to F6E2C8. Its group mask
    // lives behind the same input-context object.
    uintptr_t input = selector_read_ptr(control, 0x80);
    uintptr_t context = selector_read_ptr(input, 0x28);
    if (!selector_range(context, 0xb1c)) return 0;
    uintptr_t groups = selector_read_ptr(context, 0xb18);
    if (!selector_range(groups, 0x15)) return 0;
    uint8_t mask = ((const uint8_t *)groups)[0x14];
    int group = ((int (*)(uintptr_t))native_group_getter)(input);
    if (group < 0 || group >= 8 || !(mask & (1u << group))) return 0;
    if (out_group) *out_group = group;
    return 1;
}

// BoxCursorControl calls this virtual predicate before adopting an entry.
// Keep the call on the native selector thread and outside g_menu_mu.
static int selector_entry_eligible(uintptr_t entry, int group) {
    uintptr_t vtable = selector_read_ptr(entry, 0);
    uintptr_t predicate = selector_read_ptr(vtable, 0x28);
    if (!entry || !predicate || group < 0 || group >= 8 || !selector_range(predicate, 4)) return 0;
    return ((int (*)(uintptr_t, int))predicate)(entry, group) != 0;
}

static uintptr_t selector_nearest_part(uintptr_t pane) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++) {
        char name[17];
        if (!selector_pane_name(pane, name)) return 0;
        if (!strcmp(name, "RootPane")) return 0;
        if (!strncmp(name, "Pa_", 3) && strncmp(name, "Pa_Rstick", 9)) return pane;
        pane = selector_pane_parent(pane);
    }
    return 0;
}

static void selector_trace_state(uintptr_t manager, uintptr_t focus, uintptr_t screen,
                                 uintptr_t vtable, uintptr_t root, int group,
                                 int input_active, int inventory_screen, int popup_active,
                                 const dm_botw_touch_menu_view *view, int view_valid) {
    if (!manager || !atomic_load_explicit(&g_trace, memory_order_acquire)) return;
    selector_trace_state_t state;
    memset(&state, 0, sizeof state);
    state.manager = manager; state.focus = focus; state.screen = screen;
    state.vtable = vtable; state.root = root; state.group = group;
    state.input_active = input_active; state.inventory_screen = inventory_screen;
    state.popup_active = popup_active; state.view_valid = view_valid;
    if (view) {
        state.generic_mode = view->generic_mode;
        state.generic_count = view->generic_count;
        state.back_valid = view->back_valid;
        state.inventory_visible = view->inventory_visible;
    }
    int changed = 1;
    pthread_mutex_lock(&g_selector_trace_mu);
    int slot = -1;
    for (int i = 0; i < 16; i++) {
        if (g_selector_trace_states[i].manager == manager && manager) { slot = i; break; }
    }
    if (slot < 0) {
        slot = (int)(g_selector_trace_next++ % 16);
    } else {
        changed = memcmp(&g_selector_trace_states[slot], &state, sizeof state) != 0;
    }
    g_selector_trace_states[slot] = state;
    pthread_mutex_unlock(&g_selector_trace_mu);
    if (!changed) return;
    int shown_fd = -1, shown_fe = -1;
    if (screen && selector_range(screen + 0xfd, 2)) {
        shown_fd = (int8_t)((const uint8_t *)screen)[0xfd];
        shown_fe = ((const uint8_t *)screen)[0xfe];
    }
    LOG("BOTW menu selector state manager=%p focus=%p screen=%p vtable=%p shown=(%d,%d) group=%d input=%d inventory=%d popup=%d root=%p view=%d generic=%d targets=%d back=%d inventoryVisible=%d",
        (void *)manager, (void *)focus, (void *)screen, (void *)vtable,
        shown_fd, shown_fe, group, input_active, inventory_screen, popup_active,
        (void *)root, view_valid, state.generic_mode, state.generic_count,
        state.back_valid, state.inventory_visible);
}

static int selector_find_generic_targets(uintptr_t manager, uintptr_t screen, int group,
                                         uintptr_t current_root,
                                         uintptr_t native_screen_shown,
                                         uintptr_t native_group_getter,
                                         dm_botw_touch_menu_view *view) {
    if (!screen || !view || !native_screen_shown || !native_group_getter ||
        !selector_range(screen, 0xa0) ||
        !((int (*)(uintptr_t))native_screen_shown)(screen)) return 0;
    uintptr_t state = selector_read_ptr(screen, 0x38);
    if (!selector_range(state, 0x39) || !(((const uint8_t *)state)[0x38] & 2) ||
        ((int (*)(uintptr_t))native_group_getter)(screen) != group) return 0;

    uintptr_t control = selector_read_ptr(manager, 0x20);
    uintptr_t model = selector_read_ptr(control, 0x80);
    uintptr_t registry = selector_read_ptr(model, 0x28);
    if (!selector_range(registry, 0x48)) return 0;
    uint32_t count = 0;
    memcpy(&count, (const void *)(registry + 0x28), sizeof count);
    uintptr_t screens = selector_read_ptr(registry, 0x30);
    uintptr_t active = selector_read_ptr(registry, 0x40);
    if (!count || count > 256 || !selector_range(screens, (size_t)count * sizeof(uintptr_t)) ||
        !selector_range(active, count)) return 0;

    generic_hit_t hits[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
    int hit_count = generic_hit_snapshot(hits, menu_render_frame());
    uintptr_t sentinel = screen + 0x88;
    uintptr_t node = selector_read_ptr(screen, 0x90);
    int32_t delta = 0;
    memcpy(&delta, (const void *)(screen + 0x9c), sizeof delta);
    if (delta < 0 || delta > 0x400 || node == sentinel) return 0;
    uintptr_t end = sentinel - (uintptr_t)delta;
    node -= (uintptr_t)delta;
    int emitted = 0, ring_found = 0;
    for (uint32_t i = 0; i < count; i++) {
        uintptr_t listed_screen = selector_read_ptr(screens, (size_t)i * sizeof(uintptr_t));
        if (listed_screen != screen) continue;
        ring_found = 1;
        if (((const uint8_t *)active)[i] & 0x80) return 0;
        break;
    }
    if (!ring_found) return 0;
    for (unsigned n = 0; n < 512 && node != end && emitted < DM_BOTW_MENU_MAX_GENERIC_TARGETS; n++) {
        uintptr_t entry = node;
        if (!selector_range(entry, (size_t)delta + 0x28)) break;
        uintptr_t owner = selector_read_ptr(entry, 0x18);
        uintptr_t entry_screen = selector_read_ptr(entry, 0x20);
        uintptr_t owner_pane = selector_read_ptr(owner, 0x60);
        if (entry_screen == screen && selector_entry_eligible(entry, group) &&
            selector_range(owner, 0x62) &&
            (owner_pane == 0 || selector_range(owner_pane, PANE_NAME + 16))) {
            uintptr_t root = 0;
            if (selector_pane_visible_alpha(owner_pane, &root) &&
                root == current_root) {
                char owner_name[17];
                if (selector_pane_name(owner_pane, owner_name)) {
                    uintptr_t part = 0;
                    int direct_hit = !strcmp(owner_name, "B_Hit_00");
                    if (direct_hit) part = owner_pane;
                    else if (!strcmp(owner_name, "N_Cursor_00")) part = selector_nearest_part(owner_pane);
                    if (part) {
                        int match = -1, matches = 0;
                        for (int h = 0; h < hit_count; h++) {
                            if (hits[h].root != root) continue;
                            int same_part = direct_hit ? hits[h].pane == part :
                                selector_nearest_part(hits[h].pane) == part;
                            if (same_part) { match = h; matches++; }
                        }
                        // Match the nearest native part, allowing wrappers
                        // such as N_Disable while avoiding ambiguous aliases.
                        if (matches == 1 && emitted < DM_BOTW_MENU_MAX_GENERIC_TARGETS) {
                            int h = match;
                            dm_botw_touch_menu_target *target = &view->generic_targets[emitted++];
                            target->pane = hits[h].pane;
                            target->owner_pane = owner_pane;
                            target->entry = entry;
                            target->root = root;
                            memcpy(target->rect, hits[h].rect, sizeof target->rect);
                        }
                    }
                }
            }
        }
        uintptr_t next = selector_read_ptr(entry, (size_t)delta + 8);
        if (!next || next < (uintptr_t)delta) break;
        node = next - (uintptr_t)delta;
    }
    view->generic_count = emitted;
    return emitted;
}

static int selector_generic_entry_live(uintptr_t manager, uintptr_t screen, uintptr_t entry,
                                      uintptr_t owner_pane) {
    if (!manager || !screen || !entry || !owner_pane || !selector_range(screen, 0xa0)) return 0;
    uintptr_t control = selector_read_ptr(manager, 0x20);
    uintptr_t model = selector_read_ptr(control, 0x80);
    uintptr_t registry = selector_read_ptr(model, 0x28);
    if (!selector_range(registry, 0x48)) return 0;
    uint32_t count = 0;
    memcpy(&count, (const void *)(registry + 0x28), sizeof count);
    uintptr_t screens = selector_read_ptr(registry, 0x30);
    uintptr_t active = selector_read_ptr(registry, 0x40);
    if (!count || count > 256 || !selector_range(screens, (size_t)count * sizeof(uintptr_t)) ||
        !selector_range(active, count)) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (selector_read_ptr(screens, (size_t)i * sizeof(uintptr_t)) != screen) continue;
        if (((const uint8_t *)active)[i] & 0x80) return 0;
        uintptr_t sentinel = screen + 0x88;
        uintptr_t node = selector_read_ptr(screen, 0x90);
        int32_t delta = 0;
        memcpy(&delta, (const void *)(screen + 0x9c), sizeof delta);
        if (delta < 0 || delta > 0x400 || node == sentinel) return 0;
        uintptr_t end = sentinel - (uintptr_t)delta;
        node -= (uintptr_t)delta;
        for (unsigned n = 0; n < 512 && node != end; n++) {
            uintptr_t candidate = node;
            if (!selector_range(candidate, (size_t)delta + 0x28)) return 0;
            if (candidate == entry && selector_read_ptr(candidate, 0x20) == screen) {
                uintptr_t owner = selector_read_ptr(candidate, 0x18);
                if (!selector_range(owner, 0x62) || selector_read_ptr(owner, 0x60) != owner_pane)
                    return 0;
                uintptr_t root = 0;
                return selector_pane_visible_alpha(owner_pane, &root);
            }
            uintptr_t next = selector_read_ptr(candidate, (size_t)delta + 8);
            if (!next || next < (uintptr_t)delta) return 0;
            node = next - (uintptr_t)delta;
        }
        return 0;
    }
    return 0;
}

static void selector_publish_generic_view(uintptr_t manager, uintptr_t screen, int group,
                                          int input_active, uintptr_t native_screen_shown,
                                          uintptr_t native_group_getter,
                                          int allow_pause_header) {
    dm_botw_touch_menu_view view = {0};
    uint64_t frame = menu_render_frame();
    view.render_frame = frame;
    view.generic_mode = 1;
    view.generic_screen = screen;
    view.generic_group = group;
    view.page_key = view.generic_key = ((uint64_t)(screen >> 4) ^ ((uint64_t)(uint32_t)group << 48));
    uintptr_t focused = selector_read_ptr(manager, 0x48);
    uintptr_t focused_owner = selector_read_ptr(focused, 0x18);
    uintptr_t focused_pane = selector_read_ptr(focused_owner, 0x60);
    selector_pane_visible_alpha(focused_pane, &view.generic_root);
    view.generic_key ^= (uint64_t)view.generic_root << 1;
    view.page_key = view.generic_key;
    if (!(input_active && screen && view.generic_root && view.generic_key &&
          selector_find_generic_targets(manager, screen, group, view.generic_root, native_screen_shown,
                                        native_group_getter, &view) > 0))
        view.generic_count = 0;
    // Generic modal rows are enabled only when the live PauseMenuInfo tree
    // also exposes its native B/Back prompt. X/Y prompts are not inherited
    // across screen owners because their action may change with the modal.
    if (view.generic_count > 0) {
        pthread_mutex_lock(&g_native_view_mu);
        dm_botw_touch_menu_view native = snapshot_native_view_locked();
        int live_back_label = 0;
        for (int i = 0; i < 5; i++) {
            if (g_native_view.guide_icon_valid[i] && g_native_view.guide_icon_glyph[i] == 0xe041 &&
                frame >= g_native_view.guide_icon_seen[i] && frame - g_native_view.guide_icon_seen[i] <= 2 &&
                g_native_view.guide_text_valid[i] && frame >= g_native_view.guide_text_seen[i] &&
                frame - g_native_view.guide_text_seen[i] <= 2) {
                live_back_label = 1;
                break;
            }
        }
        pthread_mutex_unlock(&g_native_view_mu);
        if (live_back_label && native.back_valid) {
            view.back_valid = 1;
            memcpy(view.back, native.back, sizeof view.back);
            if (allow_pause_header) {
                for (int i = 0; i < native.footer_action_count; i++) {
                    uint64_t button = native.footer_action_buttons[i];
                    if ((button != DM_BTN_L && button != DM_BTN_R) ||
                        view.footer_action_count >= DM_BOTW_MENU_MAX_FOOTER_ACTIONS) continue;
                    int at = view.footer_action_count++;
                    view.footer_action_buttons[at] = button;
                    memcpy(view.footer_actions[at], native.footer_actions[i], sizeof view.footer_actions[at]);
                }
            }
        } else {
            view.generic_count = 0;
        }
    }
    dm_botw_touch_menu_observe(&view);
    selector_trace_state(manager, focused, screen, selector_read_ptr(screen, 0),
                         view.generic_root, group, input_active, 0, 0, &view, 1);
}

static int selector_native_inventory_context(int pause_screen_class,
                                              int inventory_geometry,
                                              uintptr_t inventory_root,
                                              uintptr_t focused_root,
                                              int popup_owner) {
    return (pause_screen_class && inventory_geometry && inventory_root &&
            focused_root == inventory_root) || popup_owner;
}

static void selector_clear_generic_mode(void) {
    pthread_mutex_lock(&g_menu_mu);
    if (g_view_valid && g_view.generic_mode) {
        memset(&g_view, 0, sizeof g_view);
        g_view_valid = 0;
        menu_clear_queue_locked();
    }
    pthread_mutex_unlock(&g_menu_mu);
}

static uintptr_t selector_ancestor_named(uintptr_t pane, const char *wanted) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++) {
        char name[17];
        if (!selector_pane_name(pane, name)) return 0;
        if (!strcmp(name, wanted)) return pane;
        if (!strcmp(name, "RootPane")) return 0;
        pane = selector_pane_parent(pane);
    }
    return 0;
}

static uintptr_t selector_find_entry(uintptr_t manager, uintptr_t target_pane, int popup) {
    uintptr_t popup_button = 0, popup_root = 0;
    if (popup) {
        char name[17];
        if (!selector_pane_name(target_pane, name) || strcmp(name, "B_Hit_00")) return 0;
        popup_button = selector_pane_parent(target_pane);
        if (!selector_pane_name(popup_button, name) || strncmp(name, "Pa_Btn_", 7)) return 0;
        popup_root = selector_ancestor_named(popup_button, "N_TypeBtn_01");
        if (!popup_root || selector_ancestor_named(target_pane, "N_TypeBtn_01") != popup_root) return 0;
    }
    uintptr_t control = selector_read_ptr(manager, 0x20);
    uintptr_t model = selector_read_ptr(control, 0x80);
    uintptr_t registry = selector_read_ptr(model, 0x28);
    if (!selector_range(registry, 0x48)) return 0;
    uint32_t count = 0;
    memcpy(&count, (const void *)(registry + 0x28), sizeof count);
    uintptr_t screens = selector_read_ptr(registry, 0x30);
    uintptr_t active = selector_read_ptr(registry, 0x40);
    if (!count || count > 256 || !selector_range(screens, (size_t)count * sizeof(uintptr_t)) ||
        !selector_range(active, count)) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (((const uint8_t *)active)[i] & 0x80) continue;
        uintptr_t screen = selector_read_ptr(screens, (size_t)i * sizeof(uintptr_t));
        if (!selector_range(screen, 0xa0)) continue;
        uint8_t state_flags = 0;
        uintptr_t state = selector_read_ptr(screen, 0x38);
        if (!selector_range(state, 0x39)) continue;
        memcpy(&state_flags, (const void *)(state + 0x38), 1);
        if (!(state_flags & 2)) continue;
        uintptr_t sentinel = screen + 0x88;
        uintptr_t node = selector_read_ptr(screen, 0x90);
        int32_t delta = 0;
        memcpy(&delta, (const void *)(screen + 0x9c), sizeof delta);
        if (delta < 0 || delta > 0x400 || node == sentinel) continue;
        uintptr_t end = sentinel - (uintptr_t)delta;
        node -= (uintptr_t)delta;
        for (unsigned n = 0; n < 512 && node != end; n++) {
            uintptr_t entry = node;
            if (!selector_range(entry, (size_t)delta + 0x10)) break;
            uintptr_t owner = selector_read_ptr(entry, 0x18);
            if (selector_range(owner, 0x62)) {
                uint16_t flags = 0;
                memcpy(&flags, (const void *)(owner + 0x3a), sizeof flags);
                uintptr_t pane = selector_read_ptr(owner, 0x60);
                if (flags & 0x10) {
                    if (pane == target_pane) return entry;
                    if (popup) {
                        char pane_name_buf[17];
                        if (selector_pane_name(pane, pane_name_buf) &&
                            !strcmp(pane_name_buf, "N_Cursor_00") &&
                            selector_pane_parent(pane) == popup_button &&
                            selector_ancestor_named(pane, "N_TypeBtn_01") == popup_root)
                            return entry;
                    }
                }
            }
            uintptr_t next = selector_read_ptr(entry, (size_t)delta + 8);
            if (!next || next < (uintptr_t)delta) break;
            node = next - (uintptr_t)delta;
        }
    }
    return 0;
}

static uintptr_t selector_find_category_screen(uintptr_t manager, uintptr_t target_pane,
                                               int category, uintptr_t expected_vtable) {
    char name[17];
    if (category < 0 || category > 6 ||
        !selector_pane_name(target_pane, name) || strcmp(name, "B_Hit_00") ||
        pane_category_index((uint8_t *)target_pane) != category) return 0;
    uintptr_t control = selector_read_ptr(manager, 0x20);
    uintptr_t model = selector_read_ptr(control, 0x80);
    uintptr_t registry = selector_read_ptr(model, 0x28);
    if (!selector_range(registry, 0x48)) return 0;
    uint32_t count = 0;
    memcpy(&count, (const void *)(registry + 0x28), sizeof count);
    uintptr_t screens = selector_read_ptr(registry, 0x30);
    uintptr_t active = selector_read_ptr(registry, 0x40);
    if (!count || count > 256 || !selector_range(screens, (size_t)count * sizeof(uintptr_t)) ||
        !selector_range(active, count)) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (((const uint8_t *)active)[i] & 0x80) continue;
        uintptr_t registry_screen = selector_read_ptr(screens, (size_t)i * sizeof(uintptr_t));
        if (!selector_range(registry_screen, 0xa0)) continue;
        uintptr_t state = selector_read_ptr(registry_screen, 0x38);
        if (!selector_range(state, 0x39) || !(((const uint8_t *)state)[0x38] & 2)) continue;
        uintptr_t sentinel = registry_screen + 0x88;
        uintptr_t node = selector_read_ptr(registry_screen, 0x90);
        int32_t delta = 0;
        memcpy(&delta, (const void *)(registry_screen + 0x9c), sizeof delta);
        if (delta < 0 || delta > 0x400 || node == sentinel) continue;
        uintptr_t end = sentinel - (uintptr_t)delta;
        node -= (uintptr_t)delta;
        for (unsigned n = 0; n < 512 && node != end; n++) {
            uintptr_t entry = node;
            if (!selector_range(entry, (size_t)delta + 0x10)) break;
            uintptr_t owner = selector_read_ptr(entry, 0x18);
            if (selector_range(owner, 0x62) && selector_read_ptr(owner, 0x60) == target_pane) {
                uintptr_t screen = selector_read_ptr(entry, 0x20);
                if (selector_range(screen, 0x3a14) && selector_read_ptr(screen, 0) == expected_vtable)
                    return screen;
            }
            uintptr_t next = selector_read_ptr(entry, (size_t)delta + 8);
            if (!next || next < (uintptr_t)delta) break;
            node = next - (uintptr_t)delta;
        }
    }
    return 0;
}

static int selector_request_category(uintptr_t manager, uintptr_t pane, int category,
                                     uintptr_t expected_screen_vtable, uintptr_t native_flag_setter,
                                     uintptr_t native_commit, uintptr_t native_refresh) {
    uintptr_t screen = selector_find_category_screen(manager, pane, category, expected_screen_vtable);
    if (!screen) return 0;
    if (!selector_range(screen + 0x368c, 4) || !selector_range(screen + 0x365c, 4) ||
        !selector_range(screen + 0x3660, 4) || !selector_range(screen + 0x3664, 4) ||
        !selector_range(screen + 0x3a10, 4) ||
        !selector_range(screen + 0x3690 + (size_t)category * 0x80 + 0x7c, 4)) return 0;
    int32_t in_transition = 0, current_category = -1, first_page = -1, inventory_count = 0;
    memcpy(&in_transition, (const void *)(screen + 0x368c), 4);
    memcpy(&current_category, (const void *)(screen + 0x3a10), 4);
    memcpy(&first_page, (const void *)(screen + 0x3690 + (size_t)category * 0x80 + 0x78), 4);
    memcpy(&inventory_count, (const void *)(screen + 0x363c), 4);
    if (in_transition) return 0; // let the native carousel finish before consuming a new request
    if (current_category == category) {
        pthread_mutex_lock(&g_menu_mu);
        if (g_target_valid && g_target_category && g_target_pane == pane && g_target_index == category) {
            g_target_valid = g_target_category = g_confirm_pending = 0;
            g_target_pane = 0;
            g_target_page_key = g_target_popup_key = 0;
        }
        pthread_mutex_unlock(&g_menu_mu);
        return 2;
    }
    if (first_page < 0 || inventory_count <= 0 || first_page >= inventory_count ||
        !native_flag_setter || !native_commit || !native_refresh) return 0;

    int consume = 0;
    pthread_mutex_lock(&g_menu_mu);
    uint64_t frame = menu_render_frame();
    if (menu_active_locked(frame) && g_target_valid && g_target_category &&
        g_target_pane == pane && g_target_index == category &&
        g_target_page_key == g_view.page_key && g_target_popup_key == g_view.popup_key) {
        g_target_valid = g_target_category = g_confirm_pending = 0;
        g_target_pane = 0;
        g_target_page_key = g_target_popup_key = 0;
        consume = 1;
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (!consume) return 0;

    // OBS37 runs on the guest UI thread. Stage the same pending-page tuple
    // consumed by the native screen's vtable method, then let that method do
    // the carousel refresh, item focus and transition bookkeeping.
    int32_t selected_slot = 0;
    memcpy((void *)(screen + 0x3660), &first_page, 4);
    memcpy((void *)(screen + 0x3664), &selected_slot, 4);
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_native_ready, memory_order_acquire)) {
        g_test_category_flag_screen = screen;
        g_test_category_flag_value = 1;
        g_test_category_flag_count++;
        g_test_category_call_order[g_test_category_call_order_count++] = 1;
        int32_t request = 1;
        memcpy((void *)(screen + 0x368c), &request, 4);
        g_test_category_commit_screen = screen;
        g_test_category_commit_count++;
        g_test_category_call_order[g_test_category_call_order_count++] = 2;
        int32_t committed_page = 0;
        memcpy(&committed_page, (const void *)(screen + 0x3660), 4);
        memcpy((void *)(screen + 0x365c), &committed_page, 4);
        request = 0; memcpy((void *)(screen + 0x368c), &request, 4);
        g_test_category_refresh_screen = screen;
        g_test_category_refresh_delta = 0;
        g_test_category_refresh_count++;
        g_test_category_call_order[g_test_category_call_order_count++] = 3;
    } else
#endif
    {
        ((void (*)(uintptr_t, int))native_flag_setter)(screen, 1);
        ((void (*)(uintptr_t))native_commit)(screen);
        ((void (*)(uintptr_t, int8_t))native_refresh)(screen, 0);
    }
    return 1;
}

void dm_botw_touch_menu_selector(const uint64_t *regs) {
    if (!regs || strcmp(DM_GAME_ID, "01007EF00011E000") || strcmp(dm_main_build(), BOTW_BUILD)) return;
    uintptr_t manager = (uintptr_t)regs[0];
    if (!selector_range(manager, 0x58)) return;
    module_t *main = NULL;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) { main = &g_mod[i]; break; }
    uintptr_t vtable = selector_read_ptr(manager, 0);
    if (!main || vtable != (uintptr_t)(main->base + 0x1d0cdf8)) {
        if (atomic_load_explicit(&g_trace, memory_order_acquire) && g_selector_bad_manager != manager) {
            g_selector_bad_manager = manager;
            LOG("BOTW menu selector ignored manager=%p vtable=%p; expected the build-gated BoxCursorControl vtable",
                (void *)manager, (void *)vtable);
        }
        return;
    }
    uint64_t frame = menu_render_frame();
    uintptr_t control = selector_read_ptr(manager, 0x20);
    uintptr_t native_group_getter = (uintptr_t)(main->base + 0xf6e2c8);
    uintptr_t native_screen_shown = (uintptr_t)(main->base + 0xf6e08c);
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_generic_selector, memory_order_acquire)) {
        native_group_getter = g_test_native_group_getter;
        native_screen_shown = g_test_native_screen_shown;
    }
#endif
    int group = -1;
    int input_active = selector_native_input_group(control, native_group_getter, &group);
    uintptr_t focus_entry = selector_read_ptr(manager, 0x48);
    uintptr_t focus_screen = selector_read_ptr(focus_entry, 0x20);
    uintptr_t focus_vtable = selector_read_ptr(focus_screen, 0);
    dm_botw_touch_menu_view native_view = {0};
    uintptr_t native_inventory_root = 0, native_popup_root = 0;
    pthread_mutex_lock(&g_native_view_mu);
    native_view = snapshot_native_view_locked();
    native_inventory_root = g_native_view.root;
    native_popup_root = g_native_view.popup_root;
    pthread_mutex_unlock(&g_native_view_mu);
    int native_view_fresh = frame >= native_view.render_frame && frame - native_view.render_frame <= 2;
    uintptr_t focus_owner = selector_read_ptr(focus_entry, 0x18);
    uintptr_t focus_pane = selector_read_ptr(focus_owner, 0x60);
    uintptr_t focus_root = 0;
    selector_pane_visible_alpha(focus_pane, &focus_root);
    int pause_screen_class = focus_vtable == (uintptr_t)(main->base + 0x1cf9ad8);
    // PauseMenu owns several tabs with the same screen vtable. Only route the
    // inventory adapter when its own fresh clip is on-canvas and the focused
    // native owner belongs to that inventory root. A visible native item
    // popup is the other proven inventory-owned state.
    int inventory_geometry = native_view_fresh && native_view.inventory_visible &&
        native_view.clip_valid && rect_intersects_canvas(native_view.clip);
    uintptr_t focused_popup_root = selector_ancestor_named(focus_pane, "N_TypeBtn_01");
    int popup_context = native_view_fresh && native_view.popup_visible && native_popup_root &&
        focused_popup_root == native_popup_root;
    int inventory_screen = selector_native_inventory_context(pause_screen_class,
        inventory_geometry, native_inventory_root, focus_root, popup_context);
    int specialized_inventory = inventory_screen || popup_context;
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_native_ready, memory_order_acquire) &&
        !atomic_load_explicit(&g_test_generic_selector, memory_order_acquire)) {
        inventory_screen = specialized_inventory = 1;
        pthread_mutex_lock(&g_menu_mu);
        native_view = g_view;
        pthread_mutex_unlock(&g_menu_mu);
        native_view_fresh = 1;
    }
#endif
    int inventory_active = specialized_inventory && native_view_fresh &&
        native_view.back_valid && menu_view_has_visible_region(&native_view) &&
        dm_botw_touch_hud_active() &&
        atomic_load_explicit(&g_selector_hook_installed, memory_order_acquire);
    int popup_active = inventory_active && native_view.popup_visible;

    if (!inventory_screen && !popup_active) {
        selector_publish_generic_view(manager, focus_screen, group, input_active,
                                      native_screen_shown, native_group_getter, pause_screen_class);
        uintptr_t target_entry = 0, target_owner = 0, target_screen = 0, target_pane = 0, target_root = 0;
        uint64_t target_key = 0;
        int pending = 0;
        pthread_mutex_lock(&g_menu_mu);
        if (menu_active_locked(frame) && g_target_valid && g_target_generic &&
            g_target_page_key == g_view.page_key && g_target_popup_key == g_view.popup_key &&
            g_target_screen == g_view.generic_screen) {
            pending = 1;
            target_entry = g_target_entry;
            target_owner = g_target_owner_pane;
            target_screen = g_target_screen;
            target_pane = g_target_pane;
            target_root = g_target_root;
            target_key = g_view.generic_key;
            if (g_selector_manager != manager) {
                g_selector_manager = manager;
                g_requested_entry = 0;
                g_selector_ready = 0;
            }
        }
        pthread_mutex_unlock(&g_menu_mu);
        if (!pending || target_screen != focus_screen || !input_active ||
            !((int (*)(uintptr_t))native_screen_shown)(focus_screen) ||
            !selector_generic_entry_live(manager, target_screen, target_entry, target_owner)) return;
        if (!selector_entry_eligible(target_entry, group)) {
            pthread_mutex_lock(&g_menu_mu);
            if (g_target_valid && g_target_generic && g_target_entry == target_entry)
                menu_clear_queue_locked();
            pthread_mutex_unlock(&g_menu_mu);
            return;
        }
        if (focus_entry == target_entry) {
            pthread_mutex_lock(&g_menu_mu);
            if (g_target_valid && g_target_generic && g_target_pane == target_pane &&
                g_target_page_key == target_key && g_target_root == target_root &&
                g_view.generic_root == target_root && g_view.generic_group == group) {
                g_requested_entry = target_entry;
                g_selector_ready = 1;
                g_generic_eligible_frame = frame;
                g_generic_eligible_entry = target_entry;
                g_generic_eligible_screen = target_screen;
                g_generic_eligible_root = target_root;
                g_generic_eligible_group = group;
            }
            pthread_mutex_unlock(&g_menu_mu);
            return;
        }
        pthread_mutex_lock(&g_menu_mu);
        if (menu_active_locked(frame) && g_target_valid && g_target_generic &&
            g_target_pane == target_pane && g_target_entry == target_entry &&
            g_target_screen == target_screen && g_target_page_key == target_key &&
            g_selector_manager == manager) {
            g_requested_entry = target_entry;
            g_selector_ready = 0;
            g_generic_eligible_frame = 0;
            if (selector_range(manager + 0x50, sizeof target_entry))
                memcpy((void *)(manager + 0x50), &target_entry, sizeof target_entry);
        }
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (specialized_inventory) {
        selector_clear_generic_mode();
        // Re-publish the independent native observation when returning from
        // a generic Pause tab; generic snapshots intentionally suppress late
        // inventory-pane publications.
        dm_botw_touch_menu_observe(&native_view);
        dm_botw_touch_menu_view current = {0};
        int current_valid = 0;
        pthread_mutex_lock(&g_menu_mu);
        if (g_view_valid) { current = g_view; current_valid = 1; }
        pthread_mutex_unlock(&g_menu_mu);
        selector_trace_state(manager, focus_entry, focus_screen, focus_vtable,
                             focus_root, group, input_active, 1, popup_active,
                             current_valid ? &current : NULL, current_valid);
    }

    pthread_mutex_lock(&g_menu_mu);
    if (!menu_active_locked(frame) || !g_target_valid || !g_target_pane ||
        g_target_page_key != g_view.page_key || g_target_popup_key != g_view.popup_key) {
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    uintptr_t pane = g_target_pane;
    int category = g_target_category, popup = g_target_popup, index = g_target_index;
    if (g_selector_manager != manager) {
        g_selector_manager = manager;
        g_requested_entry = 0;
        g_selector_ready = 0;
    }
    pthread_mutex_unlock(&g_menu_mu);

    if (category) {
        uintptr_t screen_vtable = (uintptr_t)(main->base + 0x1cf9ad8);
        uintptr_t native_flag_setter = (uintptr_t)(main->base + 0xe39c08);
        uintptr_t native_commit = (uintptr_t)(main->base + 0xe3b9f0);
        uintptr_t native_refresh = (uintptr_t)(main->base + 0xe3ddcc);
        int result = selector_request_category(manager, pane, index, screen_vtable,
                                               native_flag_setter, native_commit, native_refresh);
        if (result && atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW menu selector %s native category=%d pane=%p",
                result == 1 ? "refreshed" : "already on", index, (void *)pane);
        return;
    }

    uintptr_t entry = selector_find_entry(manager, pane, popup);
    if (!entry) {
        int report = 0;
        pthread_mutex_lock(&g_menu_mu);
        if (g_selector_miss_pane != pane || g_selector_miss_page != g_target_page_key ||
            g_selector_miss_popup != g_target_popup_key) {
            g_selector_miss_pane = pane;
            g_selector_miss_page = g_target_page_key;
            g_selector_miss_popup = g_target_popup_key;
            report = 1;
        }
        uint64_t miss_page = g_selector_miss_page, miss_popup = g_selector_miss_popup;
        pthread_mutex_unlock(&g_menu_mu);
        if (report && atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW menu selector found no live entry for pane=%p page=%llx popup=%llx",
                (void *)pane, (unsigned long long)miss_page, (unsigned long long)miss_popup);
        return;
    }
    g_selector_miss_pane = 0;
    uintptr_t focused = selector_read_ptr(manager, 0x48);
    if (focused == entry) {
        pthread_mutex_lock(&g_menu_mu);
        int newly_focused = !g_selector_ready;
        if (g_target_valid && g_target_pane == pane && g_selector_manager == manager) {
            g_requested_entry = entry;
            g_selector_ready = 1;
        }
        pthread_mutex_unlock(&g_menu_mu);
        if (newly_focused && atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW menu selector focused pane=%p entry=%p category=%d popup=%d index=%d",
                (void *)pane, (void *)entry, category, popup, index);
        return;
    }

    pthread_mutex_lock(&g_menu_mu);
    int new_request = g_requested_entry != entry;
    if (menu_active_locked(frame) && g_target_valid && g_target_pane == pane &&
        g_target_page_key == g_view.page_key && g_target_popup_key == g_view.popup_key &&
        g_selector_manager == manager) {
        g_requested_entry = entry;
        g_selector_ready = 0;
        if (selector_range(manager + 0x50, sizeof entry))
            memcpy((void *)(manager + 0x50), &entry, sizeof entry);
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (new_request && atomic_load_explicit(&g_trace, memory_order_acquire))
        LOG("BOTW menu selector requested pane=%p entry=%p category=%d popup=%d index=%d",
            (void *)pane, (void *)entry, category, popup, index);
}

static void menu_clear_queue_locked(void) {
    g_pointer_down = g_pointer_dragged = 0;
    g_target_valid = g_target_popup = g_confirm_pending = 0;
    g_target_button_bits = 0;
    g_target_category = g_target_generic = g_selector_ready = 0;
    g_target_pane = g_target_owner_pane = g_target_entry = g_target_screen = 0;
    g_target_root = 0;
    g_generic_eligible_frame = 0;
    g_generic_eligible_entry = g_generic_eligible_screen = g_generic_eligible_root = 0;
    g_generic_eligible_group = -1;
    g_requested_entry = g_selector_manager = 0;
    g_target_page_key = g_target_popup_key = 0;
}

void dm_botw_touch_menu_observe(const dm_botw_touch_menu_view *view) {
    int notify = 0;
    dm_botw_touch_menu_view report = {0};
    uint64_t frame = menu_render_frame();
    pthread_mutex_lock(&g_menu_mu);
    int was_active = menu_active_locked(frame);
    int late_inventory_view = view && !view->generic_mode && g_view_valid && g_view.generic_mode &&
                              menu_view_fresh_locked(frame);
    if (late_inventory_view) {
        // The native focus screen is a modal authority; late inventory pane
        // callbacks must not replace its same-frame generic hit map.
    } else if (view && view->slot_count >= 0 && view->slot_count <= DM_BOTW_MENU_MAX_SLOTS &&
        view->category_count >= 0 && view->category_count <= DM_BOTW_MENU_MAX_CATEGORIES &&
        view->popup_count >= 0 && view->popup_count <= DM_BOTW_MENU_MAX_POPUP_ROWS &&
        view->footer_action_count >= 0 && view->footer_action_count <= DM_BOTW_MENU_MAX_FOOTER_ACTIONS &&
        view->generic_count >= 0 && view->generic_count <= DM_BOTW_MENU_MAX_GENERIC_TARGETS) {
        g_view = *view;
        g_view_valid = 1;
    } else {
        memset(&g_view, 0, sizeof g_view);
        g_view_valid = 0;
    }
    int is_active = menu_active_locked(frame);
    if (view) report = g_view;
    if (!is_active) menu_clear_queue_locked();
    if (was_active != is_active || g_active_notified != is_active) {
        g_active_notified = is_active;
        notify = 1;
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (notify) {
        if (atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW menu snapshot: active=%d inventory=%d popup=%d cursor=%d back=%d slots=%d popupRows=%d frame=%llu",
                is_active, report.inventory_visible, report.popup_visible, report.cursor_valid,
                report.back_valid, report.slot_count, report.popup_count,
                (unsigned long long)report.render_frame);
        front_botw_touch_menu_changed();
    }
}

int dm_botw_touch_menu_active(void) {
    int active, notify = 0;
    pthread_mutex_lock(&g_menu_mu);
    active = menu_active_locked(menu_render_frame());
    if (!active && g_active_notified) {
        g_active_notified = 0;
        menu_clear_queue_locked();
        notify = 1;
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (notify) front_botw_touch_menu_changed();
    return active;
}

static int point_in_rect(float x, float y, const float rect[4]) {
    return rect[2] > 0 && rect[3] > 0 && x >= rect[0] && y >= rect[1] &&
           x < rect[0] + rect[2] && y < rect[1] + rect[3];
}

static int hit_rects(float x, float y, const float rects[][4], int count) {
    for (int i = 0; i < count; i++) if (point_in_rect(x, y, rects[i])) return i;
    return -1;
}

static int clipped_hit(float x, float y, const float rect[4], const dm_botw_touch_menu_view *view) {
    if (!point_in_rect(x, y, rect)) return 0;
    if (!view->clip_valid) return 1;
    if (!point_in_rect(x, y, view->clip)) return 0;
    float left = fmaxf(rect[0], view->clip[0]);
    float top = fmaxf(rect[1], view->clip[1]);
    float right = fminf(rect[0] + rect[2], view->clip[0] + view->clip[2]);
    float bottom = fminf(rect[1] + rect[3], view->clip[1] + view->clip[3]);
    float visible = fmaxf(0, right - left) * fmaxf(0, bottom - top);
    return visible >= rect[2] * rect[3] * .5f;
}

static int hit_slots(float x, float y, const dm_botw_touch_menu_view *view) {
    for (int i = 0; i < view->slot_count; i++)
        if (clipped_hit(x, y, view->slots[i], view)) return i;
    return -1;
}


void dm_botw_touch_menu_pointer(int phase, float x, float y) {
    pthread_mutex_lock(&g_menu_mu);
    uint64_t frame = menu_render_frame();
    if (!menu_active_locked(frame)) {
        menu_clear_queue_locked();
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (phase == DM_BOTW_MENU_CANCEL) {
        menu_clear_queue_locked();
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
        if (phase == DM_BOTW_MENU_END || phase == DM_BOTW_MENU_CANCEL)
            menu_clear_queue_locked();
        g_pointer_down = 0;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (phase == DM_BOTW_MENU_BEGIN) {
        menu_clear_queue_locked();
        g_pointer_down = 1;
        g_pointer_start[0] = x; g_pointer_start[1] = y;
        g_pointer_page_key = g_view.page_key;
        g_pointer_popup_key = g_view.popup_key;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (!g_pointer_down) { pthread_mutex_unlock(&g_menu_mu); return; }
    if (g_pointer_page_key != g_view.page_key || g_pointer_popup_key != g_view.popup_key) {
        menu_clear_queue_locked();
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (phase == DM_BOTW_MENU_MOVE) {
        double dx = (double)(x - g_pointer_start[0]) * 1280.0;
        double dy = (double)(y - g_pointer_start[1]) * 720.0;
        if (dx * dx + dy * dy >= 64.0) g_pointer_dragged = 1;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (phase != DM_BOTW_MENU_END) { pthread_mutex_unlock(&g_menu_mu); return; }
    g_pointer_down = 0;
    int target = -1;
    double end_dx = (double)(x - g_pointer_start[0]) * 1280.0;
    double end_dy = (double)(y - g_pointer_start[1]) * 720.0;
    if (end_dx * end_dx + end_dy * end_dy >= 64.0) g_pointer_dragged = 1;
    if (g_view.generic_mode) {
        if (!g_pointer_dragged) {
            int tapped_target = 0;
            for (int i = 0; i < g_view.generic_count; i++) {
                if (!point_in_rect(x, y, g_view.generic_targets[i].rect)) continue;
                const dm_botw_touch_menu_target *hit = &g_view.generic_targets[i];
                g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                g_target_category = g_selector_ready = 0;
                g_target_index = i;
                g_target_pane = hit->pane;
                g_target_owner_pane = hit->owner_pane;
                g_target_entry = hit->entry;
                g_target_screen = g_view.generic_screen;
                g_target_root = hit->root;
                g_requested_entry = 0;
                g_target_page_key = g_view.generic_key;
                g_target_popup_key = g_view.popup_key;
                g_target_center[0] = hit->rect[0] + hit->rect[2] * .5f;
                g_target_center[1] = hit->rect[1] + hit->rect[3] * .5f;
                g_confirm_pending = 1;
                tapped_target = 1;
                break;
            }
            if (!tapped_target && g_view.back_valid && point_in_rect(x, y, g_view.back)) {
                g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                g_target_category = g_selector_ready = 0;
                g_target_index = -1; g_target_pane = g_target_owner_pane = g_target_entry = 0;
                g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                g_requested_entry = 0; g_confirm_pending = 0;
                g_target_page_key = g_view.generic_key; g_target_popup_key = g_view.popup_key;
            } else if (!tapped_target &&
                       (target = hit_rects(x, y, g_view.footer_actions, g_view.footer_action_count)) >= 0) {
                uint64_t button = g_view.footer_action_buttons[target];
                if (button == DM_BTN_L || button == DM_BTN_R) {
                    g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                    g_target_category = g_selector_ready = 0;
                    g_target_index = -3; g_target_pane = g_target_owner_pane = g_target_entry = 0;
                    g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                    g_requested_entry = 0; g_target_button_bits = button; g_confirm_pending = 0;
                    g_target_page_key = g_view.generic_key; g_target_popup_key = g_view.popup_key;
                }
            }
        }
        g_pointer_dragged = 0;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (g_view.popup_visible && g_pointer_dragged) {
        menu_clear_queue_locked();
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (!g_view.popup_visible && g_pointer_dragged && g_view.clip_valid &&
        point_in_rect(g_pointer_start[0], g_pointer_start[1], g_view.clip) &&
        point_in_rect(x, y, g_view.clip) && fabs(end_dx) >= 40.0 && fabs(end_dx) >= 1.5 * fabs(end_dy)) {
        // The native inventory's category row is navigated by R-stick; a
        // horizontal swipe advances exactly one native category/tab edge.
        g_target_valid = 1; g_target_index = -2; g_target_popup = 0;
        g_target_axis = end_dx < 0 ? DM_STICK_MAX : -DM_STICK_MAX;
        g_confirm_pending = 0;
        g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
        g_pointer_dragged = 0;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (g_view.popup_visible) {
        target = hit_rects(x, y, g_view.popup_rows, g_view.popup_count);
        if (target >= 0 && g_view.popup_row_panes[target]) {
            g_target_popup = 1; g_target_index = target; g_target_valid = 1;
            g_target_generic = 0;
            g_target_pane = g_view.popup_row_panes[target];
            g_target_category = g_selector_ready = 0; g_requested_entry = 0;
            g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            g_target_center[0] = g_view.popup_rows[target][0] + g_view.popup_rows[target][2] * .5f;
            g_target_center[1] = g_view.popup_rows[target][1] + g_view.popup_rows[target][3] * .5f;
            g_confirm_pending = 1;
        } else if (!g_pointer_dragged && g_view.back_valid && point_in_rect(x, y, g_view.back)) {
            g_target_valid = 1; g_target_popup = 0; g_target_index = -1;
            g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            g_confirm_pending = 0;
        } else {
            // In the native item popup, tapping outside its actions is Back.
            g_target_valid = 1; g_target_popup = 0; g_target_index = -1;
            g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            g_confirm_pending = 0;
        }
    } else if ((target = hit_rects(x, y, g_view.categories, g_view.category_count)) >= 0 &&
               g_view.category_panes[target]) {
        g_target_valid = 1; g_target_popup = 0; g_target_index = g_view.category_ids[target];
        g_target_generic = 0;
        g_target_category = 1; g_target_pane = g_view.category_panes[target];
        g_requested_entry = 0; g_selector_ready = 0; g_confirm_pending = 0;
        g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
    } else {
        target = hit_slots(x, y, &g_view);
        if (target >= 0 && g_view.slot_panes[target]) {
            g_target_popup = 0; g_target_index = target; g_target_valid = 1;
            g_target_generic = 0;
            g_target_pane = g_view.slot_panes[target];
            g_target_category = g_selector_ready = 0; g_requested_entry = 0;
            g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            g_target_center[0] = g_view.slots[target][0] + g_view.slots[target][2] * .5f;
            g_target_center[1] = g_view.slots[target][1] + g_view.slots[target][3] * .5f;
            // A drag selects the destination only. A tap selects and opens
            // the game's native item-action popup after the cursor arrives.
            g_confirm_pending = !g_pointer_dragged;
        } else if (!g_pointer_dragged && g_view.back_valid && point_in_rect(x, y, g_view.back)) {
            g_target_valid = 1; g_target_popup = 0; g_target_index = -1;
            g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            g_confirm_pending = 0;
        } else if (!g_pointer_dragged &&
                   (target = hit_rects(x, y, g_view.footer_actions, g_view.footer_action_count)) >= 0) {
            g_target_valid = 1; g_target_popup = 0; g_target_index = -3;
            g_target_category = g_selector_ready = 0; g_target_pane = g_requested_entry = 0;
            g_target_button_bits = g_view.footer_action_buttons[target];
            g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            g_confirm_pending = 0;
        }
    }
    g_pointer_dragged = 0;
    pthread_mutex_unlock(&g_menu_mu);
}

int dm_botw_touch_menu_apply(uint64_t *buttons, int32_t axes[4], uint64_t frame) {
    if (!buttons || !axes) return 0;
    uint64_t render_frame = menu_render_frame();
    uint64_t emit = 0;
    int notify = 0;
    pthread_mutex_lock(&g_menu_mu);
    if (!menu_active_locked(render_frame)) {
        menu_clear_queue_locked();
        g_release_pending = g_axis_release_pending = 0;
        if (g_active_notified) { g_active_notified = 0; notify = 1; }
        pthread_mutex_unlock(&g_menu_mu);
        if (notify) front_botw_touch_menu_changed();
        return 0;
    }
    if (g_last_apply_valid && g_last_apply_frame == frame) {
        *buttons |= g_apply_output_bits;
        if (g_apply_output_axis_valid) {
            axes[2] = g_apply_output_rx; axes[3] = 0;
            pthread_mutex_unlock(&g_menu_mu);
            return 1;
        }
        pthread_mutex_unlock(&g_menu_mu);
        return 0;
    }
    g_last_apply_valid = 1; g_last_apply_frame = frame;
    g_apply_output_bits = 0;
    g_apply_output_axis_valid = 0;
    if (g_release_pending) {
        g_release_pending = 0;
        int axis_released = g_axis_release_pending;
        if (axis_released) {
            g_axis_release_pending = 0;
            axes[2] = 0; axes[3] = 0;
            g_apply_output_axis_valid = 1; g_apply_output_rx = 0;
        }
        pthread_mutex_unlock(&g_menu_mu);
        return axis_released;
    }
    if (g_target_valid && (g_target_page_key != g_view.page_key ||
                           g_target_popup_key != g_view.popup_key))
        menu_clear_queue_locked();
    if (g_target_valid && g_target_index == -3) {
        int action_still_visible = 0;
        for (int i = 0; i < g_view.footer_action_count; i++)
            if (g_view.footer_action_buttons[i] == g_target_button_bits) action_still_visible = 1;
        if (!action_still_visible) menu_clear_queue_locked();
    }
    if (!g_target_valid) { pthread_mutex_unlock(&g_menu_mu); return 0; }
    if (g_target_pane) {
        if (!g_selector_ready || !g_requested_entry || !selector_range(g_selector_manager, 0x58)) {
            pthread_mutex_unlock(&g_menu_mu);
            return 0;
        }
        int native_target_live = g_target_generic ?
            (g_view.generic_mode && g_view.generic_key == g_target_page_key &&
             g_view.generic_screen == g_target_screen &&
             g_view.generic_root == g_target_root &&
             frame >= g_generic_eligible_frame && frame - g_generic_eligible_frame <= 1 &&
             g_generic_eligible_entry == g_target_entry &&
             g_generic_eligible_screen == g_target_screen &&
             g_generic_eligible_root == g_target_root &&
             g_generic_eligible_group == g_view.generic_group &&
             (int8_t)((const uint8_t *)g_target_screen)[0xfd] >= 0 &&
             ((const uint8_t *)g_target_screen)[0xfe] == 2 &&
             selector_generic_entry_live(g_selector_manager, g_target_screen,
                                         g_target_entry, g_target_owner_pane)) :
            (selector_find_entry(g_selector_manager, g_target_pane, g_target_popup) == g_requested_entry);
        if (!native_target_live) {
            pthread_mutex_unlock(&g_menu_mu);
            return 0;
        }
        uintptr_t focused = selector_read_ptr(g_selector_manager, 0x48);
        if (focused != g_requested_entry ||
            (!g_target_generic && selector_find_entry(g_selector_manager, g_target_pane, g_target_popup) != g_requested_entry)) {
            pthread_mutex_unlock(&g_menu_mu);
            return 0;
        }
        if (g_target_category || !g_confirm_pending) {
            menu_clear_queue_locked();
        } else if (!(*buttons & DM_BTN_A)) {
            emit = DM_BTN_A;
            menu_clear_queue_locked();
        }
    } else if (g_target_index < 0) {
        if (g_target_index == -2) {
            axes[2] = g_target_axis; axes[3] = 0;
            g_apply_output_axis_valid = 1; g_apply_output_rx = g_target_axis;
            g_release_pending = g_axis_release_pending = 1;
            if (atomic_load_explicit(&g_trace, memory_order_acquire))
                LOG("BOTW menu emit frame=%llu rightX=%d cursor=(%.4f,%.4f) target=category-swipe",
                    (unsigned long long)frame, g_target_axis, g_view.cursor[0], g_view.cursor[1]);
            g_target_valid = 0; g_target_axis = 0;
            pthread_mutex_unlock(&g_menu_mu);
            return 1;
        } else if (g_target_index == -3) {
            if (g_target_button_bits && !(*buttons & g_target_button_bits)) emit = g_target_button_bits;
            g_target_valid = 0; g_target_button_bits = 0;
        } else {
            if (!(*buttons & DM_BTN_B)) emit = DM_BTN_B;
            g_target_valid = 0;
        }
    }
    if (emit) {
        *buttons |= emit;
        g_apply_output_bits = emit;
        g_release_pending = 1;
        g_last_action_bits = emit;
        g_last_action_frame = frame;
        if (atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW menu emit frame=%llu buttons=%llx target=%d popup=%d cursor=(%.4f,%.4f) center=(%.4f,%.4f)",
                (unsigned long long)frame, (unsigned long long)emit, g_target_index,
                g_target_popup, g_view.cursor[0], g_view.cursor[1],
                g_target_center[0], g_target_center[1]);
    }
    pthread_mutex_unlock(&g_menu_mu);
    return 0;
}
void dm_botw_touch_menu_reset(void) {
    int notify;
    pthread_mutex_lock(&g_menu_mu);
    notify = g_active_notified;
    memset(&g_view, 0, sizeof g_view); g_view_valid = 0;
    menu_clear_queue_locked();
    g_last_apply_valid = 0; g_last_action_bits = 0;
    g_apply_output_bits = 0; g_release_pending = g_axis_release_pending = 0;
    g_apply_output_axis_valid = 0; g_apply_output_rx = 0;
    g_active_notified = 0;
    pthread_mutex_unlock(&g_menu_mu);
    pthread_mutex_lock(&g_native_view_mu);
    memset(&g_native_view, 0, sizeof g_native_view);
    pthread_mutex_unlock(&g_native_view_mu);
    pthread_mutex_lock(&g_generic_hits_mu);
    memset(g_generic_hits, 0, sizeof g_generic_hits);
    pthread_mutex_unlock(&g_generic_hits_mu);
    if (notify) front_botw_touch_menu_changed();
}

#ifdef DM_TEST_HOOKS
void dm_botw_touch_menu_test_publish(const dm_botw_touch_menu_view *view) {
    atomic_store_explicit(&g_test_ready, 1, memory_order_release);
    if (view) atomic_store_explicit(&g_test_render_frame, view->render_frame, memory_order_release);
    dm_botw_touch_menu_observe(view);
}
void dm_botw_touch_menu_test_set_render_frame(uint64_t frame) {
    atomic_store_explicit(&g_test_render_frame, frame, memory_order_release);
}
void dm_botw_touch_menu_test_set_native_ready(int ready) {
    atomic_store_explicit(&g_test_native_ready, ready, memory_order_release);
}
void dm_botw_touch_menu_test_set_generic_selector(int enabled,
                                                   uintptr_t group_getter,
                                                   uintptr_t screen_shown) {
    g_test_native_group_getter = group_getter;
    g_test_native_screen_shown = screen_shown;
    atomic_store_explicit(&g_test_generic_selector, enabled, memory_order_release);
}
uint64_t dm_botw_touch_menu_test_last_action(uint64_t *frame) {
    pthread_mutex_lock(&g_menu_mu);
    uint64_t bits = g_last_action_bits;
    if (frame) *frame = g_last_action_frame;
    pthread_mutex_unlock(&g_menu_mu);
    return bits;
}
void dm_botw_touch_menu_test_snapshot(dm_botw_touch_menu_view *view) {
    if (!view) return;
    pthread_mutex_lock(&g_menu_mu);
    *view = g_view;
    pthread_mutex_unlock(&g_menu_mu);
}
void dm_botw_touch_menu_test_back_rect(const float text[4], const float icon[4],
                                       float nearest_left, float nearest_right, float out[4]) {
    back_hit_rect(text, icon, nearest_left, nearest_right, out);
}
#endif
