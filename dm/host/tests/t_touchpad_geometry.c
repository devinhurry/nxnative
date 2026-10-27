#include "../touchpad_geometry.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

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
        nearf(zr.x-r.x,(DM_TP_ZL_R*2+DM_TP_SHOULDER_GAP)*u,0.001f);
        assert(r.y + DM_TP_ZL_R*u < x.y - DM_TP_FACE_R*u);
        assert(zr.x + DM_TP_ZL_R*u < w);
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
        float stick_r = DM_TP_STICK_R * u;
        assert(!dm_touchpad_sprint_requested(stick_r * 1.19f, stick_r));
        assert(!dm_touchpad_sprint_requested(stick_r * 1.2f, stick_r));
        assert(dm_touchpad_sprint_requested(stick_r * 1.21f, stick_r));
        assert(!dm_touchpad_sprint_requested(stick_r * 1.21f, 0.0f));
        assert(!dm_touchpad_cancel_outside(60,50,50,50,DM_TP_CANCEL_RADIUS));
        assert(dm_touchpad_cancel_outside(50+DM_TP_CANCEL_RADIUS+1,50,50,50,DM_TP_CANCEL_RADIUS));
        float canvas_width = h * 16.0f / 9.0f;
        dm_touchpad_rect plus = dm_touchpad_botw_menu_rect(40,20,canvas_width,h,0);
        dm_touchpad_rect minus = dm_touchpad_botw_menu_rect(40,20,canvas_width,h,1);
        nearf(plus.width,39*h/720,.01f); nearf(plus.height,plus.width,.01f);
        nearf(plus.x-(40+1196*canvas_width/1280),8,.01f);
        nearf(plus.y,20+20*h/720+4,.01f); // four frontend points below the minimap top
        nearf(minus.x,plus.x,.001f); nearf(minus.y-plus.y-plus.height,8,.001f);
        assert(dm_touchpad_rounded_rect_contains(plus,plus.width*.5f,plus.x+plus.width*.5f,plus.y+plus.height*.5f));
        assert(!dm_touchpad_rounded_rect_contains(plus,plus.width*.5f,plus.x,plus.y));
    }
}

int main(void) {
    test_directional_ownership();
    test_stick_shaping();
    test_safe_insets_and_resize();
    test_botw_right_cluster_and_camera_tap();
    test_botw_new_touch_geometry();
    puts("touchpad geometry: direction ownership, layout, and BOTW control geometry passed");
    return 0;
}
