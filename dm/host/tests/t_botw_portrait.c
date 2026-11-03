// Rotation permission shares the control layout's 600pt window-width boundary.
#include "../botw_touch_layout.h"
#include <assert.h>

static void test_explicit_anchors(void) {
    const float panes[][2]={{932,430},{390,844},{744,1133},{1800,1200}};
    for (int compact=0;compact<2;compact++) {
        dm_botw_touch_layout layout=dm_botw_layout_defaults_for(compact);
        layout.control[6]=(dm_botw_control_transform){.x=20,.y=35,.size=60,.anchor=DM_BOTW_ANCHOR_RIGHT};
        layout.control[0]=(dm_botw_control_transform){.x=30,.y=45,.size=70,.anchor=DM_BOTW_ANCHOR_LEFT};
        for (unsigned p=0;p<sizeof panes/sizeof *panes;p++) {
            float w=panes[p][0],h=panes[p][1];
            dm_touchpad_rect canvas=dm_botw_layout_canvas(w,h);
            for (int safe=0;safe<2;safe++) {
                dm_touchpad_rect l=dm_botw_layout_control(&layout,6,w,h,59*safe,24*safe,59*safe,34*safe,canvas);
                dm_touchpad_rect a=dm_botw_layout_control(&layout,0,w,h,59*safe,24*safe,59*safe,34*safe,canvas);
                assert(fabsf(w-l.x-l.width-20)<.001f && fabsf(h-l.y-l.height-35)<.001f);
                assert(fabsf(a.x-30)<.001f && fabsf(h-a.y-a.height-45)<.001f);
            }
        }
        layout.control[6].x=1800; layout.control[6].y=1500;
        layout.control[0].x=1800; layout.control[0].y=1500;
        dm_touchpad_rect canvas=dm_botw_layout_canvas(320,240);
        dm_touchpad_rect l=dm_botw_layout_control(&layout,6,320,240,0,0,0,0,canvas);
        dm_touchpad_rect a=dm_botw_layout_control(&layout,0,320,240,0,0,0,0,canvas);
        assert(l.x==0 && l.y==0 && l.width==60);
        assert(a.x==250 && a.y==0 && a.width==70);
    }
    setenv("DM_BOTW_PAD_L_ANCHOR","2",1);
    setenv("DM_BOTW_PAD_L_X_PT","1800",1);
    setenv("DM_BOTW_PAD_L_Y_PT","1500",1);
    dm_botw_touch_layout layout;
    assert(dm_botw_layout_read_for(&layout,0) && layout.control[6].anchor==DM_BOTW_ANCHOR_RIGHT);
    assert(layout.control[6].x==1800 && layout.control[6].y==1500);
    assert(dm_botw_layout_read_for(&layout,1) && layout.control[6].anchor==DM_BOTW_ANCHOR_DEFAULT);
    const char *bad_anchors[]={"3","1.5","nan"};
    for (unsigned i=0;i<sizeof bad_anchors/sizeof *bad_anchors;i++) {
        setenv("DM_BOTW_PAD_L_ANCHOR",bad_anchors[i],1);
        assert(!dm_botw_layout_read_for(&layout,0));
    }
    setenv("DM_BOTW_PAD_L_ANCHOR","1",1);
    setenv("DM_BOTW_PAD_L_X_PT","-1",1); assert(!dm_botw_layout_read_for(&layout,0));
    setenv("DM_BOTW_PAD_L_X_PT","0",1);
    setenv("DM_BOTW_PAD_L_Y_PT","-1",1); assert(!dm_botw_layout_read_for(&layout,0));
    setenv("DM_BOTW_PAD_L_ANCHOR","0",1); assert(dm_botw_layout_read_for(&layout,0));
    setenv("DM_BOTW_PAD_L_Y_PT","10001",1); assert(!dm_botw_layout_read_for(&layout,0));
    unsetenv("DM_BOTW_PAD_L_ANCHOR"); unsetenv("DM_BOTW_PAD_L_X_PT"); unsetenv("DM_BOTW_PAD_L_Y_PT");
}

int main(void) {
    test_explicit_anchors();
    const float cases[][5]={
        {390,844,0,0,0}, {844,390,59,34,0}, {599.9f,1000,0,0,0},
        {600,1000,0,0,1}, {1000,600,20,20,1}, {620,1000,10,10,1},
        {620,1000,10,11,1}, {744,1133,0,0,1}, {1133,744,0,0,1},
        {768,1024,0,0,1}, {1024,768,0,0,1}, {590,590,0,0,1}
    };
    for (int enabled=0;enabled<2;enabled++) {
        setenv("DM_BOTW_PORTRAIT",enabled ? "1" : "0",1);
        for (unsigned i=0;i<sizeof cases/sizeof *cases;i++) {
            const float *c=cases[i];
            assert(dm_botw_portrait_allowed(c[0],c[1],c[2],c[3])==(enabled || c[4]));
            if (c[1]>=c[0]) assert(dm_botw_compact_mode(c[0],c[1],c[2],c[3])==!c[4]);
        }
    }
    unsetenv("DM_BOTW_PORTRAIT");
    assert(!dm_botw_portrait_allowed(390,844,0,0));
    assert(dm_botw_portrait_allowed(768,1024,0,0));
    assert(!dm_botw_portrait_allowed(0,0,0,0));
    dm_botw_touch_layout layout;
    assert(dm_botw_layout_read_for(&layout,0));
    assert(dm_botw_layout_control_visible(&layout,12) && !dm_botw_layout_control_visible(&layout,16));
    for (int compact=0;compact<2;compact++) {
        const char *icon=compact ? "DM_BOTW_PORTRAIT_PAD_L_ICON_MODE" : "DM_BOTW_PAD_L_ICON_MODE";
        dm_botw_touch_layout saved;
        assert(dm_botw_layout_read_for(&saved,compact) && saved.rune_icon_mode==0);
        setenv(icon,"1",1); assert(dm_botw_layout_read_for(&saved,compact) && saved.rune_icon_mode==1);
        setenv(icon,"2",1); assert(!dm_botw_layout_read_for(&saved,compact)); unsetenv(icon);
        dm_botw_touch_layout editor=dm_botw_layout_defaults_for(compact);
        uint64_t directions=DM_BTN_LEFT|DM_BTN_UP|DM_BTN_RIGHT|DM_BTN_DOWN;
        assert(dm_botw_layout_dpad_mask(&editor,0)==directions);
        assert(dm_botw_layout_dpad_mask(&editor,1)==directions);
        editor.dpad_visible=0;
        assert(!dm_botw_layout_dpad_mask(&editor,0));
        assert(dm_botw_layout_dpad_mask(&editor,1)==(DM_BTN_UP|DM_BTN_DOWN));
        assert(dm_botw_layout_control_visible(&editor,DM_BOTW_CANCEL));
        editor.cancel_enabled=0;
        assert(!dm_botw_layout_control_visible(&editor,DM_BOTW_CANCEL));
        editor.trigger_drag[0]=1;
        assert(!dm_botw_layout_control_visible(&editor,DM_BOTW_CANCEL));
        editor.trigger_drag[0]=0; editor.trigger_drag[1]=1;
        assert(!dm_botw_layout_control_visible(&editor,DM_BOTW_CANCEL));
        editor.cancel_enabled=1;
        assert(dm_botw_layout_control_visible(&editor,DM_BOTW_CANCEL));
    }
    setenv("DM_BOTW_PAD_WEAPON_ENABLED","1",1); setenv("DM_BOTW_PAD_WEAPON_MODE","2",1);
    setenv("DM_BOTW_PAD_CANCEL_ENABLED","0",1);
    setenv("DM_BOTW_PAD_DPAD_VISIBLE","0",1);
    assert(dm_botw_layout_read_for(&layout,0) && layout.switch_mode[0]==2);
    assert(!dm_botw_layout_control_visible(&layout,12) && dm_botw_layout_control_visible(&layout,16) && !dm_botw_layout_control_visible(&layout,20));
    assert(dm_botw_layout_read_for(&layout,1) && !layout.added[0] && layout.dpad_visible);
    assert(dm_botw_layout_control_visible(&layout,20));
    setenv("DM_BOTW_PAD_WEAPON_MODE","1.5",1); assert(!dm_botw_layout_read_for(&layout,0));
    puts("BOTW portrait rotation and cross-screen edge anchors passed");
    return 0;
}
