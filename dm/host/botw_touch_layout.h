// BOTW-only point layouts, shared by the launcher and both touch frontends.
#pragma once
#include "touchpad_geometry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { float x, y, size; } dm_botw_control_transform;
typedef struct { dm_botw_control_transform control[16]; int badges, portrait; } dm_botw_touch_layout;
typedef struct { float side, bottom, size; } dm_botw_control_anchor;

static inline int dm_botw_portrait_enabled(void) {
    const char *value=getenv("DM_BOTW_PORTRAIT");
    return value && !strcmp(value,"1");
}
static inline int dm_botw_compact_mode(float width,float height,float left,float right) {
    // Orientation permission is separate from the system's window geometry.
    (void)left; (void)right;
    return height>width && width<600;
}
static inline int dm_botw_portrait_allowed(float width,float height,float left,float right) {
    if (dm_botw_portrait_enabled()) return 1;
    if (width<=0 || height<=0) return 0;
    if (width>height) { float swap=width; width=height; height=swap; left=right=0; }
    return !dm_botw_compact_mode(width,height,left,right);
}
static inline const char *dm_botw_control_name(int id) {
    switch (id) {
        case 0: return "A"; case 1: return "B"; case 2: return "X"; case 3: return "Y";
        case 4: return "STICK"; case 6: return "L"; case 7: return "R";
        case 8: return "ZL"; case 9: return "ZR"; case 12: return "DPAD";
        default: return NULL;
    }
}
static inline dm_botw_control_anchor dm_botw_layout_anchor(int id,int portrait) {
    // Outer-edge distances in frontend points. Preserve the former default
    // phone layouts (932x430 normal, 390x844 compact), independently of insets.
    static const dm_botw_control_anchor normal[16]={
        [0]={28.6f,115.5f,59.4f}, [1]={86.9f,57.2f,59.4f},
        [2]={86.9f,173.8f,59.4f}, [3]={145.2f,115.5f,59.4f},
        [4]={60.4f,54.5f,123.2f}, [6]={205.7f,193.7f,57.6f},
        [7]={34.3f,250.1f,57.2f}, [8]={35,225,154},
        [9]={130.2f,250.5f,57.2f}, [12]={246.1f,50,96}
    };
    static const dm_botw_control_anchor compact[16]={
        [0]={22.1f,42.4f,43.9f}, [1]={96.7f,42.4f,43.9f},
        [2]={17.1f,107,53.9f}, [3]={86.7f,102,63.9f},
        [4]={27.6f,102.5f,111.7f}, [6]={10,44,46.2f},
        [7]={18.1f,250.6f,51.9f}, [8]={3.6f,214.5f,139.7f},
        [9]={18.1f,191.5f,51.9f}, [12]={71.2f,26.6f,81.1f}
    };
    return id>=0 && id<16 ? (portrait ? compact[id] : normal[id]) : (dm_botw_control_anchor){0};
}
static inline dm_botw_touch_layout dm_botw_layout_defaults_for(int portrait) {
    dm_botw_touch_layout layout={.portrait=portrait};
    for (int i=0;i<16;i++) layout.control[i].size=dm_botw_layout_anchor(i,portrait).size;
    return layout;
}
static inline dm_botw_touch_layout dm_botw_layout_defaults(void) {
    return dm_botw_layout_defaults_for(0);
}
static inline int dm_botw_layout_number(const char *key,float low,float high,float *out) {
    const char *text=getenv(key); if (!text) return 1;
    char *end; float value=strtof(text,&end);
    if (end==text || *end || !isfinite(value) || value<low || value>high) return 0;
    *out=value; return 1;
}
static inline int dm_botw_layout_read_for(dm_botw_touch_layout *out,int portrait) {
    *out=dm_botw_layout_defaults_for(portrait);
    const char *prefix=portrait ? "DM_BOTW_PORTRAIT_PAD_" : "DM_BOTW_PAD_";
    float enabled=0;
    if (!dm_botw_layout_number("DM_BOTW_PORTRAIT",0,1,&enabled) || (enabled!=0 && enabled!=1)) return 0;
    for (int i=0;i<16;i++) {
        const char *name=dm_botw_control_name(i); if (!name) continue;
        const char *fields[]={"X_PT","Y_PT","SIZE_PT"};
        float *values[]={&out->control[i].x,&out->control[i].y,&out->control[i].size};
        for (int f=0;f<3;f++) {
            char key[64]; snprintf(key,sizeof key,"%s%s_%s",prefix,name,fields[f]);
            if (!dm_botw_layout_number(key,f==2 ? 20 : -500,f==2 ? 240 : 500,values[f])) return 0;
        }
    }
    float badges=0; char key[64]; snprintf(key,sizeof key,"%sBADGES",prefix);
    if (!dm_botw_layout_number(key,0,1,&badges) || (badges!=0 && badges!=1)) return 0;
    out->badges=(int)badges; return 1;
}
static inline int dm_botw_layout_read(dm_botw_touch_layout *out) {
    return dm_botw_layout_read_for(out,0);
}
// Artwork uses points too; only the final frontend display scale changes pixels.
static inline float dm_botw_layout_unit(const dm_botw_touch_layout *layout,float width,float height) {
    (void)layout; (void)width; (void)height; return 1;
}
static inline float dm_botw_layout_scale(const dm_botw_touch_layout *layout,int id) {
    float base=id<4 ? 54 : id==4 || id==8 ? 154 : id==6 ? 48 : id==12 ? 96 : 52;
    return layout->control[id].size/base;
}
static inline float dm_botw_layout_hud_scale(float point_scale,float canvas_height,float native_y_scale) {
    // Native equipment artwork is authored for the old 430pt reference.
    // Cancel the game's HUD-to-view scale so its size follows the point D-pad.
    return point_scale*430/(canvas_height*native_y_scale);
}
static inline dm_touchpad_rect dm_botw_layout_canvas(float width,float height) {
    float w=fminf(width,height*16.f/9),h=w*9.f/16;
    return (dm_touchpad_rect){(width-w)*.5f,(height-h)*.5f,w,h};
}
static inline dm_touchpad_rect dm_botw_layout_control(const dm_botw_touch_layout *layout,int id,
        float width,float height,float left,float top,float right,float bottom,dm_touchpad_rect canvas) {
    if (id==10 || id==11) {
        float safe_right=fmaxf(0,right-(width-canvas.x-canvas.width));
        dm_touchpad_rect r=dm_touchpad_botw_menu_rect(canvas.x,canvas.y,canvas.width,canvas.height,safe_right,id==11);
        if (canvas.height>canvas.width*9.f/16) r.y+=fmaxf(0,top-canvas.y);
        return r;
    }
    (void)left; (void)bottom;
    dm_botw_control_anchor a=dm_botw_layout_anchor(id,layout->portrait);
    if (!a.size) return (dm_touchpad_rect){0};
    dm_botw_control_transform t=layout->control[id];
    int at_right=id<4 || id==7 || id==9;
    // Normal left margins contract below 768pt, retaining at least 90%.
    // Only the base margin responds to width; user offsets stay in points.
    float side=a.side;
    if (!at_right && !layout->portrait) side*=fminf(1,fmaxf(.9f,width/768.f));
    // Anchor the outside edge first. Resizing keeps side/bottom margins;
    // independent point offsets translate drawing and input together.
    return (dm_touchpad_rect){(at_right ? width-side-t.size : side)+t.x,
        height-a.bottom-t.size+t.y,t.size,t.size};
}
