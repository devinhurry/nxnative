#include "../botw_touch_trackpad.h"
#include <stdio.h>

static int checks, failures;
#define CHECK(c, message) do { checks++; if (!(c)) { failures++; printf("FAIL: %s\n", message); } } while (0)

int main(void) {
    dm_botw_trackpad_scroll g = {0};
    dm_botw_trackpad_scroll_begin(&g, 100, 120);
    dm_botw_trackpad_scroll_move(&g, 9, -11, 1000, 600);
    dm_botw_trackpad_scroll_move(&g, 30, -30, 1000, 600);
    float x = -1, y = -1;
    CHECK(dm_botw_trackpad_scroll_end(&g, &x, &y), "active precise scroll can end");
    CHECK(x == 139 && y == 79, "scroll deltas accumulate from the began point");
    CHECK(!g.active && !dm_botw_trackpad_scroll_end(&g, &x, &y), "zero-delta ended event preserves endpoint and ends only once");

    dm_botw_trackpad_scroll_begin(&g, 20, 20);
    dm_botw_trackpad_scroll_move(&g, 8, 0, 100, 100);
    dm_botw_trackpad_scroll_cancel(&g);
    CHECK(!g.active && !dm_botw_trackpad_scroll_end(&g, &x, &y), "cancelled scroll cannot become an ended swipe");

    dm_botw_trackpad_scroll_discrete(640, 360, 0, 1, 1280, 720, 1280, 720, &x, &y);
    CHECK(x == 640 && y == 312 && fabsf(y - 360) >= 40, "one discrete wheel notch emits a native-threshold vertical swipe");
    dm_botw_trackpad_scroll_discrete(640, 360, -1, 0, 1280, 720, 1280, 720, &x, &y);
    CHECK(x == 592 && y == 360 && fabsf(x - 640) >= 40, "horizontal wheel notch emits a native-threshold swipe");

    CHECK(dm_botw_trackpad_magnify_allowed(1, 1, 1, 0, 1), "active touch-mode map owner accepts magnification");
    CHECK(!dm_botw_trackpad_magnify_allowed(0, 1, 1, 0, 1), "non-BOTW/controller mode ignores magnification");
    CHECK(!dm_botw_trackpad_magnify_allowed(1, 0, 1, 0, 1), "gameplay mode ignores magnification");
    CHECK(!dm_botw_trackpad_magnify_allowed(1, 1, 0, 0, 1), "stale native menu ignores magnification");
    CHECK(!dm_botw_trackpad_magnify_allowed(1, 1, 1, 1, 1), "mouse-owned pointer blocks magnification");
    CHECK(!dm_botw_trackpad_magnify_allowed(1, 1, 1, 0, 0), "footer and outside-map starts cannot magnify");

    dm_botw_camera_gesture camera = {0};
    dm_botw_camera_gesture_begin(&camera, 50, 50, 100);
    float ratio = 1, pose_x = 0, pose_y = 0;
    int kind = dm_botw_camera_gesture_update(&camera, 70, 30, 100,
                                              2, &ratio, &pose_x, &pose_y);
    CHECK(kind == DM_BOTW_CAMERA_GESTURE_POSE && fabsf(pose_x - .707107f) < .0001f &&
          fabsf(pose_y - .707107f) < .0001f && fabsf(pose_x * 32767) > 16384 &&
          fabsf(pose_y * 32767) > 16384, "parallel translation sends native-threshold unit pose");
    kind = dm_botw_camera_gesture_update(&camera, 70, 30, 180,
                                          2, &ratio, &pose_x, &pose_y);
    CHECK(kind == DM_BOTW_CAMERA_GESTURE_POSE, "camera gesture stays locked to pose after threshold");
    dm_botw_camera_gesture_end(&camera);
    CHECK(!camera.active, "camera pose cancellation ends the gesture");

    dm_botw_camera_gesture_begin(&camera, 50, 50, 100);
    ratio = 1; pose_x = pose_y = 0;
    kind = dm_botw_camera_gesture_update(&camera, 60, 50, 120,
                                          1, &ratio, &pose_x, &pose_y);
    CHECK(kind == DM_BOTW_CAMERA_GESTURE_NONE && pose_x == 0 && pose_y == 0,
          "one finger's leading sample in a parallel drag does not lock as zoom");
    kind = dm_botw_camera_gesture_update(&camera, 70, 50, 100,
                                          1, &ratio, &pose_x, &pose_y);
    CHECK(kind == DM_BOTW_CAMERA_GESTURE_POSE,
          "the matching second-finger sample locks the same gesture to pose");

    dm_botw_camera_gesture_begin(&camera, 50, 50, 100);
    kind = dm_botw_camera_gesture_update(&camera, 70, 50, 100,
                                          1, &ratio, &pose_x, &pose_y);
    CHECK(kind == DM_BOTW_CAMERA_GESTURE_POSE && fabsf(pose_x * 32767) > 16384 && pose_y == 0,
          "a 20-point two-finger drag clears neutral and crosses native LS direction threshold");

    dm_botw_camera_gesture_begin(&camera, 50, 50, 100);
    kind = dm_botw_camera_gesture_update(&camera, 55, 50, 120,
                                         2, &ratio, &pose_x, &pose_y);
    CHECK(kind == DM_BOTW_CAMERA_GESTURE_ZOOM && fabsf(ratio - 1.2f) < .0001f,
          "distance change selects pinch zoom without pose");
    dm_botw_trackpad_pose pose = {0};
    dm_botw_trackpad_pose_begin(&pose);
    dm_botw_trackpad_pose_drag(&pose, 7, 0);
    CHECK(pose.active && pose.x == 0 && pose.y == 0, "pose motion below threshold stays neutral");
    dm_botw_trackpad_pose_drag(&pose, 20, 0);
    CHECK(fabsf(pose.x * 32767) > 16384 && pose.y == 0,
          "20-point Option-drag emits a native left-stick direction");
    CHECK(dm_botw_trackpad_pose_end(&pose) && !pose.active && pose.x == 0 && pose.y == 0 &&
          !dm_botw_trackpad_pose_end(&pose), "pose end and cancellation both release to neutral");

    dm_botw_trackpad_pose_begin(&pose);
    dm_botw_trackpad_pose_scroll(&pose, 20, 0);
    CHECK(fabsf(pose.x * 32767) > 16384, "20-point Shift-scroll emits a native left-stick direction");

    printf("%s: %d/%d\n", failures ? "FAILED" : "all passed", checks - failures, checks);
    return failures != 0;
}
