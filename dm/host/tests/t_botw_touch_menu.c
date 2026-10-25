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
static int mock_entry_eligible(uintptr_t entry, int group);

module_t g_mod[MAX_MOD];
int g_nmod;
static uint64_t current_guest_frame;
static int mock_touch_hud_active = 1;
static uintptr_t mock_guest_start;
static size_t mock_guest_size;
static uintptr_t selector_test_vtable[8];
static uint8_t selector_test_guest_entry[0x80];

int gate_obs_present(int id) { (void)id; return 0; }
void gate_obs_set(int id, void (*fn)(const uint64_t *regs)) { (void)id; (void)fn; }
int dm_guest_as_contains(uintptr_t address) {
    return mock_guest_size && address >= mock_guest_start && address - mock_guest_start < mock_guest_size;
}
void front_botw_touch_menu_changed(void) {}
uint64_t dm_nvn_frame_count(void) { return 0; }
uint64_t dm_guest_frame(void) { return current_guest_frame; }
int dm_botw_touch_hud_active(void) { return mock_touch_hud_active; }

static dm_botw_touch_menu_view view;
typedef struct { _Alignas(16) uint8_t bytes[0x100]; } fake_pane_t;
static fake_pane_t native_panes[60];

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
    uint8_t active[1], screen[0x3b20], state[0x80];
    uint8_t entry[0x40], entry2[0x40], owner[0x100], owner2[0x100], pane[0x100];
    uintptr_t screen_list[1];
} selector_fixture_t;
static selector_fixture_t selector;
static uint8_t fake_main_base;
static unsigned mock_eligibility_calls;
static int mock_eligibility_allowed = 1;
static int mock_eligibility_group = -1;

static int mock_native_group(uintptr_t object) { (void)object; return 2; }
static int mock_native_shown(uintptr_t screen) {
    const uint8_t *bytes = (const uint8_t *)screen;
    return (int8_t)bytes[0xfd] >= 0 && bytes[0xfe] == 2;
}
static int mock_entry_eligible(uintptr_t entry, int group) {
    (void)entry;
    mock_eligibility_calls++;
    mock_eligibility_group = group;
    return mock_eligibility_allowed;
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
    put_ptr(selector.manager, (uintptr_t)(g_mod[0].base + 0x1d0cdf8));
    put_ptr(selector.manager + 0x20, (uintptr_t)selector.control);
    put_ptr(selector.control + 0x80, (uintptr_t)selector.model);
    put_ptr(selector.model + 0x28, (uintptr_t)selector.registry);
    uint32_t count = 1; memcpy(selector.registry + 0x28, &count, sizeof count);
    selector.screen_list[0] = (uintptr_t)selector.screen;
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

int main(void) {
    test_selector_pointer_ranges();
    const float back_text[4] = {.40f, .48f, .12f, .04f};
    const float back_icon[4] = {.46f, .46f, .04f, .08f};
    float back_hit[4];
    dm_botw_touch_menu_test_back_rect(back_text, back_icon, -INFINITY, INFINITY, back_hit);
    assert(fabsf(back_hit[0] - .40f) < 1e-6f && fabsf(back_hit[2] - .12f) < 1e-6f);
    dm_botw_touch_menu_test_back_rect(back_text, back_icon, .35f, .62f, back_hit);
    assert(fabsf(back_hit[0] - .415f) < 1e-6f && fabsf(back_hit[2] - .105f) < 1e-6f);

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
    dm_botw_touch_menu_view generic_view;
    (void)menu_root; (void)row_one; (void)hit_wrapper; (void)row_two; (void)background_root; (void)background_row;
    // The visible System row shares PauseMenu's screen class with inventory,
    // but the native inventory clip is absent. It must use generic targets.
    put_ptr(selector.screen, (uintptr_t)(g_mod[0].base + 0x1cf9ad8));
    selector.screen[0xfd] = 0; selector.screen[0xfe] = 2;
    selector.state[0x38] = 2;
    put_ptr(selector.control + 0x80, (uintptr_t)selector.model);
    uintptr_t group_vtable[8] = {0};
    put_ptr((uint8_t *)group_vtable + 0x28, (uintptr_t)mock_entry_eligible);
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
    generic_hit_observe(hit_one, 1);
    generic_hit_observe(hit_one, 0); // clean-pane pre-phase must retain the last global matrix
    generic_hit_observe(hit_two, 1);
    generic_hit_observe(background_hit, 1);
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
    assert(generic_view.generic_count == 2);
    assert(generic_view.back_valid); // only live, labeled native B prompt is inherited
    assert(generic_view.generic_targets[0].pane == (uintptr_t)hit_one);
    assert(generic_view.generic_targets[1].pane == (uintptr_t)hit_two);
    assert(mock_eligibility_calls >= 2 && mock_eligibility_group == 2);
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
    assert(sample(62) == DM_BTN_A); // native eligibility tick may precede HID by one frame
    assert(sample(63) == 0);

    current_guest_frame = 64;
    dm_botw_touch_menu_test_set_render_frame(64);
    g_native_view.frame = 64;
    g_native_view.guide_icon_seen[0] = g_native_view.guide_text_seen[0] = 64;
    generic_hit_observe(hit_one, 1); generic_hit_observe(hit_two, 1);
    selector_tick();
    dm_botw_touch_menu_test_snapshot(&generic_view);
    tap(generic_view.back[0] + generic_view.back[2] * .5f,
        generic_view.back[1] + generic_view.back[3] * .5f);
    assert(sample(64) == DM_BTN_B); // current modal closes through native B dispatch

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
    g_native_view.header_icon_valid[1] = 0; // observed ZR sits under alpha-zero N_Disable_00
    g_native_view.header_text_valid[1] = 1;
    g_native_view.header_text_seen[1] = 65;
    g_native_view.header_icon_seen[1] = 65;
    g_native_view.header_icon_glyph[1] = 0xe045;
    set_rect(g_native_view.header_icons[1], .65f, .8f, .05f, .05f);
    set_rect(g_native_view.header_texts[1], .7f, .8f, .1f, .05f);
    g_native_view.frame = 65;
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
    generic_view.render_frame = 65;
    uintptr_t request_before_header = get_ptr(selector.manager + 0x50);
    view = generic_view;
    publish(65);
    tap(.45f, .85f);
    assert(sample(65) == 0); // release the preceding B pulse first
    assert(sample(66) == DM_BTN_L);
    assert(sample(67) == 0);
    assert(get_ptr(selector.manager + 0x50) == request_before_header);

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
    selector_tick(); assert(get_ptr(selector.manager + 0x50) == 0);
    puts("t_botw_touch_menu: native inventory/category/popup and current-screen generic targets, eligibility, delayed focus and inactive gates passed");
    return 0;
}
