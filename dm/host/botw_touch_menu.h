// BOTW 1.9.0 touch routing for the native pause-menu targets.
#pragma once
#include <stdint.h>

enum { DM_BOTW_MENU_MAX_SLOTS = 20, DM_BOTW_MENU_MAX_CATEGORIES = 8,
       DM_BOTW_MENU_MAX_POPUP_ROWS = 8,
       DM_BOTW_MENU_MAX_FOOTER_ACTIONS = 4,
       DM_BOTW_MENU_MAX_GENERIC_TARGETS = 128 };

enum {
    DM_BOTW_MENU_BEGIN = 0,
    DM_BOTW_MENU_MOVE = 1,
    DM_BOTW_MENU_END = 2,
    DM_BOTW_MENU_CANCEL = 3,
};

// True only while an exact-build BOTW native menu has a fresh touch target and
// the validated selector hook is installed; controller/off-mode bypasses it.
int dm_botw_touch_menu_active(void);

// Pointer coordinates are normalized against the logical 1280x720 canvas.
// The host owns hit testing, gesture recognition and native menu actions.
void dm_botw_touch_menu_pointer(int phase, float x, float y);

// Snapshot consumed by the native hit-test and navigation queue. Rectangles
// and cursor coordinates use normalized logical-canvas coordinates (0..1,
// top-left origin). The pane observer publishes current visible native hit
// panes. For the inventory adapter it also publishes slot/category/popup
// geometry and cursor state; generic menu views are scoped to the currently
// focused native screen and input group.
typedef struct {
    uintptr_t pane;
    uintptr_t owner_pane;
    uintptr_t entry;
    uintptr_t root;
    float rect[4];
} dm_botw_touch_menu_target;

typedef struct {
    uint64_t render_frame;
    uint64_t page_key;
    uint64_t popup_key;
    uint64_t generic_key;
    uintptr_t generic_screen;
    uintptr_t generic_root;
    int generic_group;
    int generic_mode;
    int generic_count;
    dm_botw_touch_menu_target generic_targets[DM_BOTW_MENU_MAX_GENERIC_TARGETS];
    int inventory_visible;
    int popup_visible;
    int cursor_valid;
    int clip_valid;
    int slot_count;
    int category_count;
    int category_ids[DM_BOTW_MENU_MAX_CATEGORIES];
    uintptr_t category_panes[DM_BOTW_MENU_MAX_CATEGORIES];
    float categories[DM_BOTW_MENU_MAX_CATEGORIES][4];
    int popup_count;
    int back_valid;
    int footer_action_count;
    float cursor[2];
    float clip[4];
    float slots[DM_BOTW_MENU_MAX_SLOTS][4];
    uintptr_t slot_panes[DM_BOTW_MENU_MAX_SLOTS];
    float popup_rows[DM_BOTW_MENU_MAX_POPUP_ROWS][4];
    uintptr_t popup_row_panes[DM_BOTW_MENU_MAX_POPUP_ROWS];
    float back[4];
    uint64_t footer_action_buttons[DM_BOTW_MENU_MAX_FOOTER_ACTIONS];
    float footer_actions[DM_BOTW_MENU_MAX_FOOTER_ACTIONS][4];
} dm_botw_touch_menu_view;

void dm_botw_touch_menu_observe(const dm_botw_touch_menu_view *view);

// Host internals: the existing BOTW build-gated Pane::Calculate observers
// pass x0 before global-matrix composition and x19 after it. Menu routing is
// active only for a fresh supported inventory view with a visible native
// region and Back-prompt geometry. Cursor freshness is required before
// selection/navigation actions, but not for menu ownership itself.
void dm_botw_touch_menu_install(void);
void dm_botw_touch_menu_pane(const uint64_t *regs, int after_matrix);
void dm_botw_touch_menu_selector(const uint64_t *regs);
int dm_botw_touch_menu_apply(uint64_t *buttons, int32_t axes[4], uint64_t frame);
void dm_botw_touch_menu_reset(void);

#ifdef DM_TEST_HOOKS
void dm_botw_touch_menu_test_publish(const dm_botw_touch_menu_view *view);
void dm_botw_touch_menu_test_set_render_frame(uint64_t frame);
void dm_botw_touch_menu_test_set_native_ready(int ready);
void dm_botw_touch_menu_test_set_generic_selector(int enabled,
                                                  uintptr_t group_getter,
                                                  uintptr_t screen_shown);
uint64_t dm_botw_touch_menu_test_last_action(uint64_t *frame);
void dm_botw_touch_menu_test_snapshot(dm_botw_touch_menu_view *view);
void dm_botw_touch_menu_test_back_rect(const float text[4], const float icon[4],
                                       float nearest_left, float nearest_right, float out[4]);
#endif
