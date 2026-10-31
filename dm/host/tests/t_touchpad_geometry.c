#include "../touchpad_geometry.h"
#include "../botw_stick_settings.h"
#include "../botw_touch_layout.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static void nearf(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

static void test_layout(float width, float height, float expected_u) {
    float u = dm_touchpad_u(height);
    nearf(u, expected_u, 0.0001f);

    dm_touchpad_point face = dm_touchpad_face_center(width, height, 0, 0, 0, 0);
    dm_touchpad_point stick = dm_touchpad_stick_home(width, height, 0, 0, 0, 0);
    dm_touchpad_point dpad = dm_touchpad_dpad_center(width, height, 0, 0, 0, 0);
    nearf(face.x, width - DM_TP_FACE_X * u, 0.001f);
    nearf(face.y, height - DM_TP_PAD_Y * u, 0.001f);
    nearf(stick.x, DM_TP_STICK_X * u, 0.001f);
    nearf(stick.y, height - DM_TP_PAD_Y * u, 0.001f);
    nearf(dpad.x, DM_TP_LOW_X * u, 0.001f);
    nearf(dpad.y, height - DM_TP_LOW_Y * u, 0.001f);

    dm_touchpad_point a = dm_touchpad_face_button(width, height, 0, 0, 0, 0, 0);
    dm_touchpad_point b = dm_touchpad_face_button(width, height, 0, 0, 0, 0, 1);
    dm_touchpad_point x = dm_touchpad_face_button(width, height, 0, 0, 0, 0, 2);
    dm_touchpad_point y = dm_touchpad_face_button(width, height, 0, 0, 0, 0, 3);
    float gap = DM_TP_FACE_GAP * u;
    nearf(a.x - face.x, gap, 0.001f); nearf(a.y, face.y, 0.001f);
    nearf(b.y - face.y, gap, 0.001f); nearf(b.x, face.x, 0.001f);
    nearf(x.y - face.y, -gap, 0.001f); nearf(x.x, face.x, 0.001f);
    nearf(y.x - face.x, -gap, 0.001f); nearf(y.y, face.y, 0.001f);
}

static void test_directional_ownership(void) {
    const float cx = 400, cy = 300, gap = 50, radius = 33.75f;
    assert(dm_touchpad_face_buttons(cx + gap, cy, cx, cy, gap, radius) & DM_BTN_A);
    assert(dm_touchpad_face_buttons(cx, cy + gap, cx, cy, gap, radius) & DM_BTN_B);
    assert(dm_touchpad_face_buttons(cx, cy - gap, cx, cy, gap, radius) & DM_BTN_X);
    assert(dm_touchpad_face_buttons(cx - gap, cy, cx, cy, gap, radius) & DM_BTN_Y);

    const float r = 48;
    assert(dm_touchpad_dpad_buttons(cx + r, cy, cx, cy, r) == DM_BTN_RIGHT);
    assert(dm_touchpad_dpad_buttons(cx, cy - r, cx, cy, r) == DM_BTN_UP);
    assert(dm_touchpad_dpad_buttons(cx - r, cy, cx, cy, r) == DM_BTN_LEFT);
    assert(dm_touchpad_dpad_buttons(cx, cy + r, cx, cy, r) == DM_BTN_DOWN);
    assert(dm_touchpad_dpad_buttons(cx + r, cy - r, cx, cy, r) == (DM_BTN_RIGHT | DM_BTN_UP));
    assert(dm_touchpad_dpad_buttons(cx, cy, cx, cy, r) == 0); // native centre dead region
}

static void test_stick_shaping(void) {
    const float r = 77;
    int32_t x, y;
    dm_touchpad_stick_axis(r * 0.05f, 0, r, 0, &x, &y);
    assert(x == 0 && y == 0); // dead zone

    dm_touchpad_stick_axis(r * 0.45f, 0, r, 0, &x, &y);
    assert(x >= 16383 && x <= 16384 && y == 0); // half of full travel after dead-zone remap

    dm_touchpad_stick_axis(0, -r, r, 0, &x, &y);
    assert(x == 0 && y == DM_STICK_MAX);
    dm_touchpad_stick_axis(-r, 0, r, 0, &x, &y);
    assert(x == -DM_STICK_MAX && y == 0);

    dm_touchpad_stick_axis(r * 0.1f, 0, r, 1, &x, &y);
    assert(x == DM_STICK_MAX && y == 0); // legacy full-tilt right-stick mode

    const float heights[] = {390, 430, 431, 540, 1080};
    for (unsigned i=0;i<sizeof heights/sizeof *heights;i++) {
        float radius=dm_touchpad_botw_stick_radius(heights[i]);
        nearf(radius,heights[i]>430 ? 70 : 77*heights[i]/430,.001f);
        dm_touchpad_stick_axis_with_deadzone(radius*.06f,0,radius,0,DM_TP_BOTW_STICK_DEAD,&x,&y);
        assert(!x && !y);
        dm_touchpad_stick_axis_with_deadzone(radius*.08f,0,radius,0,DM_TP_BOTW_STICK_DEAD,&x,&y);
        assert(x>0 && !y); // BOTW starts before the ordinary pad's ten-percent deadzone
        dm_touchpad_stick_axis_with_deadzone(radius*.8f,0,radius,0,DM_TP_BOTW_STICK_DEAD,&x,&y);
        assert(x == DM_STICK_MAX && !y);
        dm_touchpad_stick_axis(radius*.08f,0,radius,0,&x,&y);
        assert(!x && !y); // shared default stays unchanged
        dm_touchpad_botw_move_axis(radius*.06f,0,radius,&x,&y);
        assert(!x && !y);
        dm_touchpad_botw_move_axis(radius*.2f,0,radius,&x,&y);
        assert(x > DM_STICK_MAX*.619f && x < DM_STICK_MAX*.621f && !y);
        dm_touchpad_botw_move_axis(radius*.4f,0,radius,&x,&y);
        assert(x > DM_STICK_MAX*.819f && x < DM_STICK_MAX*.821f && !y);
        dm_touchpad_botw_move_axis(radius*.8f,0,radius,&x,&y);
        assert(x == DM_STICK_MAX && !y);
        dm_touchpad_botw_move_axis(radius*1.3f,0,radius,&x,&y);
        assert(x == DM_STICK_MAX && !y); // outside the ring remains ordinary full movement
        dm_touchpad_botw_move_axis(-radius*.12f,-radius*.16f,radius,&x,&y);
        assert(x < 0 && y > 0);
        nearf(-(float)x/y,.75f,.0003f); // radial shaping preserves direction
    }
}

static void test_safe_insets_and_resize(void) {
    dm_touchpad_rect safe = dm_touchpad_safe_rect(844, 390, 42, 0, 42, 21);
    nearf(safe.x, 42, 0.001f); nearf(safe.y, 0, 0.001f);
    nearf(safe.width, 760, 0.001f); nearf(safe.height, 369, 0.001f);

    dm_touchpad_rect corner = dm_touchpad_corner_rect(844, 390, 42, 0, 42, 21);
    nearf(corner.x, 21, 0.001f); nearf(corner.width, 802, 0.001f);
    nearf(corner.height, 369, 0.001f);
    dm_touchpad_point face = dm_touchpad_face_center(844, 390, 42, 0, 42, 21);
    dm_touchpad_point stick = dm_touchpad_stick_home(844, 390, 42, 0, 42, 21);
    float u = 390.0f / 430.0f;
    nearf(face.x, 21 + 802 - DM_TP_FACE_X * u, 0.001f);
    nearf(stick.x, 21 + DM_TP_STICK_X * u, 0.001f);

    // 16:9 and 21:10 both cap control size at 1.3; a short resized window scales down.
    test_layout(1920, 1080, 1.3f);
    test_layout(1680, 800, 1.3f);
    test_layout(1280, 430, 1.0f);
}

static void test_botw_right_cluster_and_camera_tap(void) {
    for (int i = 0; i < 2; i++) {
        float w = i ? 1920.0f : 844.0f, h = i ? 1080.0f : 390.0f;
        float u = dm_touchpad_u(h);
        dm_touchpad_point face = dm_touchpad_face_center(w,h,0,0,0,0);
        dm_touchpad_point r = dm_touchpad_right_shoulder(w,h,0,0,0,0,0);
        dm_touchpad_point zr = dm_touchpad_right_shoulder(w,h,0,0,0,0,1);
        dm_touchpad_point x = dm_touchpad_face_button(w,h,0,0,0,0,2);
        nearf(r.y,zr.y,0.001f);
        nearf(r.x-zr.x,(DM_TP_ZL_R*2+DM_TP_SHOULDER_GAP)*u,0.001f);
        assert(r.y + DM_TP_ZL_R*u < x.y - DM_TP_FACE_R*u);
        assert(r.x + DM_TP_ZL_R*u < w);
        float xgr = DM_TP_FACE_R * u * 1.25f;
        float shoulder_hit = DM_TP_ZL_R * u * DM_TP_SHOULDER_HIT_SCALE;
        assert(hypotf(r.x-x.x,r.y-x.y) > shoulder_hit+xgr);
        assert(hypotf(zr.x-x.x,zr.y-x.y) > shoulder_hit+xgr);
        assert(face.y > 0);

        float slop = DM_TP_LOOK_TAP_SLOP*u;
        assert(!dm_touchpad_look_dragged(400,200,400+slop*.5f,200,slop));
        assert(dm_touchpad_look_dragged(400,200,400+slop*1.1f,200,slop));
        // A drag that returns to its start is still classified as a drag by the caller's sticky flag.
        int dragged = dm_touchpad_look_dragged(400,200,400+slop*1.1f,200,slop);
        assert(dragged);
        assert(dm_touchpad_look_tap(.2f,0));
        assert(!dm_touchpad_look_tap(.36f,0));
        assert(!dm_touchpad_look_tap(.1f,1));
        assert(dm_touchpad_look_double_tap(10000000.08,10000000.28,100,100,101,102,u));
        assert(!dm_touchpad_look_double_tap(10000000.08,10000000.48,100,100,101,102,u));
        assert(!dm_touchpad_look_double_tap(10000000.08,10000000.28,100,100,100+49*u,102,u));
        assert(dm_touchpad_stick_double_tap_gap(.19));
        assert(dm_touchpad_stick_double_tap_gap(.20));
        assert(!dm_touchpad_stick_double_tap_gap(.21));
        assert(!dm_touchpad_stick_double_tap_gap(-.01));
        dragged |= dm_touchpad_look_dragged(400,200,400,200,slop);
        assert(dragged);
    }
}

static void test_botw_new_touch_geometry(void) {
    for (int i = 0; i < 2; i++) {
        float w = i ? 1680.0f : 844.0f, h = i ? 800.0f : 390.0f;
        float u = dm_touchpad_u(h);
        dm_touchpad_point stick = dm_touchpad_stick_home(w,h,42,0,42,21);
        dm_touchpad_point moved_stick = dm_touchpad_botw_stick_home(w,h,42,0,42,21);
        nearf(moved_stick.x,stick.x+10,.001f); nearf(moved_stick.y,stick.y-10,.001f);
        dm_touchpad_point shield = dm_touchpad_shield_stick_home(w,h,42,0,42,21);
        dm_touchpad_point rune = dm_touchpad_rune_button(w,h,42,0,42,21);
        float rune_dist = hypotf(rune.x-stick.x, rune.y-stick.y);
        nearf(shield.x, stick.x, 0.001f);
        assert(shield.y < rune.y && rune.y < stick.y);
        assert(rune_dist >= (DM_TP_STICK_R*DM_TP_STICK_GRAB + DM_TP_L_R*1.45f + DM_TP_SHIELD_GAP)*u - 0.01f);
        assert(hypotf(rune.x-shield.x, rune.y-shield.y) > (DM_TP_STICK_R+DM_TP_L_R)*u);
        assert(!dm_touchpad_cancel_outside(60,50,50,50,DM_TP_CANCEL_RADIUS));
        assert(dm_touchpad_cancel_outside(50+DM_TP_CANCEL_RADIUS+1,50,50,50,DM_TP_CANCEL_RADIUS));
        float canvas_width = h * 16.0f / 9.0f;
        dm_touchpad_rect plus = dm_touchpad_botw_menu_rect(40,20,canvas_width,h,0);
        dm_touchpad_rect minus = dm_touchpad_botw_menu_rect(40,20,canvas_width,h,1);
        nearf(plus.width,39*h/720,.01f); nearf(plus.height,plus.width,.01f);
        float glyphRight=plus.x+plus.width*.5f+DM_TP_BOTW_MENU_GLYPH_SIZE*h/1440;
        nearf(40+canvas_width-glyphRight,58*h/720+2,.01f);
        float mapRight=40+canvas_width-dm_touchpad_botw_map_right_inset(720/h)*h/720;
        nearf(plus.x-mapRight,8,.01f);
        nearf(plus.y,20+20*h/720+4,.01f); // four frontend points below the minimap top
        nearf(minus.x,plus.x,.001f); nearf(minus.y-plus.y-plus.height,8,.001f);
        assert(dm_touchpad_rounded_rect_contains(plus,plus.width*.5f,plus.x+plus.width*.5f,plus.y+plus.height*.5f));
        assert(!dm_touchpad_rounded_rect_contains(plus,plus.width*.5f,plus.x,plus.y));
    }
}

static void test_configurable_stick(void) {
    const char *keys[] = {"DM_BOTW_MOVE_DEADZONE", "DM_BOTW_MOVE_CURVE", "DM_BOTW_MOVE_FULL", "DM_BOTW_MOVE_SIZE"};
    for (int i=0;i<4;i++) unsetenv(keys[i]);
    dm_touchpad_stick_response response;
    assert(!dm_botw_stick_settings_read(&response));
    nearf(response.deadzone,.07f,1e-6f); nearf(response.curve,.3f,1e-6f);
    nearf(response.full,.71f,1e-6f); nearf(response.size,.8f,1e-6f);
    setenv(keys[0],"0.15",1); setenv(keys[1],"1.00",1);
    setenv(keys[2],"0.60",1); setenv(keys[3],"1.25",1);
    assert(!dm_botw_stick_settings_read(&response));
    float radius=70*response.size;
    int32_t x,y;
    dm_touchpad_stick_axis_with_response(radius*.15f,0,radius,response,&x,&y);
    assert(!x && !y);
    dm_touchpad_stick_axis_with_response(radius*.375f,0,radius,response,&x,&y);
    nearf(x,DM_STICK_MAX*.5f,1); assert(!y);
    dm_touchpad_stick_axis_with_response(radius*.6f,0,radius,response,&x,&y);
    assert(x==DM_STICK_MAX && !y);
    dm_touchpad_stick_axis_with_response(-radius*.3f,radius*.4f,radius,response,&x,&y);
    assert(x<0 && y<0); nearf((float)x/y,.75f,.001f);
    for (int i=0;i<4;i++) unsetenv(keys[i]);
    const char *bad[] = {"nan","inf","-inf","invalid","","1.0junk"};
    for (int i=0;i<4;i++) for (unsigned j=0;j<sizeof bad/sizeof *bad;j++) {
        setenv(keys[i],bad[j],1);
        assert(!strcmp(dm_botw_stick_settings_read(&response),keys[i]));
        unsetenv(keys[i]);
    }
    const char *low[] = {"-0.01","0.29","0.34","0.59"}, *high[] = {"0.31","2.01","1.01","1.51"};
    for (int i=0;i<4;i++) {
        setenv(keys[i],low[i],1); assert(!strcmp(dm_botw_stick_settings_read(&response),keys[i]));
        setenv(keys[i],high[i],1); assert(!strcmp(dm_botw_stick_settings_read(&response),keys[i]));
        unsetenv(keys[i]);
    }
    for (int dead=0;dead<2;dead++) for (int curve=0;curve<2;curve++) for (int full=0;full<2;full++) {
        response=(dm_touchpad_stick_response){dead?.3f:0,curve?2:.3f,full?1:.35f,1};
        int32_t previous=0;
        for (int i=0;i<=200;i++) {
            dm_touchpad_stick_axis_with_response(i,0,100,response,&x,&y);
            assert(x>=previous && x<=DM_STICK_MAX && !y); previous=x;
        }
        assert(previous==DM_STICK_MAX);
    }
}

static void test_custom_layout(void) {
    dm_botw_touch_layout layout; assert(dm_botw_layout_read(&layout));
    assert(!layout.badges);
    nearf(layout.face_gap,1.06f,.0001f);
    nearf(layout.control[0].x,-.006f,.0001f); nearf(layout.control[0].y,-.068f,.0001f); nearf(layout.control[0].scale,1.1f,.0001f);
    nearf(layout.control[4].x,0,.0001f); nearf(layout.control[4].y,.023f,.0001f);
    nearf(layout.control[6].x,.021f,.0001f); nearf(layout.control[6].y,0,.0001f); nearf(layout.control[6].scale,1.2f,.0001f);
    nearf(layout.control[7].x,.025f,.0001f); nearf(layout.control[7].y,-.097f,.0001f); nearf(layout.control[7].scale,1.1f,.0001f);
    nearf(layout.control[9].x,-.022f,.0001f); nearf(layout.control[9].y,-.098f,.0001f); nearf(layout.control[9].scale,1.1f,.0001f);
    nearf(layout.control[12].x,.042f,.0001f); nearf(layout.control[12].y,0,.0001f); nearf(layout.control[12].scale,1,.0001f);
    nearf(layout.control[8].x,0,.0001f); nearf(layout.control[8].y,0,.0001f); nearf(layout.control[8].scale,1,.0001f);
    setenv("DM_BOTW_PAD_BADGES","1",1); assert(dm_botw_layout_read(&layout) && layout.badges);
    setenv("DM_BOTW_PAD_BADGES","0.5",1); assert(!dm_botw_layout_read(&layout));
    unsetenv("DM_BOTW_PAD_BADGES"); assert(dm_botw_layout_read(&layout) && !layout.badges);
    dm_touchpad_rect canvas=dm_botw_layout_canvas(932,430);
    dm_touchpad_rect r=dm_botw_layout_control(&layout,7,932,430,0,0,0,0,canvas);
    dm_touchpad_rect zr=dm_botw_layout_control(&layout,9,932,430,0,0,0,0,canvas);
    nearf(r.width,zr.width,.001f);
    assert(zr.x < r.x); // the frequently used bow trigger occupies the inward position

    dm_touchpad_rect before=dm_botw_layout_control(&layout,0,932,430,0,0,0,0,canvas);
    setenv("DM_BOTW_PAD_FACE_X","-0.1",1); setenv("DM_BOTW_PAD_FACE_SCALE","0.8",1);
    setenv("DM_BOTW_PAD_FACE_GAP","1.2",1); setenv("DM_BOTW_PAD_R_Y","0.1",1);
    assert(dm_botw_layout_read(&layout));
    dm_touchpad_rect after=dm_botw_layout_control(&layout,0,932,430,0,0,0,0,canvas);
    nearf(after.x+after.width/2,before.x+before.width/2-canvas.width*.094f,.001f);
    nearf(after.width,2*(27+50*1.2f)*.8f,.001f);
    dm_touchpad_rect shoulder=dm_botw_layout_control(&layout,7,932,430,0,0,0,0,canvas);
    dm_touchpad_point native=dm_touchpad_right_shoulder(932,430,0,0,0,0,0);
    nearf(shoulder.x+shoulder.width/2,native.x+canvas.width*.025f,.001f);
    nearf(shoulder.y+shoulder.height/2,native.y+43,.001f);
    setenv("DM_BOTW_PAD_FACE_SCALE","nan",1); assert(!dm_botw_layout_read(&layout));
    const char *keys[]={"DM_BOTW_PAD_FACE_X","DM_BOTW_PAD_FACE_SCALE","DM_BOTW_PAD_FACE_GAP","DM_BOTW_PAD_R_Y"};
    for(unsigned i=0;i<sizeof keys/sizeof *keys;i++) unsetenv(keys[i]);
    assert(dm_botw_layout_read(&layout));
}

static void test_portrait_layout(void) {
    dm_botw_touch_layout layout=dm_botw_layout_defaults_for(1), landscape=dm_botw_layout_defaults();
    const float sizes[][2]={{320,568},{390,844},{430,932},{768,1024}};
    const int controls[]={0,4,6,7,8,9,12};
    for (unsigned s=0;s<sizeof sizes/sizeof *sizes;s++) {
        float w=sizes[s][0], h=sizes[s][1];
        dm_touchpad_rect canvas=dm_botw_layout_canvas(w,h), r[16]={{0}};
        for (unsigned i=0;i<sizeof controls/sizeof *controls;i++) {
            int b=controls[i]; r[b]=dm_botw_layout_control(&layout,b,w,h,0,59,0,34,canvas);
            assert(r[b].x>=0 && r[b].y>=59 && r[b].x+r[b].width<=w && r[b].y+r[b].height<=h-34);
        }
        nearf(r[12].x+r[12].width*.5f,r[6].x+r[6].width*.5f,.001f);
        nearf(r[6].x+r[6].width*.5f,r[8].x+r[8].width*.5f,.001f);
        assert(r[12].y<r[6].y && r[6].y<r[8].y && r[8].y<r[4].y);
        float dx=r[4].x+r[4].width*.5f-r[8].x-r[8].width*.5f;
        float dy=r[4].y+r[4].height*.5f-r[8].y-r[8].height*.5f;
        assert(hypotf(dx,dy) >= dm_botw_layout_stick_radius(&layout,w,h)*DM_TP_STICK_GRAB*1.8f);
        float u=dm_botw_layout_unit(&layout,w,h), cx=r[0].x+r[0].width*.5f, cy=r[0].y+r[0].height*.5f;
        dm_touchpad_point p[4];
        for (int b=0;b<4;b++) {
            p[b]=dm_botw_layout_face_offset(&layout,b,u);
            assert(dm_botw_layout_face_buttons(&layout,cx+p[b].x,cy+p[b].y,cx,cy,u)==(1ull<<b));
        }
        assert(p[1].x<p[0].x && p[1].y>p[0].y && p[3].x<p[2].x && p[3].y>p[2].y);
        assert(p[2].y<p[0].y && p[3].y<p[1].y);
        assert(r[9].x<r[7].x && r[9].y>r[7].y && r[9].y+r[9].height<cy+p[3].y);
    }
    // Orientation permission does not stop a system-resized narrow window
    // from selecting the compact control bank.
    setenv("DM_BOTW_PORTRAIT","0",1); assert(dm_botw_compact_mode(390,844,0,0));
    setenv("DM_BOTW_PORTRAIT","1",1);
    const float modes[][5]={{390,844,0,0,1},{599.9f,1000,0,0,1},{600,1000,0,0,0},
        {600.1f,1000,0,0,0},{626,890,0,0,0},{744,1133,0,0,0},
        {620,1000,10,10,0},{620,1000,10,11,1},{600,599,20,20,0},{590,590,0,0,0}};
    for (unsigned i=0;i<sizeof modes/sizeof *modes;i++)
        assert(dm_botw_compact_mode(modes[i][0],modes[i][1],modes[i][2],modes[i][3])==(int)modes[i][4]);
    setenv("DM_BOTW_PORTRAIT_PAD_FACE_X","0.15",1);
    assert(dm_botw_layout_read_for(&layout,1) && dm_botw_layout_read(&landscape));
    nearf(layout.control[0].x,.15f,.0001f); nearf(landscape.control[0].x,-.006f,.0001f);
    setenv("DM_BOTW_PORTRAIT_MOVE_DEADZONE","0.2",1);
    dm_touchpad_stick_response a,b;
    assert(!dm_botw_stick_settings_read_for(&a,1) && !dm_botw_stick_settings_read(&b));
    nearf(a.deadzone,.2f,.0001f); nearf(b.deadzone,.07f,.0001f);
    unsetenv("DM_BOTW_PORTRAIT_MOVE_DEADZONE"); unsetenv("DM_BOTW_PORTRAIT_PAD_FACE_X"); unsetenv("DM_BOTW_PORTRAIT");
}

static void test_fold_regions(void) {
    dm_touchpad_rect area={0,0,795,1100},picture,controls;
    assert(!dm_touchpad_seated_split(area,(dm_touchpad_rect){392,0,11,1100},&picture,&controls));
    assert(!memcmp(&picture,&area,sizeof area) && !memcmp(&controls,&area,sizeof area));
    assert(dm_touchpad_seated_split(area,(dm_touchpad_rect){0,540.25f,795,19.5f},&picture,&controls));
    nearf(picture.height,540.25f,.001f); nearf(controls.y,559.75f,.001f); nearf(controls.height,540.25f,.001f);
    assert(dm_touchpad_seated_split(area,(dm_touchpad_rect){0,550,795,0},&picture,&controls));
    assert(!dm_touchpad_seated_split(area,(dm_touchpad_rect){0,0,795,10},&picture,&controls));
    assert(!dm_touchpad_seated_split(area,(dm_touchpad_rect){0,NAN,795,10},&picture,&controls));
    dm_touchpad_rect map=dm_touchpad_seated_map(controls),plus=dm_touchpad_seated_menu(controls,0),minus=dm_touchpad_seated_menu(controls,1);
    assert(map.y>=controls.y && map.y+map.height<=controls.y+controls.height);
    assert(plus.x>map.x+map.width && minus.x==plus.x && minus.y>plus.y);
    nearf(map.width,166.f*430/720,.001f);
}
int main(void) {
    test_fold_regions();
    test_configurable_stick();
    test_custom_layout();
    test_portrait_layout();
    test_directional_ownership();
    test_stick_shaping();
    test_safe_insets_and_resize();
    test_botw_right_cluster_and_camera_tap();
    test_botw_new_touch_geometry();
    puts("touchpad geometry: direction ownership, layout, and BOTW control geometry passed");
    return 0;
}
