// BOTW-only layout settings, shared by the launcher preview and both touch frontends.
#pragma once
#include "touchpad_geometry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float x, y, scale; } dm_botw_control_transform;
typedef struct { dm_botw_control_transform control[16]; float face_gap; int badges; } dm_botw_touch_layout;
static inline const char *dm_botw_control_name(int id) {
    switch (id) {
        case 0: return "FACE"; case 4: return "STICK"; case 6: return "L";
        case 7: return "R"; case 8: return "ZL"; case 9: return "ZR";
        case 12: return "DPAD";
        default: return NULL;
    }
}
static inline dm_botw_touch_layout dm_botw_layout_defaults(void) {
    dm_botw_touch_layout layout = {.face_gap = 1.060f, .badges = 0};
    for (int i = 0; i < 16; i++) layout.control[i].scale = 1;
    layout.control[0] = (dm_botw_control_transform){-.006f, -.068f, 1.100f};
    layout.control[4].y = .023f;
    layout.control[6] = (dm_botw_control_transform){.021f, 0, 1.200f};
    layout.control[7] = (dm_botw_control_transform){.025f, -.097f, 1.100f};
    layout.control[9] = (dm_botw_control_transform){-.022f, -.098f, 1.100f};
    layout.control[12].x = .042f;
    return layout;
}
static inline int dm_botw_layout_number(const char *key, float low, float high, float *out) {
    const char *text = getenv(key); if (!text) return 1;
    char *end; float value = strtof(text, &end);
    if (end == text || *end || !isfinite(value) || value < low || value > high) return 0;
    *out = value; return 1;
}
static inline int dm_botw_layout_read(dm_botw_touch_layout *out) {
    *out = dm_botw_layout_defaults();
    for (int i = 0; i < 16; i++) {
        const char *name = dm_botw_control_name(i); if (!name) continue;
        const char *fields[] = {"X", "Y", "SCALE"};
        float *values[] = {&out->control[i].x, &out->control[i].y, &out->control[i].scale};
        for (int f = 0; f < (i == 4 ? 2 : 3); f++) {
            char key[64]; snprintf(key, sizeof key, "DM_BOTW_PAD_%s_%s", name, fields[f]);
            if (!dm_botw_layout_number(key, f == 2 ? .5f : -.5f, f == 2 ? 1.5f : .5f, values[f])) return 0;
        }
    }
    float badges = out->badges;
    if (!dm_botw_layout_number("DM_BOTW_PAD_BADGES", 0, 1, &badges) || (badges != 0 && badges != 1)) return 0;
    out->badges = (int)badges;
    return dm_botw_layout_number("DM_BOTW_PAD_FACE_GAP", .5f, 1.5f, &out->face_gap);
}
static inline dm_touchpad_rect dm_botw_layout_canvas(float width, float height) {
    float w = fminf(width, height * 16.f / 9), h = w * 9.f / 16;
    return (dm_touchpad_rect){(width-w)*.5f, (height-h)*.5f, w, h};
}
static inline dm_touchpad_rect dm_botw_layout_control(const dm_botw_touch_layout *layout, int id,
        float width, float height, float left, float top, float right, float bottom, dm_touchpad_rect canvas) {
    dm_touchpad_point p = {0}; float u = dm_touchpad_u(height), radius = 0;
    switch (id) {
        case 0:
            p = dm_touchpad_face_center(width,height,left,top,right,bottom);
            radius = (DM_TP_FACE_GAP * layout->face_gap + DM_TP_FACE_R) * u; break;
        case 4: p = dm_touchpad_botw_stick_home(width,height,left,top,right,bottom);
            radius = dm_touchpad_botw_stick_radius(height); break;
        case 6: p = dm_touchpad_rune_button(width,height,left,top,right,bottom); radius = DM_TP_L_R*u; break;
        case 7: case 9: p = dm_touchpad_right_shoulder(width,height,left,top,right,bottom,id==9); radius = DM_TP_ZL_R*u; break;
        case 8: p = dm_touchpad_shield_stick_home(width,height,left,top,right,bottom); radius = dm_touchpad_botw_stick_radius(height); break;
        case 10: case 11: {
            dm_touchpad_rect r = dm_touchpad_botw_menu_rect(canvas.x,canvas.y,canvas.width,canvas.height,id==11);
            p = (dm_touchpad_point){r.x+r.width*.5f,r.y+r.height*.5f}; radius=r.width*.5f; break;
        }
        case 12: p = dm_touchpad_dpad_center(width,height,left,top,right,bottom); radius=DM_TP_DPAD_R*u; break;
        default: return (dm_touchpad_rect){0};
    }
    dm_botw_control_transform t = layout->control[id];
    p.x += t.x * canvas.width; p.y += t.y * canvas.height;
    radius *= t.scale;
    return (dm_touchpad_rect){p.x-radius,p.y-radius,radius*2,radius*2};
}
