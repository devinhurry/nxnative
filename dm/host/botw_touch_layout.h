// BOTW-only layout settings, shared by the launcher preview and both touch frontends.
#pragma once
#include "touchpad_geometry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float x, y, scale; } dm_botw_control_transform;
typedef struct { dm_botw_control_transform control[16]; float face_gap; int badges, portrait; } dm_botw_touch_layout;
static inline int dm_botw_portrait_enabled(void) {
    const char *value = getenv("DM_BOTW_PORTRAIT");
    return value && !strcmp(value, "1");
}
static inline int dm_botw_compact_mode(float width, float height, float left, float right) {
    return dm_botw_portrait_enabled() && height > width && width-left-right < 600;
}
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
static inline dm_botw_touch_layout dm_botw_layout_defaults_for(int portrait) {
    if (!portrait) return dm_botw_layout_defaults();
    dm_botw_touch_layout layout={.face_gap=1.060f,.badges=0,.portrait=1};
    for (int i=0;i<16;i++) layout.control[i].scale=1;
    layout.control[0].scale=1.100f; layout.control[6].scale=1.200f;
    layout.control[7].scale=layout.control[9].scale=1.100f;
    return layout;
}
static inline int dm_botw_layout_number(const char *key, float low, float high, float *out) {
    const char *text = getenv(key); if (!text) return 1;
    char *end; float value = strtof(text, &end);
    if (end == text || *end || !isfinite(value) || value < low || value > high) return 0;
    *out = value; return 1;
}
static inline int dm_botw_layout_read_for(dm_botw_touch_layout *out, int portrait) {
    *out = dm_botw_layout_defaults_for(portrait);
    const char *prefix = portrait ? "DM_BOTW_PORTRAIT_PAD" : "DM_BOTW_PAD";
    float enabled = 0;
    if (!dm_botw_layout_number("DM_BOTW_PORTRAIT", 0, 1, &enabled) || (enabled != 0 && enabled != 1)) return 0;
    for (int i = 0; i < 16; i++) {
        const char *name = dm_botw_control_name(i); if (!name) continue;
        const char *fields[] = {"X", "Y", "SCALE"};
        float *values[] = {&out->control[i].x, &out->control[i].y, &out->control[i].scale};
        for (int f = 0; f < (i == 4 ? 2 : 3); f++) {
            char key[64]; snprintf(key, sizeof key, "%s_%s_%s", prefix, name, fields[f]);
            if (!dm_botw_layout_number(key, f == 2 ? .5f : -.5f, f == 2 ? 1.5f : .5f, values[f])) return 0;
        }
    }
    float badges = out->badges;
    char key[64]; snprintf(key, sizeof key, "%s_BADGES", prefix);
    if (!dm_botw_layout_number(key, 0, 1, &badges) || (badges != 0 && badges != 1)) return 0;
    out->badges = (int)badges;
    snprintf(key, sizeof key, "%s_FACE_GAP", prefix);
    return dm_botw_layout_number(key, .5f, 1.5f, &out->face_gap);
}
static inline int dm_botw_layout_read(dm_botw_touch_layout *out) {
    return dm_botw_layout_read_for(out, 0);
}
static inline float dm_botw_layout_unit(const dm_botw_touch_layout *layout, float width, float height) {
    return dm_touchpad_u(layout->portrait ? fminf(width, height) : height);
}
static inline float dm_botw_layout_stick_radius(const dm_botw_touch_layout *layout, float width, float height) {
    return dm_touchpad_botw_stick_radius(layout->portrait ? fminf(width, height) : height);
}
static inline dm_touchpad_point dm_botw_layout_face_offset(const dm_botw_touch_layout *layout, int button, float unit) {
    float gap = DM_TP_FACE_GAP * layout->face_gap * layout->control[0].scale * unit;
    if (layout->portrait)
        return (dm_touchpad_point){(button == 0 || button == 2 ? .5f : -.5f) * gap,
            ((button < 2 ? 1.1f : -1.1f) + (button == 0 || button == 2 ? -.5f : .5f)) * gap};
    switch (button) {
        case 0: return (dm_touchpad_point){gap, 0};
        case 1: return (dm_touchpad_point){0, gap};
        case 2: return (dm_touchpad_point){0, -gap};
        default: return (dm_touchpad_point){-gap, 0};
    }
}
static inline uint64_t dm_botw_layout_face_buttons(const dm_botw_touch_layout *layout, float x, float y,
                                                  float center_x, float center_y, float unit) {
    float radius = DM_TP_FACE_R * layout->control[0].scale * unit * 1.25f;
    uint64_t bits = 0;
    for (int b = 0; b < 4; b++) {
        dm_touchpad_point p = dm_botw_layout_face_offset(layout, b, unit);
        float dx = x - center_x - p.x, dy = y - center_y - p.y;
        if (dx*dx + dy*dy <= radius*radius) bits |= 1ull << b;
    }
    return bits;
}
static inline dm_touchpad_rect dm_botw_layout_canvas(float width, float height) {
    float w = fminf(width, height * 16.f / 9), h = w * 9.f / 16;
    return (dm_touchpad_rect){(width-w)*.5f, (height-h)*.5f, w, h};
}
static inline dm_touchpad_rect dm_botw_layout_control(const dm_botw_touch_layout *layout, int id,
        float width, float height, float left, float top, float right, float bottom, dm_touchpad_rect canvas) {
    dm_touchpad_point p = {0}; float u = dm_botw_layout_unit(layout, width, height), radius = 0;
    float rx = 0, ry = 0;
    if (layout->portrait && id != 10 && id != 11) {
        canvas = (dm_touchpad_rect){0, 0, width, height};
        dm_touchpad_rect safe = dm_touchpad_safe_rect(width,height,left,top,right,bottom);
        float base_y = safe.y + safe.height - DM_TP_PAD_Y*u;
        float default_gap = DM_TP_FACE_GAP * 1.060f * 1.100f * u;
        // Halve the full vertical steps, including the expanded grab-region spacing.
        float shield_y = base_y - 5 - (DM_TP_STICK_R*DM_TP_STICK_GRAB*1.8f + DM_TP_SHIELD_GAP*.5f + 6)*u*.5f;
        float rune_y = shield_y - (DM_TP_STICK_R*DM_TP_STICK_GRAB + DM_TP_L_R*1.2f*1.45f + DM_TP_SHIELD_GAP*.5f)*u*.5f;
        switch (id) {
            case 0:
                p = (dm_touchpad_point){safe.x + safe.width - DM_TP_FACE_X*u, base_y - DM_TP_FACE_GAP*3.1f*u - 100};
                rx = (DM_TP_FACE_GAP*layout->face_gap*.5f + DM_TP_FACE_R)*u;
                ry = (DM_TP_FACE_GAP*layout->face_gap*1.6f + DM_TP_FACE_R)*u;
                break;
            case 4: p = (dm_touchpad_point){safe.x+DM_TP_STICK_X*u+10, base_y-10}; radius=dm_botw_layout_stick_radius(layout,width,height); break;
            case 8: p = (dm_touchpad_point){safe.x+DM_TP_STICK_X*u, shield_y}; radius=dm_botw_layout_stick_radius(layout,width,height); break;
            case 6: p = (dm_touchpad_point){safe.x+DM_TP_STICK_X*u, rune_y}; radius=DM_TP_L_R*u; break;
            case 12:
                p = (dm_touchpad_point){safe.x+DM_TP_STICK_X*u,
                    rune_y - (DM_TP_L_R*1.2f*1.45f + DM_TP_DPAD_R*DM_TP_DPAD_GRAB + DM_TP_SHIELD_GAP*.5f)*u*.5f};
                radius=DM_TP_DPAD_R*u; break;
            case 7: case 9:
                p = (dm_touchpad_point){safe.x+safe.width-DM_TP_FACE_X*u+(id==7?.5f:-.5f)*default_gap,
                    base_y-DM_TP_FACE_GAP*3.1f*u-100-(3.3f+(id==7?.5f:-.5f))*default_gap};
                radius=DM_TP_ZL_R*u; break;
            default: return (dm_touchpad_rect){0};
        }
    } else switch (id) {
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
            if (canvas.height > canvas.width * 9.f/16.f) r.y += fmaxf(0,top-canvas.y);
            p = (dm_touchpad_point){r.x+r.width*.5f,r.y+r.height*.5f}; radius=r.width*.5f; break;
        }
        case 12: p = dm_touchpad_dpad_center(width,height,left,top,right,bottom); radius=DM_TP_DPAD_R*u; break;
        default: return (dm_touchpad_rect){0};
    }
    dm_botw_control_transform t = layout->control[id];
    p.x += t.x * canvas.width; p.y += t.y * canvas.height;
    rx = (rx ? rx : radius) * t.scale; ry = (ry ? ry : radius) * t.scale;
    return (dm_touchpad_rect){p.x-rx,p.y-ry,rx*2,ry*2};
}
