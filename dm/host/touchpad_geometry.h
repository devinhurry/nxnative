// Shared virtual-pad geometry for the UIKit controls and the opt-in Mac preview.
#pragma once
#include <math.h>

typedef struct { float x, y; } dm_touchpad_point;
typedef struct { float x, y, width, height; } dm_touchpad_rect;

#include "dm_input.h"

#define DM_TP_ZL_X 44.0f
#define DM_TP_ZL_Y 40.0f
#define DM_TP_ZL_R 26.0f
#define DM_TP_L_X 44.0f
#define DM_TP_L_Y 108.0f
#define DM_TP_L_R 24.0f
#define DM_TP_DROP_TIP 1.45f
#define DM_TP_CORNER_IN 0.5f
#define DM_TP_FACE_X 81.0f
#define DM_TP_PAD_Y 82.0f
#define DM_TP_FACE_GAP 50.0f
#define DM_TP_FACE_R 27.0f
#define DM_TP_PILL_DX 52.0f
#define DM_TP_PILL_Y 22.0f
#define DM_TP_PILL_W 50.0f
#define DM_TP_PILL_H 28.0f
#define DM_TP_SWAP_R 15.0f
#define DM_TP_STICK_X 81.0f
#define DM_TP_STICK_R 77.0f
#define DM_TP_KNOB_R 30.0f
#define DM_TP_STICK_GRAB 1.4f
#define DM_TP_LSWIPE (1.0f / 3.0f)
#define DM_TP_FULL 0.8f
#define DM_TP_DEAD 0.1f
#define DM_TP_LOW_X 231.0f
#define DM_TP_LOW_Y 64.0f
#define DM_TP_DPAD_R 48.0f
#define DM_TP_ARM_W 17.0f
#define DM_TP_ARM_IN 11.0f
#define DM_TP_DPAD_GRAB 1.3f
#define DM_TP_RSTICK_R 60.0f
#define DM_TP_RSWIPE (1.0f / 2.0f)
#define DM_TP_CLICK_X 102.0f
#define DM_TP_CLICK_R 17.0f
#define DM_TP_LOOK_TAP_SLOP 12.0f
#define DM_TP_LOOK_TAP_MAX_SECONDS 0.35f
#define DM_TP_LOOK_DOUBLE_TAP_INTERVAL 0.35f
#define DM_TP_LOOK_DOUBLE_TAP_DISTANCE 48.0f
#define DM_TP_SHOULDER_GAP 8.0f
#define DM_TP_SHOULDER_HIT_SCALE 1.0f

static inline float dm_touchpad_u(float height) {
    float u = height / 430.0f;
    return u < 1.3f ? u : 1.3f;
}

// safe insets and result use top-left coordinates, as UIKit does. AppKit
// callers convert their bottom-left mouse coordinates at the view boundary.
static inline dm_touchpad_rect dm_touchpad_corner_rect(float width, float height,
                                                        float left, float top,
                                                        float right, float bottom) {
    return (dm_touchpad_rect){left * .5f, top, width - (left + right) * .5f,
                              height - top - bottom};
}

static inline dm_touchpad_rect dm_touchpad_safe_rect(float width, float height,
                                                      float left, float top,
                                                      float right, float bottom) {
    return (dm_touchpad_rect){left, top, width - left - right, height - top - bottom};
}

static inline dm_touchpad_point dm_touchpad_face_center(float width, float height,
                                                         float left, float top,
                                                         float right, float bottom) {
    dm_touchpad_rect c = dm_touchpad_corner_rect(width, height, left, top, right, bottom);
    float u = dm_touchpad_u(height);
    return (dm_touchpad_point){c.x + c.width - DM_TP_FACE_X * u,
                               c.y + c.height - DM_TP_PAD_Y * u};
}

// R and ZR sit together just above the face cluster on BOTW's virtual pad.
static inline dm_touchpad_point dm_touchpad_right_shoulder(float width, float height,
                                                            float left, float top,
                                                            float right, float bottom,
                                                            int zr) {
    dm_touchpad_point face = dm_touchpad_face_center(width, height, left, top, right, bottom);
    float u = dm_touchpad_u(height);
    float half = (DM_TP_ZL_R + DM_TP_SHOULDER_GAP * .5f) * u;
    float y = face.y - (DM_TP_FACE_GAP + DM_TP_FACE_R + DM_TP_ZL_R + 18.0f) * u;
    return (dm_touchpad_point){face.x + (zr ? half : -half), y};
}

static inline int dm_touchpad_look_dragged(float down_x, float down_y,
                                          float x, float y, float slop) {
    float dx = x - down_x, dy = y - down_y;
    return dx * dx + dy * dy > slop * slop;
}
static inline int dm_touchpad_look_tap(float duration, int dragged) {
    return !dragged && duration >= 0.0f && duration <= DM_TP_LOOK_TAP_MAX_SECONDS;
}
static inline int dm_touchpad_look_double_tap(double first_time, double second_time,
                                               float first_x, float first_y,
                                               float second_x, float second_y,
                                               float u) {
    float dx = second_x - first_x, dy = second_y - first_y;
    double dt = second_time - first_time;
    float limit = DM_TP_LOOK_DOUBLE_TAP_DISTANCE * u;
    return dt >= 0.0f && dt <= DM_TP_LOOK_DOUBLE_TAP_INTERVAL && dx*dx + dy*dy <= limit*limit;
}

static inline dm_touchpad_point dm_touchpad_stick_home(float width, float height,
                                                        float left, float top,
                                                        float right, float bottom) {
    dm_touchpad_rect c = dm_touchpad_corner_rect(width, height, left, top, right, bottom);
    float u = dm_touchpad_u(height);
    return (dm_touchpad_point){c.x + DM_TP_STICK_X * u,
                               c.y + c.height - DM_TP_PAD_Y * u};
}

static inline dm_touchpad_point dm_touchpad_dpad_center(float width, float height,
                                                         float left, float top,
                                                         float right, float bottom) {
    dm_touchpad_rect c = dm_touchpad_corner_rect(width, height, left, top, right, bottom);
    float u = dm_touchpad_u(height);
    return (dm_touchpad_point){c.x + DM_TP_LOW_X * u,
                               c.y + c.height - DM_TP_LOW_Y * u};
}

static inline dm_touchpad_point dm_touchpad_face_button(float width, float height,
                                                         float left, float top,
                                                         float right, float bottom,
                                                         int button) {
    dm_touchpad_point c = dm_touchpad_face_center(width, height, left, top, right, bottom);
    float g = DM_TP_FACE_GAP * dm_touchpad_u(height);
    switch (button) {
        case 0: c.x += g; break; // A
        case 1: c.y += g; break; // B
        case 2: c.y -= g; break; // X
        default: c.x -= g; break; // Y
    }
    return c;
}

static inline uint64_t dm_touchpad_face_buttons(float x, float y, float center_x,
                                                float center_y, float gap, float radius) {
    uint64_t bits = 0;
    for (int b = 0; b < 4; b++) {
        dm_touchpad_point c = {center_x, center_y};
        if (b == 0) c.x += gap;
        else if (b == 1) c.y += gap;
        else if (b == 2) c.y -= gap;
        else c.x -= gap;
        float dx = x - c.x, dy = y - c.y;
        if (dx * dx + dy * dy <= radius * radius) bits |= 1ull << b;
    }
    return bits;
}

static inline uint64_t dm_touchpad_dpad_buttons(float x, float y, float center_x,
                                                float center_y, float radius) {
    float dx = x - center_x, dy = y - center_y;
    if (hypotf(dx, dy) < radius * .25f) return 0;
    float a = atan2f(-dy, dx) * (180.0f / 3.14159265358979323846f);
    uint64_t bits = 0;
    if (a > -67.5f && a < 67.5f) bits |= DM_BTN_RIGHT;
    if (a > 22.5f && a < 157.5f) bits |= DM_BTN_UP;
    if (a > 112.5f || a < -112.5f) bits |= DM_BTN_LEFT;
    if (a < -22.5f && a > -157.5f) bits |= DM_BTN_DOWN;
    return bits;
}

static inline void dm_touchpad_stick_axis(float dx, float dy, float radius,
                                         int full_tilt, int32_t *x, int32_t *y) {
    float d = hypotf(dx, dy), dead = radius * DM_TP_DEAD;
    if (d <= (full_tilt ? 0.0f : dead) || radius <= 0.0f) { *x = *y = 0; return; }
    float magnitude = (full_tilt ? 1.0f : fminf((d - dead) / (radius * DM_TP_FULL - dead), 1.0f)) / d;
    *x = (int32_t)lrintf(dx * magnitude * DM_STICK_MAX);
    *y = (int32_t)lrintf(-dy * magnitude * DM_STICK_MAX);
}

