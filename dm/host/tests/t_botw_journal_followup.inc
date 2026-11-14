static void test_journal_menu_followup(void) {
    uint64_t saved_guest_frame = current_guest_frame;
    uint64_t saved_render_frame = atomic_load(&g_test_render_frame);
    int saved_generic_selector = atomic_load(&g_test_generic_selector);
    dm_botw_touch_menu_reset(); init_selector_fixture();
    uintptr_t saved_guest_start = mock_guest_start; size_t saved_guest_size = mock_guest_size;
    mock_guest_start = (uintptr_t)native_panes; mock_guest_size = sizeof native_panes;
    current_guest_frame = 11000; dm_botw_touch_menu_test_set_render_frame(11000);
    uintptr_t entry_vtable[8] = {0}; entry_vtable[5] = (uintptr_t)mock_entry_eligible;
    put_ptr(selector.entry, (uintptr_t)entry_vtable);
    put_ptr(selector.entry + 8, (uintptr_t)(selector.screen + 0x88));
    mock_eligibility_allowed = 1;
    uint8_t *root = fake_pane(100, "RootPane", -1, 1280, 720, 0, 0);
    uint8_t *quest = fake_pane(101, "Pa_Quest_00", 100, 1280, 720, 0, 0);
    uint8_t *part = fake_pane(102, "Pa_QuestName_00", 101, 350, 50, -260, 0);
    uint8_t *hit = fake_pane(103, "B_Hit_00", 102, 350, 50, -260, 0);
    link_child(root, quest); link_child(quest, part); link_child(part, hit);
    put_ptr(selector.owner + 0x60, (uintptr_t)hit);
    uint8_t widget[0x400] = {0}, config[0x398] = {0}, descriptor[0x50] = {0};
    uintptr_t widget_vtable[8] = {0}, array[1] = {(uintptr_t)config};
    widget_vtable[BOTW_LIST_WIDGET_VTABLE_SLOT / 8] = (uintptr_t)mock_category_set;
    put_ptr(widget, (uintptr_t)widget_vtable); put_ptr(widget + 0x60, (uintptr_t)selector.screen);
    put_ptr(widget + 0x290, (uintptr_t)array); put_ptr(config + 8, (uintptr_t)widget);
    strcpy((char *)config + 0x3c, "Pa_Quest_00/Pa_Category_00");
    int32_t one = 1; memcpy(widget + 0x288, &one, 4); memcpy(widget + 0xc0, &one, 4);
    float upper = 300; memcpy(widget + 0x2bc, &upper, 4);
    put_ptr(descriptor + 0x28, (uintptr_t)selector.entry);
    g_test_list_widget_override = 1; g_test_list_widget_vtable = (uintptr_t)widget_vtable;
    g_test_list_widget_update = (uintptr_t)mock_category_set;
    g_test_list_widget_index_resolver = (uintptr_t)mock_list_widget_index;
    g_test_list_widget_descriptor_resolver = (uintptr_t)mock_list_widget_descriptor;
    mock_list_query_widget = (uintptr_t)widget; mock_list_query_entry = (uintptr_t)selector.entry;
    mock_list_query_descriptor = (uintptr_t)descriptor; mock_list_query_index = 0;
    memset(g_list_widget_observations, 0, sizeof g_list_widget_observations);
    g_list_widget_observations[0] = (botw_list_widget_observation_t){(uintptr_t)widget, 11000, 0, 0};
    dm_botw_touch_menu_view view = {0}; view.generic_mode = 1;
    view.generic_screen = (uintptr_t)selector.screen; view.generic_root = (uintptr_t)root;
    view.page_key = view.generic_key = 800; view.render_frame = 11000; view.generic_count = 1;
    view.generic_targets[0] = (dm_botw_touch_menu_target){.entry=(uintptr_t)selector.entry,
        .owner_pane=(uintptr_t)hit, .pane=(uintptr_t)hit, .root=(uintptr_t)root};
    set_rect(view.generic_targets[0].rect, .15f, .3f, .35f, .3f);
    dm_botw_touch_menu_test_publish(&view);
    g_test_list_category_setter=(uintptr_t)mock_category_set;
    int32_t pages=3,page=0;
    memcpy(config+0x2f4,&pages,4);memcpy(widget+0x2f0,&page,4);
    mock_category_calls=0;
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,.3f,.5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,.3f,.48f);
    assert(!g_target_valid); // below the page threshold, no focus at DOWN
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,.3f,.43f);
    assert(g_pointer_down && g_target_valid && g_target_index==-4 && g_target_axis==1);
    uint64_t serial=atomic_load(&g_target_serial);
    assert(selector_quest_list_scroll((uintptr_t)selector.screen,(uintptr_t)selector.entry,
        (uintptr_t)hit,1,11000,serial));
    assert(mock_category_calls==1 && mock_category_page==1 && !g_target_valid);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,.3f,.25f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END,.3f,.25f);
    assert(mock_category_calls==1 && !g_target_valid && !sample(11000));
    assert(!get_ptr(selector.manager+0x50)); // never select the starting row
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,.3f,.5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,.3f,.43f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL,.3f,.43f);
    assert(!g_target_valid && !g_journal_drag.tracking);
    // Empty content still owns category swipes through its native clip. The
    // first MOVE changes category once; further moves and END never tap a row.
    uint8_t category_widget[0x400] = {0}, categories[4][0x398] = {{0}};
    uintptr_t category_array[4]; uint32_t four = 4;
    memcpy(category_widget + 0x288, &four, 4); memcpy(category_widget + 0x2a8, &four, 4);
    put_ptr(category_widget + 0x290, (uintptr_t)category_array);
    for (int i = 0; i < 4; i++) {
        category_array[i] = (uintptr_t)categories[i];
        put_ptr(categories[i] + 8, (uintptr_t)category_widget);
        snprintf((char *)categories[i] + 0x19c, 64, "Pa_Quest_00/Pa_ChallengeCategory_%02d", i);
        memcpy(categories[i] + 0x2f0, &i, 4); memcpy(categories[i] + 0x2f4, &one, 4);
        view.category_ids[i] = i; view.category_panes[i] = (uintptr_t)hit + i;
        set_rect(view.categories[i], .2f + .06f * i, .2f, .04f, .05f);
    }
    view.category_count = 4; view.list_category_widget = (uintptr_t)category_widget;
    view.generic_count = 0;
    uint8_t *cut = fake_pane(105, "N_Cut_00", 101, 520, 480, -260, -30);
    link_child(quest, cut);
    dm_botw_touch_menu_test_publish(&view);
    g_test_list_category_setter = (uintptr_t)mock_category_set;
    mock_category_calls = 0;
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .3f, .5f);
    assert(g_journal_drag.tracking);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .25f, .5f);
    assert(g_target_valid && g_target_category == 2 && g_target_index == 1);
    assert(selector_apply_list_category((uintptr_t)selector.screen, 11000));
    assert(mock_category_calls == 1 && mock_category_id == 1);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .2f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .2f, .5f);
    assert(!g_target_valid && !g_journal_drag.tracking && !sample(11000));
    int32_t selected_category = 3; memcpy(category_widget + 0x2e8, &selected_category, 4);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .3f, .5f);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE, .35f, .5f);
    assert(g_target_valid && g_target_category == 2 && g_target_index == 2);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, .35f, .5f);
    // A top/header tap outside the native content clip is never captured.
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .3f, .1f);
    assert(!g_journal_drag.tracking);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, .3f, .1f);
    // Native memory popup buttons can park their hit cursor offscreen and
    // retain both label copies; the visible button surface stays clickable.
    dm_botw_touch_menu_reset(); init_selector_fixture();
    current_guest_frame = 11000; dm_botw_touch_menu_test_set_render_frame(11000);
    root = fake_pane(100, "RootPane", -1, 1280, 720, 0, 0);
    uint8_t *popup = fake_pane(101, "N_TypeBtn_00", 100, 1280, 720, 0, 0);
    part = fake_pane(102, "Pa_BtnL_00", 101, 230, 54, 0, 0);
    hit = fake_pane(103, "B_Hit_00", 102, 20, 20, 991, 0);
    uint8_t *window = fake_pane(104, "W_Base_01", 102, 230, 54, 0, 0);
    link_child(root, popup); link_child(popup, part); link_child(part, hit); link_child(part, window);
    uintptr_t surface = 0; float rect[4];
    assert(selector_button_surface((uintptr_t)part, &surface, rect) && surface == (uintptr_t)window);
    assert(rect[2] > .17f && point_in_rect(.57f, .5f, rect));
    window[0x58] = 0;
    assert(!selector_button_surface((uintptr_t)part, &surface, rect));
    window[0x58] = 1; strcpy((char *)window + PANE_NAME, "W_Base_03");
    strcpy((char *)part + PANE_NAME, "Pa_Btn_00");
    assert(selector_button_surface((uintptr_t)part, &surface, rect));
    // Exercise publication and native acknowledgement with two cached label
    // copies. Touch the padding beyond the labels, using the window's full hit.
    uint8_t *label = fake_pane(105, "T_Btn_00", 102, 100, 28, 0, 0);
    uint8_t *other_label = fake_pane(106, "T_Btn_01", 102, 100, 28, 0, 0);
    link_child(part, label); link_child(part, other_label);
    put_ptr(selector.owner + 0x60, (uintptr_t)hit);
    put_ptr(selector.entry, (uintptr_t)entry_vtable);
    put_ptr(selector.entry + 8, (uintptr_t)(selector.screen + 0x88));
    put_ptr(selector.manager + 0x48, (uintptr_t)selector.entry);
    selector.screen[0xfe] = 2; strcpy((char *)selector.screen + 0x200, "SystemWindow_00");
    uint8_t mask[0x20] = {0}; mask[0x14] = 1u << 2;
    put_ptr(selector.registry + 0xb18, (uintptr_t)mask);
    dm_botw_touch_menu_test_set_generic_selector(1, (uintptr_t)mock_native_group,
        (uintptr_t)mock_native_shown);
    generic_hit_observe(hit, 1); generic_text_observe(label, 1); generic_text_observe(other_label, 1);
    selector_tick(); dm_botw_touch_menu_test_snapshot(&view);
    assert(view.generic_count == 1 && view.generic_targets[0].pane == (uintptr_t)window);
    tap(.57f, .5f); selector_tick(); assert(sample(11000) == DM_BTN_A);
    sample(11001);
    window[0x58] = 0; selector_tick(); dm_botw_touch_menu_test_snapshot(&view);
    assert(view.generic_count == 0);
    g_test_list_widget_override = 0;
    g_test_list_category_setter = 0;
    g_test_list_widget_index_resolver = g_test_list_widget_descriptor_resolver = 0;
    dm_botw_touch_menu_reset();
    mock_guest_start = saved_guest_start; mock_guest_size = saved_guest_size;
    current_guest_frame = saved_guest_frame;
    dm_botw_touch_menu_test_set_render_frame(saved_render_frame);
    atomic_store(&g_test_generic_selector, saved_generic_selector);
}
