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
        dragged |= dm_touchpad_look_dragged(400,200,400,200,slop);
        assert(dragged);
    }
}

int main(void) {
    test_directional_ownership();
    test_stick_shaping();
    test_safe_insets_and_resize();
    test_botw_right_cluster_and_camera_tap();
    puts("touchpad geometry: direction ownership, layout, and stick shaping passed");
    return 0;
}
