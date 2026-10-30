// Small, platform-neutral reducers for BOTW touch-mode camera gestures.
#pragma once
#include <math.h>

enum { DM_BOTW_CAMERA_GESTURE_NONE, DM_BOTW_CAMERA_GESTURE_ZOOM, DM_BOTW_CAMERA_GESTURE_POSE };

typedef struct {
    int active, kind, zoom_samples;
    float x, y, distance;
} dm_botw_camera_gesture;

typedef struct {
    int active;
    float x, y;
    float dx, dy;
} dm_botw_trackpad_pose;

// Link's pose commands are stick directions. Full radial output makes a short
// two-finger motion cross the native directional threshold (0x4000).
static inline void dm_botw_camera_pose_direction(float dx, float dy, float *x, float *y) {
    float magnitude = hypotf(dx, dy);
    if (!isfinite(magnitude) || magnitude < 8.0f) { *x = *y = 0; return; }
    *x = dx / magnitude;
    *y = -dy / magnitude;
}

static inline void dm_botw_trackpad_pose_begin(dm_botw_trackpad_pose *g) {
    g->active = 1; g->x = g->y = g->dx = g->dy = 0;
}

static inline void dm_botw_trackpad_pose_drag(dm_botw_trackpad_pose *g, float dx, float dy) {
    if (g->active) dm_botw_camera_pose_direction(dx, dy, &g->x, &g->y);
}

static inline void dm_botw_trackpad_pose_scroll(dm_botw_trackpad_pose *g, float dx, float dy) {
    if (g->active) {
        g->dx += dx; g->dy += dy;
        dm_botw_camera_pose_direction(g->dx, g->dy, &g->x, &g->y);
    }
}

static inline int dm_botw_trackpad_pose_end(dm_botw_trackpad_pose *g) {
    int was_active = g->active;
    g->active = 0; g->x = g->y = g->dx = g->dy = 0;
    return was_active;
}

static inline void dm_botw_camera_gesture_begin(dm_botw_camera_gesture *g, float x, float y,
                                                 float distance) {
    g->active = 1; g->kind = DM_BOTW_CAMERA_GESTURE_NONE; g->zoom_samples = 0;
    g->x = x; g->y = y; g->distance = fmaxf(distance, 1.0f);
}

// Lock once the pair moves enough; midpoint translation selects pose, span
// change selects zoom. One gesture can never drive both native controls.
static inline int dm_botw_camera_gesture_update(dm_botw_camera_gesture *g, float x, float y,
                                                 float distance, int changed_fingers, float *zoom_ratio,
                                                 float *pose_x, float *pose_y) {
    if (!g->active) return DM_BOTW_CAMERA_GESTURE_NONE;
    float dx = x - g->x, dy = y - g->y;
    float translation = hypotf(dx, dy), spread = fabsf(distance - g->distance);
    if (g->kind == DM_BOTW_CAMERA_GESTURE_NONE && translation >= 8.0f &&
        translation > spread * 1.25f) g->kind = DM_BOTW_CAMERA_GESTURE_POSE;
    else if (g->kind == DM_BOTW_CAMERA_GESTURE_NONE && spread >= 8.0f &&
             spread > translation * 1.25f) {
        if (changed_fingers > 1 || ++g->zoom_samples >= 2) g->kind = DM_BOTW_CAMERA_GESTURE_ZOOM;
    } else if (g->kind == DM_BOTW_CAMERA_GESTURE_NONE) g->zoom_samples = 0;
    if (g->kind == DM_BOTW_CAMERA_GESTURE_POSE)
        dm_botw_camera_pose_direction(dx, dy, pose_x, pose_y);
    else if (g->kind == DM_BOTW_CAMERA_GESTURE_ZOOM)
        *zoom_ratio = fmaxf(distance, 1.0f) / g->distance;
    return g->kind;
}

static inline void dm_botw_camera_gesture_end(dm_botw_camera_gesture *g) {
    g->active = 0; g->kind = DM_BOTW_CAMERA_GESTURE_NONE; g->zoom_samples = 0;
}

typedef struct {
    int active;
    float x, y;
} dm_botw_trackpad_scroll;

static inline void dm_botw_trackpad_scroll_begin(dm_botw_trackpad_scroll *g, float x, float y) {
    g->active = 1; g->x = x; g->y = y;
}

static inline void dm_botw_trackpad_scroll_move(dm_botw_trackpad_scroll *g, float dx, float dy,
                                                 float width, float height) {
    if (!g->active) return;
    g->x = fminf(fmaxf(g->x + dx, 0), width);
    g->y = fminf(fmaxf(g->y + dy, 0), height);
}

static inline int dm_botw_trackpad_scroll_end(dm_botw_trackpad_scroll *g, float *x, float *y) {
    if (!g->active) return 0;
    *x = g->x; *y = g->y; g->active = 0;
    return 1;
}

static inline void dm_botw_trackpad_scroll_cancel(dm_botw_trackpad_scroll *g) { g->active = 0; }

// A precise scroll delta is in view points. A discrete wheel notch is expanded to
// 48 logical-canvas pixels so it crosses the native menu's 40-pixel swipe threshold.
static inline void dm_botw_trackpad_scroll_discrete(float x, float y, float dx, float dy,
                                                     float rect_width, float rect_height,
                                                     float view_width, float view_height,
                                                     float *out_x, float *out_y) {
    *out_x = x; *out_y = y;
    if (fabsf(dx) >= fabsf(dy) && dx != 0 && rect_width > 0)
        *out_x = fminf(fmaxf(x + copysignf(48.0f * rect_width / 1280.0f, dx), 0), view_width);
    else if (dy != 0 && rect_height > 0)
        *out_y = fminf(fmaxf(y - copysignf(48.0f * rect_height / 720.0f, dy), 0), view_height);
}

static inline int dm_botw_trackpad_magnify_allowed(int botw_touch_mode, int menu_mode,
                                                    int native_menu_active, int pointer_busy,
                                                    int live_map_pointer) {
    return botw_touch_mode && menu_mode && native_menu_active && !pointer_busy && live_map_pointer;
}
