#define DM_TEST_HOOKS 1
#include "../botw_touch_menu.h"
#include "../dm_input.h"
#include "../front.h"
#include "../hle_botw_touch_menu.c"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int mock_native_group(uintptr_t object);
static int mock_native_shown(uintptr_t screen);
static const char *mock_native_screen_name(uintptr_t screen);
static int mock_entry_eligible(uintptr_t entry, int group);
static uintptr_t mock_list_query_widget, mock_list_query_entry, mock_list_query_descriptor;
static int32_t mock_list_query_index;
static unsigned mock_list_query_index_calls, mock_list_query_descriptor_calls;
static uintptr_t mock_list_setter_manager, mock_list_setter_screen, mock_list_setter_entry;
static unsigned mock_list_setter_calls;
static int32_t mock_list_setter_last_index;
static void put_ptr(void *at, uintptr_t value);

static int32_t mock_list_widget_index(uintptr_t widget, uintptr_t entry) {
    mock_list_query_index_calls++;
    return widget == mock_list_query_widget && entry == mock_list_query_entry ? mock_list_query_index : -1;
}
static uintptr_t mock_list_widget_descriptor(uintptr_t widget, uint32_t index) {
    mock_list_query_descriptor_calls++;
    return widget == mock_list_query_widget && (int32_t)index == mock_list_query_index
        ? mock_list_query_descriptor : 0;
}
static void mock_list_widget_set(uintptr_t widget, uint32_t index) {
    mock_list_setter_calls++;
    mock_list_setter_last_index = (int32_t)index;
    memcpy((void *)(widget + 0x30c), &index, sizeof index);
    memcpy((void *)(widget + 0x310), &index, sizeof index);
    put_ptr((void *)(mock_list_setter_manager + 0x48), mock_list_setter_entry);
    put_ptr((void *)(mock_list_setter_manager + 0x50), mock_list_setter_entry);
    put_ptr((void *)(mock_list_setter_screen + 0xe0), mock_list_setter_entry);
}

module_t g_mod[MAX_MOD];
int g_nmod;
static uint64_t current_guest_frame;
static int mock_touch_hud_active = 1;
static uintptr_t mock_guest_start;
static size_t mock_guest_size;
static uintptr_t selector_test_vtable[8];
static uint8_t selector_test_guest_entry[0x80];
static int mock_gate_present[OBS_MAX];
static void (*mock_gate_callbacks[OBS_MAX])(const uint64_t *regs);

int gate_obs_present(int id) { return id > 0 && id < OBS_MAX && mock_gate_present[id]; }
void gate_obs_set(int id, void (*fn)(const uint64_t *regs)) {
    if (id > 0 && id < OBS_MAX) mock_gate_callbacks[id] = fn;
}
int dm_guest_as_contains(uintptr_t address) {
    return mock_guest_size && address >= mock_guest_start && address - mock_guest_start < mock_guest_size;
}
void front_botw_touch_menu_changed(void) {}
uint64_t dm_nvn_frame_count(void) { return 0; }
static int mock_touch_sets;
void dm_touch_set(const dm_touch *t, int n) { (void)t; if (n > 0) mock_touch_sets++; }
uint64_t dm_guest_frame(void) { return current_guest_frame; }
int dm_botw_touch_hud_active(void) { return mock_touch_hud_active; }

static dm_botw_touch_menu_view view;
typedef struct { _Alignas(16) uint8_t bytes[0x100]; } fake_pane_t;
static fake_pane_t native_panes[128];

static void set_rect(float rect[4], float x, float y, float w, float h) {
    rect[0] = x; rect[1] = y; rect[2] = w; rect[3] = h;
}

static void publish(uint64_t frame) {
    view.render_frame = frame;
    dm_botw_touch_menu_test_publish(&view);
}

static uint64_t sample(uint64_t frame) {
    uint64_t buttons = 0;
    int32_t axes[4] = {0};
    dm_botw_touch_menu_apply(&buttons, axes, frame);
    return buttons;
}

static uint64_t sample_with_buttons(uint64_t frame, uint64_t initial_buttons) {
    int32_t axes[4] = {0};
    dm_botw_touch_menu_apply(&initial_buttons, axes, frame);
    return initial_buttons;
}

static int sample_axes(uint64_t frame, int32_t axes[4], uint64_t *out_buttons) {
    uint64_t buttons = 0;
    int handled = dm_botw_touch_menu_apply(&buttons, axes, frame);
    if (out_buttons) *out_buttons = buttons;
    return handled;
}

static void tap(float x, float y) {
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, x, y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, x, y);
}

static uint8_t *fake_pane(int index, const char *name, int parent,
                          float width, float height, float x, float y) {
    uint8_t *pane = native_panes[index].bytes;
    memset(pane, 0, sizeof native_panes[index].bytes);
    memcpy(pane + 0xb8, name, strlen(name));
    pane[0x58] = 1; // visible
    pane[0x59] = 0xff; // fully opaque
    uint8_t *parent_pane = parent < 0 ? NULL : native_panes[parent].bytes;
    memcpy(pane + 0x18, &parent_pane, sizeof parent_pane);
    memcpy(pane + 0x50, &width, sizeof width);
    memcpy(pane + 0x54, &height, sizeof height);
    float one = 1.0f;
    memcpy(pane + 0x70, &one, sizeof one);
    memcpy(pane + 0x84, &one, sizeof one);
    memcpy(pane + 0x70 + 0x0c, &x, sizeof x);
    memcpy(pane + 0x70 + 0x1c, &y, sizeof y);
    return pane;
}

static void set_affine(uint8_t *pane, float m00, float m01, float m10, float m11) {
    memcpy(pane + 0x70, &m00, 4);
    memcpy(pane + 0x74, &m01, 4);
    memcpy(pane + 0x80, &m10, 4);
    memcpy(pane + 0x84, &m11, 4);
}

// Native panes keep their children in an intrusive list: parent+0x28 points at
// the first child + 8, each child+0x10 points at the next child + 8, and the
// last one points at the sentinel at parent+0x20.
static void link_child(uint8_t *parent, uint8_t *child) {
    uintptr_t sentinel = (uintptr_t)parent + 0x20, node = (uintptr_t)child + 8;
    uintptr_t head = 0;
    memcpy(&head, parent + 0x28, sizeof head);
    memcpy(child + 0x10, &sentinel, sizeof sentinel);
    if (!head || head == sentinel) {
        memcpy(parent + 0x28, &node, sizeof node);
        return;
    }
    uintptr_t cur = head, prev = 0;
    while (cur && cur != sentinel) {
        prev = cur;
        memcpy(&cur, (const void *)(cur - 8 + 0x10), sizeof cur);
    }
    if (prev) memcpy((void *)(prev - 8 + 0x10), &node, sizeof node);
}

static void observe_fake_pane(int index) {
    uint64_t regs[20] = {0};
    regs[19] = (uintptr_t)native_panes[index].bytes;
    dm_botw_touch_menu_pane(regs, 1);
}

static void init_inventory(void) {
    memset(&view, 0, sizeof view);
    view.inventory_visible = 1;
    view.cursor_valid = 1;
    view.clip_valid = 1;
    view.page_key = 1;
    view.slot_count = DM_BOTW_MENU_MAX_SLOTS;
    view.back_valid = 1;
    set_rect(view.clip, .15f, .15f, .72f, .62f);
    set_rect(view.back, .86f, .85f, .1f, .08f);
    for (int i = 0; i < view.slot_count; i++) {
        int row = i % 4;       // PaPage20's native grid is column-major.
        int col = i / 4;
        set_rect(view.slots[i], .2f + col * .08f, .2f + row * .12f, .06f, .08f);
    }
    view.cursor[0] = view.slots[0][0] + view.slots[0][2] * .5f;
    view.cursor[1] = view.slots[0][1] + view.slots[0][3] * .5f;
}

typedef struct {
    uint8_t manager[0x80], control[0x100], model[0x60], registry[0xb40];
    uint8_t active[3], screen[0x3b20], state[0x80];
    uint8_t entry[0x40], entry2[0x40], owner[0x100], owner2[0x100], pane[0x100];
    uint8_t map_screen[0x4000], map_state[0x80], map_entry[0x40], map_owner[0x100];
    uint8_t apphome_screen[0x100], apphome_state[0x80], apphome_wrapper[0x40];
    uint8_t mapview[0x900], map_model[0x3900], map_cursor_object[0x3bc0];
    uintptr_t screen_list[3];
} selector_fixture_t;
static selector_fixture_t selector;
static uint8_t fake_main_base;
static unsigned mock_eligibility_calls;
static unsigned mock_group_calls, mock_shown_calls;
static int mock_eligibility_allowed = 1;
static int mock_eligibility_group = -1;
static unsigned mock_map_current_calls, mock_map_target_calls;
static int mock_map_replace_request;
static float mock_map_replacement_point[2];
static uint8_t *mock_map_cursor_pane;
static int mock_map_cursor_updates = 1;
static float mock_map_setter_matrix[6];

static int mock_native_group(uintptr_t object) { (void)object; mock_group_calls++; return 2; }
static int mock_native_shown(uintptr_t screen) {
    mock_shown_calls++;
    const uint8_t *bytes = (const uint8_t *)screen;
    return (int8_t)bytes[0xfd] >= 0 && bytes[0xfe] == 2;
}
static const char *mock_native_screen_name(uintptr_t screen) {
    if (screen == (uintptr_t)selector.screen) return (const char *)selector.screen + 0x200;
    if (screen == (uintptr_t)selector.map_screen) return (const char *)selector.map_screen + 0xa0;
    if (screen == (uintptr_t)selector.apphome_screen) return "AppHome_00";
    return NULL;
}
static int mock_entry_eligible(uintptr_t entry, int group) {
    (void)entry;
    mock_eligibility_calls++;
    mock_eligibility_group = group;
    return mock_eligibility_allowed;
}
static void mock_map_set_current(uintptr_t model, const float *point) {
    mock_map_current_calls++;
    memcpy((void *)(model + 0x3868), point, 2 * sizeof(float));
    if (mock_map_cursor_pane && mock_map_cursor_updates) {
        float x = mock_map_setter_matrix[0] * point[0] + mock_map_setter_matrix[1] * point[1] + mock_map_setter_matrix[2];
        float y = mock_map_setter_matrix[3] * point[0] + mock_map_setter_matrix[4] * point[1] + mock_map_setter_matrix[5];
        memcpy(mock_map_cursor_pane + 0x7c, &x, sizeof x);
        memcpy(mock_map_cursor_pane + 0x8c, &y, sizeof y);
    }
    if (mock_map_replace_request) {
        mock_map_replace_request = 0;
        dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,
                                   mock_map_replacement_point[0], mock_map_replacement_point[1]);
        dm_botw_touch_menu_pointer(DM_BOTW_MENU_END,
                                   mock_map_replacement_point[0], mock_map_replacement_point[1]);
    }
}
static void mock_map_set_target(uintptr_t model, const float *point) {
    mock_map_target_calls++;
    memcpy((void *)(model + 0x3870), point, 2 * sizeof(float));
}

static void test_selector_pointer_ranges(void) {
    module_t saved_module = g_mod[0];
    int saved_nmod = g_nmod;
    atomic_store_explicit(&g_test_native_ready, 0, memory_order_release);
    mock_guest_start = (uintptr_t)selector_test_guest_entry;
    mock_guest_size = sizeof selector_test_guest_entry;
    uintptr_t vtable = (uintptr_t)selector_test_vtable;
    uintptr_t predicate = (uintptr_t)mock_entry_eligible;
    uintptr_t low = vtable < predicate ? vtable : predicate;
    uintptr_t high = (vtable + sizeof selector_test_vtable) > (predicate + 4) ?
        vtable + sizeof selector_test_vtable : predicate + 4;
    memset(&g_mod[0], 0, sizeof g_mod[0]);
    g_nmod = 1;
    g_mod[0].base = (uint8_t *)low;
    g_mod[0].size = high - low;
    g_mod[0].loaded = 1;
    memcpy(selector_test_vtable + 5, &predicate, sizeof predicate); // entry vtable slot +0x28
    memcpy(selector_test_guest_entry, &vtable, sizeof vtable);
    assert(selector_range((uintptr_t)selector_test_guest_entry, sizeof selector_test_guest_entry));
    assert(selector_range(vtable, 0x30));
    assert(selector_range(predicate, 4));
    assert(!selector_range(low - 1, 2)); // do not accept a range merely because one endpoint is loaded
    assert(!selector_range(high - 2, 4));
    mock_eligibility_calls = 0; mock_eligibility_allowed = 1; mock_eligibility_group = -1;
    assert(selector_entry_eligible((uintptr_t)selector_test_guest_entry, 2));
    assert(mock_eligibility_calls == 1 && mock_eligibility_group == 2);
    g_mod[0].loaded = 0;
    assert(!selector_range(vtable, 0x30) && !selector_range(predicate, 4));
    assert(!selector_entry_eligible((uintptr_t)selector_test_guest_entry, 2));

    // For a negative patch offset, the patch and image are distinct valid
    // spans; an interval crossing their unmapped gap must fail.
    g_mod[0].base = (uint8_t *)(uintptr_t)0x7000000000;
    g_mod[0].size = 0x1000;
    g_mod[0].patch_off = -0x2000;
    g_mod[0].patch_len = 0x1000;
    g_mod[0].loaded = 1;
    assert(selector_range((uintptr_t)g_mod[0].base - 0x2000, 0x100));
    assert(selector_range((uintptr_t)g_mod[0].base, 0x100));
    assert(!selector_range((uintptr_t)g_mod[0].base - 0x1002, 0x1005));
    g_mod[0] = saved_module;
    g_nmod = saved_nmod;
    mock_guest_start = 0; mock_guest_size = 0;
}

static void put_ptr(void *at, uintptr_t value) { memcpy(at, &value, sizeof value); }
static uintptr_t get_ptr(void *at) { uintptr_t value; memcpy(&value, at, sizeof value); return value; }

static void init_selector_fixture(void) {
    memset(&selector, 0, sizeof selector);
    memset(g_mod, 0, sizeof g_mod[0]);
    g_nmod = 1;
    strcpy(g_mod[0].name, "main");
    strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = &fake_main_base;
    g_mod[0].loaded = 1;
    put_ptr(selector.manager, (uintptr_t)(g_mod[0].base + 0x1d0cdf8));
    put_ptr(selector.manager + 0x20, (uintptr_t)selector.control);
    put_ptr(selector.control + 0x80, (uintptr_t)selector.model);
    put_ptr(selector.model + 0x28, (uintptr_t)selector.registry);
    uint32_t count = 1; memcpy(selector.registry + 0x28, &count, sizeof count);
    selector.screen_list[0] = (uintptr_t)selector.screen;
    strcpy((char *)selector.screen + 0x200, "PauseMenu_00");
    atomic_store_explicit(&g_test_native_screen_name_getter,
                          (uintptr_t)mock_native_screen_name, memory_order_release);
    put_ptr(selector.registry + 0x30, (uintptr_t)selector.screen_list);
    put_ptr(selector.registry + 0x40, (uintptr_t)selector.active);
    put_ptr(selector.screen + 0x38, (uintptr_t)selector.state);
    selector.state[0x38] = 2; // the native screen's input-enabled state
    put_ptr(selector.screen + 0x90, (uintptr_t)selector.entry);
    int32_t delta = 0; memcpy(selector.screen + 0x9c, &delta, sizeof delta);
    put_ptr(selector.entry + 8, (uintptr_t)selector.entry2);
    put_ptr(selector.entry + 0x18, (uintptr_t)selector.owner);
    put_ptr(selector.entry + 0x20, (uintptr_t)selector.screen);
    put_ptr(selector.entry2 + 8, (uintptr_t)(selector.screen + 0x88));
    put_ptr(selector.entry2 + 0x18, (uintptr_t)selector.owner2);
    put_ptr(selector.entry2 + 0x20, (uintptr_t)selector.screen);
    uint16_t selectable = 0x10; memcpy(selector.owner + 0x3a, &selectable, sizeof selectable);
    put_ptr(selector.owner + 0x60, (uintptr_t)selector.pane);
    memcpy(selector.pane + 0xb8, "B_Hit_00", 8);
    uint16_t selectable2 = 0x10; memcpy(selector.owner2 + 0x3a, &selectable2, sizeof selectable2);
    dm_botw_touch_menu_test_set_native_ready(1);
}

static void selector_tick(void) {
    uint64_t regs[31] = {0};
    regs[0] = (uintptr_t)selector.manager;
    dm_botw_touch_menu_selector(regs);
}

static void expect_no_virtual_input(uint64_t frame) {
    uint64_t buttons = DM_BTN_R;
    int32_t axes[4] = {11, -22, 33, -44};
    assert(!dm_botw_touch_menu_apply(&buttons, axes, frame));
    assert(buttons == DM_BTN_R);
    assert(axes[0] == 11 && axes[1] == -22 && axes[2] == 33 && axes[3] == -44);
}

static unsigned mock_category_calls;
static uintptr_t mock_category_widget;
static int32_t mock_category_page, mock_category_id;
static void mock_category_set(uintptr_t widget, int32_t page, int32_t category) {
    mock_category_calls++;
    mock_category_widget = widget;
    mock_category_page = page; mock_category_id = category;
}

static void test_quest_category_touch(void) {
    dm_botw_touch_menu_reset();
    init_selector_fixture();
    current_guest_frame = 5000;
    dm_botw_touch_menu_test_set_render_frame(5000);
    uint8_t widget[0x400] = {0}, descriptors[4][0x398] = {{0}};
    uintptr_t array[4], vtable[8] = {0};
    g_test_list_widget_override = 1;
    g_test_list_widget_vtable = (uintptr_t)vtable;
    g_test_list_widget_update = (uintptr_t)mock_category_set;
    vtable[BOTW_LIST_WIDGET_VTABLE_SLOT / 8] = g_test_list_widget_update;
    put_ptr(widget, (uintptr_t)vtable);
    put_ptr(widget + 0x60, (uintptr_t)selector.screen);
    uint32_t four = 4, one = 1;
    memcpy(widget + 0x288, &four, 4); memcpy(widget + 0x2a8, &four, 4);
    put_ptr(widget + 0x290, (uintptr_t)array);
    for (int i = 0; i < 4; i++) {
        array[i] = (uintptr_t)descriptors[i];
        put_ptr(descriptors[i] + 8, (uintptr_t)widget);
        snprintf((char *)descriptors[i] + 0x19c, 64, "Pa_Quest_00/Pa_ChallengeCategory_%02d", i);
        memcpy(descriptors[i] + 0x2f0, &i, 4);
        memcpy(descriptors[i] + 0x2f4, &one, 4);
    }
    descriptors[1][0x38d] = descriptors[2][0x38d] = 1;
    memset(g_list_widget_observations, 0, sizeof g_list_widget_observations);
    g_list_widget_observations[0] = (botw_list_widget_observation_t){(uintptr_t)widget, 5000, 0, 0};
    memset(g_generic_hits, 0, sizeof g_generic_hits);
    uint8_t *root = fake_pane(100, "RootPane", -1, 1280, 720, 0, 0);
    fake_pane(101, "Pa_Quest_00", 100, 1280, 720, 0, 0);
    fake_pane(102, "N_Category_00", 101, 30, 40, 0, 0);
    for (int i = 0; i < 4; i++) {
        char name[25]; snprintf(name, sizeof name, "Pa_ChallengeCategory_%02d", i);
        fake_pane(103 + i * 2, name, 102, 211, 126, -347 + i * 58, 190);
        uint8_t *hit = fake_pane(104 + i * 2, "B_Hit_00", 103 + i * 2, 32, 32, -347 + i * 58, 191);
        generic_hit_observe(hit, 1);
    }
    dm_botw_touch_menu_view categories = {0};
    categories.generic_mode = 1; categories.generic_root = (uintptr_t)root;
    categories.generic_screen = (uintptr_t)selector.screen;
    categories.generic_key = categories.page_key = 902;
    categories.render_frame = 5000;
    selector_quest_categories_to_view((uintptr_t)selector.screen, (uintptr_t)root, 5000, &categories);
    assert(categories.quest_category_widget == (uintptr_t)widget && categories.category_count == 2);
    assert(categories.category_ids[0] == 0 && categories.category_ids[1] == 3);
    assert(fabsf(categories.categories[1][2] - .025f) < .0001f); // native B_Hit, not overlapping part bounds
    assert(!selector_quest_category_descriptor((uintptr_t)widget, -1));
    assert(!selector_quest_category_descriptor((uintptr_t)widget, 1));
    assert(!selector_quest_category_descriptor((uintptr_t)widget, 4));
    descriptors[3][0x19c + 34] = '0'; // wrong native pane binding cannot select a different tab
    assert(!selector_quest_category_descriptor((uintptr_t)widget, 3));
    descriptors[3][0x19c + 34] = '3';
    g_test_list_category_setter = (uintptr_t)mock_category_set;
    dm_botw_touch_menu_test_publish(&categories);
    float x = categories.categories[1][0] + .0125f;
    float y = categories.categories[1][1] + .0222f;
    mock_category_calls = 0;
    tap(x, y);
    assert(g_target_valid && g_target_category == 2);
    assert(sample(5000) == 0); // no A or simulated stick traversal
    assert(selector_apply_quest_category((uintptr_t)selector.screen, 5000));
    assert(mock_category_calls == 1 && mock_category_widget == (uintptr_t)widget &&
           mock_category_page == 0 && mock_category_id == 3);
    assert(sample(5001) == 0);
    tap(x, y);
    mock_touch_hud_active = 0;
    assert(!selector_apply_quest_category((uintptr_t)selector.screen, 5000));
    assert(mock_category_calls == 1);
    mock_touch_hud_active = 1;
    tap(x, y);
    categories.page_key++;
    dm_botw_touch_menu_test_publish(&categories);
    assert(!selector_apply_quest_category((uintptr_t)selector.screen, 5000));
    assert(mock_category_calls == 1);
    categories.category_count = 0; categories.quest_category_widget = 0;
    selector_quest_categories_to_view((uintptr_t)selector.screen, (uintptr_t)root, 5003, &categories);
    assert(!categories.category_count && !categories.quest_category_widget);
    // Vertical drags use the same native page setter on the row-owning
    // widget and never confirm a row or emit virtual directional input.
    uint8_t row_descriptor[0x50] = {0};
    uintptr_t entry = (uintptr_t)selector.entry;
    put_ptr(row_descriptor + 0x28, entry);
    g_test_list_widget_index_resolver = (uintptr_t)mock_list_widget_index;
    g_test_list_widget_descriptor_resolver = (uintptr_t)mock_list_widget_descriptor;
    mock_list_query_widget = (uintptr_t)widget; mock_list_query_entry = entry;
    mock_list_query_descriptor = (uintptr_t)row_descriptor; mock_list_query_index = 0;
    int32_t selected_category = 3, page = 0;
    memcpy(widget + 0x2e8, &selected_category, 4); memcpy(widget + 0x2f0, &page, 4);
    memcpy(descriptors[3] + 0x2f4, &four, 4);
    strcpy((char *)descriptors[3] + 0x3c, "Pa_Quest_00/Pa_Category_01");
    categories.generic_count = 1;
    categories.generic_targets[0].entry = entry;
    categories.generic_targets[0].pane = categories.generic_targets[0].owner_pane =
        (uintptr_t)native_panes[104].bytes;
    categories.generic_targets[0].root = (uintptr_t)root;
    set_rect(categories.generic_targets[0].rect, .2f, .3f, .3f, .2f);
    dm_botw_touch_menu_test_publish(&categories);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .3f, .4f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .3f, .2f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .3f, .2f);
    assert(g_target_valid && g_target_index == -4 && g_target_axis == 1);
    uint64_t serial = atomic_load_explicit(&g_target_serial, memory_order_acquire);
    assert(sample(5000) == 0);
    assert(selector_quest_list_scroll((uintptr_t)selector.screen, entry,
        (uintptr_t)native_panes[104].bytes, 1, 5000, serial));
    assert(mock_category_calls == 2 && mock_category_page == 1 && mock_category_id == 3);
    assert(!g_target_valid && sample(5001) == 0);
    // A replacement/cancelled gesture, an edge page, or another owner is inert.
    assert(!selector_quest_list_scroll((uintptr_t)selector.screen, entry,
        (uintptr_t)native_panes[104].bytes, 1, 5000, serial));
    page = 3; memcpy(widget + 0x2f0, &page, 4);
    assert(!selector_quest_list_scroll((uintptr_t)selector.screen, entry,
        (uintptr_t)native_panes[104].bytes, 1, 5000, serial));
    assert(mock_category_calls == 2);
    g_test_list_widget_index_resolver = g_test_list_widget_descriptor_resolver = 0;
    g_test_list_category_setter = 0; g_test_list_widget_override = 0;
    dm_botw_touch_menu_reset();
}

static void test_option_arrow_touch(void) {
    dm_botw_touch_menu_reset(); init_selector_fixture();
    current_guest_frame = 6000;
    dm_botw_touch_menu_test_set_render_frame(6000);
    strcpy((char *)selector.screen + 0x200, "OptionWindow_00");
    selector.screen[0xfe] = 2;
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf7988));
    uintptr_t vtable[8] = {0}; vtable[5] = (uintptr_t)mock_entry_eligible;
    put_ptr(selector.entry, (uintptr_t)vtable);
    put_ptr(selector.entry + 8, (uintptr_t)(selector.screen + 0x88));
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    uint8_t mask[0x20] = {0}; mask[0x14] = 1u << 2;
    put_ptr(selector.registry + 0xb18, (uintptr_t)mask);
    dm_botw_touch_menu_test_set_generic_selector(1, (uintptr_t)mock_native_group,
                                                   (uintptr_t)mock_native_shown);
    mock_guest_start = (uintptr_t)native_panes; mock_guest_size = sizeof native_panes;
    uint8_t *root = fake_pane(70, "RootPane", -1, 1280, 720, 0, 0);
    fake_pane(71, "Pa_SlideBtn_04", 70, 800, 80, 0, 0);
    uint8_t *part = fake_pane(72, "Pa_Btn_01", 71, 400, 40, 0, 0);
    uint8_t *left = fake_pane(73, "Pa_ArrowL_00", 72, 35, 40, -180, 0);
    uint8_t *right = fake_pane(74, "Pa_ArrowR_00", 72, 35, 40, 180, 0);
    uint8_t *hit = fake_pane(75, "B_Hit_00", 72, 400, 40, 0, 0);
    link_child(part, left); link_child(part, right); link_child(part, hit);
    put_ptr(selector.owner + 0x60, (uintptr_t)hit);
    generic_hit_observe(hit, 1);
    selector_tick();
    dm_botw_touch_menu_view options;
    dm_botw_touch_menu_test_snapshot(&options);
    assert(options.generic_count == 3 && options.generic_root == (uintptr_t)root);
    assert(options.generic_targets[1].adjustment == -1 && options.generic_targets[2].adjustment == 1);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .3f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .6f, .5f);
    assert(g_target_valid && g_target_axis == DM_STICK_MAX && g_target_pane == (uintptr_t)right);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, .6f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .6f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .3f, .5f);
    assert(g_target_valid && g_target_axis == -DM_STICK_MAX && g_target_pane == (uintptr_t)left);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, .3f, .5f);
    float x = options.generic_targets[2].rect[0] + options.generic_targets[2].rect[2] * .5f;
    float y = options.generic_targets[2].rect[1] + options.generic_targets[2].rect[3] * .5f;
    tap(x, y);
    selector_tick();
    int32_t axes[4] = {10, 20, 30, 40}; uint64_t buttons = 0;
    assert(sample_axes(6000, axes, &buttons));
    assert(!buttons && axes[0] == DM_STICK_MAX && !axes[1] && axes[2] == 30 && axes[3] == 40);
    axes[0] = 5; axes[1] = 6;
    assert(sample_axes(6000, axes, &buttons) && axes[0] == DM_STICK_MAX && !buttons);
    axes[0] = 5; axes[1] = 6; axes[2] = 70; axes[3] = 80;
    assert(sample_axes(6001, axes, &buttons));
    assert(!buttons && !axes[0] && !axes[1] && axes[2] == 70 && axes[3] == 80);
    // A disappearing arrow must not turn into an A confirmation on its row.
    tap(x, y); right[0x58] = 0;
    selector_tick();
    axes[0] = 5; axes[1] = 6;
    assert(!sample_axes(6002, axes, &buttons));
    assert(!buttons && axes[0] == 5 && axes[1] == 6);
    // The ON/OFF labels are native targets too; each chooses a value instead
    // of blindly toggling the current value with A.
    right[0x58] = 1; left[0x58] = 0;
    // Remove the arrow nodes: this row now has the boolean control layout.
    put_ptr(part + 0x28, (uintptr_t)hit + 8);
    uint8_t *on = fake_pane(76, "T_BtnON_00", 72, 150, 30, -90, 0);
    uint8_t *off = fake_pane(77, "T_BtnOFF_00", 72, 150, 30, 90, 0);
    generic_text_observe(on, 1); generic_text_observe(off, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&options);
    assert(options.generic_count == 3 && options.generic_targets[1].pane == (uintptr_t)on &&
           options.generic_targets[2].pane == (uintptr_t)off);
    // A swipe beginning on the setting label selects a distant row in one
    // native focus request, without activating that row's setting.
    uint8_t *row_part = native_panes[71].bytes;
    link_child(row_part, part);
    // Match the native asset's right-anchored label at x=-14, width=246.
    uint8_t *label = fake_pane(78, "T_Option_00", 71, 246, 24, -14, 0);
    link_child(row_part, label);
    fake_pane(79, "Pa_SlideBtn_10", 70, 800, 80, 0, -220);
    fake_pane(80, "Pa_Btn_00", 79, 400, 40, 0, -220);
    uint8_t *last_hit = fake_pane(81, "B_Hit_00", 80, 400, 40, 0, -220);
    put_ptr(selector.entry + 8, (uintptr_t)selector.entry2);
    put_ptr(selector.entry2, (uintptr_t)vtable);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)last_hit);
    current_guest_frame = 6003;
    dm_botw_touch_menu_test_set_render_frame(6003);
    generic_hit_observe(hit, 1);
    generic_hit_observe(last_hit, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&options);
    int label_found = 0;
    for (int i = 0; i < options.generic_count; i++) {
        if (options.generic_targets[i].pane != (uintptr_t)label) continue;
        label_found++;
        assert(fabsf(options.generic_targets[i].rect[0] - 380.0f / 1280.0f) < 1e-6f);
        assert(fabsf(options.generic_targets[i].rect[2] - 246.0f / 1280.0f) < 1e-6f);
    }
    assert(label_found == 1);
    // Start in the native row's blank padding, outside both text and values.
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .49f, .545f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .49f, .345f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .49f, .245f);
    assert(g_target_valid && g_target_index == -4 && g_target_entry == (uintptr_t)selector.entry);
    selector_tick();
    assert(g_target_valid && g_target_entry == (uintptr_t)selector.entry2 && !g_confirm_pending && !g_target_axis);
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry2);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    selector_tick();
    assert(!sample(6003) && !g_target_valid);
    // Save rows use the same native focus-and-scroll operation, under the
    // actual FileSelect/SlideArea hierarchy, and never confirm a load.
    current_guest_frame = 6004; dm_botw_touch_menu_test_set_render_frame(6004);
    strcpy((char *)selector.screen + 0x200, "SystemWindow_01");
    fake_pane(83, "N_FileSelect_00", 70, 800, 600, 0, 0);
    uint8_t *slide = fake_pane(84, "N_SlideArea_00", 83, 800, 600, 0, 0);
    strcpy((char *)row_part + PANE_NAME, "Pa_File_00");
    strcpy((char *)native_panes[79].bytes + PANE_NAME, "Pa_File_01");
    put_ptr(row_part + PANE_PARENT, (uintptr_t)slide);
    put_ptr(native_panes[79].bytes + PANE_PARENT, (uintptr_t)slide);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.manager + 0x50, 0);
    generic_hit_observe(hit, 1); generic_hit_observe(last_hit, 1); selector_tick();
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .5f, .2f);
    selector_tick();
    assert(g_target_valid && g_target_entry == (uintptr_t)selector.entry2 && !g_confirm_pending);
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry2);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2); selector_tick();
    assert(!sample(6004) && !g_target_valid);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .8f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .5f, .99f);
    selector_tick();
    assert(g_target_valid && g_target_entry == (uintptr_t)selector.entry && !g_confirm_pending);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    // A similarly named part outside the native list is not scrollable.
    put_ptr(row_part + PANE_PARENT, (uintptr_t)root);
    assert(!selector_scroll_row((uintptr_t)hit));
    // Message quantity controls use an offscreen cursor anchor and a visible
    // number. Their +/- arrows lie outside the number's narrow text bounds.
    current_guest_frame = 6004; dm_botw_touch_menu_test_set_render_frame(6004);
    strcpy((char *)selector.screen + 0x200, "Message_00");
    strcpy((char *)row_part + PANE_NAME, "N_BtnNum_00");
    put_ptr(selector.entry + 8, (uintptr_t)(selector.screen + 0x88));
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.manager + 0x50, 0);
    on[0x58] = off[0x58] = 0;
    generic_text_observe(on, 0); generic_text_observe(off, 0);
    left[0x58] = right[0x58] = 1;
    link_child(part, left); link_child(part, right);
    uint8_t *number = fake_pane(82, "T_Num_00", 72, 60, 30, 0, 0);
    link_child(part, number);
    float offscreen_x = 991; memcpy(hit + PANE_MATRIX + 0xc, &offscreen_x, 4);
    observe_native_pane(hit, 1); observe_native_pane(number, 1);
    selector_tick(); dm_botw_touch_menu_test_snapshot(&options);
    assert(options.generic_count == 3 && options.generic_targets[0].rect[2] < .1f);
    tap(options.generic_targets[2].rect[0] + options.generic_targets[2].rect[2] * .5f, .5f);
    selector_tick(); axes[0] = axes[1] = 0; buttons = 0;
    assert(sample_axes(6004, axes, &buttons) && axes[0] == DM_STICK_MAX && !buttons);
    mock_guest_start = 0; mock_guest_size = 0;
    dm_botw_touch_menu_reset();
}

static void test_cursorless_help_prompts(void) {
    dm_botw_touch_menu_reset(); init_selector_fixture();
    current_guest_frame = 9000; dm_botw_touch_menu_test_set_render_frame(9000);
    dm_botw_touch_menu_test_set_generic_selector(1, (uintptr_t)mock_native_group,
                                               (uintptr_t)mock_native_shown);
    mock_guest_start = (uintptr_t)native_panes; mock_guest_size = sizeof native_panes;
    uint8_t mask[0x20] = {0}; mask[0x14] = 1 << 2;
    put_ptr(selector.registry + 0xb18, (uintptr_t)mask);
    put_ptr(selector.manager + 0x48, 0);
    strcpy((char *)selector.screen + 0x200, "ControllerWindow_00");
    selector.screen[0xfd] = 0; selector.screen[0xfe] = 2;
    uint8_t *root = fake_pane(80, "RootPane", -1, 1280, 720, 0, 0);
    put_ptr(selector.screen + 0x30, (uintptr_t)selector.apphome_wrapper);
    put_ptr(selector.apphome_wrapper + 0x18, (uintptr_t)root);
    fake_pane(81, "Pa_GuideB_00", 80, 200, 40, 0, 0);
    uint8_t *icon = fake_pane(82, "T_Icon_00", 81, 32, 32, 560, -318);
    uint8_t *label = fake_pane(83, "T_Guide_00", 81, 120, 24, 540, -318);
    uint16_t glyph = 0xe041; memcpy(icon + 0xf0, &glyph, 2);
    put_ptr(icon + 0xe0, (uintptr_t)(icon + 0xf0));
    generic_back_prompt_observe(icon, 1); generic_back_prompt_observe(label, 1);
    fake_pane(84, "Pa_ArrowU_00", 80, 64, 36, 0, 280);
    uint8_t *arrow = fake_pane(85, "P_ArrowL_00", 84, 64, 30, 0, 280);
    uint8_t *page = fake_pane(86, "Pa_PageTips_00", 80, 720, 420, 0, 0);
    generic_hit_observe(arrow, 1); generic_hit_observe(page, 1);
    dm_botw_touch_menu_view help = {0};
    assert(selector_cursorless_prompt_view((uintptr_t)selector.manager, 9000,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &help));
    assert(help.back_valid && help.prompt_owner_screen == (uintptr_t)selector.screen);
    unsigned calls = mock_group_calls;
    mock_touch_hud_active = 0;
    assert(!selector_cursorless_prompt_view((uintptr_t)selector.manager, 9000,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &help));
    assert(mock_group_calls == calls); // controller mode makes no extra guest calls
    mock_touch_hud_active = 1;
    assert(help.generic_count == 0 && help.clip_valid && help.footer_action_count == 1);
    assert(help.footer_action_buttons[0] == DM_BTN_UP);
    dm_botw_touch_menu_test_publish(&help);
    tap(.5f, .11f); assert(sample(9000) == DM_BTN_UP);
    sample(9001);
    help.render_frame = help.prompt_owner_frame = 9002;
    dm_botw_touch_menu_test_publish(&help);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .4f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .5f, .65f);
    assert(sample(9002) == DM_BTN_UP); // same live arrow through a downward swipe
    sample(9003);
    help.render_frame = help.prompt_owner_frame = 9004;
    dm_botw_touch_menu_test_publish(&help);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .65f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .5f, .4f);
    assert(sample(9004) == 0); // no down arrow on the last page
    help.render_frame = help.prompt_owner_frame = 9005;
    dm_botw_touch_menu_test_publish(&help);
    tap(help.back[0] + help.back[2] * .5f, help.back[1] + help.back[3] * .5f);
    selector.state[0x38] = 0;
    assert(sample(9005) == 0); // native ownership lost before emission
    selector.state[0x38] = 2; root[0x59] = 0;
    assert(!selector_cursorless_prompt_view((uintptr_t)selector.manager, 9000,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &help));
    root[0x59] = 255;
    uint32_t two = 2; memcpy(selector.registry + 0x28, &two, 4);
    selector.screen_list[1] = (uintptr_t)selector.map_screen;
    strcpy((char *)selector.map_screen + 0xa0, "SystemWindow_00");
    selector.map_screen[0xfd] = 0; selector.map_screen[0xfe] = 2;
    put_ptr(selector.map_screen + 0x38, (uintptr_t)selector.map_state);
    selector.map_state[0x38] = 2;
    put_ptr(selector.map_screen + 0x30, (uintptr_t)selector.mapview);
    put_ptr(selector.mapview + 0x18, (uintptr_t)root);
    assert(!selector_cursorless_prompt_view((uintptr_t)selector.manager, 9000,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &help)); // ambiguous owners
    uint32_t one = 1; memcpy(selector.registry + 0x28, &one, 4);
    strcpy((char *)selector.screen + 0x200, "PauseMenuRecipe_00");
    uint8_t *plain = native_panes[81].bytes;
    strcpy((char *)plain + PANE_NAME, "N_Pos_02");
    link_child(plain, icon); link_child(plain, label);
    assert(ancestor_action_guide(icon) == plain && ancestor_action_guide(label) == plain);
    generic_back_prompt_observe(icon, 1); generic_back_prompt_observe(label, 1);
    assert(selector_cursorless_prompt_view((uintptr_t)selector.manager, 9000,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &help));
    assert(help.back_valid && help.prompt_owner_root == (uintptr_t)root);
    mock_guest_start = 0; mock_guest_size = 0;
    dm_botw_touch_menu_reset();
}

static void test_inventory_category_touch_cells(void) {
    dm_botw_touch_menu_view categories = {0};
    categories.inventory_visible = 1; categories.category_count = 3;
    categories.clip_valid = 1; set_rect(categories.clip, 0, .27f, 1, .6f);
    for (int i = 0; i < 3; i++)
        set_rect(categories.categories[i], .2f + .045f * i, .2f, .025f, .044444f);
    inventory_category_touch_rects(&categories);
    for (int i = 0; i < 3; i++) {
        const float *r = categories.categories[i];
        assert(r[2] > .044f && r[3] > .079f); // finger-sized surrounding cell
        assert(r[1] < .2f && r[1] + r[3] <= categories.clip[1]);
        if (i) assert(categories.categories[i - 1][0] + categories.categories[i - 1][2] <= r[0] + 1e-6f);
    }
    // Pointer menus such as quests keep their own native category geometry.
    categories.inventory_visible = 0;
    float before[sizeof categories.categories / sizeof(float)];
    memcpy(before, categories.categories, sizeof before);
    inventory_category_touch_rects(&categories);
    assert(!memcmp(before, categories.categories, sizeof before));
    // Publication must expand after loading the live item-list clip.
    dm_botw_touch_menu_reset(); current_guest_frame = 7000;
    g_native_view.frame = g_native_view.inventory_seen = g_native_view.clip_seen = 7000;
    g_native_view.inventory_visible = g_native_view.clip_valid = 1;
    set_rect(g_native_view.clip, 0, .24f, 1, .6f);
    g_native_view.category_valid[0] = 1; g_native_view.category_seen[0] = 7000;
    set_rect(g_native_view.categories[0], .2f, .2f, .025f, .044444f);
    categories = snapshot_native_view_locked();
    assert(categories.category_count == 1 && categories.categories[0][2] > .049f);
    assert(categories.categories[0][1] + categories.categories[0][3] <= .240001f);
    dm_botw_touch_menu_reset();
}

static void test_inline_holding_prompts(void) {
    dm_botw_touch_menu_reset();
    mock_guest_start = (uintptr_t)native_panes; mock_guest_size = sizeof native_panes;
    current_guest_frame = 7000;
    uint8_t *root = fake_pane(100, "RootPane", -1, 1280, 720, 0, 0);
    uint8_t *part = fake_pane(101, "Pa_HaveNum_00", 100, 240, 240, 0, 0);
    uint8_t *layer = fake_pane(102, "N_InOut_00", 101, 240, 240, 0, 0);
    link_child(root, part); link_child(part, layer);
    const uint16_t glyphs[] = {0xe040, 0xe042, 0xe041};
    uint8_t *icons[3];
    for (int i = 0; i < 3; i++) {
        char name[17]; snprintf(name, sizeof name, "T_Icon_%02d", i);
        icons[i] = fake_pane(103 + i * 2, name, 102, 32, 32, 64, 100 - i * 45);
        memcpy(icons[i] + 0xf0, &glyphs[i], 2);
        put_ptr(icons[i] + 0xe0, (uintptr_t)(icons[i] + 0xf0));
        // Real Add and Stop labels have reversed suffixes relative to icons.
        snprintf(name, sizeof name, "T_Guide_%02d", i < 2 ? 1 - i : i);
        uint8_t *label = fake_pane(104 + i * 2, name, 102, 150, 24, 84, 100 - i * 45);
        link_child(layer, icons[i]); link_child(layer, label);
    }
    for (int i = 103; i <= 108; i++) generic_back_prompt_observe(native_panes[i].bytes, 1);
    g_native_view.footer_root = (uintptr_t)root; g_native_view.frame = 7000;
    dm_botw_touch_menu_view holding = snapshot_native_view_locked();
    assert(holding.footer_action_count == 3);
    for (int i = 0; i < 3; i++) {
        float rect[4];
        assert(generic_action_prompt_snapshot((uintptr_t)root, 7000, guide_glyph_button(glyphs[i]), rect));
        assert(rect[0] <= 840.0f / 1280.0f && rect[0] + rect[2] >= 840.0f / 1280.0f);
        assert(rect[1] <= (260.0f + i * 45) / 720.0f && rect[1] + rect[3] >= (260.0f + i * 45) / 720.0f);
    }
    layer[0x59] = 0; // parent animation hides cached children without updating them
    float rect[4];
    assert(!generic_action_prompt_snapshot((uintptr_t)root, 7000, DM_BTN_A, rect));
    mock_guest_start = 0; mock_guest_size = 0;
    dm_botw_touch_menu_reset();
}

static void test_menu_animation_visibility(void) {
    dm_botw_touch_menu_reset(); init_selector_fixture();
    assert(!dm_botw_touch_controls_visible()); // startup has no affirmative gameplay owner
    current_guest_frame = 8000;
    dm_botw_touch_menu_test_set_render_frame(8000);
    atomic_store(&g_selector_hook_installed, 1);
    uint8_t *root = fake_pane(70, "RootPane", -1, 1280, 720, 0, 0);
    put_ptr(selector.screen + 0x30, (uintptr_t)selector.apphome_wrapper);
    put_ptr(selector.apphome_wrapper + 0x18, (uintptr_t)root);
    // No cursor, clickable geometry or input permission during a tab slide.
    put_ptr(selector.manager + 0x48, 0);
    selector.state[0x38] = 0;
    for (int mode = 1; mode <= 3; mode++) {
        selector.screen[0xfd] = mode == 3 ? 0xff : 0;
        selector.screen[0xfe] = mode;
        selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
        assert(!dm_botw_touch_menu_active());
        assert(dm_botw_touch_menu_visible());
        tap(.5f, .5f);
        expect_no_virtual_input(8000 + mode);
        assert(dm_botw_touch_menu_visible());
    }
    // Hidden native screens restore gameplay controls immediately.
    root[0x59] = 0;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(dm_botw_touch_menu_visible() && !dm_botw_touch_controls_visible());
    root[0x59] = 255;
    root[0x58] = 0; selector.state[0x38] = 2;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(dm_botw_touch_menu_visible()); // between dialogue lines, native screen still owns input
    root[0x58] = 1; selector.state[0x38] = 0;
    selector.screen[0xfe] = 0;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible());
    selector.screen[0xfe] = 2; selector.screen[0xfd] = 0;
    root[0x58] = 0;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible());
    root[0x58] = 1;
    selector.screen[0xfe] = 2; selector.screen[0xfd] = 0xff;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible());
    selector.screen[0xfd] = 0; selector.active[0] = 0x80;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible());
    selector.active[0] = 0;
    strcpy((char *)selector.screen + 0x200, "MainScreen_00");
    fake_pane(71, "N_All_00", 70, 0, 0, 0, 0);
    fake_pane(72, "N_State_00", 71, 0, 0, 0, 0);
    fake_pane(73, "Pa_HeartGauge_00", 72, 0, 0, 0, 0);
    uint8_t *hud = fake_pane(74, "N_InOut_00", 73, 0, 0, 0, 0);
    for (int i = 70; i < 74; i++) link_child(native_panes[i].bytes, native_panes[i + 1].bytes);
    selector.state[0x38] = 2;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible());
    assert(dm_botw_touch_controls_visible());
    // Return-to-title unregisters the menu before MainScreen hides its HUD.
    // The native Fade screen owns that gap without becoming a touch target.
    uint8_t *fade = fake_pane(75, "RootPane", -1, 1280, 720, 0, 0);
    strcpy((char *)selector.map_screen + 0xa0, "Fade_00");
    put_ptr(selector.map_screen + 0x30, (uintptr_t)selector.map_owner);
    put_ptr(selector.map_owner + 0x18, (uintptr_t)fade);
    put_ptr(selector.map_screen + 0x38, (uintptr_t)selector.map_state);
    selector.map_state[0x38] = 2;
    selector.map_screen[0xfe] = 2;
    selector.screen_list[1] = (uintptr_t)selector.map_screen;
    uint32_t registry_count = 2;
    memcpy(selector.registry + 0x28, &registry_count, sizeof registry_count);
    assert(!selector_pointer_screen_name("Fade_00"));
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(g_presented_gameplay && dm_botw_touch_menu_visible());
    assert(!dm_botw_touch_controls_visible());
    selector.active[1] = 0x80;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible() && dm_botw_touch_controls_visible());
    hud[0x59] = 0;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_controls_visible()); // no menu registered between dialogue pages
    hud[0x59] = 255;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(dm_botw_touch_controls_visible()); // actual gameplay HUD returned
    root[0x58] = 0;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_controls_visible()); // loading/cutscene hides the native gameplay HUD
    root[0x58] = 1; selector.state[0x38] = 0;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_controls_visible()); // visible artwork alone is not input permission
    selector.state[0x38] = 2;
    strcpy((char *)selector.screen + 0x200, "Message3D_00");
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible()); // ambient NPC speech does not own gameplay input
    strcpy((char *)selector.screen + 0x200, "AppMap_00");
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(!dm_botw_touch_menu_visible()); // retained child without its AppHome owner
    strcpy((char *)selector.screen + 0x200, "AppHome_00");
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    assert(dm_botw_touch_menu_visible());
    assert(!dm_botw_touch_controls_visible());
    strcpy((char *)selector.screen + 0x200, "PauseMenu_00");
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    atomic_store(&g_validated_box_cursor_manager, (uintptr_t)selector.manager);
    dm_botw_touch_menu_test_set_render_frame(8001);
    selector_refresh_presentation_pane(root);
    assert(g_presented_menu_frame == 8001 && dm_botw_touch_menu_visible());
    root[0x58] = 0; selector.state[0x38] = 0;
    selector_refresh_presentation_pane(root);
    assert(!dm_botw_touch_menu_visible()); // cursor update need not run after exit
    root[0x58] = 1;
    selector_publish_menu_presentation((uintptr_t)selector.manager, 8000);
    mock_touch_hud_active = 0;
    assert(!dm_botw_touch_menu_visible());
    mock_touch_hud_active = 1;
    dm_botw_touch_menu_test_set_render_frame(8003);
    assert(!dm_botw_touch_menu_visible());
    dm_botw_touch_menu_reset();
    assert(!dm_botw_touch_menu_visible());
    assert(!dm_botw_touch_controls_visible());
}

static void mock_pan_current(uintptr_t model, const float *point) {
    memcpy((void *)(model + 0x880), point, 8);
}
static void mock_pan_target(uintptr_t transform, const float *point) {
    memcpy((void *)(transform + 0x40), point, 8);
}

static void test_inventory_preview_rotation(void) {
    dm_botw_touch_menu_reset(); init_inventory();
    assert(guide_glyph_button(0xe057) == DM_BTN_RS && generic_action_button(DM_BTN_RS));
    view.inventory_rotate_visible = 1;
    current_guest_frame = 10000;
    dm_botw_touch_menu_test_set_render_frame(10000); publish(10000);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .7f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .8f, .5f);
    int32_t axes[4] = {1,2,3,4}; uint64_t buttons = 0;
    assert(sample_axes(10000, axes, &buttons) && axes[2] > 0 && !buttons);
    assert(axes[0] == 1 && axes[1] == 2);
    assert(sample_axes(10001, axes, &buttons) && !axes[2]);
    // A stationary finger never continues spinning the character.
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .8f, .5f);
    assert(!sample(10002));
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .72f, .5f);
    assert(sample_axes(10003, axes, &buttons) && axes[2] < 0 && !buttons);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .72f, .5f);
    assert(sample_axes(10004, axes, &buttons) && !axes[2] && !buttons);
    // Changing native mode invalidates an unconsumed drag without a slot tap.
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .7f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .8f, .5f);
    view.inventory_rotate_visible = 0; publish(10000);
    assert(!sample(10005) && !g_target_valid);
    view.inventory_rotate_visible = 1; publish(10000);
    tap(view.back[0] + .01f, view.back[1] + .01f);
    assert(sample(10006) == DM_BTN_B);
    sample(10007);
    view.inventory_rotate_visible = 0;
    view.inventory_arrow_valid[1] = 1;
    set_rect(view.inventory_arrows[1], .9f, .3f, .06f, .3f); publish(10000);
    tap(.93f, .4f);
    assert(sample_axes(10008, axes, &buttons) && axes[2] == DM_STICK_MAX && !buttons);
    sample(10009);
    view.inventory_arrow_valid[1] = 0; publish(10000);
    tap(.93f, .4f);
    assert(!sample(10010));
    dm_botw_touch_menu_reset();
    // Rotation is established by the live exclusive guide, not a host toggle.
    uint8_t *root = fake_pane(90, "RootPane", -1, 1280, 720, 0, 0);
    uint8_t *guide = fake_pane(91, "Pa_RotateGuide_00", 90, 100, 40, 0, 0);
    g_native_view.frame = g_native_view.inventory_seen = g_native_view.rotate_seen = 10000;
    g_native_view.inventory_visible = 1; g_native_view.rotate_guide = (uintptr_t)guide;
    g_native_view.rotate_root = g_native_view.footer_root = (uintptr_t)root;
    assert(snapshot_native_view_locked().inventory_rotate_visible);
    root[0x59] = 0;
    assert(!snapshot_native_view_locked().inventory_rotate_visible);
    root[0x59] = 255; g_native_view.footer_root = 0;
    assert(!snapshot_native_view_locked().inventory_rotate_visible);
    g_native_view.root = (uintptr_t)root;
    g_native_view.inventory_arrow_pane[1] = (uintptr_t)guide;
    g_native_view.inventory_arrow_root[1] = (uintptr_t)root;
    g_native_view.inventory_arrow_seen[1] = 10000;
    assert(snapshot_native_view_locked().inventory_arrow_valid[1]);
    guide[0x59] = 0;
    assert(!snapshot_native_view_locked().inventory_arrow_valid[1]);
    dm_botw_touch_menu_reset();
}

static void test_map_displacement_drag(void) {
    dm_botw_touch_menu_reset(); init_selector_fixture();
    current_guest_frame = 9000;
    dm_botw_touch_menu_view map = {0};
    map.generic_mode = map.map_visible = 1; map.render_frame = 9000;
    map.generic_screen = (uintptr_t)selector.map_screen;
    map.map_root = map.generic_root = (uintptr_t)native_panes[70].bytes;
    map.map_pane = (uintptr_t)native_panes[71].bytes;
    map.page_key = 21; map.generic_group = 2;
    set_rect(map.map, 0, 0, 1, 1);
    put_ptr(selector.map_screen + 0x3628, (uintptr_t)selector.mapview);
    put_ptr(selector.mapview + 0x8d8, (uintptr_t)selector.map_model);
    float initial_origin[2] = {20,30}, initial_cursor[2] = {100,200};
    memcpy(selector.map_model + 0x880, initial_origin, 8);
    memcpy(selector.map_model + 0x3868, initial_cursor, 8);
    g_native_view.map_transform_root = map.map_root;
    g_native_view.map_transform_map_pane = map.map_pane;
    g_native_view.map_transform_seen = 9000;
    float matrix[6] = {2,0,10,0,2,20};
    memcpy(g_native_view.map_transform, matrix, sizeof matrix);
    g_test_map_setter_current = (uintptr_t)mock_map_set_current;
    g_test_map_setter_target = (uintptr_t)mock_map_set_target;
    g_test_map_pan_current = (uintptr_t)mock_pan_current;
    g_test_map_pan_target = (uintptr_t)mock_pan_target;
    mock_map_cursor_updates = 0;
    dm_botw_touch_menu_test_publish(&map);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .6f, .6f);
    selector_service_map_drag(9000, &map);
    float origin[2], cursor[2], target[2];
    memcpy(origin, selector.map_model + 0x880, 8);
    memcpy(target, selector.map_model + 0x890, 8);
    memcpy(cursor, selector.map_model + 0x3868, 8);
    assert(fabsf(origin[0] - 84) < .001f && fabsf(origin[1] + 6) < .001f);
    assert(!memcmp(origin, target, 8));
    assert(fabsf(cursor[0] - 36) < .001f && fabsf(cursor[1] - 236) < .001f);
    // Holding still neither repeats displacement nor emits stick velocity.
    unsigned calls = mock_map_current_calls;
    for (int i = 0; i < 10; i++) selector_service_map_drag(9000, &map);
    assert(mock_map_current_calls == calls);
    int32_t axes[4] = {1,2,3,4};
    sample_axes(9000, axes, NULL);
    assert(!axes[0] && !axes[1] && axes[2] == 3 && axes[3] == 4);
    // Consume the final release position, and do not turn a drag into A.
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .65f, .6f);
    selector_service_map_drag(9000, &map);
    memcpy(origin, selector.map_model + 0x880, 8);
    assert(fabsf(origin[0] - 116) < .001f && !g_map_tap.pending);
    // Rotated/nonuniform geometry still follows screen-space displacement.
    matrix[0]=0; matrix[1]=-.5f; matrix[3]=.25f; matrix[4]=0;
    memcpy(g_native_view.map_transform, matrix, sizeof matrix);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .6f, .6f);
    selector_service_map_drag(9000, &map);
    memcpy(target, selector.map_model + 0x880, 8);
    assert(fabsf(target[0] - origin[0] + 288) < .002f);
    assert(fabsf(target[1] - origin[1] + 256) < .002f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .7f, .7f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    calls = mock_map_current_calls;
    selector_service_map_drag(9000, &map);
    assert(mock_map_current_calls == calls);
    g_test_map_pan_current = g_test_map_pan_target = 0;
    g_test_map_setter_current = g_test_map_setter_target = 0;
    mock_map_cursor_updates = 1;
    dm_botw_touch_menu_reset();
}

static void test_message_advance_owner(void) {
    dm_botw_touch_menu_reset(); init_selector_fixture();
    current_guest_frame = 7000;
    dm_botw_touch_menu_test_set_render_frame(7000);
    strcpy((char *)selector.screen + 0x200, "Message_00");
    selector.screen[0xfe] = 2;
    put_ptr(selector.manager + 0x48, 0);
    uint8_t mask[0x20] = {0}; mask[0x14] = 1u << 2;
    put_ptr(selector.registry + 0xb18, (uintptr_t)mask);
    dm_botw_touch_menu_test_set_generic_selector(1, (uintptr_t)mock_native_group,
                                                   (uintptr_t)mock_native_shown);
    uint8_t *root = fake_pane(80, "RootPane", -1, 1280, 720, 0, 0);
    fake_pane(81, "Pa_ABtn_00", 80, 60, 60, 400, -250);
    uint8_t *arrow = fake_pane(82, "P_ArrowS_00", 81, 48, 48, 400, -250);
    generic_hit_observe(arrow, 1);
    put_ptr(selector.screen + 0x30, (uintptr_t)selector.apphome_wrapper);
    put_ptr(selector.apphome_wrapper + 0x18, (uintptr_t)root);
    dm_botw_touch_menu_view message;
    assert(selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    assert(message.generic_root == (uintptr_t)root && message.generic_screen == (uintptr_t)selector.screen &&
           !message.generic_count && message.footer_action_count == 1 &&
           message.footer_action_buttons[0] == DM_BTN_A && message.prompt_owner_valid);
    dm_botw_touch_menu_test_publish(&message);
    tap(message.footer_actions[0][0] + .01f, message.footer_actions[0][1] + .01f);
    assert(sample(7000) == DM_BTN_A && !sample(7001));
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    put_ptr(selector.manager + 0x48, 0);
    selector.state[0x38] = 0;
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    selector.state[0x38] = 2;
    selector.active[0] = 0x80;
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    selector.active[0] = 0;
    put_ptr(selector.apphome_wrapper + 0x18, (uintptr_t)native_panes[70].bytes);
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    put_ptr(selector.apphome_wrapper + 0x18, (uintptr_t)root);
    strcpy((char *)selector.screen + 0x200, "MessageDialog_00");
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    strcpy((char *)selector.screen + 0x200, "Message_00");
    mock_touch_hud_active = 0;
    unsigned calls = mock_group_calls + mock_shown_calls;
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    assert(mock_group_calls + mock_shown_calls == calls);
    mock_touch_hud_active = 1;
    arrow[0x59] = 0; generic_hit_observe(arrow, 0);
    calls = mock_group_calls + mock_shown_calls;
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    assert(mock_group_calls + mock_shown_calls == calls);
    // The native window itself accepts taps, even while the continuation
    // arrow is hidden during text reveal. Choice rows still retain ownership.
    uint8_t *body_parent = fake_pane(83, "N_NameBase_00", 80, 800, 160, 0, -240);
    uint8_t *body = fake_pane(84, "W_Base_00", 83, 800, 160, 0, -240);
    generic_hit_observe(body, 1);
    assert(selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    dm_botw_touch_menu_test_publish(&message);
    tap(.21f, .75f); // blank left padding of the window, far from its arrow
    assert(sample(7000) == DM_BTN_A && !sample(7001));
    tap(.1f, .75f);
    assert(!sample(7001)); // the scene outside the window is not a continuation target
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    dm_botw_touch_menu_view choice = message;
    choice.footer_action_count = 0;
    choice.generic_count = 1;
    dm_botw_touch_menu_test_publish(&choice);
    observe_native_pane(body, 1);
    assert(g_view_valid && g_view.generic_count == 1); // a late backdrop callback must retain choice targets
    put_ptr(selector.manager + 0x48, 0);
    body_parent[0x59] = 0;
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    body_parent[0x59] = 255; body[0x58] = 0;
    assert(!selector_message_prompt_view((uintptr_t)selector.manager, 7000, &message));
    dm_botw_touch_menu_reset();
}

int main(void) {
    // Native taps invert the full two-dimensional pane transform, including
    // rotation, nonuniform scale and translation.
    float rotated_map[6] = {0.0f, -.5f, 120.0f, .25f, 0.0f, -40.0f};
    float map_x = 0.0f, map_y = 0.0f;
    assert(map_inverse_point(rotated_map, 150.0f, -30.0f, &map_x, &map_y));
    assert(fabsf(map_x - 40.0f) < .001f && fabsf(map_y + 60.0f) < .001f);
    float singular_map[6] = {1, 2, 0, 2, 4, 0};
    assert(!map_inverse_point(singular_map, 0, 0, &map_x, &map_y));

    uint16_t native_back_glyph = 0xe041;
    test_selector_pointer_ranges();
    const float back_text[4] = {.40f, .48f, .12f, .04f};
    const float back_icon[4] = {.46f, .46f, .04f, .08f};
    float back_hit[4];
    dm_botw_touch_menu_test_back_rect(back_text, back_icon, -INFINITY, INFINITY, back_hit);
    assert(fabsf(back_hit[0] - .40f) < 1e-6f && fabsf(back_hit[2] - .12f) < 1e-6f);
    dm_botw_touch_menu_test_back_rect(back_text, back_icon, .415f, .51f, back_hit);
    assert(fabsf(back_hit[0] - .415f) < 1e-6f && fabsf(back_hit[2] - .095f) < 1e-6f);

    // The generic Back target comes from the active modal's paired B icon
    // and label, keyed to their shared Pa_GuideB part and owner root.
    uint8_t *options_root = fake_pane(63, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *back_guide = fake_pane(59, "Pa_GuideB_00", 63, 160, 40, 559, -318);
    uint8_t *back_icon_pane = fake_pane(57, "T_Icon_00", 59, 34, 34, 559, -318);
    uint8_t *back_label_pane = fake_pane(58, "T_Guide_00", 59, 120, 24, 541, -318);
    put_ptr(back_icon_pane + 0xe0, (uintptr_t)&native_back_glyph);
    uint8_t *restore_guide = fake_pane(56, "Pa_GuideY_00", 63, 160, 40, 400, -318);
    uint8_t *restore_icon = fake_pane(54, "T_Icon_00", 56, 34, 34, 400, -318);
    uint8_t *restore_label = fake_pane(55, "T_Guide_00", 56, 120, 24, 382, -318);
    uint16_t native_restore_glyph = 0xe043;
    put_ptr(restore_icon + 0xe0, (uintptr_t)&native_restore_glyph);
    (void)back_guide; (void)restore_guide;
    generic_back_prompt_observe(back_icon_pane, 1);
    generic_back_prompt_observe(back_label_pane, 1);
    generic_back_prompt_observe(restore_icon, 1);
    generic_back_prompt_observe(restore_label, 1);
    float options_back[4];
    assert(generic_back_prompt_snapshot((uintptr_t)options_root, 0, options_back));
    assert(fabsf(options_back[0] - .8289f) < .002f);
    assert(fabsf(options_back[2] - .1211f) < .002f); // the full label remains between neighboring glyphs
    float options_restore[4];
    assert(generic_action_prompt_snapshot((uintptr_t)options_root, 0, DM_BTN_Y, options_restore));
    assert(!generic_back_prompt_snapshot((uintptr_t)native_panes[40].bytes, 0, options_back));
    native_back_glyph = 0xe043;
    generic_back_prompt_observe(back_icon_pane, 1);
    assert(!generic_back_prompt_snapshot((uintptr_t)options_root, 0, options_back));
    native_back_glyph = 0xe041;
    generic_back_prompt_observe(back_icon_pane, 1);
    assert(generic_back_prompt_snapshot((uintptr_t)options_root, 0, options_back));
    native_restore_glyph = 0xe041;
    generic_back_prompt_observe(restore_icon, 1);
    assert(!generic_action_prompt_snapshot((uintptr_t)options_root, 0, DM_BTN_Y, options_restore));
    native_restore_glyph = 0xe043;
    generic_back_prompt_observe(restore_icon, 1);
    restore_icon[0x58] = 0;
    generic_back_prompt_observe(restore_icon, 1);
    assert(!generic_action_prompt_snapshot((uintptr_t)options_root, 0, DM_BTN_Y, options_restore));

    init_selector_fixture();
    init_inventory();
    view.render_frame = 10;
    view.slot_count = 1;
    view.slot_panes[0] = (uintptr_t)selector.pane;
    publish(10);
    tap(view.slots[0][0] + view.slots[0][2] * .5f, view.slots[0][1] + view.slots[0][3] * .5f);
    expect_no_virtual_input(10); // native selection is pending; never pulse D-pad
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry);
    expect_no_virtual_input(11); // A waits for native focus acknowledgement
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    dm_botw_touch_menu_test_set_render_frame(12);
    selector_tick();
    assert(sample(12) == DM_BTN_A);
    assert(sample(12) == DM_BTN_A); // one guest-frame edge
    assert(sample(13) == 0);

    // Category icons request the category's actual first page through the
    // native screen transition setter/commit path, with no D-pad or A press.
    dm_botw_touch_menu_reset();
    memset(&view, 0, sizeof view);
    view.inventory_visible = view.clip_valid = view.back_valid = 1;
    view.page_key = 21; view.render_frame = 20;
    set_rect(view.clip, .1f, .1f, .8f, .8f); set_rect(view.back, .9f, .9f, .05f, .05f);
    uint8_t *category_root = fake_pane(40, "RootPane", -1, 100, 100, 0, 0);
    uint8_t *category_slide = fake_pane(41, "N_Slide_01", 40, 100, 100, 0, 0);
    uint8_t *category_row = fake_pane(42, "N_Cat_01", 41, 100, 100, 0, 0);
    uint8_t *category = fake_pane(43, "Pa_CategoryS_05", 42, 40, 40, 0, 0);
    uint8_t *category_invalid = fake_pane(44, "N_Invalid_00", 43, 40, 40, 0, 0);
    uint8_t *category_hit = fake_pane(45, "B_Hit_00", 44, 32, 32, 0, 0);
    (void)category_root; (void)category_slide; (void)category_row; (void)category; (void)category_invalid;
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf9ad8));
    uint16_t category_flags = 0x202f; memcpy(selector.owner + 0x3a, &category_flags, sizeof category_flags);
    put_ptr(selector.owner + 0x60, (uintptr_t)category_hit);
    int32_t count = 20, current_category = 0, current_page = 0, first_page = 12;
    memcpy(selector.screen + 0x363c, &count, 4);
    memcpy(selector.screen + 0x3a10, &current_category, 4);
    memcpy(selector.screen + 0x365c, &current_page, 4);
    memcpy(selector.screen + 0x3690 + 5 * 0x80 + 0x78, &first_page, 4);
    view.category_count = 1; view.category_ids[0] = 5;
    view.category_panes[0] = (uintptr_t)category_hit;
    set_rect(view.categories[0], .4f, .2f, .08f, .08f);
    g_test_category_flag_count = g_test_category_commit_count = 0;
    g_test_category_flag_screen = g_test_category_commit_screen = 0;
    g_test_category_flag_value = 0;
    g_test_category_refresh_count = 0; g_test_category_refresh_screen = 0;
    g_test_category_refresh_delta = -1; g_test_category_call_order_count = 0;
    put_ptr(selector.manager + 0x48, 0); put_ptr(selector.manager + 0x50, 0);
    publish(20); tap(.44f, .24f);
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf9ae0));
    selector_tick();
    assert(g_test_category_commit_count == 0); // wrong native owner class is inert
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf9ad8));
    int32_t transitioning = 1;
    memcpy(selector.screen + 0x368c, &transitioning, 4);
    selector_tick();
    assert(g_test_category_commit_count == 0); // wait for the active carousel transition
    transitioning = 0; memcpy(selector.screen + 0x368c, &transitioning, 4);
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == 0); // category entry is registered but not BoxCursor-focusable
    assert(g_test_category_flag_count == 1 && g_test_category_commit_count == 1 &&
           g_test_category_refresh_count == 1);
    assert(g_test_category_flag_screen == (uintptr_t)selector.screen);
    assert(g_test_category_commit_screen == (uintptr_t)selector.screen);
    assert(g_test_category_refresh_screen == (uintptr_t)selector.screen);
    assert(g_test_category_flag_value == 1);
    assert(g_test_category_refresh_delta == 0);
    assert(g_test_category_call_order_count == 3 && g_test_category_call_order[0] == 1 &&
           g_test_category_call_order[1] == 2 && g_test_category_call_order[2] == 3);
    int32_t staged_page = 0, staged_item = -1, staged_request = 0;
    memcpy(&staged_page, selector.screen + 0x3660, 4);
    memcpy(&staged_item, selector.screen + 0x3664, 4);
    memcpy(&staged_request, selector.screen + 0x368c, 4);
    assert(staged_page == 12); // category 5's first page, not category id 5
    assert(staged_item == 0 && staged_request == 0); // native commit consumed the staged request
    int32_t native_category = 0;
    memcpy(&native_category, selector.screen + 0x3a10, 4);
    assert(native_category == 0); // host stages no category label/state writes; native updater owns this
    expect_no_virtual_input(20);
    dm_botw_touch_menu_test_set_render_frame(21); selector_tick();
    assert(sample(21) == 0); // direct tab selection never synthesizes A
    g_test_category_flag_count = g_test_category_commit_count = 0;
    int32_t selected_category = 5;
    memcpy(selector.screen + 0x3a10, &selected_category, 4);
    transitioning = 0; memcpy(selector.screen + 0x368c, &transitioning, 4);
    tap(.44f, .24f); selector_tick();
    assert(g_test_category_flag_count == 0 && g_test_category_commit_count == 0);

    // Popup geometry hit panes resolve to the selectable N_Cursor sibling
    // under the exact same Pa_Btn row and N_TypeBtn root.
    dm_botw_touch_menu_reset();
    memset(&view, 0, sizeof view);
    view.inventory_visible = view.popup_visible = view.back_valid = 1;
    view.page_key = 30; view.popup_key = 31; view.render_frame = 30;
    set_rect(view.back, .9f, .9f, .05f, .05f);
    uint8_t *popup_root = fake_pane(30, "N_TypeBtn_01", -1, 100, 100, 0, 0);
    uint8_t *equip_button = fake_pane(31, "Pa_Btn_02", 30, 100, 100, 0, 0);
    uint8_t *equip_hit = fake_pane(32, "B_Hit_00", 31, 50, 20, 0, 0);
    uint8_t *equip_cursor = fake_pane(33, "N_Cursor_00", 31, 50, 20, 0, 0);
    uint8_t *cancel_button = fake_pane(34, "Pa_Btn_00", 30, 100, 100, 0, 0);
    uint8_t *cancel_hit = fake_pane(35, "B_Hit_00", 34, 50, 20, 0, 0);
    uint8_t *cancel_cursor = fake_pane(36, "N_Cursor_00", 34, 50, 20, 0, 0);
    (void)popup_root; (void)equip_button; (void)equip_hit; (void)equip_cursor;
    (void)cancel_button;
    uint16_t selectable = 0x10; memcpy(selector.owner + 0x3a, &selectable, sizeof selectable);
    memcpy(selector.owner2 + 0x3a, &selectable, sizeof selectable);
    put_ptr(selector.owner + 0x60, (uintptr_t)equip_cursor);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)cancel_cursor);
    view.popup_count = 2;
    view.popup_row_panes[0] = (uintptr_t)equip_hit;
    view.popup_row_panes[1] = (uintptr_t)cancel_hit;
    set_rect(view.popup_rows[0], .4f, .4f, .2f, .1f);
    set_rect(view.popup_rows[1], .4f, .52f, .2f, .1f);
    put_ptr(selector.manager + 0x48, 0); put_ptr(selector.manager + 0x50, 0);
    publish(30); tap(.5f, .57f); selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry2);
    expect_no_virtual_input(30); // no D-pad while Cancel's native focus is pending
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    dm_botw_touch_menu_test_set_render_frame(31); selector_tick();
    assert(sample(31) == DM_BTN_A); // activation only after Cancel entry is focused

    // Generic screens use only the currently focused screen's registered
    // ring. A sibling B_Hit row maps to its own N_Cursor entry; cached hits
    // from another pane root cannot become targets. Generic mode also needs
    // the live native B/Back glyph and label so unsupported views stay usable.
    // Inventory, System and other PauseMenu tabs share one vtable. Only the
    // visible inventory clip on the focused root selects the inventory
    // adapter; the exact visible item-popup owner is its modal exception.
    uintptr_t pause_root = 0x1000, other_root = 0x2000;
    assert(!selector_native_inventory_context(1, 0, pause_root, pause_root, 0)); // System tab
    assert(selector_native_inventory_context(1, 1, pause_root, pause_root, 0)); // Inventory tab
    assert(!selector_native_inventory_context(1, 0, pause_root, pause_root, 0)); // back to System
    assert(!selector_native_inventory_context(0, 1, pause_root, other_root, 0)); // modal over inventory
    assert(selector_native_inventory_context(0, 0, 0, other_root, 1)); // owned item popup

    dm_botw_touch_menu_reset(); init_selector_fixture();
    current_guest_frame = 60;
    dm_botw_touch_menu_test_set_render_frame(60);
    g_native_view.frame = 60;
    g_native_view.guide_icon_valid[0] = g_native_view.guide_text_valid[0] = 1;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 60;
    g_native_view.guide_icon_glyph[0] = 0xe041;
    set_rect(g_native_view.guide_icons[0], .93f, .9f, .04f, .05f);
    set_rect(g_native_view.guide_texts[0], .82f, .9f, .1f, .05f);
    uint8_t *menu_root = fake_pane(40, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *row_one = fake_pane(41, "Pa_Btn_00", 40, 180, 80, 380, 300);
    uint8_t *hit_wrapper = fake_pane(42, "N_Disable_00", 41, 180, 80, 380, 300);
    uint8_t *hit_one = fake_pane(50, "B_Hit_00", 42, 180, 80, 380, 300);
    uint8_t *cursor_one = fake_pane(43, "N_Cursor_00", 41, 180, 80, 380, 300);
    uint8_t *row_two = fake_pane(44, "Pa_Btn_01", 40, 180, 80, 600, 300);
    uint8_t *hit_two = fake_pane(45, "B_Hit_00", 44, 180, 80, 600, 300);
    uint8_t *cursor_two = fake_pane(46, "N_Cursor_00", 44, 180, 80, 600, 300);
    uint8_t *background_root = fake_pane(47, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *background_row = fake_pane(48, "Pa_Btn_00", 47, 180, 80, 700, 300);
    uint8_t *background_hit = fake_pane(49, "B_Hit_00", 48, 180, 80, 700, 300);
    uint8_t *background_cursor = fake_pane(53, "N_Cursor_00", 48, 180, 80, 700, 300);
    uint8_t *generic_back_guide = fake_pane(59, "Pa_GuideB_00", 40, 160, 40, 559, -318);
    uint8_t *generic_back_icon = fake_pane(57, "T_Icon_00", 59, 34, 34, 559, -318);
    uint8_t *generic_back_label = fake_pane(58, "T_Guide_00", 59, 120, 24, 541, -318);
    put_ptr(generic_back_icon + 0xe0, (uintptr_t)&native_back_glyph);
    uint8_t *generic_restore_guide = fake_pane(31, "Pa_GuideY_00", 40, 160, 40, 400, -318);
    uint8_t *generic_restore_icon = fake_pane(32, "T_Icon_00", 31, 34, 34, 400, -318);
    uint8_t *generic_restore_label = fake_pane(33, "T_Guide_00", 31, 120, 24, 382, -318);
    uint16_t generic_restore_glyph = 0xe043;
    put_ptr(generic_restore_icon + 0xe0, (uintptr_t)&generic_restore_glyph);
    (void)generic_back_guide; (void)generic_restore_guide;
    observe_native_pane(generic_back_icon, 1);
    observe_native_pane(generic_back_label, 1);
    observe_native_pane(generic_restore_icon, 1);
    observe_native_pane(generic_restore_label, 1);
    dm_botw_touch_menu_view generic_view;
    (void)menu_root; (void)row_one; (void)hit_wrapper; (void)row_two; (void)background_root; (void)background_row; (void)background_cursor;
    // The visible System row shares PauseMenu's screen class with inventory,
    // but the native inventory clip is absent. It must use generic targets.
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf9ad8));
    selector.screen[0xfd] = 0; selector.screen[0xfe] = 2;
    selector.state[0x38] = 2;
    put_ptr(selector.control + 0x80, (uintptr_t)selector.model);
    uintptr_t group_vtable[8] = {0};
    put_ptr((uint8_t *)group_vtable + 0x28, (uintptr_t)mock_entry_eligible);
    uint8_t *map_cursor = fake_pane(63, "N_Cursor_00", 47, 80, 80, 640, 360);
    put_ptr(selector.entry, (uintptr_t)group_vtable);
    put_ptr(selector.entry2, (uintptr_t)group_vtable);
    put_ptr(selector.screen + 0x90, (uintptr_t)selector.entry);
    put_ptr(selector.entry + 8, (uintptr_t)selector.entry2);
    put_ptr(selector.entry2 + 8, (uintptr_t)(selector.screen + 0x88));
    put_ptr(selector.entry2 + 0x18, (uintptr_t)selector.owner2);
    put_ptr(selector.entry2 + 0x20, (uintptr_t)selector.screen);
    uint16_t generic_owner_flags = 0x200f; // seen on live AppMap/System entries; native vfunc decides eligibility
    memcpy(selector.owner + 0x3a, &generic_owner_flags, 2);
    memcpy(selector.owner2 + 0x3a, &generic_owner_flags, 2);
    put_ptr(selector.owner + 0x60, (uintptr_t)cursor_one);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)cursor_two);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    uint8_t group_mask[0x20] = {0}; group_mask[0x14] = 1u << 2;
    put_ptr(selector.registry + 0xb18, (uintptr_t)group_mask);
    uint32_t registry_count = 3;
    memcpy(selector.registry + 0x28, &registry_count, sizeof registry_count);
    selector.screen_list[1] = (uintptr_t)selector.map_screen;
    selector.screen_list[2] = (uintptr_t)selector.apphome_screen;
    put_ptr(selector.map_screen, (uintptr_t)(g_mod[0].base + 0x1ce8298));
    strcpy((char *)selector.map_screen + 0xa0, "AppHome_00");
    selector.map_screen[0xfd] = 0; selector.map_screen[0xfe] = 2;
    put_ptr(selector.map_screen + 0x38, (uintptr_t)selector.map_state);
    selector.map_state[0x38] = 2;
    put_ptr(selector.map_screen + 0x90, (uintptr_t)selector.map_entry);
    put_ptr(selector.map_screen + 0x9c, 0);
    put_ptr(selector.map_entry, (uintptr_t)group_vtable);
    put_ptr(selector.map_entry + 8, (uintptr_t)(selector.map_screen + 0x88));
    put_ptr(selector.map_entry + 0x18, (uintptr_t)selector.map_owner);
    put_ptr(selector.map_entry + 0x20, (uintptr_t)selector.map_screen);
    memcpy(selector.map_owner + 0x3a, &generic_owner_flags, sizeof generic_owner_flags);
    put_ptr(selector.map_owner + 0x60, (uintptr_t)map_cursor);
    put_ptr(selector.apphome_screen, (uintptr_t)(g_mod[0].base + 0x1ce75f0));
    selector.apphome_screen[0xfd] = 0; selector.apphome_screen[0xfe] = 0;
    put_ptr(selector.apphome_screen + 0x38, (uintptr_t)selector.apphome_state);
    selector.apphome_state[0x38] = 2;
    uint8_t *apphome_root = fake_pane(72, "RootPane", -1, 1280, 720, 640, 360);
    put_ptr(selector.apphome_screen + 0x30, (uintptr_t)selector.apphome_wrapper);
    put_ptr(selector.apphome_wrapper + 0x18, (uintptr_t)apphome_root);
    selector.active[2] = 0xff; // free registry slot until the fullscreen AppHome opens
    uint8_t *map_pane = fake_pane(62, "Pa_Map_00", 47, 1280, 720, 640, 360);
    uint8_t *map_field = fake_pane(64, "N_Field_00", 62, 1280, 720, 640, 360);
    uint8_t *map_scroll = fake_pane(65, "N_MapSR_00", 64, 1280, 720, 640, 360);
    uint8_t *map_transform = fake_pane(66, "N_MapT_00", 65, 1280, 720, 640, 360);
    (void)map_field; (void)map_scroll;
    mock_map_cursor_pane = fake_pane(67, "Pa_Cursor_00", 62, 32, 32, 0, 0);
    mock_map_setter_matrix[0] = 0.0f; mock_map_setter_matrix[1] = -.5f;
    mock_map_setter_matrix[2] = 120.0f; mock_map_setter_matrix[3] = .25f;
    mock_map_setter_matrix[4] = 0.0f; mock_map_setter_matrix[5] = -40.0f;
    memcpy(map_transform + 0x70, &mock_map_setter_matrix[0], 4);
    memcpy(map_transform + 0x74, &mock_map_setter_matrix[1], 4);
    memcpy(map_transform + 0x7c, &mock_map_setter_matrix[2], 4);
    memcpy(map_transform + 0x80, &mock_map_setter_matrix[3], 4);
    memcpy(map_transform + 0x84, &mock_map_setter_matrix[4], 4);
    memcpy(map_transform + 0x8c, &mock_map_setter_matrix[5], 4);
    put_ptr(selector.map_screen + 0x3628, (uintptr_t)selector.mapview);
    put_ptr(selector.mapview + 0x8d8, (uintptr_t)selector.map_model);
    put_ptr(selector.mapview + 0x128, (uintptr_t)selector.map_cursor_object);
    put_ptr(selector.map_cursor_object + 0x3bb0, (uintptr_t)mock_map_cursor_pane);
    float initial_map_point[2] = {160.0f, 240.0f};
    memcpy(selector.map_model + 0x3868, initial_map_point, sizeof initial_map_point);
    memcpy(selector.map_model + 0x3870, initial_map_point, sizeof initial_map_point);
    dm_botw_touch_menu_test_set_map_setters((uintptr_t)mock_map_set_current,
                                            (uintptr_t)mock_map_set_target);
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_view candidate_only;
    dm_botw_touch_menu_test_snapshot(&candidate_only);
    assert(g_native_view.map_candidate_visible && !candidate_only.map_visible);
    uint8_t *hidden_map_root = fake_pane(55, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *hidden_map = fake_pane(54, "Pa_Map_00", 55, 1280, 720, 640, 360);
    (void)hidden_map_root;
    hidden_map[0x58] = 0;
    observe_native_pane(hidden_map, 1);
    assert(g_native_view.map_candidate_visible &&
           g_native_view.map_candidate_root == (uintptr_t)background_root);
    generic_hit_observe(hit_one, 1);
    generic_hit_observe(hit_one, 0); // clean-pane pre-phase must retain the last global matrix
    generic_hit_observe(hit_two, 1);
    generic_hit_observe(background_hit, 1);
    assert(g_native_view.map_candidate_visible); // the pane observation is only a candidate
    mock_eligibility_calls = 0; mock_eligibility_allowed = 1; mock_eligibility_group = -1;
    dm_botw_touch_menu_test_set_generic_selector(1, (uintptr_t)mock_native_group,
                                                   (uintptr_t)mock_native_shown);
    group_mask[0x14] = 0;
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_mode && generic_view.generic_count == 0); // group inactive
    group_mask[0x14] = 1u << 2;
    selector.screen[0xfe] = 1;
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 0); // native screen hidden
    selector.screen[0xfe] = 2;
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_mode && generic_view.generic_group == 2);
    assert(!generic_view.map_visible); // unrelated visible map cannot take over a focused modal
    assert(generic_view.generic_count == 2);
    assert(generic_view.back_valid); // only live, labeled native B prompt is inherited
    assert(fabsf(generic_view.back[0] - .8289f) < .002f); // current focused root wins over footer cache
    int restore_y_action = 0;
    for (int i = 0; i < generic_view.footer_action_count; i++)
        restore_y_action |= generic_view.footer_action_buttons[i] == DM_BTN_Y;
    assert(restore_y_action); // focused root's native Y prompt is touchable
    assert(generic_view.generic_targets[0].pane == (uintptr_t)hit_one);
    assert(generic_view.generic_targets[1].pane == (uintptr_t)hit_two);
    assert(mock_eligibility_calls >= 2 && mock_eligibility_group == 2);
    // AppMap's stamp box names a part's touch bounds B_Btn_00 (its stamp list
    // buttons) instead of B_Hit_00. The fallback tier must resolve the same
    // native entry, and a live B_Hit_00 under that part must still win.
    uint8_t *alt_hit_two = fake_pane(68, "B_Btn_00", 44, 180, 80, 600, 300);
    uint8_t *primary_two = fake_pane(69, "B_Hit_00", 44, 180, 80, 600, 300);
    hit_two[0x58] = 0;
    generic_hit_observe(hit_two, 1);
    observe_native_pane(alt_hit_two, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2);
    assert(generic_view.generic_targets[1].entry == (uintptr_t)selector.entry2);
    assert(generic_view.generic_targets[1].pane == (uintptr_t)alt_hit_two);
    observe_native_pane(primary_two, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_targets[1].pane == (uintptr_t)primary_two);
    uint8_t *ambiguous_primary = fake_pane(70, "B_Hit_00", 44, 180, 80, 600, 300);
    observe_native_pane(ambiguous_primary, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 1); // ambiguous primary hits do not fall through to B_Btn
    ambiguous_primary[0x58] = 0;
    observe_native_pane(ambiguous_primary, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2 &&
           generic_view.generic_targets[1].pane == (uintptr_t)primary_two);
    // Native bounds nest (a container's area around its buttons), so the
    // innermost live target under the finger must take the tap.
    hit_one = fake_pane(50, "B_Hit_00", 42, 700, 500, 400, 300);
    observe_native_pane(hit_one, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2);
    float small_area = generic_view.generic_targets[1].rect[2] * generic_view.generic_targets[1].rect[3];
    float wide_area = generic_view.generic_targets[0].rect[2] * generic_view.generic_targets[0].rect[3];
    assert(wide_area > small_area);
    tap(generic_view.generic_targets[1].rect[0] + generic_view.generic_targets[1].rect[2] * .5f,
        generic_view.generic_targets[1].rect[1] + generic_view.generic_targets[1].rect[3] * .5f);
    assert(g_target_valid && g_target_generic && g_target_index == 1 &&
           g_target_entry == (uintptr_t)selector.entry2);
    // Restore the fixture the later map cases expect.
    primary_two[0x58] = 0; alt_hit_two[0x58] = 0; ambiguous_primary[0x58] = 0;
    observe_native_pane(primary_two, 1);
    observe_native_pane(alt_hit_two, 1);
    hit_one = fake_pane(50, "B_Hit_00", 42, 180, 80, 380, 300);
    observe_native_pane(hit_one, 1);
    hit_two[0x58] = 1;
    generic_hit_observe(hit_two, 1);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2);
    assert(generic_view.generic_targets[0].pane == (uintptr_t)hit_one);
    assert(generic_view.generic_targets[1].pane == (uintptr_t)hit_two);
    for (int i = 0; i < generic_view.footer_action_count; i++)
        if (generic_view.footer_action_buttons[i] == DM_BTN_Y) {
            tap(generic_view.footer_actions[i][0] + generic_view.footer_actions[i][2] * .5f,
                generic_view.footer_actions[i][1] + generic_view.footer_actions[i][3] * .5f);
            assert(sample(60) == DM_BTN_Y);
            break;
        }
    put_ptr(selector.manager + 0x48, 0);
    map_cursor[0x58] = 0; // hidden, ineligible AppMap control still proves the owning root
    mock_eligibility_allowed = 0; mock_eligibility_calls = 0;
    // Simulate retained PauseMenu geometry while the Map pane is being
    // observed: none of this foreign-root state may survive map publication.
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.inventory_visible = 1; g_native_view.inventory_seen = 60;
    g_native_view.clip_valid = 1; g_native_view.clip_seen = 60;
    set_rect(g_native_view.clip, .1f, .1f, .8f, .8f);
    g_native_view.slot_valid[0][0] = 1; g_native_view.slot_seen[0][0] = 60;
    set_rect(g_native_view.slots[0][0], .3f, .3f, .1f, .1f);
    g_native_view.footer_root = (uintptr_t)menu_root;
    g_native_view.guide_icon_valid[0] = g_native_view.guide_text_valid[0] = 1;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 60;
    g_native_view.guide_icon_glyph[0] = 0xe041;
    set_rect(g_native_view.guide_icons[0], .9f, .9f, .04f, .06f);
    set_rect(g_native_view.guide_texts[0], .8f, .9f, .1f, .05f);
    g_native_view.header_root = (uintptr_t)menu_root;
    g_native_view.header_icon_valid[0] = g_native_view.header_text_valid[0] = 1;
    g_native_view.header_icon_seen[0] = g_native_view.header_text_seen[0] = 60;
    g_native_view.header_icon_glyph[0] = 0xe044;
    set_rect(g_native_view.header_icons[0], .2f, .9f, .04f, .06f);
    set_rect(g_native_view.header_texts[0], .25f, .9f, .1f, .05f);
    pthread_mutex_unlock(&g_native_view_mu);
    observe_native_pane(map_pane, 1); // validate from cached manager; OBS37 need not tick
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(!generic_view.map_visible); // R42 AppMap alone also exists as a gameplay capture surface
    selector.active[2] = 1; // allocated AppHome registry slot (the free marker is 0xff)
    selector.apphome_screen[0xfe] = 2;
    g_map_validation_cache.frame = UINT64_MAX;
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible); // null-focus AppMap owns its live pane root
    // The map candidate must not inherit a fresh unrelated PauseMenuInfo footer.
    assert(!generic_view.inventory_visible && generic_view.slot_count == 0);
    assert(!generic_view.back_valid && generic_view.footer_action_count == 0);
    assert(mock_eligibility_calls == 0); // map ownership does not require a selectable stamp/popup entry
    // The AppHome footer may cross to the fullscreen map only when its live
    // guide cache belongs to the exact AppHome layout root.
    uint64_t guide_frame = menu_render_frame();
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.frame = guide_frame;
    g_native_view.footer_root = (uintptr_t)apphome_root;
    g_native_view.guide_icon_valid[0] = g_native_view.guide_text_valid[0] = 1;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = guide_frame;
    g_native_view.guide_icon_glyph[0] = 0xe041;
    set_rect(g_native_view.guide_icons[0], .92f, .90f, .03f, .05f);
    set_rect(g_native_view.guide_texts[0], .86f, .90f, .06f, .05f);
    g_native_view.guide_icon_valid[1] = g_native_view.guide_text_valid[1] = 1;
    g_native_view.guide_icon_seen[1] = g_native_view.guide_text_seen[1] = guide_frame;
    g_native_view.guide_icon_glyph[1] = 0xe043;
    set_rect(g_native_view.guide_icons[1], .78f, .90f, .03f, .05f);
    set_rect(g_native_view.guide_texts[1], .72f, .90f, .06f, .05f);
    pthread_mutex_unlock(&g_native_view_mu);
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible && generic_view.back_valid);
    int apphome_y_action = 0;
    for (int i = 0; i < generic_view.footer_action_count; i++)
        apphome_y_action |= generic_view.footer_action_buttons[i] == DM_BTN_Y;
    assert(apphome_y_action); // the live AppHome guide exposes Y on the fullscreen map
    // A guide's Calculate callback must retain the validated map owner.
    // Publishing AppHome's prompt-only view here cancels held map gestures
    // between Begin and End even though the map is still the active surface.
    fake_pane(110, "Pa_GuideY_00", 72, 200, 40, 400, -320);
    uint8_t *map_y_icon = fake_pane(111, "T_Icon_00", 110, 34, 34, 400, -320);
    uint16_t map_y_glyph = 0xe043;
    put_ptr(map_y_icon + 0xe0, (uintptr_t)&map_y_glyph);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .75f, .925f);
    assert(g_pointer_down && g_map_prompt_down);
    observe_native_pane(map_y_icon, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible && g_pointer_down && g_map_prompt_down);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, .75f, .925f);
    dm_botw_touch_menu_view empty_album = {0};
    assert(selector_cursorless_prompt_view((uintptr_t)selector.manager, guide_frame,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &empty_album));
    assert(empty_album.generic_mode && empty_album.back_valid && !empty_album.generic_count);
    assert(empty_album.generic_screen == (uintptr_t)selector.apphome_screen &&
           empty_album.prompt_owner_root == (uintptr_t)apphome_root);
    selector.apphome_state[0x38] = 0;
    assert(!selector_cursorless_prompt_view((uintptr_t)selector.manager, guide_frame,
        (uintptr_t)mock_native_shown, (uintptr_t)mock_native_group, &empty_album));
    selector.apphome_state[0x38] = 2;
    // Empty pages stop BoxCursor ticks. The ordinary guide-pane publication
    // must still publish Back and the page tabs without a focused item.
    int saved_map_candidate = g_native_view.map_candidate_visible;
    g_native_view.map_candidate_visible = 0;
    atomic_store(&g_validated_box_cursor_manager, (uintptr_t)selector.manager);
    dm_botw_touch_menu_view raw_page = snapshot_native_view_locked();
    assert(!raw_page.generic_mode);
    publish_native_menu_view(&raw_page, guide_frame);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_mode && generic_view.back_valid &&
           generic_view.generic_screen == (uintptr_t)selector.apphome_screen);
    g_native_view.map_candidate_visible = saved_map_candidate;
    observe_native_pane(map_pane, 1);
    // A focused AppMap modal (for example StampBox) owns input while the
    // fullscreen AppHome guide remains a separate, but validated, layout root.
    // It may inherit that guide only when the registered focused entry proves
    // this exact AppMap screen and root.
    strcpy((char *)selector.map_screen + 0xa0, "AppMap_00");
    map_cursor[0x58] = 1;
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.map_entry);
    uintptr_t map_owner_test = 0, apphome_owner_test = 0, apphome_root_test = 0;
    assert(selector_map_owner_active((uintptr_t)selector.manager, 2,
        (uintptr_t)(g_mod[0].base + 0x1ce8298), (uintptr_t)mock_native_shown,
        (uintptr_t)mock_native_group, (uintptr_t)background_root, &map_owner_test,
        &apphome_owner_test, &apphome_root_test));
    assert(map_owner_test == (uintptr_t)selector.map_screen &&
           apphome_owner_test == (uintptr_t)selector.apphome_screen &&
           apphome_root_test == (uintptr_t)apphome_root);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_mode && generic_view.generic_screen == (uintptr_t)selector.map_screen);
    assert(generic_view.generic_root == (uintptr_t)background_root);
    assert(generic_view.prompt_owner_valid &&
           generic_view.prompt_owner_screen == (uintptr_t)selector.apphome_screen &&
           generic_view.prompt_owner_root == (uintptr_t)apphome_root);
    apphome_y_action = 0;
    for (int i = 0; i < generic_view.footer_action_count; i++)
        apphome_y_action |= generic_view.footer_action_buttons[i] == DM_BTN_Y;
    assert(generic_view.back_valid && apphome_y_action);
    for (int i = 0; i < generic_view.footer_action_count; i++)
        if (generic_view.footer_action_buttons[i] == DM_BTN_Y) {
            tap(generic_view.footer_actions[i][0] + generic_view.footer_actions[i][2] * .5f,
                generic_view.footer_actions[i][1] + generic_view.footer_actions[i][3] * .5f);
            break;
        }
    assert(g_target_valid && g_target_index == -3 && g_target_button_bits == DM_BTN_Y);
    uint64_t appmap_action = sample(guide_frame);
    if (appmap_action != DM_BTN_Y) appmap_action = sample(guide_frame + 1);
    assert(appmap_action == DM_BTN_Y); // prompt action remains available above the map modal
    put_ptr(selector.manager + 0x48, 0); // restore free-map ownership for following map cases
    strcpy((char *)selector.map_screen + 0xa0, "AppHome_00");
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible);
    for (int i = 0; i < generic_view.footer_action_count; i++)
        if (generic_view.footer_action_buttons[i] == DM_BTN_Y) {
            tap(generic_view.footer_actions[i][0] + generic_view.footer_actions[i][2] * .5f,
                generic_view.footer_actions[i][1] + generic_view.footer_actions[i][3] * .5f);
            break;
        }
    assert(g_target_valid && g_target_prompt_owner_root == (uintptr_t)apphome_root);
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.footer_root = (uintptr_t)menu_root; // fresh, but owned by another screen
    pthread_mutex_unlock(&g_native_view_mu);
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible && !generic_view.back_valid &&
           generic_view.footer_action_count == 0); // foreign cached footer is rejected
    uint64_t stale_footer_buttons = 0; int32_t stale_footer_axes[4] = {0};
    dm_botw_touch_menu_apply(&stale_footer_buttons, stale_footer_axes, guide_frame + 1);
    assert(!(stale_footer_buttons & DM_BTN_Y)); // a queued AppHome action dies with its owner proof
    observe_native_pane(map_transform, 1);
    float tap_x = (150.0f + 640.0f) / 1280.0f;
    float tap_y = (360.0f - (-30.0f)) / 720.0f;
    float saved_map_rect[4];
    pthread_mutex_lock(&g_menu_mu);
    memcpy(saved_map_rect, g_view.map, sizeof saved_map_rect);
    set_rect(g_view.map, .1f, .1f, .8f, .8f);
    pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .91f, .5f);
    assert(!g_map_tap.pending); // a map tap must end inside the map too
    pthread_mutex_lock(&g_menu_mu);
    memcpy(g_view.map, saved_map_rect, sizeof saved_map_rect);
    pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, tap_x, tap_y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, tap_x, tap_y);
    mock_map_cursor_updates = 0;
    observe_native_pane(map_pane, 1);
    assert(mock_map_current_calls == 1 && mock_map_target_calls == 1);
    assert(fabsf(*(float *)(selector.map_model + 0x3868) - 40.0f) < .01f);
    assert(fabsf(*(float *)(selector.map_model + 0x386c) + 60.0f) < .01f);
    assert(fabsf(*(float *)(selector.map_model + 0x3870) - 40.0f) < .01f);
    assert(fabsf(*(float *)(selector.map_model + 0x3874) + 60.0f) < .01f);
    assert(sample(60) == 0); // point mutation alone is not enough to activate
    mock_map_cursor_updates = 1;
    current_guest_frame = 61;
    dm_botw_touch_menu_test_set_render_frame(61);
    observe_native_pane(map_transform, 1);
    observe_native_pane(map_pane, 1);
    assert(sample(61) == 0); // mismatched projected cursor triggers one bounded same-point retry
    assert(mock_map_current_calls == 2 && mock_map_target_calls == 2);
    // Native recentering changes the rendered position after point selection.
    float recentered_x = 182.0f, recentered_translation = 152.0f;
    memcpy(map_transform + 0x7c, &recentered_translation, 4);
    memcpy(mock_map_cursor_pane + 0x7c, &recentered_x, 4);
    current_guest_frame = 62;
    dm_botw_touch_menu_test_set_render_frame(62);
    observe_native_pane(map_transform, 1);
    observe_native_pane(map_pane, 1);
    assert(sample(62) == DM_BTN_A); // same selected point acknowledges even after recentering
    memcpy(map_transform + 0x7c, &mock_map_setter_matrix[2], 4);
    recentered_x = 150.0f;
    memcpy(mock_map_cursor_pane + 0x7c, &recentered_x, 4);
    assert(mock_map_current_calls == 2 && mock_map_target_calls == 2);
    dm_botw_touch_menu_test_set_map_setters(0, 0);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, tap_x, tap_y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, tap_x, tap_y);
    observe_native_pane(map_pane, 1);
    assert(g_map_tap.pending && !g_map_tap.issued);
    assert(mock_map_current_calls == 2 && mock_map_target_calls == 2);
    assert(sample(62) == 0); // a mismatched/unknown native setter never falls back to A
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    dm_botw_touch_menu_test_set_map_setters((uintptr_t)mock_map_set_current,
                                            (uintptr_t)mock_map_set_target);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, tap_x, tap_y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, tap_x, tap_y);
    assert(g_map_tap.pending);
    mock_touch_hud_active = 0; // controller mode cancels an unissued tap
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    mock_touch_hud_active = 1;
    assert(!g_map_tap.pending);
    observe_native_pane(map_transform, 1);
    observe_native_pane(map_pane, 1);
    assert(mock_map_current_calls == 2 && mock_map_target_calls == 2);
    current_guest_frame = 63;
    dm_botw_touch_menu_test_set_render_frame(63);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, tap_x, tap_y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, tap_x, tap_y);
    observe_native_pane(map_transform, 1);
    observe_native_pane(map_pane, 1);
    current_guest_frame = 64;
    dm_botw_touch_menu_test_set_render_frame(64);
    observe_native_pane(map_transform, 1);
    observe_native_pane(map_pane, 1);
    assert(g_map_tap.pending && g_map_tap.ack_ready);
    assert(sample_with_buttons(64, DM_BTN_A) == DM_BTN_A && g_map_tap.pending);
    assert(sample_with_buttons(65, DM_BTN_A) == DM_BTN_A && g_map_tap.pending);
    assert(sample_with_buttons(66, 0) == DM_BTN_A && !g_map_tap.pending);

    current_guest_frame = 67;
    dm_botw_touch_menu_test_set_render_frame(67);
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, tap_x, tap_y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, tap_x, tap_y);
    uint64_t replaced_serial = g_map_tap.serial;
    mock_map_replacement_point[0] = .65f;
    mock_map_replacement_point[1] = tap_y;
    mock_map_replace_request = 1;
    observe_native_pane(map_transform, 1);
    observe_native_pane(map_pane, 1);
    assert(g_map_tap.pending && g_map_tap.serial != replaced_serial && !g_map_tap.issued &&
           fabsf(g_map_tap.point[0] - mock_map_replacement_point[0]) < .001f);
    assert(sample(67) == 0); // a replaced request cannot inherit the old tap's acknowledgement
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    current_guest_frame = 60;
    dm_botw_touch_menu_test_set_render_frame(60);
    pthread_mutex_lock(&g_native_view_mu);
    g_native_view.inventory_visible = g_native_view.clip_valid = 0;
    memset(g_native_view.slot_valid, 0, sizeof g_native_view.slot_valid);
    memset(g_native_view.guide_icon_valid, 0, sizeof g_native_view.guide_icon_valid);
    memset(g_native_view.guide_text_valid, 0, sizeof g_native_view.guide_text_valid);
    memset(g_native_view.header_icon_valid, 0, sizeof g_native_view.header_icon_valid);
    memset(g_native_view.header_text_valid, 0, sizeof g_native_view.header_text_valid);
    g_native_view.footer_root = g_native_view.header_root = 0;
    pthread_mutex_unlock(&g_native_view_mu);
    selector.map_screen[0xfe] = 1; // hidden AppMap alone cannot authorize a fresh candidate
    g_map_validation_cache.frame = UINT64_MAX;
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(!generic_view.map_visible);
    selector.map_screen[0xfe] = 2;
    g_map_validation_cache.frame = UINT64_MAX;
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible);
    mock_eligibility_allowed = 1;
    g_map_ax = 123; g_map_ay = -456; g_map_ry = 789;
    dm_botw_touch_menu_view late_inventory = {0};
    late_inventory.render_frame = 62;
    late_inventory.inventory_visible = late_inventory.cursor_valid = late_inventory.clip_valid = 1;
    late_inventory.slot_count = 1;
    late_inventory.back_valid = 1;
    set_rect(late_inventory.clip, .1f, .1f, .8f, .8f);
    set_rect(late_inventory.back, .85f, .85f, .1f, .1f);
    dm_botw_touch_menu_observe(&late_inventory);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible && g_map_ax == 123 && g_map_ay == -456 && g_map_ry == 789);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, tap_x, tap_y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, tap_x, tap_y);
    assert(g_map_tap.pending);
    selector.active[2] = 0xff;
    selector.apphome_screen[0xfe] = 0; // AppHome closes while gameplay AppMap remains shown
    g_map_validation_cache.frame = UINT64_MAX;
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(!generic_view.map_visible && g_map_ax == 0 && g_map_ay == 0 && g_map_ry == 0);
    assert(!g_map_tap.pending); // losing AppHome ownership cancels a queued native tap
    selector.active[2] = 1;
    selector.apphome_screen[0xfe] = 2;
    g_map_validation_cache.frame = UINT64_MAX;
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)map_cursor);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    observe_native_pane(map_pane, 1); // a focused same-root modal defeats map ownership
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(!generic_view.map_visible); // a focused stamp/modal entry wins even on the map root
    assert(g_map_ax == 0 && g_map_ay == 0 && g_map_ry == 0);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_mode && generic_view.generic_screen == (uintptr_t)selector.screen);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)cursor_two);
    put_ptr(selector.manager + 0x48, 0);
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible); // returning to the free map restores its surface
    current_guest_frame = 74;
    dm_botw_touch_menu_test_set_render_frame(74);
    g_map_pan_active = 1; g_map_ax = 1234; g_map_ay = -2345; g_map_left_owned = 1;
    g_map_ry = 987; g_map_right_owned = 1;
    g_map_tap.pending = g_map_tap.issued = g_map_tap.ack_ready = 1;
    g_map_tap.ack_frame = 74;
    dm_botw_touch_menu_view replacement_map = generic_view;
    replacement_map.render_frame = 74;
    replacement_map.map_pane = (uintptr_t)hidden_map;
    replacement_map.map_root = (uintptr_t)hidden_map_root;
    replacement_map.generic_screen = (uintptr_t)selector.map_screen;
    replacement_map.page_key++;
    dm_botw_touch_menu_observe(&replacement_map);
    assert(!g_map_pan_active && g_map_ax == 0 && g_map_ay == 0 && g_map_ry == 0 &&
           !g_map_tap.pending); // replacing a valid surface cancels its old gestures and tap
    int32_t replacement_axes[4] = {0};
    uint64_t replacement_buttons = 0;
    dm_botw_touch_menu_apply(&replacement_buttons, replacement_axes, 74);
    assert(!replacement_buttons && replacement_axes[0] == 0 && replacement_axes[1] == 0 &&
           replacement_axes[3] == 0);
    g_map_left_owned = g_map_right_owned = 0;
    current_guest_frame = 60;
    dm_botw_touch_menu_test_set_render_frame(60);
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.map_visible);
    g_map_ax = 111; g_map_ay = -222; g_map_ry = 333;
    selector.map_screen[0xfe] = 1; // map closes between selector ticks
    map_pane[0x58] = 0;
    observe_native_pane(map_pane, 1);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(!generic_view.map_visible); // closing AppMap cannot leave the map surface active
    assert(g_map_ax == 0 && g_map_ay == 0 && g_map_ry == 0);
    selector.map_screen[0xfe] = 2;
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    // Title's native focus entry points to an offscreen 20x20 anchor. The
    // visible text under the same Pa_* part supplies click geometry, while
    // the anchor remains the native identity used for focus acknowledgement.
    uint8_t *title_root = fake_pane(75, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *title_part = fake_pane(24, "Pa_SaveFile_00", 75, 300, 100, 500, 0);
    uint8_t *title_disabled = fake_pane(25, "N_Disable_00", 24, 285, 28, 500, 0);
    uint8_t *title_text = fake_pane(26, "T_Btn_00", 25, 285, 28, 433, 0);
    uint8_t *title_anchor = fake_pane(27, "B_Hit_00", 24, 20, 20, 991, 0);
    uint8_t *title_cursor = fake_pane(28, "N_Cursor_00", 24, 20, 20, 991, 0);
    uint8_t *capture_branch = fake_pane(29, "N_CaptureSh_00", 24, 285, 28, 433, 0);
    uint8_t *capture_text = fake_pane(30, "T_Btn_02", 29, 285, 28, 433, 0);
    (void)title_root; (void)title_part; (void)title_disabled; (void)capture_branch;
    put_ptr(selector.owner + 0x60, (uintptr_t)title_cursor);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)cursor_two);
    cursor_two[0x58] = 0; // only the title entry is visible in this focused case
    observe_native_pane(title_anchor, 1);
    observe_native_pane(title_text, 1);
    observe_native_pane(capture_text, 1);
    strcpy((char *)selector.screen + 0x200, "Title_00");
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 1);
    assert(!generic_view.back_valid && generic_view.footer_action_count == 0); // fresh Pause footer is foreign
    assert(generic_view.generic_targets[0].pane == (uintptr_t)title_anchor);
    assert(generic_view.generic_targets[0].rect[0] < 1.0f &&
           generic_view.generic_targets[0].rect[0] + generic_view.generic_targets[0].rect[2] <= 1.0f);
    assert(generic_view.generic_targets[0].rect[2] > .1f); // visible label, not the 20px anchor
    assert(generic_view.generic_targets[0].rect[0] != 0.0f);
    title_text[0x58] = 0;
    observe_native_pane(title_text, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 0); // hidden label cannot back the offscreen anchor
    title_text[0x58] = 1;
    observe_native_pane(title_text, 1);
    strcpy((char *)selector.screen + 0x200, "MessageDialog_00");
    cursor_two[0x58] = 1;
    put_ptr(selector.owner + 0x60, (uintptr_t)cursor_one);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);

    // Title and choice dialogs stay touchable when the focused screen has no
    // Back prompt; rows are sufficient native targets.
    generic_back_icon[0x59] = generic_back_label[0x59] = 0;
    generic_back_prompt_observe(generic_back_icon, 1);
    generic_back_prompt_observe(generic_back_label, 1);
    strcpy((char *)selector.screen + 0x200, "Title_00");
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2 && !generic_view.back_valid);
    assert(dm_botw_touch_menu_active());
    strcpy((char *)selector.screen + 0x200, "MessageDialog_00");
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2 && !generic_view.back_valid);

    // A focused MessageDialog root wins over the underlying menu's rows.
    put_ptr(selector.owner2 + 0x60, (uintptr_t)background_cursor);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 1);
    assert(generic_view.generic_targets[0].pane == (uintptr_t)background_hit);
    put_ptr(selector.owner2 + 0x60, (uintptr_t)cursor_two);

    generic_restore_icon[0x59] = generic_restore_label[0x59] = 0;
    observe_native_pane(generic_restore_icon, 1);
    observe_native_pane(generic_restore_label, 1);
    strcpy((char *)selector.screen + 0x200, "MainScreen_00");
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 0 && !dm_botw_touch_menu_active());
    strcpy((char *)selector.screen + 0x200, "MainShortCut_00");
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 0 && !dm_botw_touch_menu_active());

    generic_back_icon[0x59] = generic_back_label[0x59] = 0;
    generic_back_prompt_observe(generic_back_icon, 1);
    generic_back_prompt_observe(generic_back_label, 1);
    uint8_t *pause_info_root = fake_pane(34, "RootPane", -1, 1280, 720, 640, 360);
    g_native_view.footer_root = (uintptr_t)pause_info_root; // separate from current PauseMenu focus root
    g_native_view.guide_icon_valid[0] = g_native_view.guide_text_valid[0] = 1;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 60;
    g_native_view.guide_icon_glyph[0] = 0xe041;
    set_rect(g_native_view.guide_icons[0], .92f, .9f, .03f, .05f);
    set_rect(g_native_view.guide_texts[0], .84f, .9f, .08f, .05f);
    g_native_view.guide_icon_valid[1] = g_native_view.guide_text_valid[1] = 1;
    g_native_view.guide_icon_seen[1] = g_native_view.guide_text_seen[1] = 60;
    g_native_view.guide_icon_glyph[1] = 0xe043;
    set_rect(g_native_view.guide_icons[1], .65f, .9f, .03f, .05f);
    set_rect(g_native_view.guide_texts[1], .56f, .9f, .08f, .05f);
    strcpy((char *)selector.screen + 0x200, "PauseMenu_00");
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_count == 2 && generic_view.back_valid);
    int legacy_pause_y = 0;
    for (int i = 0; i < generic_view.footer_action_count; i++)
        legacy_pause_y |= generic_view.footer_action_buttons[i] == DM_BTN_Y;
    assert(legacy_pause_y); // PauseMenuInfo prompts remain available across its separate root
    // A native list request in another row owns manager+0x50. A brief focus
    // change to the tapped row must not authorize A while the native request
    // still names the other row.
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry);
    tap(generic_view.generic_targets[1].rect[0] + generic_view.generic_targets[1].rect[2] * .5f,
        generic_view.generic_targets[1].rect[1] + generic_view.generic_targets[1].rect[3] * .5f);
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry);
    assert(!g_selector_ready && !g_generic_eligible_frame && !g_target_valid);
    assert(sample(60) == 0); // focus alone cannot activate against another pending native row
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    put_ptr(selector.manager + 0x50, 0);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    tap(generic_view.generic_targets[0].rect[0] + .01f,
        generic_view.generic_targets[0].rect[1] + .01f);
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry);
    expect_no_virtual_input(60); // A waits for the actual native focus
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    current_guest_frame = 61;
    dm_botw_touch_menu_test_set_render_frame(61);
    g_native_view.frame = 61;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 61;
    generic_hit_observe(hit_one, 1); generic_hit_observe(hit_two, 1);
    selector_tick();
    current_guest_frame = 62;
    dm_botw_touch_menu_test_set_render_frame(62);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry2);
    assert(sample(62) == 0 && !g_selector_ready && !g_target_valid); // native row ownership cancels before HID
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry);
    current_guest_frame = 63;
    dm_botw_touch_menu_test_set_render_frame(63);
    selector_tick();
    assert(sample(63) == 0); // clearing the native slot cannot replay the canceled touch
    dm_botw_touch_menu_test_snapshot(&generic_view);
    tap(generic_view.generic_targets[0].rect[0] + .01f,
        generic_view.generic_targets[0].rect[1] + .01f);
    selector_tick();
    assert(sample(64) == DM_BTN_A); // a fresh request still follows focus acknowledgement
    assert(sample(65) == 0);

    // Adventure Log uses its screen-owned list model when a native row request
    // is already pending. The tapped row resolves through one fresh widget,
    // and A remains blocked until the native model and cursor acknowledge it.
    uint8_t *quest_list = fake_pane(80, "Pa_Quest_00", 40, 700, 500, 640, 360);
    uintptr_t prior_guest_start = mock_guest_start;
    size_t prior_guest_size = mock_guest_size;
    put_ptr(row_two + 0x18, (uintptr_t)quest_list);
    uint8_t quest_list_storage[0x800] = {0};
    uint8_t *quest_widget = quest_list_storage + 0x100;
    uint8_t *quest_descriptor = quest_list_storage + 0x500;
    uintptr_t *quest_vtable = (uintptr_t *)quest_list_storage;
    uintptr_t quest_update = (uintptr_t)quest_vtable;
    g_test_list_widget_vtable = (uintptr_t)quest_vtable;
    g_test_list_widget_update = quest_update;
    g_test_list_widget_override = 1;
    quest_vtable[BOTW_LIST_WIDGET_VTABLE_SLOT / sizeof(uintptr_t)] = quest_update;
    put_ptr(quest_widget, (uintptr_t)quest_vtable);
    put_ptr(quest_widget + 0x60, (uintptr_t)selector.screen);
    int32_t quest_row0 = 0;
    memcpy(quest_widget + 0x30c, &quest_row0, sizeof quest_row0);
    memcpy(quest_widget + 0x310, &quest_row0, sizeof quest_row0);
    mock_guest_start = (uintptr_t)quest_list_storage;
    mock_guest_size = sizeof quest_list_storage;
    mock_list_query_widget = (uintptr_t)quest_widget;
    mock_list_query_entry = (uintptr_t)selector.entry2;
    mock_list_query_descriptor = (uintptr_t)quest_descriptor;
    mock_list_query_index = 1;
    put_ptr(quest_descriptor + 0x28, (uintptr_t)selector.entry2);
    g_test_list_widget_index_resolver = (uintptr_t)mock_list_widget_index;
    g_test_list_widget_descriptor_resolver = (uintptr_t)mock_list_widget_descriptor;
    g_test_list_widget_setter = (uintptr_t)mock_list_widget_set;
    mock_list_setter_manager = (uintptr_t)selector.manager;
    mock_list_setter_screen = (uintptr_t)selector.screen;
    mock_list_setter_entry = (uintptr_t)selector.entry2;
    mock_list_setter_calls = 0;
    mock_list_setter_last_index = -1;
    g_list_widget_observations[0] = (botw_list_widget_observation_t){
        (uintptr_t)quest_widget, 65, 0, 0
    };
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry);
    dm_botw_touch_menu_test_snapshot(&generic_view);
    tap(generic_view.generic_targets[1].rect[0] + generic_view.generic_targets[1].rect[2] * .5f,
        generic_view.generic_targets[1].rect[1] + generic_view.generic_targets[1].rect[3] * .5f);
    uint64_t quest_serial = atomic_load_explicit(&g_target_serial, memory_order_acquire);
    uintptr_t quest_owner = g_target_owner_pane;
    assert(g_target_valid && g_target_entry == (uintptr_t)selector.entry2 && quest_serial);
    unsigned resolver_calls_before_gate = mock_list_query_index_calls;
    mock_touch_hud_active = 0;
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) < 0);
    assert(mock_list_setter_calls == 0 && mock_list_query_index_calls == resolver_calls_before_gate);
    mock_touch_hud_active = 1;
    mock_list_query_index = -1; // ineligible native row descriptors cannot be forced
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) < 0);
    assert(mock_list_setter_calls == 0);
    mock_list_query_index = 1;
    g_list_widget_observations[1] = g_list_widget_observations[0]; // two candidate widgets is ambiguous
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) < 0);
    assert(mock_list_setter_calls == 0);
    memset(&g_list_widget_observations[1], 0, sizeof g_list_widget_observations[1]);
    int32_t already_selected = 1;
    memcpy(quest_widget + 0x30c, &already_selected, sizeof already_selected);
    memcpy(quest_widget + 0x310, &already_selected, sizeof already_selected);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry2);
    put_ptr(selector.screen + 0xe0, (uintptr_t)selector.entry2);
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) > 0);
    assert(g_list_selection.issued && g_list_selection.acknowledged && mock_list_setter_calls == 0);
    int32_t changed_after_ack = 0;
    memcpy(quest_widget + 0x30c, &changed_after_ack, sizeof changed_after_ack);
    assert(sample(65) == 0); // no A while the model no longer points at the selected row
    pthread_mutex_lock(&g_menu_mu); g_view.render_frame = 66; pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_test_set_render_frame(66);
    assert(sample(66) == 0 && !g_target_valid); // even an already-selected row is rechecked at HID
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) < 0); // a replaced/cancelled serial can never reach the setter
    assert(mock_list_setter_calls == 0);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry);
    put_ptr(selector.screen + 0xe0, (uintptr_t)selector.entry);
    int32_t initial_row = 0;
    memcpy(quest_widget + 0x30c, &initial_row, sizeof initial_row);
    memcpy(quest_widget + 0x310, &initial_row, sizeof initial_row);
    pthread_mutex_lock(&g_menu_mu); g_view.render_frame = 65; pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_test_set_render_frame(65);
    tap(generic_view.generic_targets[1].rect[0] + generic_view.generic_targets[1].rect[2] * .5f,
        generic_view.generic_targets[1].rect[1] + generic_view.generic_targets[1].rect[3] * .5f);
    quest_serial = atomic_load_explicit(&g_target_serial, memory_order_acquire);
    current_guest_frame = 65;
    dm_botw_touch_menu_test_set_render_frame(65);
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) > 0);
    assert(mock_list_setter_calls == 1 && mock_list_setter_last_index == 1);
    assert(*(int32_t *)(quest_widget + 0x30c) == 1 &&
           *(int32_t *)(quest_widget + 0x310) == 1);
    assert(sample(65) == 0 && !g_selector_ready); // issue alone never emits A
    current_guest_frame = 66;
    dm_botw_touch_menu_test_set_render_frame(65);
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 65) > 0);
    assert(mock_list_setter_calls == 1 && g_selector_ready &&
           g_generic_eligible_entry == (uintptr_t)selector.entry2);
    pthread_mutex_lock(&g_menu_mu); g_view.render_frame = 66; pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_test_set_render_frame(66);
    int32_t wrong_committed_row = 0;
    memcpy(quest_widget + 0x30c, &wrong_committed_row, sizeof wrong_committed_row);
    assert(sample(66) == 0 && !g_target_valid);
    // The owning native widget, not a Quest pane name, selects this adapter.
    strcpy((char *)quest_list + PANE_NAME, "Pa_SharedList_00"); // model change after ack cancels before HID A
    pthread_mutex_lock(&g_menu_mu); g_last_apply_valid = 0; g_view.render_frame = 66; pthread_mutex_unlock(&g_menu_mu);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry);
    put_ptr(selector.screen + 0xe0, (uintptr_t)selector.entry);
    tap(generic_view.generic_targets[1].rect[0] + generic_view.generic_targets[1].rect[2] * .5f,
        generic_view.generic_targets[1].rect[1] + generic_view.generic_targets[1].rect[3] * .5f);
    quest_serial = atomic_load_explicit(&g_target_serial, memory_order_acquire);
    quest_owner = g_target_owner_pane;
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 66) > 0);
    assert(mock_list_setter_calls == 2);
    assert(selector_native_list_select((uintptr_t)selector.manager, (uintptr_t)selector.screen,
        (uintptr_t)selector.entry2, quest_owner, (uintptr_t)menu_root, 2,
        quest_serial, 66) > 0);
    assert(g_selector_ready);
    pthread_mutex_lock(&g_menu_mu); g_view.render_frame = 66; g_last_apply_valid = 0; pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_test_set_render_frame(66);
    assert(sample(66) == DM_BTN_A); // native row commit, cursor, and focus all acknowledged
    assert(mock_list_setter_calls == 2);
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    put_ptr(selector.manager + 0x50, (uintptr_t)selector.entry);
    put_ptr(selector.screen + 0xe0, (uintptr_t)selector.entry);
    pthread_mutex_lock(&g_menu_mu); g_last_apply_valid = 0; pthread_mutex_unlock(&g_menu_mu);
    g_test_list_widget_override = 0;
    g_test_list_widget_index_resolver = g_test_list_widget_descriptor_resolver = 0;
    g_test_list_widget_setter = 0;
    put_ptr(row_two + 0x18, (uintptr_t)menu_root);
    mock_guest_start = prior_guest_start;
    mock_guest_size = prior_guest_size;

    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    current_guest_frame = 66;
    dm_botw_touch_menu_test_set_render_frame(66);
    g_native_view.frame = 66;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 66;
    generic_hit_observe(hit_one, 1); generic_hit_observe(hit_two, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    tap(generic_view.back[0] + generic_view.back[2] * .5f,
        generic_view.back[1] + generic_view.back[3] * .5f);
    assert(sample(66) == 0); // consume the release edge from the preceding A pulse
    pthread_mutex_lock(&g_menu_mu); g_view.render_frame = 66; g_last_apply_valid = 0; pthread_mutex_unlock(&g_menu_mu);
    dm_botw_touch_menu_test_set_render_frame(66);
    current_guest_frame = 66;
    tap(generic_view.back[0] + generic_view.back[2] * .5f,
        generic_view.back[1] + generic_view.back[3] * .5f);
    assert(sample(66) == DM_BTN_B); // current modal closes through native B dispatch

    // A current PauseMenu header prompt reuses the generic native-button
    // route. It sends one shoulder pulse and does not request row focus/A.
    g_native_view.footer_root = (uintptr_t)menu_root;
    uint8_t *titlebar = fake_pane(55, "N_TitleBarUp_00", 40, 400, 60, 640, 300);
    uint8_t *zl = fake_pane(56, "Pa_BtnZL_00", 55, 36, 40, 470, 310);
    uint8_t *disable = fake_pane(57, "N_Disable_00", 56, 32, 32, 470, 310);
    uint8_t *zl_icon = fake_pane(58, "T_Icon_00", 57, 36, 40, 470, 310);
    uint8_t *zl_text = fake_pane(59, "T_LeftText_01", 55, 130, 23, 470, 287);
    (void)titlebar; (void)zl; (void)disable;
    uint16_t zl_glyph = 0xe044;
    put_ptr(zl_icon + 0xe0, (uintptr_t)&zl_glyph);
    observe_native_pane(zl_icon, 1);
    observe_native_pane(zl_text, 1); // label is a sibling of Pa_BtnZL, not its descendant
    assert(g_native_view.header_root == (uintptr_t)menu_root);
    assert(g_native_view.header_icon_valid[0] && g_native_view.header_text_valid[0]);
    assert(g_native_view.header_icon_glyph[0] == 0xe044);
    // The live label alternates between the _00 and _01 text panes during a
    // page change; a hidden sibling observed after it must not clear it.
    uint8_t *zl_text_alt = fake_pane(60, "T_LeftText_00", 55, 130, 23, 470, 287);
    observe_native_pane(zl_text_alt, 1);
    assert(g_native_view.header_text_valid[0]);
    assert(g_native_view.header_text_pane[0] == (uintptr_t)zl_text_alt);
    zl_text[0x59] = 0;
    observe_native_pane(zl_text, 1);
    assert(g_native_view.header_text_valid[0]);
    assert(g_native_view.header_text_pane[0] == (uintptr_t)zl_text_alt);
    zl_text_alt[0x59] = 0;
    observe_native_pane(zl_text_alt, 1);
    assert(!g_native_view.header_text_valid[0]);
    zl_text[0x59] = 0xff;
    observe_native_pane(zl_text, 1);
    assert(g_native_view.header_text_valid[0]);
    g_native_view.header_icon_valid[1] = 0; // observed ZR sits under alpha-zero N_Disable_00
    g_native_view.header_text_valid[1] = 1;
    g_native_view.header_text_seen[1] = 67;
    g_native_view.header_icon_seen[1] = 67;
    g_native_view.header_icon_glyph[1] = 0xe045;
    set_rect(g_native_view.header_icons[1], .65f, .8f, .05f, .05f);
    set_rect(g_native_view.header_texts[1], .7f, .8f, .1f, .05f);
    g_native_view.frame = 67;
    g_native_view.header_text_seen[0] = 67;
    g_native_view.header_icon_seen[0] = 67;
    dm_botw_touch_menu_view native_header = snapshot_native_view_locked();
    int has_l = 0, has_r = 0;
    for (int i = 0; i < native_header.footer_action_count; i++) {
        has_l |= native_header.footer_action_buttons[i] == DM_BTN_L;
        has_r |= native_header.footer_action_buttons[i] == DM_BTN_R;
    }
    assert(has_l && !has_r);
    generic_view.footer_action_count = 1;
    generic_view.footer_action_buttons[0] = DM_BTN_L;
    set_rect(generic_view.footer_actions[0], .35f, .82f, .2f, .06f);
    generic_view.render_frame = 67;
    uintptr_t request_before_header = get_ptr(selector.manager + 0x50);
    view = generic_view;
    publish(67);
    tap(.45f, .85f);
    assert(sample(67) == 0); // release the preceding B pulse first
    assert(sample(68) == DM_BTN_L);
    assert(sample(69) == 0);
    assert(get_ptr(selector.manager + 0x50) == request_before_header);

    // AppHome renders its header labels through N_CaptureText_01 ->
    // N_TimeLineDemo/P_Text_00. The source panes are near the canvas center;
    // only the bound destination is at the visible top strip.
    g_native_view.header_root = 0;
    g_native_view.header_capture_mode = 0;
    g_native_view.footer_root = 0;
    memset(g_native_view.header_icon_valid, 0, sizeof g_native_view.header_icon_valid);
    memset(g_native_view.header_text_valid, 0, sizeof g_native_view.header_text_valid);
    uintptr_t capture_saved_guest_start = mock_guest_start;
    size_t capture_saved_guest_size = mock_guest_size;
    mock_guest_start = (uintptr_t)native_panes;
    mock_guest_size = sizeof native_panes;
    uint8_t *capture_apphome_root = fake_pane(81, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *scanline = fake_pane(82, "Pa_ScanningLine_", 81, 1280, 720, 640, 360);
    uint8_t *deco = fake_pane(83, "N_Deco_00", 82, 696, 36, 0, 0);
    uint8_t *timeline = fake_pane(84, "N_TimeLineDemo_0", 83, 696, 36, 0, 0);
    uint8_t *top_destination = fake_pane(85, "P_Text_00", 84, 696, 36, 0, 320);
    uint8_t *source_capture = fake_pane(86, "N_CaptureText_01", 82, 696, 36, 0, 0);
    uint8_t *apphome_zl = fake_pane(87, "Pa_BtnZL_00", 86, 40, 36, -150, 0);
    uint8_t *apphome_icon = fake_pane(88, "T_Icon_01", 87, 30, 40, -150, 0);
    uint8_t *apphome_label = fake_pane(89, "T_LeftText_00", 86, 166, 24, -255, -1);
    uint8_t *apphome_zr = fake_pane(94, "Pa_BtnZR_00", 86, 40, 36, 150, 0);
    uint8_t *apphome_right_icon = fake_pane(95, "T_Icon_01", 94, 30, 40, 150, 0);
    uint8_t *apphome_right_label = fake_pane(96, "T_RightText_00", 86, 166, 24, 255, -1);
    uint8_t *footer_align = fake_pane(97, "N_Align_00", 84, 800, 40, 480, -310);
    uint8_t *footer_guide = fake_pane(98, "Pa_Guide_00", 97, 200, 40, 500, -310);
    uint8_t *footer_capture = fake_pane(99, "N_CaptureText_00", 98, 200, 40, 0, 0);
    uint8_t *footer_destination = fake_pane(100, "P_Text_00", 98, 200, 40, 500, -310);
    (void)capture_apphome_root; (void)scanline; (void)deco; (void)timeline;
    link_child(capture_apphome_root, scanline);
    link_child(scanline, deco); link_child(deco, timeline); link_child(timeline, top_destination);
    link_child(scanline, source_capture);
    link_child(source_capture, apphome_zl); link_child(apphome_zl, apphome_icon);
    link_child(source_capture, apphome_label);
    link_child(source_capture, apphome_zr); link_child(apphome_zr, apphome_right_icon);
    link_child(source_capture, apphome_right_label);
    link_child(timeline, footer_align); link_child(footer_align, footer_guide);
    link_child(footer_guide, footer_capture); link_child(footer_guide, footer_destination);
    uintptr_t captured_destination = 0;
    assert(ancestor_named(source_capture, "RootPane") == capture_apphome_root);
    assert(ancestor_prefix(source_capture, "Pa_ScanningLine_"));
    assert(ancestor_prefix(top_destination, "N_TimeLineDemo_"));
    assert(ancestor_named(top_destination, "N_Deco_00") == deco);
    assert(pane_find_unique(capture_apphome_root, "P_Text_00", "N_TimeLineDemo_",
                            &captured_destination) == -1); // footer destination shares this ancestor
    assert(pane_find_unique_under_parent(capture_apphome_root, "P_Text_00", "N_TimeLineDemo_",
                                         &captured_destination) == 1);
    captured_destination = 0;
    assert(apphome_capture_destination(capture_apphome_root, source_capture,
                                      &captured_destination));
    assert(captured_destination == (uintptr_t)top_destination);
    uint16_t apphome_glyph = 0xe044;
    uint16_t apphome_right_glyph = 0xe045;
    put_ptr(apphome_icon + 0xe0, (uintptr_t)&apphome_glyph);
    put_ptr(apphome_right_icon + 0xe0, (uintptr_t)&apphome_right_glyph);
    g_native_view.header_root = (uintptr_t)capture_apphome_root; // address reused from a prior layout
    observe_native_pane(apphome_icon, 1);
    observe_native_pane(apphome_label, 1);
    observe_native_pane(apphome_right_icon, 1);
    observe_native_pane(apphome_right_label, 1);
    assert(g_native_view.header_root == (uintptr_t)capture_apphome_root && g_native_view.header_capture_mode);
    assert(g_native_view.header_icon_valid[0] && g_native_view.header_text_valid[0]);
    assert(g_native_view.header_icons[0][1] < .1f && g_native_view.header_texts[0][1] < .1f);
    assert(g_native_view.header_icon_valid[1] && g_native_view.header_text_valid[1]);
    assert(g_native_view.header_icons[1][1] < .1f && g_native_view.header_texts[1][1] < .1f);
    float raw_source[4]; native_rect_from_pane(apphome_icon, -150, 0, raw_source);
    assert(raw_source[1] > .45f); // source capture coordinates are not touch coordinates
    g_native_view.footer_root = (uintptr_t)capture_apphome_root;
    dm_botw_touch_menu_view apphome_header_view = snapshot_native_view_locked();
    int has_apphome_zl = 0, has_apphome_zr = 0;
    for (int i = 0; i < apphome_header_view.footer_action_count; i++) {
        if (apphome_header_view.footer_action_buttons[i] == DM_BTN_L) {
            has_apphome_zl = 1;
            assert(apphome_header_view.footer_actions[i][1] < .1f);
        }
        if (apphome_header_view.footer_action_buttons[i] == DM_BTN_R) {
            has_apphome_zr = 1;
            assert(apphome_header_view.footer_actions[i][1] < .1f);
        }
    }
    assert(has_apphome_zl && has_apphome_zr);

    // A pre-matrix callback can be the only callback for a clean pane. Keep
    // the validated identity and recalculate against its live destination
    // transform on every snapshot, without requiring a post callback.
    float moved_top_y = 300.0f;
    memcpy(top_destination + PANE_MATRIX + 0x1c, &moved_top_y, sizeof moved_top_y);
    current_guest_frame = 68;
    dm_botw_touch_menu_test_set_render_frame(68);
    observe_native_pane(apphome_icon, 0);
    observe_native_pane(apphome_label, 0);
    assert(g_native_view.header_icon_valid[0] && g_native_view.header_text_valid[0]);
    assert(fabsf(g_native_view.header_icons[0][1] - .0306f) > .02f);
    moved_top_y = 280.0f;
    memcpy(top_destination + PANE_MATRIX + 0x1c, &moved_top_y, sizeof moved_top_y);
    current_guest_frame = 69;
    dm_botw_touch_menu_test_set_render_frame(69);
    observe_native_pane(apphome_icon, 0);
    assert(g_native_view.header_icon_valid[0] && g_native_view.header_text_valid[0]);
    assert(g_native_view.header_icons[0][1] > .07f && g_native_view.header_icons[0][1] < .1f);
    apphome_icon[0x58] = 0;
    current_guest_frame = 70;
    dm_botw_touch_menu_test_set_render_frame(70);
    observe_native_pane(apphome_icon, 0);
    assert(!g_native_view.header_icon_valid[0] && !g_native_view.header_text_valid[0]);
    apphome_icon[0x58] = 1;
    current_guest_frame = 71;
    dm_botw_touch_menu_test_set_render_frame(71);
    observe_native_pane(apphome_icon, 1);
    observe_native_pane(apphome_label, 1);
    observe_native_pane(apphome_right_icon, 1);
    observe_native_pane(apphome_right_label, 1);

    char saved_dest_name[16]; memcpy(saved_dest_name, top_destination + PANE_NAME, 16);
    memset(top_destination + PANE_NAME, 0, 16);
    memcpy(top_destination + PANE_NAME, "P_Missing_00", 12);
    assert(!apphome_capture_destination(capture_apphome_root, source_capture, NULL));
    observe_native_pane(apphome_icon, 1);
    assert(!g_native_view.header_icon_valid[0] && !g_native_view.header_text_valid[0] &&
           !g_native_view.header_icon_valid[1] && !g_native_view.header_text_valid[1]);
    memcpy(top_destination + PANE_NAME, saved_dest_name, 16);
    uint8_t *duplicate_top_destination = fake_pane(93, "P_Text_00", 84, 696, 36, 0, 320);
    link_child(timeline, duplicate_top_destination);
    assert(!apphome_capture_destination(capture_apphome_root, source_capture, NULL));
    observe_native_pane(apphome_icon, 1);
    assert(!g_native_view.header_icon_valid[0] && !g_native_view.header_text_valid[0] &&
           !g_native_view.header_icon_valid[1] && !g_native_view.header_text_valid[1]);

    // The same affine mapping handles scale and rotation, not just a vertical
    // translation. A child centered in the source maps to the destination center.
    uint8_t *affine_source = fake_pane(90, "N_CaptureText_00", 81, 100, 50, -20, 0);
    uint8_t *affine_child = fake_pane(91, "T_Icon_00", 90, 20, 10, -20, 0);
    uint8_t *affine_dest = fake_pane(92, "P_Text_00", 81, 200, 100, 0, 320);
    float affine_rect[4];
    set_affine(affine_source, .8f, -.6f, .6f, .8f);
    set_affine(affine_child, .8f, -.6f, .6f, .8f);
    set_affine(affine_dest, 0.0f, -1.2f, 1.2f, 0.0f);
    assert(capture_mapped_rect(affine_source, affine_child, affine_dest, affine_rect));
    assert(fabsf(affine_rect[0] + affine_rect[2] * .5f - .5f) < .001f);
    assert(fabsf(affine_rect[1] + affine_rect[3] * .5f - (360.0f - 320.0f) / 720.0f) < .001f);
    assert(fabsf(affine_rect[2] - 24.0f / 1280.0f) < .001f);
    assert(fabsf(affine_rect[3] - 48.0f / 720.0f) < .001f);
    set_affine(affine_source, 0, 0, 0, 0);
    assert(!capture_mapped_rect(affine_source, affine_child, affine_dest, affine_rect));
    mock_guest_start = capture_saved_guest_start;
    mock_guest_size = capture_saved_guest_size;

    // The map pane is its own surface: a drag holds the native left stick for
    // panning, a tap keeps the game's native touch, and Back stays live.
    memset(&view, 0, sizeof view);
    view.map_visible = 1;
    set_rect(view.map, .1f, .1f, .8f, .8f);
    view.back_valid = 1;
    set_rect(view.back, .88f, .9f, .1f, .06f);
    current_guest_frame = 70;
    dm_botw_touch_menu_test_set_render_frame(70);
    publish(70);
    assert(!dm_botw_touch_map_active());
    int32_t idle_map_axes[4] = {101, -202, 303, -404};
    assert(!sample_axes(70, idle_map_axes, NULL));
    assert(idle_map_axes[0] == 101 && idle_map_axes[1] == -202 &&
           idle_map_axes[2] == 303 && idle_map_axes[3] == -404);
    view.footer_action_count = 1;
    view.footer_action_buttons[0] = DM_BTN_Y;
    set_rect(view.footer_actions[0], .12f, .12f, .2f, .15f); // intentionally overlaps the map surface
    publish(70);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .2f, .2f);
    assert(g_map_prompt_down && !dm_botw_touch_map_active());
    set_rect(view.footer_actions[0], .45f, .45f, .2f, .15f);
    publish(70); // same action moved while the pointer was held
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .2f, .2f);
    assert(!g_target_valid && !g_map_tap.pending); // stale begin geometry cannot activate
    set_rect(view.footer_actions[0], .12f, .12f, .2f, .15f);
    publish(70);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .2f, .2f);
    assert(g_map_prompt_down);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .2f, .2f);
    assert(sample(70) == DM_BTN_Y && !g_map_tap.pending);
    current_guest_frame = 71;
    dm_botw_touch_menu_test_set_render_frame(71);
    assert(sample(71) == 0); // release the prompt pulse
    view.footer_action_count = 0;
    publish(71);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .5f);
    assert(dm_botw_touch_map_active());
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .625f, .5f);
    int32_t map_axes[4] = {101, -202, 303, -404};
    assert(sample_axes(70, map_axes, NULL) == 1);
    assert(map_axes[0] == 0); // direct displacement; no continuing stick velocity
    assert(map_axes[1] == 0 && map_axes[2] == 303 && map_axes[3] == -404);
    int32_t cached_map_axes[4] = {7, 8, 9, 10};
    assert(sample_axes(70, cached_map_axes, NULL) == 1);
    assert(cached_map_axes[0] == map_axes[0] && cached_map_axes[1] == map_axes[1] &&
           cached_map_axes[2] == 9 && cached_map_axes[3] == 10);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    int32_t cancelled_axes[4] = {11, 22, 33, 44};
    assert(sample_axes(70, cancelled_axes, NULL) == 1);
    assert(cancelled_axes[0] == 0 && cancelled_axes[1] == 0 &&
           cancelled_axes[2] == 33 && cancelled_axes[3] == 44);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .5f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .625f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .625f, .5f);
    int32_t release_axes[4] = {0};
    sample_axes(71, release_axes, NULL);
    assert(release_axes[0] == 0 && release_axes[1] == 0);
    int touches_before = mock_touch_sets;
    current_guest_frame = 72;
    dm_botw_touch_menu_test_set_render_frame(72);
    publish(72);
    tap(.4f, .4f);
    assert(mock_touch_sets == touches_before && g_map_tap.pending && !g_map_tap.issued);
    current_guest_frame = 73;
    dm_botw_touch_menu_test_set_render_frame(73);
    publish(73);
    tap(view.back[0] + view.back[2] * .5f, view.back[1] + view.back[3] * .5f);
    assert(g_target_valid && g_target_index == -1);
    assert(sample(73) == DM_BTN_B);
    current_guest_frame = 74;
    dm_botw_touch_menu_test_set_render_frame(74);
    publish(74);
    assert(!dm_botw_touch_map_active()); // map is visible, but no touch owns its surface
    dm_botw_touch_menu_pinch(1.2f);
    int32_t zoom_axes[4] = {11, 22, 33, 44};
    assert(sample_axes(74, zoom_axes, NULL) == 1);
    assert(zoom_axes[0] == 11 && zoom_axes[1] == 22 && zoom_axes[2] == 33 && zoom_axes[3] > 0x4000);
    dm_botw_touch_menu_pinch(.8f);
    memset(zoom_axes, 0, sizeof zoom_axes);
    assert(sample_axes(74, zoom_axes, NULL) == 1 && zoom_axes[3] < -0x4000);
    dm_botw_touch_menu_pinch(0.0f);
    int32_t zoom_end[4] = {55, 66, 77, 88};
    assert(sample_axes(75, zoom_end, NULL) == 1);
    assert(zoom_end[0] == 55 && zoom_end[1] == 66 && zoom_end[2] == 77 && zoom_end[3] == 0);

    atomic_store_explicit(&g_test_ready, 0, memory_order_release);
    assert(!dm_botw_touch_menu_active()); // no validated OBS37 hook means no generic takeover
    tap(generic_view.generic_targets[1].rect[0] + .01f,
        generic_view.generic_targets[1].rect[1] + .01f);
    assert(!g_target_valid);
    atomic_store_explicit(&g_test_ready, 1, memory_order_release);

    dm_botw_touch_menu_reset();
    current_guest_frame = 65;
    dm_botw_touch_menu_test_set_render_frame(65);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    assert(generic_view.generic_mode && generic_view.generic_count == 0);
    assert(!dm_botw_touch_menu_active()); // without a live Back prompt, keep normal controls available

    // If the native eligibility predicate turns false between request and
    // focus acknowledgement, the generic request is cancelled and no A leaks.
    dm_botw_touch_menu_reset();
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry2);
    put_ptr(selector.manager + 0x50, 0);
    current_guest_frame = 66;
    dm_botw_touch_menu_test_set_render_frame(66);
    g_native_view.guide_icon_valid[0] = g_native_view.guide_text_valid[0] = 1;
    g_native_view.frame = 66;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 66;
    g_native_view.guide_icon_glyph[0] = 0xe041;
    set_rect(g_native_view.guide_icons[0], .93f, .9f, .04f, .05f);
    set_rect(g_native_view.guide_texts[0], .82f, .9f, .1f, .05f);
    generic_hit_observe(hit_one, 1); generic_hit_observe(hit_two, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    tap(generic_view.generic_targets[0].rect[0] + .01f,
        generic_view.generic_targets[0].rect[1] + .01f);
    selector_tick();
    assert(get_ptr(selector.manager + 0x50) == (uintptr_t)selector.entry);
    mock_eligibility_allowed = 0;
    selector_tick();
    assert(sample(66) == 0);
    mock_eligibility_allowed = 1;
    dm_botw_touch_menu_test_set_generic_selector(0, 0, 0);
    put_ptr(selector.control + 0x80, 0);
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf9ad8));

    // Cancel, owner change and inactive/controller mode never write a request.
    dm_botw_touch_menu_reset();
    put_ptr(selector.manager + 0x48, 0); put_ptr(selector.manager + 0x50, 0);
    memset(&view, 0, sizeof view); view.inventory_visible = view.clip_valid = view.back_valid = 1;
    view.page_key = 40; view.render_frame = 40; view.slot_count = 1;
    set_rect(view.clip, .1f, .1f, .8f, .8f); set_rect(view.back, .9f, .9f, .05f, .05f);
    view.slot_panes[0] = (uintptr_t)selector.pane; set_rect(view.slots[0], .3f, .3f, .1f, .1f);
    publish(40); tap(.35f, .35f); dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    selector_tick(); assert(get_ptr(selector.manager + 0x50) == 0);
    tap(.35f, .35f); view.page_key = 41; publish(41); selector_tick();
    assert(get_ptr(selector.manager + 0x50) == 0);
    dm_botw_touch_menu_reset();
    view.page_key = 42; view.render_frame = 42; publish(42);
    dm_botw_touch_menu_test_set_native_ready(0);
    current_guest_frame = 42;
    atomic_store_explicit(&g_test_ready, 0, memory_order_release);
    mock_touch_hud_active = 1; // HUD exists, but no validated native selector hook.
    assert(!dm_botw_touch_menu_active());
    tap(.35f, .35f); selector_tick();
    assert(get_ptr(selector.manager + 0x50) == 0);
    expect_no_virtual_input(42);
    mock_touch_hud_active = 0; // controller/inactive mode is equally inert.
    dm_botw_touch_menu_test_set_generic_selector(1, (uintptr_t)mock_native_group,
                                                  (uintptr_t)mock_native_shown);
    mock_group_calls = mock_shown_calls = mock_eligibility_calls = 0;
    g_map_ry = 1234; g_map_ry_frame = 41;
    assert(!dm_botw_touch_map_active());
    dm_botw_touch_menu_pinch(1.2f);
    assert(g_map_ry == 1234 && g_map_ry_frame == 41);
    selector_tick(); assert(get_ptr(selector.manager + 0x50) == 0);
    assert(mock_group_calls == 0 && mock_shown_calls == 0 && mock_eligibility_calls == 0);
    g_map_left_owned = g_map_right_owned = 1;
    int32_t controller_axes[4] = {101, -202, 303, -404};
    assert(!sample_axes(43, controller_axes, NULL));
    assert(controller_axes[0] == 101 && controller_axes[1] == -202 &&
           controller_axes[2] == 303 && controller_axes[3] == -404);
    assert(!g_map_left_owned && !g_map_right_owned);

    // A guide key's capture source is bound to its P_Text_00 destination.
    // Use the final destination bounds, not the capture-local child geometry.
    dm_botw_touch_menu_reset();
    uintptr_t saved_guest_start = mock_guest_start;
    size_t saved_guest_size = mock_guest_size;
    mock_guest_start = (uintptr_t)native_panes;
    mock_guest_size = sizeof native_panes;
    uint8_t *pad_root = fake_pane(71, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *pad_row = fake_pane(72, "N_Align_00", 71, 800, 40, 480, -310);
    uint8_t *pad_key = fake_pane(73, "Pa_Guide_02", 72, 360, 40, 480, -310);
    uint8_t *key_icon_box = fake_pane(74, "N_InOut_00", 73, 30, 40, 560, -310);
    uint8_t *key_plate = fake_pane(75, "P_Text_00", 73, 200, 40, 470, -310);
    uint8_t *key_capture = fake_pane(76, "N_CaptureText_00", 73, 200, 40, 0, 0);
    uint8_t *key_glyph = fake_pane(77, "T_Icon_00", 76, 34, 34, 80, 0);
    uint8_t *key_label = fake_pane(78, "T_Guide_00", 76, 120, 24, -30, 0);
    (void)pad_root; (void)pad_row; (void)key_icon_box; (void)key_plate;
    link_child(pad_key, key_icon_box);
    link_child(pad_key, key_plate);
    link_child(pad_key, key_capture);
    link_child(key_capture, key_glyph);
    link_child(key_capture, key_label);
    uint16_t pad_back_glyph = 0xe041;
    put_ptr(key_glyph + 0xe0, (uintptr_t)&pad_back_glyph);
    generic_back_prompt_observe(key_glyph, 1);
    generic_back_prompt_observe(key_label, 1);
    dm_botw_touch_menu_view pad_view;
    (void)pad_view;
    observe_native_pane(key_glyph, 1);
    observe_native_pane(key_label, 1);
    // Slot 2's prompt spans the glyph box and the label plate in picture space,
    // not the captured label's local coordinates.
    assert(g_native_view.guide_icon_valid[2] && g_native_view.guide_text_valid[2]);
    assert(fabsf(g_native_view.guide_icons[2][0] - .9164f) < .002f);
    assert(fabsf(g_native_view.guide_icons[2][1] - .9069f) < .002f);
    assert(fabsf(g_native_view.guide_icons[2][2] - .02656f) < .002f);
    assert(fabsf(g_native_view.guide_texts[2][0] - .7891f) < .002f);
    dm_botw_touch_menu_view pad_snapshot = snapshot_native_view_locked();
    assert(pad_snapshot.back_valid);
    assert(fabsf(pad_snapshot.back[0] - .7891f) < .002f);

    float mapped_rect[4];
    assert(guide_prompt_rect(pad_key, key_glyph, 1, mapped_rect));
    assert(fabsf(mapped_rect[0] - g_native_view.guide_icons[2][0]) < .001f);
    assert(guide_prompt_rect(pad_key, key_label, 0, mapped_rect));
    assert(fabsf(mapped_rect[0] - .7891f) < .002f);
    // A hidden or ambiguous destination fails closed instead of using a raw
    // source rect or manufacturing a larger hitbox.
    key_plate[0x58] = 0;
    assert(!guide_prompt_rect(pad_key, key_glyph, 1, mapped_rect));
    key_plate[0x58] = 1;
    uint8_t *duplicate_plate = fake_pane(80, "P_Text_00", 73, 200, 40, 470, -310);
    link_child(pad_key, duplicate_plate);
    assert(!guide_prompt_rect(pad_key, key_glyph, 1, mapped_rect));

    // Packed captured prompts keep their true glyph anchors. The full picture
    // remains the label target, while neighbor clamping follows the glyphs.
    dm_botw_touch_menu_reset();
    pthread_mutex_lock(&g_generic_hits_mu);
    memset(g_generic_back_prompts, 0, sizeof g_generic_back_prompts);
    pthread_mutex_unlock(&g_generic_hits_mu);
    uint8_t *packed_root = fake_pane(81, "RootPane", -1, 1280, 720, 640, 360);
    const char *packed_names[] = {"Pa_GuideA_00", "Pa_GuideX_00", "Pa_GuideB_00"};
    const uint16_t packed_glyphs[] = {0xe040, 0xe042, 0xe041};
    const float packed_x[] = {220, 380, 540};
    for (int i = 0; i < 3; i++) {
        int base = 82 + i * 5;
        uint8_t *part = fake_pane(base, packed_names[i], 81, 200, 40, packed_x[i], -310);
        uint8_t *picture = fake_pane(base + 1, "P_Text_00", base, 200, 40, packed_x[i], -310);
        uint8_t *capture = fake_pane(base + 2, "N_CaptureText_00", base, 200, 40, 0, 0);
        uint8_t *icon = fake_pane(base + 3, "T_Icon_00", base + 2, 34, 34, 80, 0);
        uint8_t *label = fake_pane(base + 4, "T_Guide_00", base + 2, 120, 24, 0, 0);
        link_child(packed_root, part);
        link_child(part, picture);
        link_child(part, capture);
        link_child(capture, icon);
        link_child(capture, label);
        put_ptr(icon + 0xe0, (uintptr_t)&packed_glyphs[i]);
        generic_back_prompt_observe(icon, 1);
        generic_back_prompt_observe(label, 1);
    }
    float packed_back[4], packed_a[4];
    uint64_t packed_frame = dm_guest_frame();
    assert(generic_back_prompt_snapshot((uintptr_t)packed_root, packed_frame, packed_back));
    assert(generic_action_prompt_snapshot((uintptr_t)packed_root, packed_frame, DM_BTN_A, packed_a));
    float b_icon_x = (620.0f + 640.0f) / 1280.0f;
    float b_label_x = (540.0f + 640.0f) / 1280.0f;
    float a_icon_x = (300.0f + 640.0f) / 1280.0f;
    assert(b_icon_x >= packed_back[0] && b_icon_x <= packed_back[0] + packed_back[2]);
    assert(b_label_x >= packed_back[0] && b_label_x <= packed_back[0] + packed_back[2]);
    assert(a_icon_x < packed_back[0] || a_icon_x > packed_back[0] + packed_back[2]);
    assert(fabsf(packed_back[0] - .872656f) < .002f);
    (void)packed_a;

    // Any native guide glyph may establish the current guide root by itself.
    // A-only roots must not depend on a Back/X/Y hint arriving first.
    pthread_mutex_lock(&g_native_view_mu);
    memset(&g_native_view, 0, sizeof g_native_view);
    pthread_mutex_unlock(&g_native_view_mu);
    uint8_t *action_root = fake_pane(70, "RootPane", -1, 1280, 720, 640, 360);
    uint8_t *action_row = fake_pane(71, "N_Align_00", 70, 800, 40, 480, -310);
    uint8_t *action_a = fake_pane(72, "Pa_Guide_00", 71, 140, 40, 560, -310);
    uint8_t *action_a_icon = fake_pane(73, "T_Icon_00", 72, 34, 34, 560, -310);
    uint8_t *action_a_label = fake_pane(74, "T_Guide_00", 72, 80, 24, 520, -310);
    uint16_t action_a_glyph = 0xe040;
    (void)action_row; (void)action_a;
    put_ptr(action_a_icon + 0xe0, (uintptr_t)&action_a_glyph);
    observe_native_pane(action_a_icon, 1);
    assert(g_native_view.footer_root == (uintptr_t)action_root);
    observe_native_pane(action_a_label, 1);
    dm_botw_touch_menu_view action_view = snapshot_native_view_locked();
    int has_a = 0;
    for (int i = 0; i < action_view.footer_action_count; i++)
        has_a |= action_view.footer_action_buttons[i] == DM_BTN_A;
    assert(has_a);

    // The shared guide cache maps both shoulder triggers by glyph and keeps
    // their distinct actions available when they are the only visible hints.
    pthread_mutex_lock(&g_generic_hits_mu);
    memset(g_generic_back_prompts, 0, sizeof g_generic_back_prompts);
    pthread_mutex_unlock(&g_generic_hits_mu);
    uint8_t *action_zl = fake_pane(75, "Pa_GuideZL_00", 70, 140, 40, 300, -310);
    uint8_t *action_zl_icon = fake_pane(76, "T_Icon_00", 75, 34, 34, 300, -310);
    uint8_t *action_zl_label = fake_pane(77, "T_Guide_00", 75, 80, 24, 260, -310);
    uint8_t *action_zr = fake_pane(78, "Pa_GuideZR_00", 70, 140, 40, 500, -310);
    uint8_t *action_zr_icon = fake_pane(79, "T_Icon_00", 78, 34, 34, 500, -310);
    (void)action_zl; (void)action_zr;
    // Reuse the old A label pane for the ZR text after changing its ancestry.
    put_ptr(action_a_label + 0x18, (uintptr_t)action_zr);
    uint16_t action_zl_glyph = 0xe046, action_zr_glyph = 0xe047;
    put_ptr(action_zl_icon + 0xe0, (uintptr_t)&action_zl_glyph);
    put_ptr(action_zr_icon + 0xe0, (uintptr_t)&action_zr_glyph);
    generic_back_prompt_observe(action_zl_icon, 1);
    generic_back_prompt_observe(action_zl_label, 1);
    generic_back_prompt_observe(action_zr_icon, 1);
    generic_back_prompt_observe(action_a_label, 1);
    dm_botw_touch_menu_view trigger_view = {0};
    generic_action_prompts_to_view((uintptr_t)action_root, dm_guest_frame(), &trigger_view);
    int has_zl = 0, has_zr = 0;
    for (int i = 0; i < trigger_view.footer_action_count; i++) {
        has_zl |= trigger_view.footer_action_buttons[i] == DM_BTN_ZL;
        has_zr |= trigger_view.footer_action_buttons[i] == DM_BTN_ZR;
    }
    assert(has_zl && has_zr);
    uint16_t move_glyph = 0xe05e; // AppHome's live Move/stick hint
    put_ptr(action_zl_icon + 0xe0, (uintptr_t)&move_glyph);
    generic_back_prompt_observe(action_zl_icon, 1);
    memset(&trigger_view, 0, sizeof trigger_view);
    generic_action_prompts_to_view((uintptr_t)action_root, dm_guest_frame(), &trigger_view);
    assert(!guide_glyph_button(move_glyph) && !generic_action_button(guide_glyph_button(move_glyph)));
    has_zl = has_zr = 0;
    for (int i = 0; i < trigger_view.footer_action_count; i++) {
        has_zl |= trigger_view.footer_action_buttons[i] == DM_BTN_ZL;
        has_zr |= trigger_view.footer_action_buttons[i] == DM_BTN_ZR;
    }
    assert(!has_zl && has_zr); // analog Move remains a gesture hint, not a button action

    // OBS38 is optional and passive: only the exact native list-widget type
    // is cached, and HUD/controller-off calls leave the cache untouched.
    uint8_t list_storage[0x500] = {0};
    uint8_t *list_widget = list_storage + 0x100;
    uintptr_t *list_vtable = (uintptr_t *)list_storage;
    uintptr_t list_update_marker = (uintptr_t)list_vtable;
    g_test_list_widget_vtable = (uintptr_t)list_vtable;
    g_test_list_widget_update = list_update_marker;
    g_test_list_widget_override = 1;
    list_vtable[BOTW_LIST_WIDGET_VTABLE_SLOT / sizeof(uintptr_t)] = list_update_marker;
    put_ptr(list_widget, g_test_list_widget_vtable);
    int32_t list_current = 3, list_wanted = 7;
    memcpy(list_widget + 0x30c, &list_current, sizeof list_current);
    memcpy(list_widget + 0x310, &list_wanted, sizeof list_wanted);
    mock_guest_start = (uintptr_t)list_storage;
    mock_guest_size = sizeof list_storage;
    memset(g_list_widget_observations, 0, sizeof g_list_widget_observations);
    memset(mock_gate_present, 0, sizeof mock_gate_present);
    memset(mock_gate_callbacks, 0, sizeof mock_gate_callbacks);
    memset(&g_mod[0], 0, sizeof g_mod[0]);
    strcpy(g_mod[0].name, "main");
    strcpy(g_mod[0].build_id, BOTW_BUILD);
    g_nmod = 1;
    mock_touch_hud_active = 0;
    atomic_store_explicit(&g_selector_hook_installed, 1, memory_order_release);
    uint64_t list_regs[32] = {0};
    list_regs[0] = (uintptr_t)list_widget;
    uint64_t saved_list_regs[32]; memcpy(saved_list_regs, list_regs, sizeof list_regs);
    selector_list_widget_observe(list_regs);
    assert(!g_list_widget_observations[0].widget);

    mock_touch_hud_active = 1;
    uintptr_t wrong_vtable[9] = {0};
    put_ptr(list_widget, (uintptr_t)wrong_vtable);
    selector_list_widget_observe(list_regs);
    assert(!g_list_widget_observations[0].widget);
    put_ptr(list_widget, g_test_list_widget_vtable);
    mock_guest_size = 0x200; // reject an object that does not cover the observed fields
    selector_list_widget_observe(list_regs);
    assert(!g_list_widget_observations[0].widget);
    mock_guest_size = sizeof list_storage;

    mock_gate_present[OBS_BOTW_TOUCH_PANE] = 1;
    mock_gate_present[OBS_BOTW_TOUCH_MATRIX] = 1;
    mock_gate_present[OBS_BOTW_MENU_SELECT] = 1;
    dm_botw_touch_menu_install();
    assert(mock_gate_callbacks[OBS_BOTW_MENU_SELECT] == dm_botw_touch_menu_selector);
    assert(!mock_gate_callbacks[OBS_BOTW_LIST_WIDGET_UPDATE]); // old rewrites remain supported
    mock_gate_present[OBS_BOTW_LIST_WIDGET_UPDATE] = 1;
    dm_botw_touch_menu_install();
    assert(mock_gate_callbacks[OBS_BOTW_LIST_WIDGET_UPDATE] == selector_list_widget_observe);
    assert(atomic_load_explicit(&g_selector_hook_installed, memory_order_acquire));
    assert(!strcmp(dm_main_build(), BOTW_BUILD));
    assert(!strcmp(DM_GAME_ID, "01007EF00011E000"));
    assert(selector_range((uintptr_t)list_widget, 0x314));
    assert(selector_read_ptr((uintptr_t)list_widget, 0) == g_test_list_widget_vtable);
    assert(selector_read_ptr(g_test_list_widget_vtable, BOTW_LIST_WIDGET_VTABLE_SLOT) ==
           g_test_list_widget_update);
    selector_list_widget_observe(list_regs);
    assert(!memcmp(saved_list_regs, list_regs, sizeof list_regs));
    assert(g_list_widget_observations[0].widget == (uintptr_t)list_widget &&
           g_list_widget_observations[0].current == 3 && g_list_widget_observations[0].wanted == 7);
    strcpy(g_mod[0].build_id, "wrong-build");
    list_current = 9; list_wanted = 10;
    memcpy(list_widget + 0x30c, &list_current, sizeof list_current);
    memcpy(list_widget + 0x310, &list_wanted, sizeof list_wanted);
    selector_list_widget_observe(list_regs);
    assert(g_list_widget_observations[0].current == 3 && g_list_widget_observations[0].wanted == 7);
    strcpy(g_mod[0].build_id, BOTW_BUILD);
    list_current = 4; list_wanted = 4;
    memcpy(list_widget + 0x30c, &list_current, sizeof list_current);
    memcpy(list_widget + 0x310, &list_wanted, sizeof list_wanted);
    selector_list_widget_observe(list_regs);
    assert(g_list_widget_observations[0].widget == (uintptr_t)list_widget &&
           g_list_widget_observations[0].current == 4 && g_list_widget_observations[0].wanted == 4);
    g_test_list_widget_override = 0;

    // Read-only list index/descriptor resolvers must round-trip the focused
    // cursor entry. A miss never calls the descriptor resolver; a descriptor
    // for another entry is rejected without changing guest memory.
    uint8_t query_storage[0x800] = {0}, query_before[0x800];
    uint8_t *query_widget = query_storage + 0x100;
    uint8_t *query_entry = query_storage + 0x500;
    uint8_t *query_descriptor = query_storage + 0x600;
    mock_guest_start = (uintptr_t)query_storage;
    mock_guest_size = sizeof query_storage;
    mock_list_query_widget = (uintptr_t)query_widget;
    mock_list_query_entry = (uintptr_t)query_entry;
    mock_list_query_descriptor = (uintptr_t)query_descriptor;
    mock_list_query_index = 5;
    mock_list_query_index_calls = mock_list_query_descriptor_calls = 0;
    put_ptr(query_descriptor + 0x28, mock_list_query_entry);
    memcpy(query_before, query_storage, sizeof query_storage);
    int32_t query_index = -1;
    uintptr_t query_result_descriptor = 0;
    int query_roundtrip = 0;
    assert(selector_list_widget_resolve_entry(mock_list_query_widget, mock_list_query_entry,
        (uintptr_t)mock_list_widget_index, (uintptr_t)mock_list_widget_descriptor,
        &query_index, &query_result_descriptor, &query_roundtrip));
    assert(query_index == 5 && query_result_descriptor == mock_list_query_descriptor && query_roundtrip);
    assert(mock_list_query_index_calls == 1 && mock_list_query_descriptor_calls == 1);
    assert(!memcmp(query_before, query_storage, sizeof query_storage));
    mock_list_query_index = -1;
    assert(selector_list_widget_resolve_entry(mock_list_query_widget, mock_list_query_entry,
        (uintptr_t)mock_list_widget_index, (uintptr_t)mock_list_widget_descriptor,
        &query_index, &query_result_descriptor, &query_roundtrip));
    assert(query_index == -1 && !query_result_descriptor && !query_roundtrip);
    assert(mock_list_query_descriptor_calls == 1);
    mock_list_query_index = 5;
    put_ptr(query_descriptor + 0x28, (uintptr_t)(query_entry + 8));
    memcpy(query_before, query_storage, sizeof query_storage);
    assert(selector_list_widget_resolve_entry(mock_list_query_widget, mock_list_query_entry,
        (uintptr_t)mock_list_widget_index, (uintptr_t)mock_list_widget_descriptor,
        &query_index, &query_result_descriptor, &query_roundtrip));
    assert(query_index == 5 && !query_roundtrip);
    assert(!memcmp(query_before, query_storage, sizeof query_storage));
    mock_guest_start = (uintptr_t)list_storage;
    mock_guest_size = sizeof list_storage;

    assert(selector_list_widget_vtable_rva_allowed(0x1cdb958));
    assert(selector_list_widget_vtable_rva_allowed(0x1cdbb58));
    assert(selector_list_widget_vtable_rva_allowed(0x1cfcf78));
    assert(!selector_list_widget_vtable_rva_allowed(0x1cdbb38)); // ctor-associated table, not either live receiver address
    assert(!selector_list_widget_vtable_rva_allowed(0x1cdb960));

    // Unknown receiver classes are logged once, up to the fixed eight-class
    // budget; a ninth class and repeated sightings are dropped quietly.
    uint8_t trace_storage[0x2000] = {0};
    mock_guest_start = (uintptr_t)trace_storage;
    mock_guest_size = sizeof trace_storage;
    atomic_store_explicit(&g_trace, 1, memory_order_release);
    pthread_mutex_lock(&g_list_widget_trace_mu);
    memset(g_list_widget_trace_classes, 0, sizeof g_list_widget_trace_classes);
    g_list_widget_trace_class_count = 0;
    pthread_mutex_unlock(&g_list_widget_trace_mu);
    uint8_t *trace_widget = trace_storage + 0x100;
    for (unsigned i = 0; i < 8; i++) {
        uintptr_t trace_vtable = (uintptr_t)(trace_storage + 0x800 + i * 0x80);
        put_ptr(trace_widget, trace_vtable);
        assert(selector_trace_list_widget_receiver((uintptr_t)trace_widget));
    }
    assert(g_list_widget_trace_class_count == 8);
    uintptr_t ninth_vtable = (uintptr_t)(trace_storage + 0xc00);
    put_ptr(trace_widget, ninth_vtable);
    assert(!selector_trace_list_widget_receiver((uintptr_t)trace_widget));
    assert(!selector_trace_list_widget_receiver((uintptr_t)trace_widget));
    assert(g_list_widget_trace_class_count == 8);
    put_ptr(trace_widget, (uintptr_t)(trace_storage + 0x800));
    assert(!selector_trace_list_widget_receiver((uintptr_t)trace_widget));
    atomic_store_explicit(&g_trace, 0, memory_order_release);
    mock_guest_start = saved_guest_start;
    mock_guest_size = saved_guest_size;
    test_quest_category_touch();
    test_option_arrow_touch();
    test_message_advance_owner();
    test_menu_animation_visibility();
    test_inline_holding_prompts();
    test_inventory_category_touch_cells();
    test_cursorless_help_prompts();
    test_inventory_preview_rotation();
    test_map_displacement_drag();
    puts("t_botw_touch_menu: native inventory/category/popup and current-screen generic targets, eligibility, delayed focus and inactive gates passed");
    return 0;
}
