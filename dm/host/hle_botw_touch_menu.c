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
       INVENTORY_PAGE_COUNT = 3, GUIDE_SLOTS = 6,
       PANE_VISIBLE = 1, PANE_TRACE_SLOTS = 2048, PANE_PATH_DEPTH = 14 };
enum { LIST_WIDGET_CACHE_SLOTS = 8, BOTW_LIST_WIDGET_VTABLE = 0x1cdbb38,
       BOTW_LIST_WIDGET_UPDATE = 0xd6f034, BOTW_LIST_WIDGET_VTABLE_SLOT = 0x40 };
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
    uintptr_t footer_root, guide_instances[GUIDE_SLOTS];
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
    uint8_t guide_icon_valid[GUIDE_SLOTS], guide_text_valid[GUIDE_SLOTS];
    uint64_t guide_icon_seen[GUIDE_SLOTS];
    uint64_t guide_text_seen[GUIDE_SLOTS];
    uint16_t guide_icon_glyph[GUIDE_SLOTS];
    float guide_icons[GUIDE_SLOTS][4], guide_texts[GUIDE_SLOTS][4];
    float cursor_xy[4][2];
    uint8_t cursor_visible[4];
    uint64_t cursor_seen[4];
    uintptr_t header_root, header_capture_dest[2];
    uintptr_t header_capture_source[2], header_capture_icon_pane[2], header_capture_text_pane[2];
    uintptr_t header_capture_icon_parent[2], header_capture_text_parent[2];
    int header_capture_mode;
    uintptr_t map_candidate_pane, map_candidate_root;
    int map_candidate_visible;
    uint64_t map_candidate_seen;
    float map_candidate_rect[4];
    uintptr_t map_transform_pane, map_transform_root;
    uintptr_t map_transform_map_pane;
    uint64_t map_transform_seen;
    float map_transform[6];
    uint8_t header_icon_valid[2], header_text_valid[2];
    uint64_t header_icon_seen[2], header_text_seen[2];
    uint16_t header_icon_glyph[2];
    uintptr_t header_text_pane[2];
    float header_icons[2][4], header_texts[2][4];
} g_native_view;
static pthread_mutex_t g_native_view_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int valid[2][2], visible[2][2];
    uint16_t glyph[2][2];
    uintptr_t root[2][2];
    int action_valid[2];
    float action_icon[2][4], action_text[2][4];
    int map_valid, map_visible;
    float map_rect[4];
} g_header_trace;
typedef struct {
    uintptr_t pane, parent, root;
    uint64_t seen;
    uint8_t valid, usable;
    float rect[4];
} generic_hit_t;
typedef struct {
    uintptr_t root, guide, text_pane, icon_pane, text_parent, icon_parent;
    uint64_t text_seen, icon_seen;
    float text[4], icon[4];
    uint64_t button;
    uint8_t text_valid, icon_valid;
} generic_back_prompt_t;
static generic_hit_t g_generic_hits[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
static generic_hit_t g_generic_alt_hits[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
static generic_hit_t g_generic_texts[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
static generic_back_prompt_t g_generic_back_prompts[32];
static pthread_mutex_t g_generic_hits_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_menu_mu = PTHREAD_MUTEX_INITIALIZER;
static dm_botw_touch_menu_view g_view;
static int g_view_valid, g_pointer_down, g_pointer_dragged;
static int g_map_pan_active;
static int32_t g_map_ax, g_map_ay;
static float g_map_start[2];
static uintptr_t g_map_published_pane, g_map_published_root;
static uint64_t g_map_tap_serial;
typedef struct {
    uintptr_t widget;
    uint64_t seen;
    int32_t current, wanted;
} botw_list_widget_observation_t;
static botw_list_widget_observation_t g_list_widget_observations[LIST_WIDGET_CACHE_SLOTS];
static pthread_mutex_t g_list_widget_observations_mu = PTHREAD_MUTEX_INITIALIZER;
static struct {
    int pending, issued, ack_ready, attempts;
    float point[2], target[2];
    uint64_t serial, requested_frame, issued_frame, last_call_frame, ack_frame;
    uintptr_t pane, root, screen, model;
    uint64_t page_key;
    int group;
} g_map_tap;
static void map_tap_clear_locked(void) {
    g_map_tap_serial++;
    if (!g_map_tap_serial) g_map_tap_serial++;
    memset(&g_map_tap, 0, sizeof g_map_tap);
}
static int g_target_valid, g_target_popup, g_target_index, g_confirm_pending;
static int g_target_category, g_selector_ready;
static int g_target_generic;
static uintptr_t g_target_pane, g_target_owner_pane, g_target_entry, g_target_screen, g_target_root;
static uintptr_t g_target_prompt_owner_screen, g_target_prompt_owner_root;
static int g_target_prompt_owner_group;
static uintptr_t g_requested_entry, g_selector_manager;
static _Atomic uintptr_t g_validated_box_cursor_manager;
static struct {
    uint64_t frame;
    uintptr_t manager, pane, root, focus, screen, apphome_screen, apphome_root;
    int result, group;
} g_map_validation_cache;
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
static int g_apply_output_map_left_valid, g_apply_output_map_right_valid;
static int g_apply_output_lx, g_apply_output_ly;
static int g_apply_output_ry;
static int32_t g_map_ry;
static uint64_t g_map_ry_frame;
static int g_map_left_owned, g_map_right_owned;
static struct {
    int valid, left, right, lx, ly, ry;
    uintptr_t pane, root;
} g_map_axis_trace;
static int g_active_notified;
typedef struct {
    uintptr_t manager, focus, screen, vtable, root;
    int group, input_active, inventory_screen, popup_active;
    int view_valid, generic_mode, generic_count, back_valid, inventory_visible;
    char screen_name[64];
} selector_trace_state_t;
static selector_trace_state_t g_selector_trace_states[16];
static unsigned g_selector_trace_next;
static pthread_mutex_t g_selector_trace_mu = PTHREAD_MUTEX_INITIALIZER;
static int point_in_rect(float x, float y, const float rect[4]);
static uint64_t menu_render_frame(void);
static uint64_t g_pointer_page_key, g_pointer_popup_key;
static int g_map_prompt_down, g_map_prompt_back;
static uint64_t g_map_prompt_button;
static int g_map_prompt_owner_valid, g_map_prompt_owner_group = -1;
static uintptr_t g_map_prompt_owner_screen, g_map_prompt_owner_root;
static void menu_clear_queue_locked(void);
static void menu_clear_target_locked(void);
static int selector_map_owner_active(uintptr_t manager, int group,
                                     uintptr_t map_vtable, uintptr_t native_screen_shown,
                                     uintptr_t native_group_getter, uintptr_t map_root,
                                     uintptr_t *out_screen, uintptr_t *out_apphome_screen,
                                     uintptr_t *out_apphome_root);
static int selector_apphome_owner_active(uintptr_t manager, int group,
                                         uintptr_t native_screen_shown,
                                         uintptr_t native_group_getter,
                                         uintptr_t *out_screen,
                                         uintptr_t *out_root);
static uintptr_t selector_ancestor_named(uintptr_t pane, const char *wanted);
static uintptr_t selector_read_ptr(uintptr_t p, size_t off);
static int generic_action_button(uint64_t button);
static uint64_t guide_glyph_button(uint16_t glyph);
static int selector_copy_apphome_prompts(uint64_t frame, int group,
                                         uintptr_t apphome_screen, uintptr_t apphome_root,
                                         dm_botw_touch_menu_view *view);
static int selector_map_view_for_manager(uintptr_t manager, uint64_t frame,
                                         dm_botw_touch_menu_view *view,
                                         uintptr_t *candidate_pane,
                                         uintptr_t *candidate_root);
static void selector_list_widget_observe(const uint64_t *regs);
static void selector_clear_map_view_if_owned(uintptr_t candidate_pane,
                                             uintptr_t candidate_root,
                                             uint64_t frame);
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
static _Atomic uintptr_t g_test_native_screen_name_getter;
static uintptr_t g_test_native_group_getter, g_test_native_screen_shown;
static uintptr_t g_test_map_setter_current, g_test_map_setter_target;
static uintptr_t g_test_list_widget_vtable, g_test_list_widget_update;
static int g_test_list_widget_override;
#endif
static _Atomic int g_map_setter_signature_reported;

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

static int pane_chain_visible(uint8_t *pane);
static int pane_chain_alpha_visible(uint8_t *pane);
static uint16_t pane_text_glyph(uint8_t *pane);
static int rect_intersects_canvas(const float rect[4]);
static int capture_mapped_rect(uint8_t *capture, uint8_t *child, uint8_t *dest,
                               float out[4]);
static int pane_find_unique(uint8_t *root, const char *wanted,
                            const char *required_ancestor, uintptr_t *out);
static int pane_find_unique_under_parent(uint8_t *root, const char *wanted,
                                         const char *parent_prefix,
                                         uintptr_t *out);

static uint8_t *ancestor_prefix(uint8_t *pane, const char *prefix) {
    size_t n = strlen(prefix);
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strncmp(name, prefix, n)) return pane;
        if (!strcmp(name, "RootPane")) break;
    }
    return NULL;
}

static int apphome_capture_destination(uint8_t *root, uint8_t *source_capture,
                                      uintptr_t *out_destination) {
    if (out_destination) *out_destination = 0;
    if (!root || !source_capture || ancestor_named(source_capture, "RootPane") != root ||
        !ancestor_prefix(source_capture, "Pa_ScanningLine_")) return 0;
    uintptr_t found = 0;
    if (pane_find_unique_under_parent(root, "P_Text_00", "N_TimeLineDemo_", &found) != 1) return 0;
    uint8_t *dest = (uint8_t *)found;
    if (ancestor_named(dest, "RootPane") != root ||
        !ancestor_named(dest, "N_Deco_00") ||
        !ancestor_prefix(dest, "Pa_ScanningLine_") ||
        !pane_chain_visible(dest) || !pane_chain_alpha_visible(dest)) return 0;
    if (out_destination) *out_destination = found;
    return 1;
}

static void refresh_captured_header_locked(uint64_t frame) {
    if (!g_native_view.header_capture_mode) return;
    for (int side = 0; side < 2; side++) {
        uintptr_t capture = g_native_view.header_capture_source[side];
        uintptr_t dest = g_native_view.header_capture_dest[side];
        uintptr_t icon = g_native_view.header_capture_icon_pane[side];
        uintptr_t text = g_native_view.header_capture_text_pane[side];
        uintptr_t icon_parent = g_native_view.header_capture_icon_parent[side];
        uintptr_t text_parent = g_native_view.header_capture_text_parent[side];
        uint8_t *root = (uint8_t *)g_native_view.header_root;
        char destination_name[17] = {0};
        if (dest && dm_guest_as_contains(dest) && dm_guest_as_contains(dest + PANE_NAME + 16))
            pane_name((uint8_t *)dest, destination_name);
        if (!root || !capture || !dest || !icon || !text || !icon_parent || !text_parent ||
            !dm_guest_as_contains(capture) || !dm_guest_as_contains(dest) ||
            !dm_guest_as_contains(icon) || !dm_guest_as_contains(text) ||
            ancestor_named((uint8_t *)capture, "RootPane") != root ||
            ancestor_named((uint8_t *)dest, "RootPane") != root ||
            strcmp(destination_name, "P_Text_00") ||
            !ancestor_named((uint8_t *)dest, "N_Deco_00") ||
            !ancestor_prefix((uint8_t *)dest, "N_TimeLineDemo_") ||
            !ancestor_prefix((uint8_t *)dest, "Pa_ScanningLine_") ||
            ancestor_named((uint8_t *)icon, "N_CaptureText_01") != (uint8_t *)capture ||
            ancestor_named((uint8_t *)text, "N_CaptureText_01") != (uint8_t *)capture ||
            ancestor_named((uint8_t *)icon, "RootPane") != root ||
            ancestor_named((uint8_t *)text, "RootPane") != root ||
            selector_read_ptr(icon, PANE_PARENT) != icon_parent ||
            selector_read_ptr(text, PANE_PARENT) != text_parent ||
            (side == 0 ? !ancestor_named((uint8_t *)icon, "Pa_BtnZL_00") :
                         !ancestor_named((uint8_t *)icon, "Pa_BtnZR_00")) ||
            (side == 0 ? strncmp((char *)text + PANE_NAME, "T_LeftText_", 11) :
                         strncmp((char *)text + PANE_NAME, "T_RightText_", 12)) ||
            !pane_chain_visible((uint8_t *)dest) || !pane_chain_alpha_visible((uint8_t *)dest)) {
            g_native_view.header_icon_valid[side] = 0;
            g_native_view.header_text_valid[side] = 0;
            continue;
        }
        int icon_valid = pane_chain_visible((uint8_t *)icon) &&
                         pane_chain_alpha_visible((uint8_t *)icon) &&
                         capture_mapped_rect((uint8_t *)capture, (uint8_t *)icon,
                                             (uint8_t *)dest, g_native_view.header_icons[side]);
        int text_valid = pane_chain_visible((uint8_t *)text) &&
                         pane_chain_alpha_visible((uint8_t *)text) &&
                         capture_mapped_rect((uint8_t *)capture, (uint8_t *)text,
                                             (uint8_t *)dest, g_native_view.header_texts[side]);
        uint16_t glyph = pane_chain_visible((uint8_t *)icon) &&
                         pane_chain_alpha_visible((uint8_t *)icon) ? pane_text_glyph((uint8_t *)icon) : 0;
        uint64_t button = guide_glyph_button(glyph);
        icon_valid = icon_valid && glyph == g_native_view.header_icon_glyph[side] &&
                     (side == 0 ? (button == DM_BTN_L || button == DM_BTN_ZL) :
                                  (button == DM_BTN_R || button == DM_BTN_ZR));
        g_native_view.header_icon_valid[side] = icon_valid;
        g_native_view.header_text_valid[side] = text_valid;
        g_native_view.header_icon_seen[side] = icon_valid ? frame : 0;
        g_native_view.header_text_seen[side] = text_valid ? frame : 0;
    }
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
    return pane_button_index(pane, "Pa_Guide_", GUIDE_SLOTS);
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

static int pane_affine(uint8_t *pane, float m[6], float *width, float *height) {
    if (!pane) return 0;
    memcpy(&m[0], pane + PANE_MATRIX, 4);
    memcpy(&m[1], pane + PANE_MATRIX + 4, 4);
    memcpy(&m[2], pane + PANE_MATRIX + 0x0c, 4);
    memcpy(&m[3], pane + PANE_MATRIX + 0x10, 4);
    memcpy(&m[4], pane + PANE_MATRIX + 0x14, 4);
    memcpy(&m[5], pane + PANE_MATRIX + 0x1c, 4);
    memcpy(width, pane + 0x50, 4);
    memcpy(height, pane + 0x54, 4);
    for (int i = 0; i < 6; i++) if (!isfinite(m[i])) return 0;
    if (!isfinite(*width) || !isfinite(*height) || *width <= 0 || *height <= 0) return 0;
    float det = m[0] * m[4] - m[1] * m[3];
    return isfinite(det) && fabsf(det) > 1e-6f;
}

// Map a child rectangle through the native capture pane into the final
// DynamicCaptureUse destination. Source and destination may have different
// transforms and dimensions; the four transformed corners preserve rotation.
static int capture_mapped_rect(uint8_t *capture, uint8_t *child, uint8_t *dest,
                               float out[4]) {
    float sm[6], cm[6], dm[6], sw, sh, cw, ch, dw, dh;
    if (!pane_affine(capture, sm, &sw, &sh) || !pane_affine(child, cm, &cw, &ch) ||
        !pane_affine(dest, dm, &dw, &dh)) return 0;
    float det = sm[0] * sm[4] - sm[1] * sm[3];
    float left = INFINITY, top = INFINITY, right = -INFINITY, bottom = -INFINITY;
    for (int iy = 0; iy < 2; iy++) for (int ix = 0; ix < 2; ix++) {
        float lx = (ix ? .5f : -.5f) * cw;
        float ly = (iy ? .5f : -.5f) * ch;
        float wx = cm[0] * lx + cm[1] * ly + cm[2];
        float wy = cm[3] * lx + cm[4] * ly + cm[5];
        float dx = wx - sm[2], dy = wy - sm[5];
        float sx = (sm[4] * dx - sm[1] * dy) / det;
        float sy = (-sm[3] * dx + sm[0] * dy) / det;
        float tx = (sx / sw) * dw;
        float ty = (sy / sh) * dh;
        float out_x = dm[0] * tx + dm[1] * ty + dm[2];
        float out_y = dm[3] * tx + dm[4] * ty + dm[5];
        float nx = (out_x + 640.0f) / 1280.0f;
        float ny = (360.0f - out_y) / 720.0f;
        if (!isfinite(nx) || !isfinite(ny)) return 0;
        left = fminf(left, nx); right = fmaxf(right, nx);
        top = fminf(top, ny); bottom = fmaxf(bottom, ny);
    }
    if (!isfinite(left) || !isfinite(top) || right <= left || bottom <= top) return 0;
    out[0] = left; out[1] = top; out[2] = right - left; out[3] = bottom - top;
    return rect_intersects_canvas(out);
}

// Bounded, fail-closed pane search. Return 1 for one match, 0 for none, and
// -1 for duplicate matches or a tree that exceeds the bounded walk.
static int pane_find_unique_matching(uint8_t *root, const char *wanted,
                                     const char *required_ancestor,
                                     const char *required_parent_prefix,
                                     uintptr_t *out) {
    enum { MAX_NODES = 512 };
    uintptr_t stack[MAX_NODES], seen[MAX_NODES];
    int sp = 0, count = 0, visited = 0, overflow = 0;
    uintptr_t match = 0;
    if (out) *out = 0;
    if (!root || !dm_guest_as_contains((uintptr_t)root) ||
        !dm_guest_as_contains((uintptr_t)root + PANE_NAME + 16)) return 0;
    stack[sp++] = (uintptr_t)root;
    while (sp && visited < MAX_NODES) {
        uintptr_t pane = stack[--sp];
        if (!dm_guest_as_contains(pane) || !dm_guest_as_contains(pane + PANE_NAME + 16)) continue;
        int duplicate_visit = 0;
        for (int i = 0; i < visited; i++) if (seen[i] == pane) { duplicate_visit = 1; break; }
        if (duplicate_visit) continue;
        seen[visited++] = pane;
        char name[17]; pane_name((uint8_t *)pane, name);
        uintptr_t parent = selector_read_ptr(pane, PANE_PARENT);
        char parent_name[17] = {0};
        if (parent && dm_guest_as_contains(parent) && dm_guest_as_contains(parent + PANE_NAME + 16))
            pane_name((uint8_t *)parent, parent_name);
        int parent_ok = !required_parent_prefix || (parent_name[0] &&
            !strncmp(parent_name, required_parent_prefix, strlen(required_parent_prefix)));
        int ancestor_ok = !required_ancestor ||
            ancestor_prefix((uint8_t *)pane, required_ancestor);
        if (!strcmp(name, wanted) && parent_ok && ancestor_ok) {
            match = pane;
            if (++count > 1) return -1;
        }
        uintptr_t sentinel = pane + 0x20;
        uintptr_t cur = selector_read_ptr(pane, 0x28);
        for (int n = 0; n < MAX_NODES && cur && cur != sentinel; n++) {
            if (cur < 8) { overflow = 1; break; }
            uintptr_t child = cur - 8;
            if (!dm_guest_as_contains(child) || !dm_guest_as_contains(child + 0x18)) break;
            if (selector_read_ptr(child, PANE_PARENT) != pane) break;
            if (sp >= MAX_NODES) { overflow = 1; break; }
            stack[sp++] = child;
            cur = selector_read_ptr(child, 0x10);
        }
        if (overflow) return -1;
    }
    if (sp || visited >= MAX_NODES) return -1;
    if (count == 1 && out) *out = match;
    return count == 1 ? 1 : 0;
}

static int pane_find_unique(uint8_t *root, const char *wanted,
                            const char *required_ancestor, uintptr_t *out) {
    return pane_find_unique_matching(root, wanted, required_ancestor, NULL, out);
}

static int pane_find_unique_under_parent(uint8_t *root, const char *wanted,
                                         const char *parent_prefix,
                                         uintptr_t *out) {
    return pane_find_unique_matching(root, wanted, NULL, parent_prefix, out);
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

static int pane_private_capture_branch(uint8_t *pane) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strncmp(name, "N_Capture", 9)) return 1;
        if (!strcmp(name, "RootPane")) break;
    }
    return 0;
}

// A part's invisible touch bounds carry its name in the native layout. The
// pause menu and the title screens name them B_Hit_00, while AppMap's stamp box
// and its stamp list buttons name the same thing B_Btn_00 and B_Area_00. B_Hit_00
// stays the only primary name, so the menus that already resolve keep their exact
// target; the other B_* bounds are a fallback tier, used only where no B_Hit_00
// lies under the part.
static int native_hit_pane_tier(const char *name) {
    if (!name) return 0;
    if (!strcmp(name, "B_Hit_00")) return 1;
    return !strcmp(name, "B_Btn_00") || !strcmp(name, "B_Area_00") ? 2 : 0;
}

static generic_hit_t *generic_geometry_cache(int kind) {
    return kind == 1 ? g_generic_texts : kind == 2 ? g_generic_alt_hits : g_generic_hits;
}

// Guide text and glyphs are captured into N_CaptureText_00 and displayed by
// the bound P_Text_00 pane. Text uses the full rendered plate as its hit area;
// glyphs retain their source sub-rectangle mapped through the same capture.
static int guide_prompt_rect(uint8_t *guide, uint8_t *source_pane, int is_icon,
                             float out[4]) {
    uintptr_t capture = 0, destination = 0;
    if (!guide || pane_find_unique(guide, "N_CaptureText_00", NULL, &capture) != 1 ||
        pane_find_unique(guide, "P_Text_00", NULL, &destination) != 1) return 0;
    uint8_t *dest = (uint8_t *)destination;
    if (!pane_chain_visible(dest) || !pane_chain_alpha_visible(dest)) return 0;
    if (is_icon) {
        if (!source_pane || ancestor_named(source_pane, "N_CaptureText_00") != (uint8_t *)capture)
            return 0;
        return capture_mapped_rect((uint8_t *)capture, source_pane, dest, out);
    }
    float x, y;
    memcpy(&x, dest + PANE_MATRIX + 0x0c, 4);
    memcpy(&y, dest + PANE_MATRIX + 0x1c, 4);
    native_rect_from_pane(dest, x, y, out);
    return rect_intersects_canvas(out);
}

static void generic_geometry_observe(uint8_t *pane, int after_matrix, int kind) {
    uintptr_t address = (uintptr_t)pane;
    uint8_t *parent = *(uint8_t **)(pane + PANE_PARENT);
    uint8_t *root = ancestor_named(pane, "RootPane");
    int text = kind == 1;
    if (text && pane_private_capture_branch(pane)) return;
    generic_hit_t *cache = generic_geometry_cache(kind);
    uint64_t frame = dm_guest_frame();
    pthread_mutex_lock(&g_generic_hits_mu);
    generic_hit_t *slot = NULL, *oldest = &cache[0];
    for (int i = 0; i < DM_BOTW_MENU_MAX_GENERIC_TARGETS; i++) {
        generic_hit_t *candidate = &cache[i];
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
    slot->pane = address;
    slot->parent = (uintptr_t)parent;
    slot->root = (uintptr_t)root;
    slot->seen = frame;
    slot->valid = 1;
    slot->usable = text ? rect_intersects_canvas(rect) :
        (rect_intersects_canvas(rect) && rect[2] > .02f && rect[3] > .02f);
    memcpy(slot->rect, rect, sizeof rect);
    pthread_mutex_unlock(&g_generic_hits_mu);
}

static void generic_hit_observe(uint8_t *pane, int after_matrix) {
    generic_geometry_observe(pane, after_matrix, 0);
}

static void generic_alt_hit_observe(uint8_t *pane, int after_matrix) {
    generic_geometry_observe(pane, after_matrix, 2);
}

static void generic_text_observe(uint8_t *pane, int after_matrix) {
    generic_geometry_observe(pane, after_matrix, 1);
}

static int generic_geometry_snapshot(generic_hit_t *cache,
                                     generic_hit_t out[DM_BOTW_MENU_MAX_GENERIC_TARGETS],
                                     uint64_t frame) {
    int count = 0;
    pthread_mutex_lock(&g_generic_hits_mu);
    for (int i = 0; i < DM_BOTW_MENU_MAX_GENERIC_TARGETS; i++) {
        const generic_hit_t *hit = &cache[i];
        if (!hit->valid || frame < hit->seen || frame - hit->seen > 2) continue;
        out[count++] = *hit;
    }
    pthread_mutex_unlock(&g_generic_hits_mu);
    return count;
}

static int generic_hit_snapshot(generic_hit_t out[DM_BOTW_MENU_MAX_GENERIC_TARGETS], uint64_t frame) {
    return generic_geometry_snapshot(g_generic_hits, out, frame);
}

static int generic_alt_hit_snapshot(generic_hit_t out[DM_BOTW_MENU_MAX_GENERIC_TARGETS], uint64_t frame) {
    return generic_geometry_snapshot(g_generic_alt_hits, out, frame);
}

static int generic_text_snapshot(generic_hit_t out[DM_BOTW_MENU_MAX_GENERIC_TARGETS], uint64_t frame) {
    return generic_geometry_snapshot(g_generic_texts, out, frame);
}

static uint8_t *ancestor_action_guide(uint8_t *pane) {
    for (int depth = 0; pane && depth < PANE_PATH_DEPTH; depth++, pane = *(uint8_t **)(pane + PANE_PARENT)) {
        char name[17]; pane_name(pane, name);
        if (!strcmp(name, "Pa_GuideA_00") || !strcmp(name, "Pa_GuideB_00") ||
            !strcmp(name, "Pa_GuideX_00") || !strcmp(name, "Pa_GuideY_00") ||
            !strcmp(name, "Pa_GuideL_00") || !strcmp(name, "Pa_GuideR_00") ||
            !strcmp(name, "Pa_GuideZL_00") || !strcmp(name, "Pa_GuideZR_00")) return pane;
        if (!strcmp(name, "RootPane")) break;
    }
    return NULL;
}

static void generic_back_prompt_observe(uint8_t *pane, int after_matrix) {
    char name[17]; pane_name(pane, name);
    int is_text = !strcmp(name, "T_Guide_00");
    int is_icon = !strcmp(name, "T_Icon_00");
    if (!is_text && !is_icon) return;
    uint8_t *guide = ancestor_action_guide(pane);
    uint8_t *root = guide ? ancestor_named(guide, "RootPane") : NULL;
    if (!guide || !root) return;
    uintptr_t address = (uintptr_t)pane, parent = *(uintptr_t *)(pane + PANE_PARENT);
    uintptr_t root_address = (uintptr_t)root, guide_address = (uintptr_t)guide;
    uint64_t frame = dm_guest_frame();
    int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
    pthread_mutex_lock(&g_generic_hits_mu);
    generic_back_prompt_t *slot = NULL, *oldest = &g_generic_back_prompts[0];
    for (int i = 0; i < 32; i++) {
        generic_back_prompt_t *candidate = &g_generic_back_prompts[i];
        if (candidate->root == root_address && candidate->guide == guide_address) {
            slot = candidate; break;
        }
        if (!candidate->root && !slot) slot = candidate;
        if (candidate->text_seen + candidate->icon_seen < oldest->text_seen + oldest->icon_seen)
            oldest = candidate;
    }
    if (!slot) slot = oldest;
    if (slot->root != root_address || slot->guide != guide_address) {
        memset(slot, 0, sizeof *slot);
        slot->root = root_address; slot->guide = guide_address;
    }
    uintptr_t old_pane = is_text ? slot->text_pane : slot->icon_pane;
    uintptr_t old_parent = is_text ? slot->text_parent : slot->icon_parent;
    uint8_t valid = is_text ? slot->text_valid : slot->icon_valid;
    if (!visible) {
        if (old_pane == address) {
            if (is_text) slot->text_valid = 0; else slot->icon_valid = 0;
        }
    } else if (!after_matrix) {
        if (old_pane == address && old_parent == parent && valid) {
            if (is_text) slot->text_seen = frame; else slot->icon_seen = frame;
        } else if (old_pane == address) {
            if (is_text) slot->text_valid = 0; else slot->icon_valid = 0;
        }
    } else {
        uint16_t glyph = is_icon ? pane_text_glyph(pane) : 0;
        uint64_t button = is_icon ? guide_glyph_button(glyph) : 0;
        if (is_icon && !button) {
            slot->icon_pane = address; slot->icon_parent = parent;
            slot->icon_valid = 0;
            slot->button = 0;
            pthread_mutex_unlock(&g_generic_hits_mu);
            return;
        }
        float x, y, rect[4];
        memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
        memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
        int rect_valid;
        if (pane_private_capture_branch(pane))
            rect_valid = guide_prompt_rect(guide, pane, is_icon, rect);
        else {
            if (is_text) native_right_anchored_rect_from_pane(pane, x, y, rect);
            else native_rect_from_pane(pane, x, y, rect);
            rect_valid = rect_intersects_canvas(rect);
        }
        if (is_text) {
            slot->text_pane = address; slot->text_parent = parent; slot->text_seen = frame;
            slot->text_valid = rect_valid;
            memcpy(slot->text, rect, sizeof rect);
        } else {
            slot->icon_pane = address; slot->icon_parent = parent; slot->icon_seen = frame;
            slot->icon_valid = rect_valid;
            slot->button = button;
            memcpy(slot->icon, rect, sizeof rect);
        }
    }
    pthread_mutex_unlock(&g_generic_hits_mu);
}

static int generic_action_prompt_snapshot(uintptr_t root, uint64_t frame,
                                          uint64_t button, float out[4]) {
    int found = 0;
    pthread_mutex_lock(&g_generic_hits_mu);
    for (int i = 0; i < 32; i++) {
        generic_back_prompt_t *prompt = &g_generic_back_prompts[i];
        if (prompt->root != root || prompt->button != button || !prompt->text_valid || !prompt->icon_valid ||
            frame < prompt->text_seen || frame - prompt->text_seen > 2 ||
            frame < prompt->icon_seen || frame - prompt->icon_seen > 2) continue;
        float icon_center = prompt->icon[0] + prompt->icon[2] * .5f;
        float nearest_left = -INFINITY, nearest_right = INFINITY;
        for (int j = 0; j < 32; j++) {
            generic_back_prompt_t *other = &g_generic_back_prompts[j];
            if (other == prompt || other->root != root || !other->icon_valid ||
                frame < other->icon_seen || frame - other->icon_seen > 2) continue;
            float center = other->icon[0] + other->icon[2] * .5f;
            if (center < icon_center && center > nearest_left) nearest_left = center;
            if (center > icon_center && center < nearest_right) nearest_right = center;
        }
        back_hit_rect(prompt->text, prompt->icon, nearest_left, nearest_right, out);
        found = 1;
        break;
    }
    pthread_mutex_unlock(&g_generic_hits_mu);
    return found;
}

static int generic_back_prompt_snapshot(uintptr_t root, uint64_t frame, float out[4]) {
    return generic_action_prompt_snapshot(root, frame, DM_BTN_B, out);
}

static void generic_action_prompts_to_view(uintptr_t root, uint64_t frame,
                                           dm_botw_touch_menu_view *view) {
    const uint64_t buttons[] = {DM_BTN_A, DM_BTN_X, DM_BTN_Y, DM_BTN_L, DM_BTN_R,
                                DM_BTN_ZL, DM_BTN_ZR};
    for (size_t i = 0; i < sizeof buttons / sizeof buttons[0] &&
         view->footer_action_count < DM_BOTW_MENU_MAX_FOOTER_ACTIONS; i++) {
        float rect[4];
        if (!generic_action_prompt_snapshot(root, frame, buttons[i], rect)) continue;
        int at = view->footer_action_count++;
        view->footer_action_buttons[at] = buttons[i];
        memcpy(view->footer_actions[at], rect, sizeof rect);
    }
}

static dm_botw_touch_menu_view snapshot_native_view_locked(void) {
    uint64_t frame = g_native_view.frame;
    refresh_captured_header_locked(frame);
    dm_botw_touch_menu_view view = {0};
    view.render_frame = frame;
    view.inventory_visible = g_native_view.inventory_visible && frame >= g_native_view.inventory_seen &&
                             frame - g_native_view.inventory_seen <= 2;
    // The observed pane is only a map candidate. Map ownership is published
    // later after validating the active native AppMap screen and BoxCursor.
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
    // T_Icon_00 is the live native button glyph. Guide indices are repacked
    // by state, so derive all button actions from glyph content, never position.
    // Include matching text and clamp between neighboring prompt midpoints.
    for (int i = 0; i < GUIDE_SLOTS; i++) {
        if (!g_native_view.guide_icon_valid[i] || frame < g_native_view.guide_icon_seen[i] ||
            frame - g_native_view.guide_icon_seen[i] > 2) continue;
        uint64_t button = guide_glyph_button(g_native_view.guide_icon_glyph[i]);
        int is_back = button == DM_BTN_B;
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
        for (int j = 0; j < GUIDE_SLOTS; j++) {
            if (j == i || !g_native_view.guide_icon_valid[j] || frame < g_native_view.guide_icon_seen[j] ||
                frame - g_native_view.guide_icon_seen[j] > 2) continue;
            float center = g_native_view.guide_icons[j][0] + g_native_view.guide_icons[j][2] * .5f;
            if (center < icon_center && center > nearest_left) nearest_left = center;
            if (center > icon_center && center < nearest_right) nearest_right = center;
        }
        float hit[4];
        // The prompt's touch area spans its glyph and its label, so a finger on
        // the text is not lost to a 30 px icon box.
        float merged[4];
        const float *base = text_rect ? text_rect : g_native_view.guide_icons[i];
        if (text_rect) {
            float left = fminf(text_rect[0], g_native_view.guide_icons[i][0]);
            float top = fminf(text_rect[1], g_native_view.guide_icons[i][1]);
            float right = fmaxf(text_rect[0] + text_rect[2], g_native_view.guide_icons[i][0] + g_native_view.guide_icons[i][2]);
            float bottom = fmaxf(text_rect[1] + text_rect[3], g_native_view.guide_icons[i][1] + g_native_view.guide_icons[i][3]);
            merged[0] = left; merged[1] = top; merged[2] = right - left; merged[3] = bottom - top;
            base = merged;
        }
        back_hit_rect(base, g_native_view.guide_icons[i], nearest_left, nearest_right, hit);
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
            uint64_t button = guide_glyph_button(glyph);
            int side_matches = i == 0 ? (button == DM_BTN_L || button == DM_BTN_ZL) :
                                        (button == DM_BTN_R || button == DM_BTN_ZR);
            if (!side_matches || !rect_intersects_canvas(g_native_view.header_icons[i]) ||
                !rect_intersects_canvas(g_native_view.header_texts[i]) ||
                view.footer_action_count >= DM_BOTW_MENU_MAX_FOOTER_ACTIONS) continue;
            const float *icon = g_native_view.header_icons[i];
            const float *text = g_native_view.header_texts[i];
            float hit[4];
            float left = fminf(icon[0], text[0]), top = fminf(icon[1], text[1]);
            float right = fmaxf(icon[0] + icon[2], text[0] + text[2]);
            float bottom = fmaxf(icon[1] + icon[3], text[1] + text[3]);
            hit[0] = left; hit[1] = top; hit[2] = right - left; hit[3] = bottom - top;
            if (atomic_load_explicit(&g_trace, memory_order_acquire) &&
                (!g_header_trace.action_valid[i] ||
                 memcmp(g_header_trace.action_icon[i], icon, sizeof hit) ||
                 memcmp(g_header_trace.action_text[i], text, sizeof hit))) {
                g_header_trace.action_valid[i] = 1;
                memcpy(g_header_trace.action_icon[i], icon, sizeof hit);
                memcpy(g_header_trace.action_text[i], text, sizeof hit);
                LOG("BOTW menu header action side=%d button=%llx icon=(%.4f,%.4f,%.4f,%.4f) text=(%.4f,%.4f,%.4f,%.4f) hit=(%.4f,%.4f,%.4f,%.4f)",
                    i, (unsigned long long)button, icon[0], icon[1], icon[2], icon[3],
                    text[0], text[1], text[2], text[3], hit[0], hit[1], hit[2], hit[3]);
            }
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

static int map_inverse_point(const float m[6], float logical_x, float logical_y,
                             float *native_x, float *native_y) {
    float det = m[0] * m[4] - m[1] * m[3];
    if (!isfinite(det) || fabsf(det) < 1e-6f) return 0;
    float x = logical_x - m[2], y = logical_y - m[5];
    float nx = (m[4] * x - m[1] * y) / det;
    float ny = (-m[3] * x + m[0] * y) / det;
    if (!isfinite(nx) || !isfinite(ny)) return 0;
    *native_x = nx; *native_y = ny;
    return 1;
}

static void observe_map_transform(uint8_t *pane, int after_matrix) {
    if (!after_matrix || !pane_chain_visible(pane) || !pane_chain_alpha_visible(pane)) return;
    uint8_t *map = ancestor_named(pane, "Pa_Map_00");
    uint8_t *root = ancestor_named(pane, "RootPane");
    if (!map || !root) return;
    char parent_name[17];
    uint8_t *parent = *(uint8_t **)(pane + PANE_PARENT);
    pane_name(parent, parent_name);
    if (strcmp(parent_name, "N_MapSR_00")) return;
    float m[6];
    memcpy(&m[0], pane + PANE_MATRIX, 4);
    memcpy(&m[1], pane + PANE_MATRIX + 4, 4);
    memcpy(&m[2], pane + PANE_MATRIX + 0x0c, 4);
    memcpy(&m[3], pane + PANE_MATRIX + 0x10, 4);
    memcpy(&m[4], pane + PANE_MATRIX + 0x14, 4);
    memcpy(&m[5], pane + PANE_MATRIX + 0x1c, 4);
    for (size_t i = 0; i < sizeof m / sizeof m[0]; i++) if (!isfinite(m[i])) return;
    if (fabsf(m[0] * m[4] - m[1] * m[3]) < 1e-6f) return;
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.map_transform_pane = (uintptr_t)pane;
    g_native_view.map_transform_root = (uintptr_t)root;
    g_native_view.map_transform_map_pane = (uintptr_t)map;
    g_native_view.map_transform_seen = dm_guest_frame();
    memcpy(g_native_view.map_transform, m, sizeof m);
    pthread_mutex_unlock(&g_native_view_mu);
}

static int observe_apphome_header_capture(uint8_t *pane, const char *name,
                                          int after_matrix) {
    uint8_t *root = ancestor_named(pane, "RootPane");
    uint8_t *capture = ancestor_named(pane, "N_CaptureText_01");
    if (!root || !capture || !ancestor_prefix(capture, "Pa_ScanningLine_")) return 0;
    int icon = !strcmp(name, "T_Icon_01");
    int text = !strncmp(name, "T_LeftText_", 11) || !strncmp(name, "T_RightText_", 12);
    if (!icon && !text) return 0;
    int side = -1;
    if (icon) {
        if (ancestor_named(pane, "Pa_BtnZL_00")) side = 0;
        else if (ancestor_named(pane, "Pa_BtnZR_00")) side = 1;
    } else if (!strncmp(name, "T_LeftText_", 11)) side = 0;
    else if (!strncmp(name, "T_RightText_", 12)) side = 1;
    if (side < 0) return 0;
    uint64_t frame = dm_guest_frame();
    int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
    uintptr_t destination = 0;
    uintptr_t parent = selector_read_ptr((uintptr_t)pane, PANE_PARENT);
    int destination_valid = visible && apphome_capture_destination(root, capture, &destination);
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.frame = frame;
    if (visible && (g_native_view.header_root != (uintptr_t)root ||
                    !g_native_view.header_capture_mode)) {
        g_native_view.header_root = (uintptr_t)root;
        g_native_view.header_capture_mode = 1;
        memset(g_native_view.header_icon_valid, 0, sizeof g_native_view.header_icon_valid);
        memset(g_native_view.header_text_valid, 0, sizeof g_native_view.header_text_valid);
        memset(g_native_view.header_text_pane, 0, sizeof g_native_view.header_text_pane);
        memset(g_native_view.header_icon_glyph, 0, sizeof g_native_view.header_icon_glyph);
        memset(g_native_view.header_capture_source, 0, sizeof g_native_view.header_capture_source);
        memset(g_native_view.header_capture_dest, 0, sizeof g_native_view.header_capture_dest);
        memset(g_native_view.header_capture_icon_pane, 0, sizeof g_native_view.header_capture_icon_pane);
        memset(g_native_view.header_capture_text_pane, 0, sizeof g_native_view.header_capture_text_pane);
        memset(g_native_view.header_capture_icon_parent, 0, sizeof g_native_view.header_capture_icon_parent);
        memset(g_native_view.header_capture_text_parent, 0, sizeof g_native_view.header_capture_text_parent);
    }
    if (visible && !destination_valid &&
        g_native_view.header_root == (uintptr_t)root && g_native_view.header_capture_mode) {
        memset(g_native_view.header_icon_valid, 0, sizeof g_native_view.header_icon_valid);
        memset(g_native_view.header_text_valid, 0, sizeof g_native_view.header_text_valid);
        memset(g_native_view.header_capture_source, 0, sizeof g_native_view.header_capture_source);
        memset(g_native_view.header_capture_dest, 0, sizeof g_native_view.header_capture_dest);
        memset(g_native_view.header_capture_icon_pane, 0, sizeof g_native_view.header_capture_icon_pane);
        memset(g_native_view.header_capture_text_pane, 0, sizeof g_native_view.header_capture_text_pane);
        memset(g_native_view.header_capture_icon_parent, 0, sizeof g_native_view.header_capture_icon_parent);
        memset(g_native_view.header_capture_text_parent, 0, sizeof g_native_view.header_capture_text_parent);
    }
    if (g_native_view.header_root == (uintptr_t)root && g_native_view.header_capture_mode) {
        if (icon) {
            uint16_t glyph = visible ? pane_text_glyph(pane) : 0;
            uint64_t button = guide_glyph_button(glyph);
            int side_matches = side == 0 ? (button == DM_BTN_L || button == DM_BTN_ZL) :
                                           (button == DM_BTN_R || button == DM_BTN_ZR);
            int same = g_native_view.header_capture_icon_pane[side] == (uintptr_t)pane &&
                       g_native_view.header_capture_icon_parent[side] == parent &&
                       g_native_view.header_capture_source[side] == (uintptr_t)capture &&
                       g_native_view.header_capture_dest[side] == destination &&
                       g_native_view.header_icon_glyph[side] == glyph;
            if (!visible || !destination_valid || !side_matches ||
                (g_native_view.header_capture_icon_pane[side] == (uintptr_t)pane && !same)) {
                if (g_native_view.header_capture_icon_pane[side] == (uintptr_t)pane) {
                    g_native_view.header_capture_icon_pane[side] = 0;
                    g_native_view.header_capture_icon_parent[side] = 0;
                    g_native_view.header_icon_valid[side] = 0;
                }
            } else if (!after_matrix) {
                if (same && g_native_view.header_icon_valid[side])
                    g_native_view.header_icon_seen[side] = frame;
            } else {
                if (g_native_view.header_capture_source[side] != (uintptr_t)capture ||
                    g_native_view.header_capture_dest[side] != destination) {
                    g_native_view.header_capture_text_pane[side] = 0;
                    g_native_view.header_capture_text_parent[side] = 0;
                    g_native_view.header_text_pane[side] = 0;
                    g_native_view.header_text_valid[side] = 0;
                }
                g_native_view.header_capture_source[side] = (uintptr_t)capture;
                g_native_view.header_capture_dest[side] = destination;
                g_native_view.header_capture_icon_pane[side] = (uintptr_t)pane;
                g_native_view.header_capture_icon_parent[side] = parent;
                g_native_view.header_icon_glyph[side] = glyph;
                g_native_view.header_icon_valid[side] = 1;
                g_native_view.header_icon_seen[side] = frame;
            }
        } else if (visible && destination_valid) {
            // A hidden alternate label cannot erase the currently rendered
            // sibling; the live capture callback names the visible one.
            int same = g_native_view.header_capture_text_pane[side] == (uintptr_t)pane &&
                       g_native_view.header_capture_text_parent[side] == parent &&
                       g_native_view.header_capture_source[side] == (uintptr_t)capture &&
                       g_native_view.header_capture_dest[side] == destination;
            if (!after_matrix) {
                if (same && g_native_view.header_text_valid[side])
                    g_native_view.header_text_seen[side] = frame;
            } else {
                if (g_native_view.header_capture_source[side] != (uintptr_t)capture ||
                    g_native_view.header_capture_dest[side] != destination) {
                    g_native_view.header_capture_icon_pane[side] = 0;
                    g_native_view.header_capture_icon_parent[side] = 0;
                    g_native_view.header_icon_valid[side] = 0;
                }
                g_native_view.header_capture_source[side] = (uintptr_t)capture;
                g_native_view.header_capture_dest[side] = destination;
                g_native_view.header_capture_text_pane[side] = (uintptr_t)pane;
                g_native_view.header_capture_text_parent[side] = parent;
                g_native_view.header_text_pane[side] = (uintptr_t)pane;
                g_native_view.header_text_valid[side] = 1;
                g_native_view.header_text_seen[side] = frame;
            }
        } else if (g_native_view.header_capture_text_pane[side] == (uintptr_t)pane &&
                   (!visible || !destination_valid ||
                    g_native_view.header_capture_text_parent[side] != parent ||
                    g_native_view.header_capture_source[side] != (uintptr_t)capture ||
                    g_native_view.header_capture_dest[side] != destination)) {
            g_native_view.header_capture_text_pane[side] = 0;
            g_native_view.header_capture_text_parent[side] = 0;
            g_native_view.header_text_pane[side] = 0;
            g_native_view.header_text_valid[side] = 0;
        }
        refresh_captured_header_locked(frame);
    }
    dm_botw_touch_menu_view view = snapshot_native_view_locked();
    pthread_mutex_unlock(&g_native_view_mu);
    dm_botw_touch_menu_observe(&view);
    return 1;
}

static void observe_native_pane(uint8_t *pane, int after_matrix) {
    if (!pane) return;
    char name[17]; pane_name(pane, name);
    generic_back_prompt_observe(pane, after_matrix);
    int hit_tier = native_hit_pane_tier(name);
    if (hit_tier == 1) generic_hit_observe(pane, after_matrix);
    else if (hit_tier == 2) generic_alt_hit_observe(pane, after_matrix);
    if (!strncmp(name, "T_Btn", 5)) generic_text_observe(pane, after_matrix);
    // Pa_Map_00 is the full-screen map's own pane; the minimap does not use
    // it. Its laid-out children keep default sizes, so the touch surface is
    // the map viewport between the native header and footer bars.
    if (!strcmp(name, "Pa_Map_00")) {
        uint64_t frame = dm_guest_frame();
        uintptr_t root = (uintptr_t)ancestor_named(pane, "RootPane");
        pthread_mutex_lock(&g_native_view_mu);
        g_native_view.frame = frame;
        int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
        if (visible) {
            g_native_view.map_candidate_visible = 1;
            g_native_view.map_candidate_seen = frame;
            g_native_view.map_candidate_pane = (uintptr_t)pane;
            g_native_view.map_candidate_root = root;
            g_native_view.map_candidate_rect[0] = 0.02f; g_native_view.map_candidate_rect[1] = 0.085f;
            g_native_view.map_candidate_rect[2] = 0.96f; g_native_view.map_candidate_rect[3] = 0.80f;
        } else if (g_native_view.map_candidate_pane == (uintptr_t)pane &&
                   g_native_view.map_candidate_root == root) {
            g_native_view.map_candidate_visible = 0;
            g_native_view.map_candidate_pane = g_native_view.map_candidate_root = 0;
        }
        if (atomic_load_explicit(&g_trace, memory_order_acquire) &&
            (!g_header_trace.map_valid || g_header_trace.map_visible != g_native_view.map_candidate_visible)) {
            g_header_trace.map_valid = 1;
            g_header_trace.map_visible = g_native_view.map_candidate_visible;
            LOG("BOTW menu map pane=%p visible=%d frame=%llu", (void *)pane,
                g_native_view.map_candidate_visible, (unsigned long long)frame);
        }
        dm_botw_touch_menu_view view = snapshot_native_view_locked();
        pthread_mutex_unlock(&g_native_view_mu);
        uintptr_t manager = atomic_load_explicit(&g_validated_box_cursor_manager, memory_order_acquire);
        if (dm_botw_touch_hud_active() &&
            selector_map_view_for_manager(manager, frame, &view, NULL, NULL))
            dm_botw_touch_menu_observe(&view);
        else
            selector_clear_map_view_if_owned((uintptr_t)pane, root, frame);
        return;
    }
    if (!strcmp(name, "N_MapT_00")) {
        observe_map_transform(pane, after_matrix);
        return;
    }
    int corner = cursor_corner_index(name);
    int back_text = !strcmp(name, "T_Guide_00");
    int back_icon = !strcmp(name, "T_Icon_00");
    int header_capture_icon = !strcmp(name, "T_Icon_01");
    int header_icon = back_icon;
    // The title bar keeps two alternate text panes per side and swaps them
    // during its label change animation; either may be the live one.
    int header_text = !strncmp(name, "T_LeftText_", 11) || !strncmp(name, "T_RightText_", 12);
    if (corner < 0 && !back_text && !header_icon && !header_capture_icon && !header_text &&
        strcmp(name, "P_Text_00") && strcmp(name, "B_Hit_00") && strcmp(name, "N_Cut_00") &&
        strcmp(name, "N_InOut_00") && strcmp(name, "N_Slide_01")) return;
    if (header_capture_icon || header_text) {
        if (observe_apphome_header_capture(pane, name, after_matrix)) return;
    }
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
            if (!strncmp(label_name, "T_LeftText_", 11)) side = 0;
            else if (!strncmp(label_name, "T_RightText_", 12)) side = 1;
        }
        if (side >= 0 && root) {
                uint64_t frame = dm_guest_frame();
                pthread_mutex_lock(&g_native_view_mu);
                g_native_view.frame = frame;
                int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
                uint16_t observed_glyph = header_icon && visible ? pane_text_glyph(pane) : 0;
                if (atomic_load_explicit(&g_trace, memory_order_acquire)) {
                    int kind = header_icon ? 0 : 1;
                    uintptr_t observed_root = (uintptr_t)root;
                    if (!g_header_trace.valid[side][kind] ||
                        g_header_trace.visible[side][kind] != visible ||
                        g_header_trace.glyph[side][kind] != observed_glyph ||
                        g_header_trace.root[side][kind] != observed_root) {
                        g_header_trace.valid[side][kind] = 1;
                        g_header_trace.visible[side][kind] = visible;
                        g_header_trace.glyph[side][kind] = observed_glyph;
                        g_header_trace.root[side][kind] = observed_root;
                        LOG("BOTW menu header observe side=%d kind=%s pane=%p visible=%d glyph=%04x root=%p viewRoot=%p footerRoot=%p",
                            side, header_icon ? "icon" : "text", (void *)pane, visible,
                            observed_glyph, (void *)root, (void *)g_native_view.header_root,
                            (void *)g_native_view.footer_root);
                    }
                }
                if (visible && (g_native_view.header_root != (uintptr_t)root ||
                                g_native_view.header_capture_mode)) {
                    g_native_view.header_root = (uintptr_t)root;
                    g_native_view.header_capture_mode = 0;
                    memset(g_native_view.header_icon_valid, 0, sizeof g_native_view.header_icon_valid);
                    memset(g_native_view.header_text_valid, 0, sizeof g_native_view.header_text_valid);
                    memset(g_native_view.header_text_pane, 0, sizeof g_native_view.header_text_pane);
                    memset(g_native_view.header_icon_glyph, 0, sizeof g_native_view.header_icon_glyph);
                }
                if (g_native_view.header_root == (uintptr_t)root) {
                    if (header_icon) {
                        uint16_t glyph = visible ? pane_text_glyph(pane) : 0;
                        uint64_t button = guide_glyph_button(glyph);
                        int side_matches = side == 0 ? (button == DM_BTN_L || button == DM_BTN_ZL) :
                                                      (button == DM_BTN_R || button == DM_BTN_ZR);
                        g_native_view.header_icon_valid[side] = visible && side_matches;
                        g_native_view.header_icon_glyph[side] = g_native_view.header_icon_valid[side] ? glyph : 0;
                        if (g_native_view.header_icon_valid[side] &&
                            (after_matrix || g_native_view.header_icon_seen[side])) {
                            float x, y;
                            memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
                            memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                            native_rect_from_pane(pane, x, y, g_native_view.header_icons[side]);
                            g_native_view.header_icon_seen[side] = frame;
                        }
                    } else if (visible) {
                        // Keep the live pane even when the hidden alternate
                        // sibling is observed afterwards in the same frame.
                        g_native_view.header_text_valid[side] = 1;
                        g_native_view.header_text_pane[side] = (uintptr_t)pane;
                        if (after_matrix || g_native_view.header_text_seen[side]) {
                            float x, y;
                            memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
                            memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                            native_rect_from_pane(pane, x, y, g_native_view.header_texts[side]);
                            g_native_view.header_text_seen[side] = frame;
                        }
                    } else if (g_native_view.header_text_pane[side] == (uintptr_t)pane) {
                        g_native_view.header_text_valid[side] = 0;
                        g_native_view.header_text_pane[side] = 0;
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
    // DM_BOTW_MENU_TRACE=2: say why a key prompt was not adopted, once per
    // pane. A bar that draws but stays untouchable is then a named gate, not
    // a guess.
    if (atomic_load_explicit(&g_trace, memory_order_acquire) >= 2 && guide_index >= 0 &&
        (back_text || back_icon)) {
        static uintptr_t seen[64];
        static pthread_mutex_t seen_mu = PTHREAD_MUTEX_INITIALIZER;
        int fresh = 1;
        pthread_mutex_lock(&seen_mu);
        for (int i = 0; i < 64; i++) {
            if (seen[i] == (uintptr_t)pane) { fresh = 0; break; }
            if (!seen[i]) { seen[i] = (uintptr_t)pane; break; }
        }
        pthread_mutex_unlock(&seen_mu);
        if (fresh) {
            char pname[17], ppath[96] = {0};
            pane_name(pane, pname);
            uint8_t *walk = pane;
            for (int d = 0; walk && d < 6; d++) {
                char n[17]; pane_name(walk, n);
                size_t used = strlen(ppath);
                snprintf(ppath + used, sizeof ppath - used, "%s%s", used ? "<-" : "", n);
                walk = *(uint8_t **)(walk + PANE_PARENT);
            }
            LOG("BOTW guide candidate pane=%p name=%s index=%d text=%d icon=%d titleBar=%d align=%d inOut=%d guide=%p root=%p path=%s",
                (void *)pane, pname, guide_index, back_text, back_icon,
                ancestor_named(pane, "N_TitleBarDown_0") != NULL,
                ancestor_named(pane, "N_Align_00") != NULL,
                ancestor_named(pane, "N_InOut_00") != NULL,
                (void *)guide, (void *)footer_root, ppath);
        }
    }
    // A guide key is a Pa_Guide_0X part in a live N_Align_00 row, holding the
    // native glyph (T_Icon_00) and its label (T_Guide_00). PauseMenuInfo's own
    // footer is one such row; the + menu's map page draws its key bar from the
    // pad layout, whose row sits under N_TimeLineDemo_0 instead of the title
    // bar, so the row itself, not one layout's ancestry, is the identity.
    if ((back_text || back_icon) && guide_index >= 0 && guide_index < GUIDE_SLOTS &&
        ancestor_named(pane, "N_Align_00") && footer_root) {
        uint64_t frame = dm_guest_frame();
        pthread_mutex_lock(&g_native_view_mu);
        g_native_view.frame = frame;
        int visible = pane_chain_visible(pane) && pane_chain_alpha_visible(pane);
        int footer_owner = g_native_view.footer_root == (uintptr_t)footer_root;
        int footer_unused = !g_native_view.footer_root;
        int footer_hidden = 1;
        for (int i = 0; i < GUIDE_SLOTS; i++) if (g_native_view.guide_icon_valid[i] &&
            frame >= g_native_view.guide_icon_seen[i] && frame - g_native_view.guide_icon_seen[i] <= 2)
            footer_hidden = 0;
        uint16_t candidate_glyph = back_icon && visible ? pane_text_glyph(pane) : 0;
        int recognized_glyph = guide_glyph_button(candidate_glyph) != 0;
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
            if (visible && (after_matrix || g_native_view.guide_text_seen[guide_index])) {
                float x, y; memcpy(&x, pane + PANE_MATRIX + 0x0c, 4); memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                int rect_valid;
                if (pane_private_capture_branch(pane))
                    rect_valid = guide_prompt_rect(guide, pane, 0,
                                                   g_native_view.guide_texts[guide_index]);
                else {
                    native_right_anchored_rect_from_pane(pane, x, y, g_native_view.guide_texts[guide_index]);
                    rect_valid = rect_intersects_canvas(g_native_view.guide_texts[guide_index]);
                }
                g_native_view.guide_text_valid[guide_index] = rect_valid;
                g_native_view.guide_text_seen[guide_index] = rect_valid ? frame : 0;
            } else if (!visible) {
                g_native_view.guide_text_valid[guide_index] = 0;
                g_native_view.guide_text_seen[guide_index] = 0;
            }
        } else if (footer_owner && back_icon && g_native_view.guide_instances[guide_index] == (uintptr_t)guide) {
            g_native_view.guide_icon_glyph[guide_index] = visible ? candidate_glyph : 0;
            if (visible && (after_matrix || g_native_view.guide_icon_seen[guide_index])) {
                float x, y; memcpy(&x, pane + PANE_MATRIX + 0x0c, 4); memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
                int rect_valid;
                if (pane_private_capture_branch(pane))
                    rect_valid = guide_prompt_rect(guide, pane, 1,
                                                   g_native_view.guide_icons[guide_index]);
                else {
                    native_rect_from_pane(pane, x, y, g_native_view.guide_icons[guide_index]);
                    rect_valid = rect_intersects_canvas(g_native_view.guide_icons[guide_index]);
                }
                g_native_view.guide_icon_valid[guide_index] = rect_valid;
                g_native_view.guide_icon_seen[guide_index] = rect_valid ? frame : 0;
            } else if (!visible) {
                g_native_view.guide_icon_valid[guide_index] = 0;
                g_native_view.guide_icon_seen[guide_index] = 0;
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

// DM_BOTW_MENU_TRACE=2: name every live pane that draws in the bottom strip of
// the picture, so a key bar the host does not yet route can be identified by
// its own layout names instead of guessed from the extracted layouts. Bounded
// to the strip and deduplicated per pane, so the log stays readable.
static void trace_bottom_strip(uint8_t *pane, int after_matrix) {
    if (!after_matrix || !pane_chain_visible(pane) || !pane_chain_alpha_visible(pane)) return;
    float x = 0, y = 0, rect[4];
    memcpy(&x, pane + PANE_MATRIX + 0x0c, 4);
    memcpy(&y, pane + PANE_MATRIX + 0x1c, 4);
    native_rect_from_pane(pane, x, y, rect);
    if (!rect_intersects_canvas(rect) || rect[1] < .90f || rect[2] < .02f || rect[3] < .02f) return;
    enum { STRIP_SLOTS = 256 };
    static struct { uintptr_t pane; float rect[4]; } seen[STRIP_SLOTS];
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    unsigned at = (unsigned)(((uintptr_t)pane >> 4) % STRIP_SLOTS);
    pthread_mutex_lock(&mu);
    int known = 0;
    for (unsigned i = 0; i < STRIP_SLOTS; i++) {
        unsigned slot = (at + i) % STRIP_SLOTS;
        if (!seen[slot].pane || seen[slot].pane == (uintptr_t)pane) {
            if (!seen[slot].pane) {
                seen[slot].pane = (uintptr_t)pane;
                memcpy(seen[slot].rect, rect, sizeof rect);
            } else if (!memcmp(seen[slot].rect, rect, sizeof rect)) {
                known = 1;
            } else {
                memcpy(seen[slot].rect, rect, sizeof rect);
            }
            break;
        }
    }
    pthread_mutex_unlock(&mu);
    if (known) return;
    char name[17]; pane_name(pane, name);
    uint8_t *parent = *(uint8_t **)(pane + PANE_PARENT);
    char parent_name[17] = {0};
    if (parent) pane_name(parent, parent_name);
    // No glyph read here: only a text pane's 0xe0 field holds one, and the
    // strip walk sees every kind of pane.
    LOG("BOTW bottom pane name=%s parent=%s rect=(%.3f,%.3f,%.3f,%.3f) alpha=%d",
        name, parent_name, rect[0], rect[1], rect[2], rect[3], pane[PANE_FLAGS + 1]);
}

void dm_botw_touch_menu_pane(const uint64_t *regs, int after_matrix) {
    if (!regs) return;
    uint8_t *pane = (uint8_t *)(uintptr_t)regs[after_matrix ? 19 : 0];
    if (!pane) return;
    int trace = atomic_load_explicit(&g_trace, memory_order_acquire);
    if (!strcmp(DM_GAME_ID, "01007EF00011E000") && !strcmp(dm_main_build(), BOTW_BUILD) &&
        (trace || dm_botw_touch_hud_active()))
        observe_native_pane(pane, after_matrix);
    if (trace >= 2 && !strcmp(DM_GAME_ID, "01007EF00011E000") && !strcmp(dm_main_build(), BOTW_BUILD))
        trace_bottom_strip(pane, after_matrix);
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

// DM_CTL "panes <hex root> [max depth]": the live pane tree below a layout root.
void dm_botw_touch_menu_dump_tree(const char *arg) {
    if (!arg) return;
    char *end = NULL;
    uintptr_t root = (uintptr_t)strtoull(arg, &end, 16);
    int max_depth = end && *end ? (int)strtol(end, NULL, 10) : 8;
    if (!root || max_depth < 0) { LOG("[RED] panes: wants <hex root> [max depth]"); return; }
    if (max_depth > 20) max_depth = 20;
    enum { TREE_NODES = 1024 };
    static uintptr_t stack[TREE_NODES];
    static int depths[TREE_NODES];
    static uintptr_t seen[TREE_NODES];
    int sp = 0, visited = 0;
    stack[sp] = root; depths[sp] = 0; sp++;
    LOG("BOTW pane tree root=%p depth=%d", (void *)root, max_depth);
    while (sp > 0 && visited < TREE_NODES - 1) {
        sp--;
        uintptr_t pane = stack[sp];
        int depth = depths[sp];
        if (!dm_guest_as_contains(pane) || !dm_guest_as_contains(pane + PANE_NAME + 16)) continue;
        int dup = 0;
        for (int i = 0; i < visited; i++) if (seen[i] == pane) { dup = 1; break; }
        if (dup) continue;
        seen[visited++] = pane;
        char name[17];
        pane_name((uint8_t *)pane, name);
        float x = 0, y = 0, rect[4] = {0};
        memcpy(&x, (const void *)(pane + PANE_MATRIX + 0x0c), 4);
        memcpy(&y, (const void *)(pane + PANE_MATRIX + 0x1c), 4);
        native_rect_from_pane((uint8_t *)pane, x, y, rect);
        LOG("BOTW pane tree depth=%d pane=%p name=%s flags=%02x alpha=%d rect=(%.3f,%.3f,%.3f,%.3f)",
            depth, (void *)pane, name, ((const uint8_t *)pane)[PANE_FLAGS],
            ((const uint8_t *)pane)[PANE_FLAGS + 1], rect[0], rect[1], rect[2], rect[3]);
        if (depth >= max_depth) continue;
        uintptr_t sentinel = pane + 0x20, cur = 0;
        memcpy(&cur, (const void *)(pane + 0x28), sizeof cur);
        for (int n = 0; n < 256 && cur && cur != sentinel; n++) {
            uintptr_t child = cur - 8, parent = 0;
            if (!dm_guest_as_contains(child) || !dm_guest_as_contains(child + 0x18)) break;
            memcpy(&parent, (const void *)(child + 0x18), sizeof parent);
            if (parent != pane) break;
            if (sp < TREE_NODES) { stack[sp] = child; depths[sp] = depth + 1; sp++; }
            uintptr_t next = 0;
            memcpy(&next, (const void *)(child + 0x10), sizeof next);
            if (!next) break;
            cur = next;
        }
    }
    LOG("BOTW pane tree done nodes=%d", visited);
}

void dm_botw_touch_menu_install(void) {
    if (strcmp(DM_GAME_ID, "01007EF00011E000") || strcmp(dm_main_build(), BOTW_BUILD)) return;
    if (!gate_obs_present(OBS_BOTW_TOUCH_PANE) || !gate_obs_present(OBS_BOTW_TOUCH_MATRIX) ||
        !gate_obs_present(OBS_BOTW_MENU_SELECT)) return;
    gate_obs_set(OBS_BOTW_MENU_SELECT, dm_botw_touch_menu_selector);
    if (gate_obs_present(OBS_BOTW_LIST_WIDGET_UPDATE))
        gate_obs_set(OBS_BOTW_LIST_WIDGET_UPDATE, selector_list_widget_observe);
    atomic_store_explicit(&g_selector_hook_installed, 1, memory_order_release);
    const char *trace = getenv("DM_BOTW_MENU_TRACE");
    int tracing = trace ? atoi(trace) : 0;
    atomic_store_explicit(&g_trace, tracing, memory_order_release);
    if (tracing)
        LOG("BOTW menu trace enabled on OBS34/35 panes, OBS37 box cursor, OBS38 list-widget cache=%d (level %d)",
            gate_obs_present(OBS_BOTW_LIST_WIDGET_UPDATE), tracing);
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
    if (view->map_visible)
        return view->map[2] > 0 && view->map[3] > 0 && rect_intersects_canvas(view->map);
    if (view->generic_mode) {
        if (view->back_valid && rect_intersects_canvas(view->back)) return 1;
        for (int i = 0; i < view->generic_count; i++)
            if (rect_intersects_canvas(view->generic_targets[i].rect)) return 1;
        for (int i = 0; i < view->footer_action_count; i++)
            if (rect_intersects_canvas(view->footer_actions[i])) return 1;
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
    return g_view.map_visible || g_view.generic_mode ||
           (g_view.inventory_visible && g_view.back_valid);
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

static int selector_map_cursor_setters(uintptr_t *current, uintptr_t *target) {
    module_t *main = NULL;
    for (int i = 0; i < g_nmod; i++)
        if (!strcmp(g_mod[i].name, "main") && g_mod[i].loaded) { main = &g_mod[i]; break; }
    if (!main) return 0;
    uintptr_t set_current = (uintptr_t)(main->base + 0xd8c780);
    uintptr_t set_target = (uintptr_t)(main->base + 0xd8c6bc);
    static const uint8_t signature[24] = {
        0x48,0x84,0x00,0xf0,0x20,0x04,0x40,0x2d,0x08,0x7d,0x47,0xf9,
        0x08,0x49,0x48,0xb9,0xc8,0x02,0x00,0x34,0x02,0xc0,0x48,0xbd
    };
    int valid = selector_loaded_module_range(set_current, sizeof signature) &&
        selector_loaded_module_range(set_target, sizeof signature) &&
        !memcmp((const void *)set_current, signature, sizeof signature) &&
        !memcmp((const void *)set_target, signature, sizeof signature);
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_native_ready, memory_order_acquire) &&
        g_test_map_setter_current && g_test_map_setter_target) {
        set_current = g_test_map_setter_current;
        set_target = g_test_map_setter_target;
        valid = 1;
    }
#endif
    if (!valid) {
        if (!atomic_exchange_explicit(&g_map_setter_signature_reported, 1, memory_order_acq_rel) &&
            atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW map tap disabled: native cursor setter signature mismatch");
        return 0;
    }
    atomic_store_explicit(&g_map_setter_signature_reported, 0, memory_order_release);
    *current = set_current;
    *target = set_target;
    return 1;
}

static int selector_range(uintptr_t p, size_t n) {
    if (!p || !n || p > UINTPTR_MAX - (n - 1)) return 0;
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_native_ready, memory_order_acquire)) return p != 0;
#endif
    if (dm_guest_as_contains(p) && dm_guest_as_contains(p + n - 1)) return 1;
    return selector_loaded_module_range(p, n);
}

// OBS38 is a passive type-specific receiver cache. It runs at the shared
// native list-widget update entry and never calls back into game code.
static void selector_list_widget_observe(const uint64_t *regs) {
    if (!regs || !atomic_load_explicit(&g_selector_hook_installed, memory_order_acquire) ||
        !dm_botw_touch_hud_active() || strcmp(DM_GAME_ID, "01007EF00011E000") ||
        strcmp(dm_main_build(), BOTW_BUILD)) return;
    uintptr_t widget = (uintptr_t)regs[0];
    if (!selector_range(widget, 0x314)) return;
    uintptr_t vtable = selector_read_ptr(widget, 0);
    uintptr_t expected_vtable = 0, expected_update = 0;
    int identity_valid = 0;
#ifdef DM_TEST_HOOKS
    if (g_test_list_widget_override) {
        expected_vtable = g_test_list_widget_vtable;
        expected_update = g_test_list_widget_update;
        identity_valid = expected_vtable && expected_update && vtable == expected_vtable &&
                         selector_read_ptr(expected_vtable, BOTW_LIST_WIDGET_VTABLE_SLOT) == expected_update;
    } else
#endif
    {
        module_t *main = NULL;
        for (int i = 0; i < g_nmod; i++)
            if (!strcmp(g_mod[i].name, "main") && g_mod[i].loaded) { main = &g_mod[i]; break; }
        if (!main || !main->base) return;
        expected_vtable = (uintptr_t)(main->base + BOTW_LIST_WIDGET_VTABLE);
        expected_update = (uintptr_t)(main->base + BOTW_LIST_WIDGET_UPDATE);
        identity_valid = selector_loaded_module_range(expected_vtable, BOTW_LIST_WIDGET_VTABLE_SLOT + sizeof(uintptr_t)) &&
                         selector_loaded_module_range(expected_update, 4) && vtable == expected_vtable &&
                         selector_read_ptr(expected_vtable, BOTW_LIST_WIDGET_VTABLE_SLOT) == expected_update;
    }
    if (!identity_valid) return;

    int32_t current = 0, wanted = 0;
    memcpy(&current, (const void *)(widget + 0x30c), sizeof current);
    memcpy(&wanted, (const void *)(widget + 0x310), sizeof wanted);
    uint64_t frame = dm_guest_frame();
    int changed = 0;
    pthread_mutex_lock(&g_list_widget_observations_mu);
    botw_list_widget_observation_t *slot = NULL, *oldest = &g_list_widget_observations[0];
    for (int i = 0; i < LIST_WIDGET_CACHE_SLOTS; i++) {
        botw_list_widget_observation_t *candidate = &g_list_widget_observations[i];
        if (candidate->widget == widget) { slot = candidate; break; }
        if (!candidate->widget && !slot) slot = candidate;
        if (candidate->seen < oldest->seen) oldest = candidate;
    }
    if (!slot) slot = oldest;
    changed = slot->widget != widget || slot->current != current || slot->wanted != wanted;
    *slot = (botw_list_widget_observation_t){widget, frame, current, wanted};
    pthread_mutex_unlock(&g_list_widget_observations_mu);
    if (changed && atomic_load_explicit(&g_trace, memory_order_acquire))
        LOG("BOTW list widget observe frame=%llu class=%p widget=%p current=%d wanted=%d",
            (unsigned long long)frame, (void *)vtable, (void *)widget, current, wanted);
}

static int selector_screen_name(uintptr_t screen, char out[64]) {
    if (!screen || !selector_range(screen, 0x80)) return 0;
    uintptr_t vtable = selector_read_ptr(screen, 0);
    uintptr_t getter = 0;
    int test_override = 0;
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_native_ready, memory_order_acquire)) {
        getter = atomic_load_explicit(&g_test_native_screen_name_getter, memory_order_acquire);
        test_override = 1;
    }
#endif
    if (!getter) {
        if (!vtable || !selector_loaded_module_range(vtable + 0x78, sizeof(uintptr_t))) return 0;
        getter = selector_read_ptr(vtable, 0x78);
    }
    // Screen names use the native raw-const-char-pointer ABI. Validate the
    // virtual slot and implementation in the loaded exact-build module; only
    // test fixtures override that call with an equivalent C-string provider.
    if (!getter || (!test_override && !selector_loaded_module_range(getter, 4)) ||
        (test_override && !selector_range(getter, 4))) return 0;
    const char *native_name = ((const char *(*)(uintptr_t))getter)(screen);
    uintptr_t address = (uintptr_t)native_name;
    if (!address) return 0;
    for (size_t i = 0; i < 64; i++) {
        if (address > UINTPTR_MAX - i || !selector_range(address + i, 1)) return 0;
        char c = *(const char *)(address + i);
        out[i] = c;
        if (!c) return i > 0;
        if (c < 0x20 || c > 0x7e) return 0;
    }
    out[0] = 0;
    return 0;
}

static int selector_name_prefix(const char *name, const char *prefix) {
    return strncmp(name, prefix, strlen(prefix)) == 0;
}

static int selector_pointer_screen_name(const char *name) {
    if (!name || !*name ||
        selector_name_prefix(name, "MainScreen") ||
        !strcmp(name, "DoCommand_00") || !strcmp(name, "MainShortCut_00") ||
        !strcmp(name, "PauseMenuBG_00") || !strcmp(name, "AppCamera_00") ||
        !strcmp(name, "BoxCursorTV") || !strcmp(name, "SeekPadMenuBG_00")) return 0;
    return !strcmp(name, "PauseMenu_00") || !strcmp(name, "Title_00") ||
        !strcmp(name, "AppHome_00") || !strcmp(name, "AppTool_00") || selector_name_prefix(name, "AppMap") ||
        selector_name_prefix(name, "SystemWindow") || selector_name_prefix(name, "GameOver") ||
        selector_name_prefix(name, "ShopBtnList") || selector_name_prefix(name, "Message") ||
        !strcmp(name, "AppSystemWindow_00") || !strcmp(name, "OptionWindow_00") ||
        !strcmp(name, "End_00") || !strcmp(name, "ControllerWindow_00") ||
        !strcmp(name, "DLCWindow_00");
}

static uintptr_t selector_read_ptr(uintptr_t p, size_t off) {
    uintptr_t v = 0;
    if (p && p <= UINTPTR_MAX - off && selector_range(p + off, sizeof v))
        memcpy(&v, (const void *)(p + off), sizeof v);
    return v;
}

// The selector request slot is also used by screen-owned lists. A non-null
// request for another entry belongs to the native screen until it clears or
// changes that slot; a transient focus pointer alone must not steal it.
static int selector_request_slot_available(uintptr_t manager, uintptr_t entry) {
    if (!entry || !selector_range(manager, 0x58)) return 0;
    uintptr_t pending = selector_read_ptr(manager, 0x50);
    return !pending || pending == entry;
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
                                 const dm_botw_touch_menu_view *view, int view_valid,
                                 const char *screen_name) {
    if (!manager || !atomic_load_explicit(&g_trace, memory_order_acquire)) return;
    selector_trace_state_t state;
    memset(&state, 0, sizeof state);
    state.manager = manager; state.focus = focus; state.screen = screen;
    state.vtable = vtable; state.root = root; state.group = group;
    state.input_active = input_active; state.inventory_screen = inventory_screen;
    state.popup_active = popup_active; state.view_valid = view_valid;
    if (screen_name) snprintf(state.screen_name, sizeof state.screen_name, "%s", screen_name);
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
    LOG("BOTW menu selector state manager=%p focus=%p screen=%p vtable=%p name=%s shown=(%d,%d) group=%d input=%d inventory=%d popup=%d root=%p view=%d generic=%d targets=%d back=%d inventoryVisible=%d",
        (void *)manager, (void *)focus, (void *)screen, (void *)vtable,
        state.screen_name,
        shown_fd, shown_fe, group, input_active, inventory_screen, popup_active,
        (void *)root, view_valid, state.generic_mode, state.generic_count,
        state.back_valid, state.inventory_visible);
}

// Exactly one visible hit pane under the part identifies that part's touch
// area. Zero or several are ambiguous and stay untargeted, as before.
static int selector_hit_under_part(const generic_hit_t *hits, int count, uintptr_t root,
                                   uintptr_t part, int *match) {
    int found = -1, matches = 0;
    for (int h = 0; h < count; h++)
        if (hits[h].root == root && selector_nearest_part(hits[h].pane) == part) {
            found = h; matches++;
        }
    if (match) *match = matches == 1 ? found : -1;
    return matches;
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
    generic_hit_t alt_hits[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
    generic_hit_t texts[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
    int hit_count = generic_hit_snapshot(hits, menu_render_frame());
    int alt_hit_count = generic_alt_hit_snapshot(alt_hits, menu_render_frame());
    int text_count = generic_text_snapshot(texts, menu_render_frame());
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
                uintptr_t part = selector_nearest_part(owner_pane);
                // Native owners may be cursors or hit panes. Their nearest
                // Pa_* part is the common identity; require one visible hit
                // under that part instead of assuming an owner pane name.
                // B_Hit_00 is the primary name; the part's other B_* bounds
                // (AppMap's B_Btn_00 stamp buttons) are the fallback.
                int alt = 0, h = -1;
                int primary_matches = part ? selector_hit_under_part(hits, hit_count, root, part, &h) : 0;
                if (primary_matches == 0) {
                    alt = 1;
                    if (part) selector_hit_under_part(alt_hits, alt_hit_count, root, part, &h);
                }
                if (part && h >= 0 && emitted < DM_BOTW_MENU_MAX_GENERIC_TARGETS) {
                    const generic_hit_t *hit = alt ? &alt_hits[h] : &hits[h];
                    dm_botw_touch_menu_target *target = &view->generic_targets[emitted++];
                    target->pane = hit->pane;
                    target->owner_pane = owner_pane;
                    target->entry = entry;
                    target->root = root;
                    if (hit->usable) {
                        memcpy(target->rect, hit->rect, sizeof target->rect);
                    } else {
                        int text_match = -1, text_matches = 0;
                        for (int t = 0; t < text_count; t++)
                            if (texts[t].usable && texts[t].root == root &&
                                selector_nearest_part(texts[t].pane) == part) {
                                text_match = t; text_matches++;
                            }
                        if (text_matches == 1) {
                            const float *r = texts[text_match].rect;
                            float pad_y = r[3] * .2f;
                            target->rect[0] = r[0] - .01f;
                            target->rect[1] = r[1] - pad_y;
                            target->rect[2] = r[2] + .02f;
                            target->rect[3] = r[3] + pad_y * 2.0f;
                            if (!rect_intersects_canvas(target->rect)) emitted--;
                        } else {
                            emitted--;
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
    char screen_name[64] = {0};
    int has_screen_name = selector_screen_name(screen, screen_name);
    int pointer_screen = has_screen_name && selector_pointer_screen_name(screen_name);
    uintptr_t focused = selector_read_ptr(manager, 0x48);
    uintptr_t focused_owner = selector_read_ptr(focused, 0x18);
    uintptr_t focused_pane = selector_read_ptr(focused_owner, 0x60);
    selector_pane_visible_alpha(focused_pane, &view.generic_root);
    view.generic_key ^= (uint64_t)view.generic_root << 1;
    view.page_key = view.generic_key;
    if (!(pointer_screen && input_active && screen && view.generic_root && view.generic_key &&
          selector_find_generic_targets(manager, screen, group, view.generic_root, native_screen_shown,
                                        native_group_getter, &view) > 0))
        view.generic_count = 0;
    // The map is a separate full-screen native surface with its own stick
    // controls; keep its freshness through the generic publication, which
    // otherwise replaces the whole view.
    pthread_mutex_lock(&g_native_view_mu);
    dm_botw_touch_menu_view native = snapshot_native_view_locked();
    int live_back_label = 0;
    for (int i = 0; i < GUIDE_SLOTS; i++) {
        if (g_native_view.guide_icon_valid[i] &&
            guide_glyph_button(g_native_view.guide_icon_glyph[i]) == DM_BTN_B &&
            frame >= g_native_view.guide_icon_seen[i] && frame - g_native_view.guide_icon_seen[i] <= 2 &&
            g_native_view.guide_text_valid[i] && frame >= g_native_view.guide_text_seen[i] &&
            frame - g_native_view.guide_text_seen[i] <= 2) {
            live_back_label = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_native_view_mu);
    (void)native_screen_shown; (void)native_group_getter;
    // The same owner validator serves selector ticks and Pane observers; a
    // live Pa_Map pane alone never makes the public touch view active.
    int map_view_applied = selector_map_view_for_manager(manager, frame, &view, NULL, NULL);
    int pause_screen = !strcmp(screen_name, "PauseMenu_00");
    // Back is optional on native menus. Prefer prompts in the focused root;
    // only PauseMenu has the proven separate PauseMenuInfo footer fallback.
    if (!map_view_applied && view.generic_mode && view.generic_root) {
        if (generic_back_prompt_snapshot(view.generic_root, frame, view.back))
            view.back_valid = 1;
        generic_action_prompts_to_view(view.generic_root, frame, &view);
        int inherit_bar = pause_screen && allow_pause_header;
        if (!view.back_valid && inherit_bar && live_back_label && native.back_valid) {
            view.back_valid = 1;
            memcpy(view.back, native.back, sizeof view.back);
        }
        if (inherit_bar) {
            for (int i = 0; i < native.footer_action_count; i++) {
                uint64_t button = native.footer_action_buttons[i];
                if (!generic_action_button(button) ||
                    view.footer_action_count >= DM_BOTW_MENU_MAX_FOOTER_ACTIONS) continue;
                int at = view.footer_action_count++;
                view.footer_action_buttons[at] = button;
                memcpy(view.footer_actions[at], native.footer_actions[i], sizeof view.footer_actions[at]);
            }
        }
        if (!strcmp(screen_name, "AppTool_00")) {
            uintptr_t apphome_screen = 0, apphome_root = 0;
            if (selector_apphome_owner_active(manager, group, native_screen_shown,
                                              native_group_getter, &apphome_screen,
                                              &apphome_root))
                selector_copy_apphome_prompts(frame, group, apphome_screen,
                                              apphome_root, &view);
        } else if (!strcmp(screen_name, "AppMap_00")) {
            module_t *main = NULL;
            for (int i = 0; i < g_nmod; i++)
                if (!strcmp(g_mod[i].name, "main") && g_mod[i].loaded) { main = &g_mod[i]; break; }
            if (main && !strcmp(main->build_id, BOTW_BUILD)) {
                uintptr_t map_screen = 0, apphome_screen = 0, apphome_root = 0;
                if (selector_map_owner_active(manager, group,
                        (uintptr_t)(main->base + 0x1ce8298), native_screen_shown,
                        native_group_getter, view.generic_root, &map_screen,
                        &apphome_screen, &apphome_root) && map_screen == screen)
                    selector_copy_apphome_prompts(frame, group, apphome_screen,
                                                  apphome_root, &view);
            }
        }
    }
    dm_botw_touch_menu_observe(&view);
    selector_trace_state(manager, focused, screen, selector_read_ptr(screen, 0),
                         view.generic_root, group, input_active, 0, 0, &view, 1,
                         screen_name);
}

static int selector_native_inventory_context(int pause_screen_class,
                                              int inventory_geometry,
                                              uintptr_t inventory_root,
                                              uintptr_t focused_root,
                                              int popup_owner) {
    return (pause_screen_class && inventory_geometry && inventory_root &&
            focused_root == inventory_root) || popup_owner;
}

static int selector_apphome_owner_active(uintptr_t manager, int group,
                                         uintptr_t native_screen_shown,
                                         uintptr_t native_group_getter,
                                         uintptr_t *out_screen,
                                         uintptr_t *out_root) {
    if (out_screen) *out_screen = 0;
    if (out_root) *out_root = 0;
    if (!manager || group < 0 || !native_screen_shown || !native_group_getter) return 0;
    module_t *main = NULL;
    for (int i = 0; i < g_nmod; i++)
        if (!strcmp(g_mod[i].name, "main") && g_mod[i].loaded) { main = &g_mod[i]; break; }
    if (!main || strcmp(main->build_id, BOTW_BUILD)) return 0;
    uintptr_t apphome_vtable = (uintptr_t)(main->base + 0x1ce75f0);
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
        uintptr_t apphome = selector_read_ptr(screens, (size_t)i * sizeof(uintptr_t));
        if (!selector_range(apphome, 0x100) || selector_read_ptr(apphome, 0) != apphome_vtable ||
            !((int (*)(uintptr_t))native_screen_shown)(apphome) ||
            ((int (*)(uintptr_t))native_group_getter)(apphome) != group) continue;
        int8_t shown = -1; uint8_t mode = 0;
        memcpy(&shown, (const void *)(apphome + 0xfd), sizeof shown);
        memcpy(&mode, (const void *)(apphome + 0xfe), sizeof mode);
        uintptr_t state = selector_read_ptr(apphome, 0x38);
        if (shown < 0 || mode != 2 || !selector_range(state, 0x39) ||
            !(((const uint8_t *)state)[0x38] & 2)) continue;
        uintptr_t wrapper = selector_read_ptr(apphome, 0x30);
        uintptr_t root = selector_read_ptr(wrapper, 0x18);
        if (!selector_range(wrapper, 0x20) || !selector_range(root, PANE_NAME + 16) ||
            selector_read_ptr(root, PANE_PARENT)) continue;
        char root_name[17]; pane_name((const uint8_t *)root, root_name);
        if (strcmp(root_name, "RootPane")) continue;
        if (out_screen) *out_screen = apphome;
        if (out_root) *out_root = root;
        return 1;
    }
    return 0;
}

static int selector_map_owner_active(uintptr_t manager, int group,
                                     uintptr_t map_vtable, uintptr_t native_screen_shown,
                                     uintptr_t native_group_getter, uintptr_t map_root,
                                     uintptr_t *out_screen, uintptr_t *out_apphome_screen,
                                     uintptr_t *out_apphome_root) {
    if (out_screen) *out_screen = 0;
    if (out_apphome_screen) *out_apphome_screen = 0;
    if (out_apphome_root) *out_apphome_root = 0;
    if (!manager || group < 0 || !map_vtable || !native_screen_shown ||
        !native_group_getter || !map_root) return 0;
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
    // AppMap remains shown for the gameplay minimap; AppHome's active screen
    // and its live layout root establish the separate fullscreen surface.
    uintptr_t apphome_screen = 0, apphome_root = 0;
    if (!selector_apphome_owner_active(manager, group, native_screen_shown,
                                       native_group_getter, &apphome_screen, &apphome_root)) return 0;
    for (uint32_t i = 0; i < count; i++) {
        if (((const uint8_t *)active)[i] & 0x80) continue;
        uintptr_t screen = selector_read_ptr(screens, (size_t)i * sizeof(uintptr_t));
        if (!selector_range(screen, 0xa0) || selector_read_ptr(screen, 0) != map_vtable ||
            !((int (*)(uintptr_t))native_screen_shown)(screen) ||
            ((int (*)(uintptr_t))native_group_getter)(screen) != group) continue;
        uintptr_t state = selector_read_ptr(screen, 0x38);
        if (!selector_range(state, 0x39) || !(((const uint8_t *)state)[0x38] & 2)) continue;
        uintptr_t sentinel = screen + 0x88;
        uintptr_t node = selector_read_ptr(screen, 0x90);
        int32_t delta = 0;
        memcpy(&delta, (const void *)(screen + 0x9c), sizeof delta);
        if (delta < 0 || delta > 0x400 || node == sentinel) continue;
        uintptr_t end = sentinel - (uintptr_t)delta;
        node -= (uintptr_t)delta;
        for (unsigned n = 0; n < 512 && node != end; n++) {
            uintptr_t entry = node;
            if (!selector_range(entry, (size_t)delta + 0x28)) break;
            uintptr_t owner = selector_read_ptr(entry, 0x18);
            uintptr_t pane = selector_read_ptr(owner, 0x60);
            if (selector_read_ptr(entry, 0x20) == screen && selector_range(owner, 0x62) &&
                selector_range(pane, PANE_NAME + 16) &&
                selector_ancestor_named(pane, "RootPane") == map_root) {
                if (out_screen) *out_screen = screen;
                if (out_apphome_screen) *out_apphome_screen = apphome_screen;
                if (out_apphome_root) *out_apphome_root = apphome_root;
                return 1;
            }
            uintptr_t next = selector_read_ptr(entry, (size_t)delta + 8);
            if (!next || next < (uintptr_t)delta) break;
            node = next - (uintptr_t)delta;
        }
    }
    return 0;
}

static int selector_copy_apphome_prompts(uint64_t frame, int group,
                                         uintptr_t apphome_screen, uintptr_t apphome_root,
                                         dm_botw_touch_menu_view *view) {
    if (!view || !apphome_screen || !apphome_root || group < 0) return 0;
    pthread_mutex_lock(&g_native_view_mu);
    dm_botw_touch_menu_view native = snapshot_native_view_locked();
    uintptr_t footer_root = g_native_view.footer_root;
    pthread_mutex_unlock(&g_native_view_mu);
    if (frame < native.render_frame || frame - native.render_frame > 2 ||
        footer_root != apphome_root) return 0;
    view->prompt_owner_valid = 1;
    view->prompt_owner_screen = apphome_screen;
    view->prompt_owner_root = apphome_root;
    view->prompt_owner_frame = frame;
    view->prompt_owner_group = group;
    if (!view->back_valid && native.back_valid) {
        view->back_valid = 1;
        memcpy(view->back, native.back, sizeof view->back);
    }
    for (int i = 0; i < native.footer_action_count; i++) {
        uint64_t button = native.footer_action_buttons[i];
        if (!generic_action_button(button) ||
            view->footer_action_count >= DM_BOTW_MENU_MAX_FOOTER_ACTIONS) continue;
        int seen = 0;
        for (int j = 0; j < view->footer_action_count; j++)
            if (view->footer_action_buttons[j] == button) seen = 1;
        if (seen) continue;
        int at = view->footer_action_count++;
        view->footer_action_buttons[at] = button;
        memcpy(view->footer_actions[at], native.footer_actions[i], sizeof view->footer_actions[at]);
    }
    return 1;
}

static void selector_service_map_tap(uint64_t frame, const dm_botw_touch_menu_view *view) {
    if (!view || !view->map_visible || !view->generic_screen || !view->map_pane || !view->map_root ||
        !dm_botw_touch_hud_active() || strcmp(DM_GAME_ID, "01007EF00011E000") ||
        strcmp(dm_main_build(), BOTW_BUILD)) return;
    float touch[2] = {0}, matrix[6] = {0}, target[2] = {0};
    uintptr_t expected_pane = 0, expected_root = 0, expected_model = 0;
    int pending = 0, issued = 0, ack_ready = 0, attempts = 0;
    uint64_t serial = 0, requested_frame = 0, issued_frame = 0, last_call_frame = 0;
    pthread_mutex_lock(&g_menu_mu);
    serial = g_map_tap.serial;
    if (g_map_tap.pending && g_map_tap.pane == view->map_pane &&
        g_map_tap.root == view->map_root && g_map_tap.screen == view->generic_screen &&
        g_map_tap.page_key == view->page_key && g_map_tap.group == view->generic_group &&
        frame >= g_map_tap.requested_frame && frame - g_map_tap.requested_frame <= 4) {
        pending = 1; issued = g_map_tap.issued; ack_ready = g_map_tap.ack_ready;
        serial = g_map_tap.serial;
        requested_frame = g_map_tap.requested_frame;
        issued_frame = g_map_tap.issued_frame;
        last_call_frame = g_map_tap.last_call_frame;
        attempts = g_map_tap.attempts;
        expected_model = g_map_tap.model;
        touch[0] = g_map_tap.point[0]; touch[1] = g_map_tap.point[1];
        target[0] = g_map_tap.target[0]; target[1] = g_map_tap.target[1];
        expected_pane = g_map_tap.pane; expected_root = g_map_tap.root;
    } else if (g_map_tap.pending) {
        if (atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW map tap cancelled frame=%llu owner=%p/%p current=%p/%p",
                (unsigned long long)frame, (void *)g_map_tap.pane, (void *)g_map_tap.root,
                (void *)view->map_pane, (void *)view->map_root);
        if (g_map_tap.serial == serial) map_tap_clear_locked();
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (!pending || ack_ready || !expected_pane || !expected_root) return;

    uintptr_t transform_pane = 0, transform_root = 0, transform_map_pane = 0;
    uint64_t transform_frame = 0;
    pthread_mutex_lock(&g_native_view_mu);
    transform_pane = g_native_view.map_transform_pane;
    transform_root = g_native_view.map_transform_root;
    transform_map_pane = g_native_view.map_transform_map_pane;
    transform_frame = g_native_view.map_transform_seen;
    memcpy(matrix, g_native_view.map_transform, sizeof matrix);
    pthread_mutex_unlock(&g_native_view_mu);
    if (!transform_pane || transform_root != expected_root || transform_map_pane != expected_pane ||
        frame < transform_frame ||
        frame - transform_frame > 2) return;

    if (!selector_range(view->generic_screen, 0x3630)) return;
    uintptr_t mapview = selector_read_ptr(view->generic_screen, 0x3628);
    if (!selector_range(mapview, 0x8e0)) return;
    uintptr_t model = selector_read_ptr(mapview, 0x8d8);
    if (!selector_range(model, 0x3878)) return;
    uintptr_t cursor_object = selector_read_ptr(mapview, 0x128);
    if (!selector_range(cursor_object, 0x3bb8)) return;
    uintptr_t cursor_pane = selector_read_ptr(cursor_object, 0x3bb0);
    if (!selector_range(cursor_pane, PANE_NAME + 16) ||
        selector_ancestor_named(cursor_pane, "RootPane") != expected_root) return;
    char cursor_name[17];
    pane_name((const uint8_t *)cursor_pane, cursor_name);
    if (strcmp(cursor_name, "Pa_Cursor_00")) return;
    if (!selector_range(model + 0x3868, 8) || !selector_range(model + 0x3870, 8)) return;
    float current[2], native_target[2];
    memcpy(current, (const void *)(model + 0x3868), sizeof current);
    memcpy(native_target, (const void *)(model + 0x3870), sizeof native_target);
    float cursor_x = 0.0f, cursor_y = 0.0f;
    memcpy(&cursor_x, (const void *)(cursor_pane + PANE_MATRIX + 0x0c), sizeof cursor_x);
    memcpy(&cursor_y, (const void *)(cursor_pane + PANE_MATRIX + 0x1c), sizeof cursor_y);
    float logical_x = touch[0] * 1280.0f - 640.0f;
    float logical_y = 360.0f - touch[1] * 720.0f;
    const float finite_values[] = {matrix[0], matrix[1], matrix[2], matrix[3], matrix[4], matrix[5],
        current[0], current[1], native_target[0], native_target[1], cursor_x, cursor_y,
        logical_x, logical_y, touch[0], touch[1]};
    for (size_t i = 0; i < sizeof finite_values / sizeof finite_values[0]; i++)
        if (!isfinite(finite_values[i])) return;
    float current_projected_x = matrix[0] * current[0] + matrix[1] * current[1] + matrix[2];
    float current_projected_y = matrix[3] * current[0] + matrix[4] * current[1] + matrix[5];
    if (!isfinite(current_projected_x) || !isfinite(current_projected_y)) return;
    if (!issued) {
        if (fabsf(current_projected_x - cursor_x) > 8.0f ||
            fabsf(current_projected_y - cursor_y) > 8.0f) return;
        target[0] = target[1] = 0.0f;
        if (!map_inverse_point(matrix, logical_x, logical_y, &target[0], &target[1])) return;
        if (fabsf(target[0]) > 1000000.0f || fabsf(target[1]) > 1000000.0f) return;

        uintptr_t set_current = 0, set_target = 0;
        if (!selector_map_cursor_setters(&set_current, &set_target)) return;
        pthread_mutex_lock(&g_menu_mu);
        int still_pending = g_map_tap.pending && g_map_tap.serial == serial && !g_map_tap.issued &&
            g_map_tap.pane == expected_pane && g_map_tap.root == expected_root &&
            g_map_tap.screen == view->generic_screen && g_map_tap.page_key == view->page_key &&
            g_map_tap.group == view->generic_group;
        if (still_pending) {
            g_map_tap.issued = 1;
            g_map_tap.issued_frame = frame;
            g_map_tap.last_call_frame = frame;
            g_map_tap.attempts = 1;
            g_map_tap.model = model;
            memcpy(g_map_tap.target, target, sizeof target);
        }
        pthread_mutex_unlock(&g_menu_mu);
        if (!still_pending) return;
        // These native setters only update cursor points; D8C89C also recenters N_MapT.
        ((void (*)(uintptr_t, const float *))set_current)(model, target);
        ((void (*)(uintptr_t, const float *))set_target)(model, target);
        float clamped_target[2];
        memcpy(clamped_target, (const void *)(model + 0x3870), sizeof clamped_target);
        pthread_mutex_lock(&g_menu_mu);
        if (g_map_tap.pending && g_map_tap.serial == serial && g_map_tap.issued && g_map_tap.pane == expected_pane &&
            g_map_tap.root == expected_root && g_map_tap.screen == view->generic_screen &&
            g_map_tap.page_key == view->page_key && g_map_tap.group == view->generic_group &&
            isfinite(clamped_target[0]) && isfinite(clamped_target[1])) {
            memcpy(g_map_tap.target, clamped_target, sizeof clamped_target);
        }
        pthread_mutex_unlock(&g_menu_mu);
        if (atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW map tap set frame=%llu serial=%llu point=(%.2f,%.2f) owner=%p/%p attempt=1",
                (unsigned long long)frame, (unsigned long long)serial,
                clamped_target[0], clamped_target[1],
                (void *)expected_pane, (void *)expected_root);
        return;
    }
    if (frame <= last_call_frame || model != expected_model || !selector_range(model + 0x3868, 8) ||
        !selector_range(model + 0x3870, 8)) return;
    if (fabsf(current[0] - target[0]) <= .5f && fabsf(current[1] - target[1]) <= .5f &&
        fabsf(native_target[0] - target[0]) <= .5f && fabsf(native_target[1] - target[1]) <= .5f &&
        fabsf(cursor_x - logical_x) <= 8.0f && fabsf(cursor_y - logical_y) <= 8.0f &&
        fabsf(matrix[0] * native_target[0] + matrix[1] * native_target[1] + matrix[2] - cursor_x) <= 8.0f &&
        fabsf(matrix[3] * native_target[0] + matrix[4] * native_target[1] + matrix[5] - cursor_y) <= 8.0f) {
        int ack_published = 0;
        pthread_mutex_lock(&g_menu_mu);
        if (g_map_tap.pending && g_map_tap.serial == serial && g_map_tap.issued && !g_map_tap.ack_ready &&
            g_map_tap.model == model && g_map_tap.pane == expected_pane && g_map_tap.root == expected_root &&
            g_map_tap.page_key == view->page_key && g_map_tap.group == view->generic_group) {
            g_map_tap.ack_ready = 1;
            g_map_tap.ack_frame = frame;
            ack_published = 1;
        }
        pthread_mutex_unlock(&g_menu_mu);
        if (ack_published && atomic_load_explicit(&g_trace, memory_order_acquire))
            LOG("BOTW map tap ack frame=%llu serial=%llu point=(%.2f,%.2f) cursor=(%.1f,%.1f) screen=(%.1f,%.1f)",
                (unsigned long long)frame, (unsigned long long)serial, target[0], target[1],
                cursor_x, cursor_y, logical_x, logical_y);
        return;
    }
    if (attempts >= 4 || frame < issued_frame || frame - requested_frame >= 4) return;
    uintptr_t set_current = 0, set_target = 0;
    if (!selector_map_cursor_setters(&set_current, &set_target)) return;
    pthread_mutex_lock(&g_menu_mu);
    int still_pending = g_map_tap.pending && g_map_tap.serial == serial && g_map_tap.issued && !g_map_tap.ack_ready &&
        g_map_tap.model == model && g_map_tap.pane == expected_pane &&
        g_map_tap.root == expected_root && g_map_tap.page_key == view->page_key &&
        g_map_tap.group == view->generic_group && g_map_tap.attempts == attempts;
    pthread_mutex_unlock(&g_menu_mu);
    if (!still_pending) return;
    ((void (*)(uintptr_t, const float *))set_current)(model, target);
    ((void (*)(uintptr_t, const float *))set_target)(model, target);
    memcpy(current, (const void *)(model + 0x3868), sizeof current);
    memcpy(native_target, (const void *)(model + 0x3870), sizeof native_target);
    if (!isfinite(current[0]) || !isfinite(current[1]) || !isfinite(native_target[0]) ||
        !isfinite(native_target[1]) || fabsf(current[0] - native_target[0]) > .5f ||
        fabsf(current[1] - native_target[1]) > .5f) return;
    pthread_mutex_lock(&g_menu_mu);
    if (g_map_tap.pending && g_map_tap.serial == serial && g_map_tap.issued && g_map_tap.model == model &&
        g_map_tap.pane == expected_pane && g_map_tap.root == expected_root &&
        g_map_tap.page_key == view->page_key && g_map_tap.group == view->generic_group) {
        g_map_tap.last_call_frame = frame;
        g_map_tap.attempts++;
        memcpy(g_map_tap.target, current, sizeof current);
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (atomic_load_explicit(&g_trace, memory_order_acquire))
        LOG("BOTW map tap retry frame=%llu serial=%llu point=(%.2f,%.2f) attempt=%d cursor=(%.1f,%.1f)",
            (unsigned long long)frame, (unsigned long long)serial, target[0], target[1],
            attempts + 1, cursor_x, cursor_y);
}

static int selector_map_view_for_manager(uintptr_t manager, uint64_t frame,
                                         dm_botw_touch_menu_view *view,
                                         uintptr_t *candidate_pane,
                                         uintptr_t *candidate_root) {
    if (candidate_pane) *candidate_pane = 0;
    if (candidate_root) *candidate_root = 0;
    if (!view || !dm_botw_touch_hud_active() ||
        strcmp(DM_GAME_ID, "01007EF00011E000") || strcmp(dm_main_build(), BOTW_BUILD)) return 0;
    uintptr_t pane = 0, root = 0;
    float rect[4] = {0};
    pthread_mutex_lock(&g_native_view_mu);
    int candidate = g_native_view.map_candidate_visible &&
        frame >= g_native_view.map_candidate_seen && frame - g_native_view.map_candidate_seen <= 2;
    if (candidate) {
        pane = g_native_view.map_candidate_pane;
        root = g_native_view.map_candidate_root;
        memcpy(rect, g_native_view.map_candidate_rect, sizeof rect);
    }
    pthread_mutex_unlock(&g_native_view_mu);
    if (!candidate || !pane || !root) return 0;
    if (candidate_pane) *candidate_pane = pane;
    if (candidate_root) *candidate_root = root;

    module_t *main = NULL;
    for (int i = 0; i < g_nmod; i++)
        if (!strcmp(g_mod[i].name, "main") && g_mod[i].loaded) { main = &g_mod[i]; break; }
    if (!main || !manager || !selector_range(manager, 0x58) ||
        selector_read_ptr(manager, 0) != (uintptr_t)(main->base + 0x1d0cdf8) ||
        selector_read_ptr(manager, 0x48) != 0) return 0;

    uintptr_t native_group_getter = (uintptr_t)(main->base + 0xf6e2c8);
    uintptr_t native_screen_shown = (uintptr_t)(main->base + 0xf6e08c);
#ifdef DM_TEST_HOOKS
    if (atomic_load_explicit(&g_test_generic_selector, memory_order_acquire)) {
        native_group_getter = g_test_native_group_getter;
        native_screen_shown = g_test_native_screen_shown;
    }
#endif
    // OBS37 and Pane::Calculate share the game UI thread. Cache this proof by
    // guest frame and candidate identity so paired pre/post pane callbacks do
    // not repeat native queries in a single frame.
    int group = -1, valid = 0;
    uintptr_t map_screen = 0, apphome_screen = 0, apphome_root = 0;
    uintptr_t focus = selector_read_ptr(manager, 0x48);
    if (g_map_validation_cache.frame == frame && g_map_validation_cache.manager == manager &&
        g_map_validation_cache.pane == pane && g_map_validation_cache.root == root &&
        g_map_validation_cache.focus == focus) {
        valid = g_map_validation_cache.result;
        group = g_map_validation_cache.group;
        map_screen = g_map_validation_cache.screen;
        apphome_screen = g_map_validation_cache.apphome_screen;
        apphome_root = g_map_validation_cache.apphome_root;
    } else {
        uintptr_t control = selector_read_ptr(manager, 0x20);
        int input_active = selector_native_input_group(control, native_group_getter, &group);
        valid = input_active && selector_map_owner_active(manager, group,
            (uintptr_t)(main->base + 0x1ce8298), native_screen_shown,
            native_group_getter, root, &map_screen, &apphome_screen, &apphome_root);
        g_map_validation_cache.frame = frame;
        g_map_validation_cache.manager = manager;
        g_map_validation_cache.pane = pane;
        g_map_validation_cache.root = root;
        g_map_validation_cache.focus = focus;
        g_map_validation_cache.result = valid;
        g_map_validation_cache.group = group;
        g_map_validation_cache.screen = map_screen;
        g_map_validation_cache.apphome_screen = apphome_screen;
        g_map_validation_cache.apphome_root = apphome_root;
    }
    if (!valid || !map_screen) return 0;
    // Publish a clean map surface. The caller may have started with a native
    // PauseMenu snapshot, so copying onto it would leak inventory slots,
    // footer actions or a Back prompt owned by an unrelated root.
    dm_botw_touch_menu_view map_view = {0};
    map_view.render_frame = frame;
    map_view.generic_mode = 1;
    map_view.generic_screen = map_screen;
    map_view.generic_root = root;
    map_view.generic_group = group;
    map_view.generic_key = ((uint64_t)(map_screen >> 4) ^ ((uint64_t)(uint32_t)group << 48) ^
                            ((uint64_t)root << 1));
    map_view.page_key = map_view.generic_key;
    map_view.map_visible = 1;
    map_view.map_pane = pane;
    map_view.map_root = root;
    memcpy(map_view.map, rect, sizeof map_view.map);
    if (generic_back_prompt_snapshot(root, frame, map_view.back)) map_view.back_valid = 1;
    generic_action_prompts_to_view(root, frame, &map_view);
    // The + menu footer is drawn under the live AppHome layout root. Match the
    // cached root to the bounded AppHome screen proof before carrying prompts
    // into AppMap; freshness alone does not transfer ownership.
    int native_fresh = selector_copy_apphome_prompts(frame, group, apphome_screen,
                                                      apphome_root, &map_view);
    pthread_mutex_lock(&g_native_view_mu);
    dm_botw_touch_menu_view native = snapshot_native_view_locked();
    pthread_mutex_unlock(&g_native_view_mu);
    selector_service_map_tap(frame, &map_view);
    if (atomic_load_explicit(&g_trace, memory_order_acquire)) {
        static uintptr_t last_root, last_footer;
        static int last_back, last_footers;
        static uint16_t last_glyph[5];
        static float last_rect[4];
        int changed = last_root != root || last_footer != g_native_view.footer_root ||
            last_back != map_view.back_valid || last_footers != map_view.footer_action_count ||
            memcmp(last_rect, map_view.back, sizeof last_rect) != 0;
        for (int i = 0; i < 5; i++) changed |= last_glyph[i] != g_native_view.guide_icon_glyph[i];
        if (changed) {
            last_root = root; last_footer = g_native_view.footer_root;
            last_back = map_view.back_valid; last_footers = map_view.footer_action_count;
            memcpy(last_rect, map_view.back, sizeof last_rect);
            for (int i = 0; i < 5; i++) last_glyph[i] = g_native_view.guide_icon_glyph[i];
            LOG("BOTW map prompts frame=%llu root=%p footerRoot=%p back=%d:(%.3f,%.3f,%.3f,%.3f) footers=%d glyphs=%04x,%04x,%04x,%04x,%04x nativeBack=%d nativeFresh=%d",
                (unsigned long long)frame, (void *)root, (void *)g_native_view.footer_root,
                map_view.back_valid, map_view.back[0], map_view.back[1], map_view.back[2], map_view.back[3],
                map_view.footer_action_count,
                g_native_view.guide_icon_glyph[0], g_native_view.guide_icon_glyph[1],
                g_native_view.guide_icon_glyph[2], g_native_view.guide_icon_glyph[3],
                g_native_view.guide_icon_glyph[4], native.back_valid, native_fresh);
        }
    }
    *view = map_view;
    return 1;
}

static void selector_clear_map_view_if_owned(uintptr_t candidate_pane,
                                             uintptr_t candidate_root,
                                             uint64_t frame) {
    dm_botw_touch_menu_view clear = {0};
    int should_clear = 0;
    pthread_mutex_lock(&g_menu_mu);
    if (g_view_valid && g_view.map_visible &&
        g_map_published_pane == candidate_pane && g_map_published_root == candidate_root) {
        clear.render_frame = frame;
        clear.generic_mode = 1;
        clear.generic_screen = g_view.generic_screen;
        clear.generic_root = g_view.generic_root;
        clear.generic_group = g_view.generic_group;
        clear.generic_key = clear.page_key = g_view.generic_key;
        should_clear = 1;
    }
    pthread_mutex_unlock(&g_menu_mu);
    if (should_clear) dm_botw_touch_menu_observe(&clear);
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
    if (!regs || strcmp(DM_GAME_ID, "01007EF00011E000") ||
        strcmp(dm_main_build(), BOTW_BUILD)) return;
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
    // Retain only the passively validated controller object. This stores no
    // screen state and calls no guest helper; map queries still require a
    // live active BOTW touch HUD and revalidate the object on the UI thread.
    atomic_store_explicit(&g_validated_box_cursor_manager, manager, memory_order_release);
    // When touch mode is off, controller input follows the native selector
    // without any additional guest virtual/native calls.
    if (!dm_botw_touch_hud_active()) return;
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
                                      native_screen_shown, native_group_getter,
                                      pause_screen_class);
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
        if (!selector_request_slot_available(manager, target_entry)) {
            pthread_mutex_lock(&g_menu_mu);
            if (g_target_valid && g_target_generic && g_target_entry == target_entry &&
                g_target_screen == target_screen && g_selector_manager == manager) {
                menu_clear_target_locked();
            }
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
                             current_valid ? &current : NULL, current_valid, NULL);
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
    if (!selector_request_slot_available(manager, entry)) {
        pthread_mutex_lock(&g_menu_mu);
        if (menu_active_locked(frame) && g_target_valid && g_target_pane == pane &&
            g_selector_manager == manager) menu_clear_target_locked();
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
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
    g_map_prompt_down = g_map_prompt_back = 0;
    g_map_prompt_button = 0;
    g_map_prompt_owner_valid = 0; g_map_prompt_owner_group = -1;
    g_map_prompt_owner_screen = g_map_prompt_owner_root = 0;
    g_map_pan_active = 0; g_map_ax = g_map_ay = g_map_ry = 0;
    g_map_ry_frame = 0;
    menu_clear_target_locked();
    map_tap_clear_locked();
}

static void menu_clear_target_locked(void) {
    g_target_valid = g_target_popup = g_confirm_pending = 0;
    g_target_button_bits = 0;
    g_target_category = g_target_generic = g_selector_ready = 0;
    g_target_pane = g_target_owner_pane = g_target_entry = g_target_screen = 0;
    g_target_root = 0;
    g_target_prompt_owner_screen = g_target_prompt_owner_root = 0;
    g_target_prompt_owner_group = -1;
    g_generic_eligible_frame = 0;
    g_generic_eligible_entry = g_generic_eligible_screen = g_generic_eligible_root = 0;
    g_generic_eligible_group = -1;
    g_requested_entry = g_selector_manager = 0;
    g_target_page_key = g_target_popup_key = 0;
}

static void menu_bind_prompt_owner_locked(const dm_botw_touch_menu_view *view) {
    g_target_prompt_owner_screen = view && view->prompt_owner_valid ? view->prompt_owner_screen : 0;
    g_target_prompt_owner_root = view && view->prompt_owner_valid ? view->prompt_owner_root : 0;
    g_target_prompt_owner_group = view && view->prompt_owner_valid ? view->prompt_owner_group : -1;
}

static int menu_prompt_owner_live_locked(uint64_t frame) {
    return !g_target_prompt_owner_root ||
        (g_view.prompt_owner_valid && g_view.prompt_owner_screen == g_target_prompt_owner_screen &&
         g_view.prompt_owner_root == g_target_prompt_owner_root &&
         g_view.prompt_owner_group == g_target_prompt_owner_group &&
         frame >= g_view.prompt_owner_frame && frame - g_view.prompt_owner_frame <= 2);
}

void dm_botw_touch_menu_observe(const dm_botw_touch_menu_view *view) {
    int notify = 0;
    dm_botw_touch_menu_view report = {0};
    uint64_t frame = menu_render_frame();
    pthread_mutex_lock(&g_menu_mu);
    int was_active = menu_active_locked(frame);
    int had_map_owner = g_view_valid && g_view.map_visible;
    uintptr_t old_map_pane = g_view.map_pane, old_map_root = g_view.map_root;
    uintptr_t old_map_screen = g_view.generic_screen;
    uint64_t old_map_page = g_view.page_key;
    int old_map_group = g_view.generic_group;
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
    if (!late_inventory_view) {
        if (g_view_valid && g_view.map_visible) {
            g_map_published_pane = g_view.map_pane;
            g_map_published_root = g_view.map_root;
        } else {
            g_map_published_pane = g_map_published_root = 0;
        }
    }
    int lost_map_owner = !late_inventory_view && had_map_owner &&
        (!g_view_valid || !g_view.map_visible ||
         g_view.map_pane != old_map_pane || g_view.map_root != old_map_root ||
         g_view.generic_screen != old_map_screen || g_view.page_key != old_map_page ||
         g_view.generic_group != old_map_group);
    if (lost_map_owner) {
        g_pointer_down = g_pointer_dragged = g_map_pan_active = 0;
        g_map_ax = g_map_ay = g_map_ry = 0;
        g_map_ry_frame = 0;
        map_tap_clear_locked();
        g_last_apply_valid = 0;
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

int dm_botw_touch_map_active(void) {
    int active;
    pthread_mutex_lock(&g_menu_mu);
    active = menu_active_locked(menu_render_frame()) && g_view.map_visible && g_pointer_down &&
             !g_map_prompt_down &&
             point_in_rect(g_map_start[0], g_map_start[1], g_view.map);
    pthread_mutex_unlock(&g_menu_mu);
    return active;
}

void dm_botw_touch_menu_pinch(float ratio) {
    // Discard pinch samples outside touch mode so a stale zoom value cannot
    // be replayed when BOTW's touch HUD becomes active again. The primary
    // pointer is cancelled before iOS sends pinch updates, so validate the
    // current focused map surface rather than requiring pointer ownership.
    pthread_mutex_lock(&g_menu_mu);
    int map_active = menu_active_locked(menu_render_frame()) && g_view.map_visible;
    if (!map_active) {
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    int32_t ry = 0;
    if (isfinite(ratio) && ratio > 0 && fabsf(ratio - 1.0f) >= 0.03f) {
        float v = (ratio - 1.0f) * 16000.0f;
        if (v < -32767.0f) v = -32767.0f; else if (v > 32767.0f) v = 32767.0f;
        ry = (int32_t)v;
    }
    g_map_ry = ry;
    g_map_ry_frame = menu_render_frame();
    g_last_apply_valid = 0;
    pthread_mutex_unlock(&g_menu_mu);
}

static int point_in_rect(float x, float y, const float rect[4]) {
    return rect[2] > 0 && rect[3] > 0 && x >= rect[0] && y >= rect[1] &&
           x < rect[0] + rect[2] && y < rect[1] + rect[3];
}

static int generic_action_button(uint64_t button) {
    return button == DM_BTN_A || button == DM_BTN_B || button == DM_BTN_X ||
           button == DM_BTN_Y || button == DM_BTN_L || button == DM_BTN_R ||
           button == DM_BTN_ZL || button == DM_BTN_ZR;
}

static uint64_t guide_glyph_button(uint16_t glyph) {
    switch (glyph) {
        case 0xe040: return DM_BTN_A;
        case 0xe041: return DM_BTN_B;
        case 0xe042: return DM_BTN_X;
        case 0xe043: return DM_BTN_Y;
        case 0xe044: return DM_BTN_L;
        case 0xe045: return DM_BTN_R;
        case 0xe046: return DM_BTN_ZL;
        case 0xe047: return DM_BTN_ZR;
        default: return 0;
    }
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

static void map_axes_trace_locked(uint64_t frame, uintptr_t pane, uintptr_t root) {
    if (!atomic_load_explicit(&g_trace, memory_order_acquire) ||
        (g_map_axis_trace.valid &&
         g_map_axis_trace.left == g_apply_output_map_left_valid &&
         g_map_axis_trace.right == g_apply_output_map_right_valid &&
         (!g_apply_output_map_left_valid ||
          (g_map_axis_trace.lx == g_apply_output_lx && g_map_axis_trace.ly == g_apply_output_ly)) &&
         (!g_apply_output_map_right_valid || g_map_axis_trace.ry == g_apply_output_ry) &&
         g_map_axis_trace.pane == pane && g_map_axis_trace.root == root)) return;
    g_map_axis_trace.valid = 1;
    g_map_axis_trace.left = g_apply_output_map_left_valid;
    g_map_axis_trace.right = g_apply_output_map_right_valid;
    g_map_axis_trace.lx = g_apply_output_lx; g_map_axis_trace.ly = g_apply_output_ly;
    g_map_axis_trace.ry = g_apply_output_ry;
    g_map_axis_trace.pane = pane; g_map_axis_trace.root = root;
    LOG("BOTW map axes frame=%llu owner=%p/%p left=%d:(%d,%d) rightY=%d:%d",
        (unsigned long long)frame, (void *)pane, (void *)root,
        g_apply_output_map_left_valid, g_apply_output_lx, g_apply_output_ly,
        g_apply_output_map_right_valid, g_apply_output_ry);
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
        g_map_pan_active = 0;
        menu_clear_queue_locked();
        g_last_apply_valid = 0;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
        if (phase == DM_BOTW_MENU_END || phase == DM_BOTW_MENU_CANCEL) {
            menu_clear_queue_locked();
            g_last_apply_valid = 0;
        }
        g_pointer_down = 0;
        pthread_mutex_unlock(&g_menu_mu);
        return;
    }
    if (g_view.map_visible) {
        // The map's own touch surface: one finger pans through the native left
        // stick, a short tap keeps the game's native touch (move cursor), and
        // taps outside it use the live Back/header prompts.
        if (phase == DM_BOTW_MENU_BEGIN) {
            int prompt_back = g_view.back_valid && point_in_rect(x, y, g_view.back);
            int prompt_action = prompt_back ? -1 :
                hit_rects(x, y, g_view.footer_actions, g_view.footer_action_count);
            uint64_t prompt_button = 0;
            if (!prompt_back && prompt_action >= 0)
                prompt_button = g_view.footer_action_buttons[prompt_action];
            menu_clear_queue_locked();
            g_last_apply_valid = 0;
            g_pointer_down = 1;
            g_map_pan_active = 0;
            g_map_ax = g_map_ay = 0;
            g_map_start[0] = x; g_map_start[1] = y;
            g_pointer_page_key = g_view.page_key;
            g_pointer_popup_key = g_view.popup_key;
            if (prompt_back || prompt_action >= 0) {
                g_map_prompt_down = 1;
                g_map_prompt_back = prompt_back;
                g_map_prompt_button = prompt_button;
                g_map_prompt_owner_valid = g_view.prompt_owner_valid;
                g_map_prompt_owner_screen = g_view.prompt_owner_screen;
                g_map_prompt_owner_root = g_view.prompt_owner_root;
                g_map_prompt_owner_group = g_view.prompt_owner_group;
            }
            pthread_mutex_unlock(&g_menu_mu);
            return;
        }
        if (!g_pointer_down) { pthread_mutex_unlock(&g_menu_mu); return; }
        if (phase == DM_BOTW_MENU_MOVE) {
            g_last_apply_valid = 0;
            if (g_map_prompt_down) {
                pthread_mutex_unlock(&g_menu_mu);
                return;
            }
            if (point_in_rect(g_map_start[0], g_map_start[1], g_view.map)) {
                float dx = (x - g_map_start[0]) * 1280.0f;
                float dy = (y - g_map_start[1]) * 720.0f;
                if (dx * dx + dy * dy >= 8.0f * 8.0f) g_map_pan_active = 1;
                if (g_map_pan_active) {
                    float ao = 400.0f; // full stick deflection after 80 picture px
                    float ax = -dx * ao, ay = -dy * ao;
                    if (ax < -32767.0f) ax = -32767.0f; else if (ax > 32767.0f) ax = 32767.0f;
                    if (ay < -32767.0f) ay = -32767.0f; else if (ay > 32767.0f) ay = 32767.0f;
                    g_map_ax = (int32_t)ax; g_map_ay = (int32_t)ay;
                }
            }
            pthread_mutex_unlock(&g_menu_mu);
            return;
        }
        if (phase != DM_BOTW_MENU_END) { pthread_mutex_unlock(&g_menu_mu); return; }
        g_pointer_down = 0;
        g_last_apply_valid = 0;
        if (g_map_prompt_down) {
            int same_view = g_pointer_page_key == g_view.page_key &&
                            g_pointer_popup_key == g_view.popup_key &&
                            g_map_prompt_owner_valid == g_view.prompt_owner_valid;
            if (same_view && g_map_prompt_owner_valid)
                same_view = g_map_prompt_owner_screen == g_view.prompt_owner_screen &&
                            g_map_prompt_owner_root == g_view.prompt_owner_root &&
                            g_map_prompt_owner_group == g_view.prompt_owner_group;
            float current_prompt_rect[4] = {0};
            int still_visible = 0;
            if (same_view && g_map_prompt_back && g_view.back_valid) {
                still_visible = 1;
                memcpy(current_prompt_rect, g_view.back, sizeof current_prompt_rect);
            }
            if (!g_map_prompt_back) {
                for (int i = 0; i < g_view.footer_action_count; i++)
                    if (same_view && g_view.footer_action_buttons[i] == g_map_prompt_button) {
                        still_visible = 1;
                        memcpy(current_prompt_rect, g_view.footer_actions[i], sizeof current_prompt_rect);
                        break;
                    }
            }
            if (still_visible && point_in_rect(g_map_start[0], g_map_start[1], current_prompt_rect) &&
                point_in_rect(x, y, current_prompt_rect)) {
                g_target_valid = g_target_generic = 1;
                g_target_popup = g_target_category = g_selector_ready = 0;
                g_target_index = g_map_prompt_back ? -1 : -3;
                g_target_pane = g_target_owner_pane = g_target_entry = 0;
                g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                g_requested_entry = 0;
                g_target_button_bits = g_map_prompt_back ? 0 : g_map_prompt_button;
                g_confirm_pending = 0;
                menu_bind_prompt_owner_locked(&g_view);
                g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            }
            g_map_prompt_down = g_map_prompt_back = 0;
            g_map_prompt_button = 0;
            g_map_prompt_owner_valid = 0; g_map_prompt_owner_group = -1;
            g_map_prompt_owner_screen = g_map_prompt_owner_root = 0;
            pthread_mutex_unlock(&g_menu_mu);
            return;
        }
        int in_map = point_in_rect(g_map_start[0], g_map_start[1], g_view.map) &&
                     point_in_rect(x, y, g_view.map);
        int panned = g_map_pan_active;
        g_map_pan_active = 0;
        g_map_ax = g_map_ay = 0;
        if (in_map && !panned) {
            g_map_tap.pending = 1;
            g_map_tap_serial++;
            if (!g_map_tap_serial) g_map_tap_serial++;
            g_map_tap.serial = g_map_tap_serial;
            g_map_tap.point[0] = x; g_map_tap.point[1] = y;
            g_map_tap.requested_frame = frame;
            g_map_tap.pane = g_view.map_pane;
            g_map_tap.root = g_view.map_root;
            g_map_tap.screen = g_view.generic_screen;
            g_map_tap.page_key = g_view.page_key;
            g_map_tap.group = g_view.generic_group;
            if (atomic_load_explicit(&g_trace, memory_order_acquire))
                LOG("BOTW map tap request frame=%llu serial=%llu touch=(%.4f,%.4f) owner=%p/%p",
                    (unsigned long long)frame, (unsigned long long)g_map_tap.serial,
                    x, y, (void *)g_view.map_pane, (void *)g_view.map_root);
        } else if (!in_map && !panned) {
            if (g_view.back_valid && point_in_rect(x, y, g_view.back)) {
                g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                g_target_category = g_selector_ready = 0;
                g_target_index = -1; g_target_pane = g_target_owner_pane = g_target_entry = 0;
                g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                menu_bind_prompt_owner_locked(&g_view);
                g_requested_entry = 0; g_confirm_pending = 0;
                g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
            } else {
                int at = hit_rects(x, y, g_view.footer_actions, g_view.footer_action_count);
                if (at >= 0) {
                    uint64_t button = g_view.footer_action_buttons[at];
                    if (generic_action_button(button)) {
                        g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                        g_target_category = g_selector_ready = 0;
                        g_target_index = -3; g_target_pane = g_target_owner_pane = g_target_entry = 0;
                        g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                        menu_bind_prompt_owner_locked(&g_view);
                        g_requested_entry = 0; g_target_button_bits = button; g_confirm_pending = 0;
                        g_target_page_key = g_view.page_key; g_target_popup_key = g_view.popup_key;
                    }
                }
            }
        }
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
            int tapped_target = -1;
            float best_area = INFINITY;
            // Native layouts nest a part's hit bounds inside a wider container's
            // (AppMap's stamp box has B_Area_00 around its B_Btn_00 buttons), so
            // the innermost live target under the finger wins.
            for (int i = 0; i < g_view.generic_count; i++) {
                const float *rect = g_view.generic_targets[i].rect;
                if (!point_in_rect(x, y, rect)) continue;
                float area = rect[2] * rect[3];
                if (area < best_area) { best_area = area; tapped_target = i; }
            }
            if (tapped_target >= 0) {
                const dm_botw_touch_menu_target *hit = &g_view.generic_targets[tapped_target];
                g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                g_target_category = g_selector_ready = 0;
                g_target_index = tapped_target;
                g_target_pane = hit->pane;
                g_target_owner_pane = hit->owner_pane;
                g_target_entry = hit->entry;
                g_target_screen = g_view.generic_screen;
                g_target_root = hit->root;
                menu_bind_prompt_owner_locked(NULL);
                g_requested_entry = 0;
                g_target_page_key = g_view.generic_key;
                g_target_popup_key = g_view.popup_key;
                g_target_center[0] = hit->rect[0] + hit->rect[2] * .5f;
                g_target_center[1] = hit->rect[1] + hit->rect[3] * .5f;
                g_confirm_pending = 1;
            }
            if (tapped_target < 0 && g_view.back_valid && point_in_rect(x, y, g_view.back)) {
                g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                g_target_category = g_selector_ready = 0;
                g_target_index = -1; g_target_pane = g_target_owner_pane = g_target_entry = 0;
                g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                menu_bind_prompt_owner_locked(&g_view);
                g_requested_entry = 0; g_confirm_pending = 0;
                g_target_page_key = g_view.generic_key; g_target_popup_key = g_view.popup_key;
            } else if (tapped_target < 0 &&
                       (target = hit_rects(x, y, g_view.footer_actions, g_view.footer_action_count)) >= 0) {
                uint64_t button = g_view.footer_action_buttons[target];
                if (generic_action_button(button)) {
                    g_target_valid = 1; g_target_generic = 1; g_target_popup = 0;
                    g_target_category = g_selector_ready = 0;
                    g_target_index = -3; g_target_pane = g_target_owner_pane = g_target_entry = 0;
                    g_target_screen = g_view.generic_screen; g_target_root = g_view.generic_root;
                    menu_bind_prompt_owner_locked(&g_view);
                    g_requested_entry = 0; g_target_button_bits = button; g_confirm_pending = 0;
                    g_target_page_key = g_view.generic_key; g_target_popup_key = g_view.popup_key;
                }
            }
        }
        if (atomic_load_explicit(&g_trace, memory_order_acquire) && !g_pointer_dragged)
            LOG("BOTW menu tap frame=%llu point=(%.3f,%.3f) targets=%d back=%d:(%.3f,%.3f,%.3f,%.3f) footers=%d root=%p screen=%p",
                (unsigned long long)frame, x, y, g_view.generic_count, g_view.back_valid,
                g_view.back[0], g_view.back[1], g_view.back[2], g_view.back[3],
                g_view.footer_action_count, (void *)g_view.generic_root,
                (void *)g_view.generic_screen);
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
    int menu_active = menu_active_locked(render_frame);
    if (g_last_apply_valid && g_last_apply_frame == frame && menu_active) {
        *buttons |= g_apply_output_bits;
        if (g_apply_output_map_left_valid) {
            axes[0] = g_apply_output_lx; axes[1] = g_apply_output_ly;
        }
        if (g_apply_output_map_right_valid) axes[3] = g_apply_output_ry;
        if (g_apply_output_axis_valid) {
            axes[2] = g_apply_output_rx; axes[3] = 0;
        }
        int handled = g_apply_output_axis_valid || g_apply_output_map_left_valid ||
                      g_apply_output_map_right_valid || g_apply_output_bits;
        pthread_mutex_unlock(&g_menu_mu);
        return handled;
    }
    if (g_last_apply_valid && g_last_apply_frame == frame) g_last_apply_valid = 0;
    g_last_apply_valid = 1; g_last_apply_frame = frame;
    g_apply_output_bits = 0;
    g_apply_output_axis_valid = 0;
    g_apply_output_map_left_valid = g_apply_output_map_right_valid = 0;
    if (!menu_active) {
        menu_clear_queue_locked();
        g_release_pending = g_axis_release_pending = 0;
        int touch_hud_active = dm_botw_touch_hud_active();
        if (g_map_left_owned && touch_hud_active) {
            axes[0] = axes[1] = 0;
            g_apply_output_map_left_valid = 1;
            g_apply_output_lx = g_apply_output_ly = 0;
        }
        if (g_map_right_owned && touch_hud_active) {
            axes[3] = 0;
            g_apply_output_map_right_valid = 1;
            g_apply_output_ry = 0;
        }
        // A HUD-off/controller sample is native input. The menu's prior
        // frame-local override must not mask it with a synthetic release.
        g_map_left_owned = g_map_right_owned = 0;
        int handled = g_apply_output_map_left_valid || g_apply_output_map_right_valid || g_apply_output_bits;
        if (handled) map_axes_trace_locked(frame, g_map_axis_trace.pane, g_map_axis_trace.root);
        if (g_active_notified) { g_active_notified = 0; notify = 1; }
        pthread_mutex_unlock(&g_menu_mu);
        if (notify) front_botw_touch_menu_changed();
        return handled;
    }
    int map_channels_released = 0;
    if (g_map_left_owned && (!g_view.map_visible || !g_map_pan_active)) {
        axes[0] = axes[1] = 0;
        g_apply_output_map_left_valid = 1;
        g_apply_output_lx = g_apply_output_ly = 0;
        g_map_left_owned = 0;
        map_channels_released = 1;
    }
    if (g_map_right_owned && (!g_view.map_visible || !g_map_ry)) {
        axes[3] = 0;
        g_apply_output_map_right_valid = 1;
        g_apply_output_ry = 0;
        g_map_right_owned = 0;
        map_channels_released = 1;
    }
    if (map_channels_released)
        map_axes_trace_locked(frame, g_map_axis_trace.pane, g_map_axis_trace.root);
    if (g_view.map_visible && !g_target_valid) {
        // A map-button pulse still needs a clean released frame before the
        // next button tap. The map branch returns below the shared release
        // handler, so consume that edge here without masking native axes.
        if (g_release_pending) {
            g_release_pending = 0;
            if (g_axis_release_pending) {
                g_axis_release_pending = 0;
                axes[2] = 0; axes[3] = 0;
                g_apply_output_axis_valid = 1; g_apply_output_rx = 0;
            }
        }
        if (g_map_tap.pending && g_map_tap.ack_ready && frame >= g_map_tap.ack_frame &&
            frame - g_map_tap.ack_frame <= 4 && g_map_tap.pane == g_view.map_pane &&
            g_map_tap.root == g_view.map_root && g_map_tap.screen == g_view.generic_screen &&
            g_map_tap.page_key == g_view.page_key && g_map_tap.group == g_view.generic_group) {
            if (!(*buttons & DM_BTN_A)) {
                *buttons |= DM_BTN_A;
                g_apply_output_bits = DM_BTN_A;
                if (atomic_load_explicit(&g_trace, memory_order_acquire))
                    LOG("BOTW map tap emit frame=%llu serial=%llu native=(%.1f,%.1f)",
                        (unsigned long long)frame, (unsigned long long)g_map_tap.serial,
                        g_map_tap.target[0], g_map_tap.target[1]);
                map_tap_clear_locked();
            }
        } else if (g_map_tap.pending && g_map_tap.ack_ready && frame >= g_map_tap.ack_frame &&
                   frame - g_map_tap.ack_frame > 4) {
            map_tap_clear_locked();
        }
        // One-finger map pans hold the native left stick while the finger is
        // displaced from where it went down; a pinch drives native zoom.
        // Each gesture owns only the stick channels it actually drives.
        if (g_map_ry && frame > g_map_ry_frame + 3) g_map_ry = 0;
        if (g_map_pan_active) {
            axes[0] = g_map_ax; axes[1] = g_map_ay;
            g_apply_output_map_left_valid = 1;
            g_apply_output_lx = g_map_ax; g_apply_output_ly = g_map_ay;
            g_map_left_owned = 1;
        } else if (g_map_left_owned) {
            axes[0] = axes[1] = 0;
            g_apply_output_map_left_valid = 1;
            g_apply_output_lx = g_apply_output_ly = 0;
            g_map_left_owned = 0;
        }
        if (g_map_ry) {
            axes[3] = g_map_ry;
            g_apply_output_map_right_valid = 1;
            g_apply_output_ry = g_map_ry;
            g_map_right_owned = 1;
        } else if (g_map_right_owned) {
            axes[3] = 0;
            g_apply_output_map_right_valid = 1;
            g_apply_output_ry = 0;
            g_map_right_owned = 0;
        }
        map_axes_trace_locked(frame, g_view.map_pane, g_view.map_root);
        int handled = g_apply_output_map_left_valid || g_apply_output_map_right_valid || g_apply_output_bits;
        pthread_mutex_unlock(&g_menu_mu);
        return handled;
    }
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
    if (g_target_valid && g_target_prompt_owner_root && !menu_prompt_owner_live_locked(frame))
        menu_clear_queue_locked();
    if (g_target_valid && g_target_index == -3) {
        int action_still_visible = 0;
        for (int i = 0; i < g_view.footer_action_count; i++)
            if (g_view.footer_action_buttons[i] == g_target_button_bits) action_still_visible = 1;
        if (!action_still_visible) menu_clear_queue_locked();
    }
    if (!g_target_valid) { pthread_mutex_unlock(&g_menu_mu); return 0; }
    if (g_target_pane) {
        if (g_requested_entry && g_selector_manager &&
            !selector_request_slot_available(g_selector_manager, g_requested_entry)) {
            menu_clear_target_locked();
            pthread_mutex_unlock(&g_menu_mu);
            return 0;
        }
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
    g_map_pan_active = 0; g_map_ax = g_map_ay = 0; g_map_ry = 0;
    notify = g_active_notified;
    memset(&g_view, 0, sizeof g_view); g_view_valid = 0;
    g_map_published_pane = g_map_published_root = 0;
    menu_clear_queue_locked();
    g_last_apply_valid = 0; g_last_action_bits = 0;
    g_apply_output_bits = 0; g_release_pending = g_axis_release_pending = 0;
    g_apply_output_axis_valid = 0; g_apply_output_rx = 0;
    g_apply_output_map_left_valid = g_apply_output_map_right_valid = 0;
    g_map_left_owned = g_map_right_owned = 0;
    memset(&g_map_axis_trace, 0, sizeof g_map_axis_trace);
    g_active_notified = 0;
    pthread_mutex_unlock(&g_menu_mu);
    memset(&g_map_validation_cache, 0, sizeof g_map_validation_cache);
    pthread_mutex_lock(&g_native_view_mu);
    memset(&g_native_view, 0, sizeof g_native_view);
    pthread_mutex_unlock(&g_native_view_mu);
    pthread_mutex_lock(&g_generic_hits_mu);
    memset(g_generic_hits, 0, sizeof g_generic_hits);
    memset(g_generic_alt_hits, 0, sizeof g_generic_alt_hits);
    memset(g_generic_texts, 0, sizeof g_generic_texts);
    memset(g_generic_back_prompts, 0, sizeof g_generic_back_prompts);
    pthread_mutex_unlock(&g_generic_hits_mu);
    pthread_mutex_lock(&g_list_widget_observations_mu);
    memset(g_list_widget_observations, 0, sizeof g_list_widget_observations);
    pthread_mutex_unlock(&g_list_widget_observations_mu);
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
void dm_botw_touch_menu_test_set_map_setters(uintptr_t set_current, uintptr_t set_target) {
    g_test_map_setter_current = set_current;
    g_test_map_setter_target = set_target;
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
