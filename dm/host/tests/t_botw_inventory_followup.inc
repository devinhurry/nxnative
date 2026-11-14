static int32_t follow_value(size_t offset) {
    int32_t value; memcpy(&value,selector.screen+offset,4); return value;
}
static void follow_fixture(void) {
    inventory_swipe_fixture();
    int32_t count=7; memcpy(selector.screen+BOTW_INVENTORY_PAGE_COUNT,&count,4);
    for(int i=0;i<7;i++) memcpy(selector.screen+0x3690+i*0x80+0x78,&i,4);
    g_test_category_call_order_count=0;
}
static void test_inventory_menu_followup(void) {
    const float x=.45f,y=.24f;
    for(int direction=-1;direction<=1;direction+=2) for(int fast=0;fast<2;fast++) {
        follow_fixture();
        dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,x,y);
        dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,x+direction*20.f/1280,y);
        assert(!g_target_valid && !get_ptr(selector.manager+0x50));
        g_test_menu_time_ns+=fast?20000000:200000000;
        dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,x+direction*44.f/1280,y);
        assert(g_pointer_down && g_target_valid && g_target_index==-2);
        // END can arrive before the next native input sample: it must keep
        // the recognized page command, without snapping the page backwards.
        dm_botw_touch_menu_pointer(DM_BOTW_MENU_END,x+direction*44.f/1280,y);
        int32_t axes[4]={0}; uint64_t buttons=0;
        assert(sample_axes(10,axes,&buttons) && axes[2]==-direction*DM_STICK_MAX && !buttons);
        memset(axes,0,sizeof axes); sample_axes(11,axes,&buttons);
        assert(!axes[2] && !buttons && !g_test_equip_count);
        assert(!get_ptr(selector.manager+0x50));
    }
    follow_fixture();
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,x,y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,x-44.f/1280,y);
    int32_t axes[4]={0}; uint64_t buttons=0;
    assert(sample_axes(10,axes,&buttons) && axes[2]==DM_STICK_MAX);
    sample_axes(11,axes,&buttons);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,x-.25f,y);
    assert(!g_target_valid); // one native animation per gesture
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END,x-.25f,y);
    assert(!g_target_valid && !g_pointer_down && !g_test_equip_count);
    follow_fixture();
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,x,y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,-.2f,y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END,-.2f,y);
    memset(axes,0,sizeof axes);buttons=0;
    assert(sample_axes(10,axes,&buttons) && axes[2]==DM_STICK_MAX && !buttons);
    follow_fixture();
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN,x,y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_MOVE,x-.1f,y);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL,x-.1f,y);
    assert(!sample(10) && !g_target_valid && !g_test_equip_count);
    // Retained focus must still be checked against the actual current slot.
    follow_fixture();
    put_ptr(selector.owner+0x60,(uintptr_t)drag_panes[0]);
    put_ptr(selector.owner2+0x60,(uintptr_t)drag_panes[2]);
    int32_t item_id=49; memcpy(selector.owner2+0x44,&item_id,4);
    put_ptr(selector.manager+0x50,(uintptr_t)selector.entry2);
    g_test_category_focus_count=0;
    selector_refresh_category_item((uintptr_t)selector.manager,(uintptr_t)selector.screen,
        (uintptr_t)g_mod[0].base+BOTW_INVENTORY_FOCUS);
    assert(!g_test_category_focus_count);
    put_ptr(selector.manager+0x50,0);
    selector_refresh_category_item((uintptr_t)selector.manager,(uintptr_t)selector.screen,
        (uintptr_t)g_mod[0].base+BOTW_INVENTORY_FOCUS);
    assert(g_test_category_focus_count==1);
    follow_fixture();
    uint8_t *root = fake_pane(70, "RootPane", -1, 1280, 720, 0, 0);
    fake_pane(71, "N_Slide_01", 70, 1280, 720, 0, 0);
    fake_pane(72, "N_Cat_01", 71, 1280, 720, 0, 0);
    for (int i = 0; i < 2; i++) {
        fake_pane(73 + i * 3, i ? "Pa_CategoryS_06" : "Pa_CategoryS_05", 72, 40, 40, 0, 0);
        fake_pane(74 + i * 3, "N_Invalid_00", 73 + i * 3, 40, 40, 0, 0);
        uint8_t *hit = fake_pane(75 + i * 3, "B_Hit_00", 74 + i * 3, 32, 32, 0, 0);
        view.category_ids[i] = 5 + i;
        view.category_panes[i] = (uintptr_t)hit;
        set_rect(view.categories[i], .4f + i * .1f, .1f, .08f, .06f);
    }
    view.category_count = 2;
    view.inventory_root = (uintptr_t)root;
    for (int i = 0; i < 3; i++) put_ptr(drag_panes[i] + PANE_PARENT, (uintptr_t)root);
    publish(10);
    put_ptr(selector.owner + 0x60, view.category_panes[0]);
    int32_t transition = 1;
    memcpy(selector.screen + BOTW_INVENTORY_TRANSITION, &transition, 4);
    tap(.44f, .13f); selector_tick();
    assert(follow_value(BOTW_INVENTORY_PAGE) == 5 && follow_value(0x3a10) == 5);
    assert(!g_target_valid && !follow_value(BOTW_INVENTORY_TRANSITION));
    // Native rendering can publish the rotated page between the next DOWN
    // and END, then again before Npad/selector; the same header stays live.
    put_ptr(selector.owner + 0x60, view.category_panes[1]);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_BEGIN, .54f, .13f);
    view.page_key++; publish(10);
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_END, .54f, .13f);
    view.page_key++; publish(10);
    assert(!sample(10));
    selector_tick();
    assert(follow_value(BOTW_INVENTORY_PAGE) == 6 && follow_value(0x3a10) == 6);
    assert(!g_target_valid && !g_test_equip_count && !sample(10));
    g_test_menu_time_ns = 0;
    dm_botw_touch_menu_reset();
}
