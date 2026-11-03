// BOTW-only point layouts, shared by the launcher and both touch frontends.
#pragma once
#include "touchpad_geometry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Default anchors retain the original base-relative offsets. Explicit anchors
// store actual side and bottom edge distances in x/y, independent of defaults.
enum { DM_BOTW_ANCHOR_DEFAULT=0, DM_BOTW_ANCHOR_LEFT=1, DM_BOTW_ANCHOR_RIGHT=2 };
typedef struct { float x, y, size; int anchor; } dm_botw_control_transform;
enum { DM_BOTW_WEAPON=16, DM_BOTW_SHIELD=17, DM_BOTW_FOOD=18, DM_BOTW_WHISTLE=19,
       DM_BOTW_CANCEL=20, DM_BOTW_CONTROL_COUNT=21 };
typedef struct {
    dm_botw_control_transform control[DM_BOTW_CONTROL_COUNT];
    int badges, portrait, dpad_visible, added[4], switch_mode[2], rune_mode;
} dm_botw_touch_layout;
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
        case DM_BOTW_WEAPON: return "WEAPON"; case DM_BOTW_SHIELD: return "SHIELD";
        case DM_BOTW_FOOD: return "FOOD"; case DM_BOTW_WHISTLE: return "WHISTLE";
        case DM_BOTW_CANCEL: return "CANCEL";
        default: return NULL;
    }
}
static inline dm_botw_control_anchor dm_botw_layout_anchor(int id,int portrait) {
    // Outer-edge distances in frontend points. Preserve the former default
    // phone layouts (932x430 normal, 390x844 compact), independently of insets.
    static const dm_botw_control_anchor normal[DM_BOTW_CONTROL_COUNT]={
        [0]={28.6f,115.5f,59.4f}, [1]={86.9f,57.2f,59.4f},
        [2]={86.9f,173.8f,59.4f}, [3]={145.2f,115.5f,59.4f},
        [4]={60.4f,54.5f,123.2f}, [6]={205.7f,193.7f,57.6f},
        [7]={34.3f,250.1f,57.2f}, [8]={35,225,154},
        [9]={130.2f,250.5f,57.2f}, [12]={246.1f,50,96},
        [16]={320,160,52}, [17]={390,160,52}, [18]={460,160,52},
        [19]={530,160,52}, [20]={390,94,52}
    };
    static const dm_botw_control_anchor compact[DM_BOTW_CONTROL_COUNT]={
        [0]={22.1f,42.4f,43.9f}, [1]={96.7f,42.4f,43.9f},
        [2]={17.1f,107,53.9f}, [3]={86.7f,102,63.9f},
        [4]={27.6f,102.5f,111.7f}, [6]={10,44,46.2f},
        [7]={18.1f,250.6f,51.9f}, [8]={3.6f,214.5f,139.7f},
        [9]={18.1f,191.5f,51.9f}, [12]={71.2f,26.6f,81.1f},
        [16]={154,270,44}, [17]={206,270,44}, [18]={154,218,44},
        [19]={206,218,44}, [20]={154,166,44}
    };
    return id>=0 && id<DM_BOTW_CONTROL_COUNT ? (portrait ? compact[id] : normal[id]) : (dm_botw_control_anchor){0};
}
static inline dm_botw_touch_layout dm_botw_layout_defaults_for(int portrait) {
    dm_botw_touch_layout layout={.portrait=portrait,.dpad_visible=1};
    for (int i=0;i<DM_BOTW_CONTROL_COUNT;i++) layout.control[i].size=dm_botw_layout_anchor(i,portrait).size;
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
    for (int i=0;i<DM_BOTW_CONTROL_COUNT;i++) {
        const char *name=dm_botw_control_name(i); if (!name) continue;
        const char *fields[]={"X_PT","Y_PT","SIZE_PT"};
        float *values[]={&out->control[i].x,&out->control[i].y,&out->control[i].size};
        for (int f=0;f<3;f++) {
            char key[64]; snprintf(key,sizeof key,"%s%s_%s",prefix,name,fields[f]);
            if (!dm_botw_layout_number(key,f==2 ? 20 : -10000,f==2 ? 240 : 10000,values[f])) return 0;
        }
        char key[64]; float anchor=0;
        snprintf(key,sizeof key,"%s%s_ANCHOR",prefix,name);
        if (!dm_botw_layout_number(key,0,2,&anchor) || anchor!=floorf(anchor)) return 0;
        out->control[i].anchor=(int)anchor;
        if (anchor && (out->control[i].x<0 || out->control[i].y<0)) return 0;
    }
    float badges=0; char key[64]; snprintf(key,sizeof key,"%sBADGES",prefix);
    if (!dm_botw_layout_number(key,0,1,&badges) || (badges!=0 && badges!=1)) return 0;
    out->badges=(int)badges;
    const char *names[]={"DPAD_VISIBLE","WEAPON_ENABLED","SHIELD_ENABLED","FOOD_ENABLED","WHISTLE_ENABLED",
        "WEAPON_MODE","SHIELD_MODE","L_MODE"};
    int *options[]={&out->dpad_visible,&out->added[0],&out->added[1],&out->added[2],&out->added[3],
        &out->switch_mode[0],&out->switch_mode[1],&out->rune_mode};
    for (int i=0;i<8;i++) {
        float v=*options[i]; snprintf(key,sizeof key,"%s%s",prefix,names[i]);
        if (!dm_botw_layout_number(key,0,i<5 ? 1 : 2,&v) || v!=floorf(v)) return 0;
        *options[i]=(int)v;
    }
    return 1;
}
static inline int dm_botw_layout_control_visible(const dm_botw_touch_layout *layout,int id) {
    if (id==12) return layout->dpad_visible;
    if (id>=16 && id<20) return layout->added[id-16];
    if (id==20) return layout->rune_mode==2 ||
        (layout->added[0] && layout->switch_mode[0]==2) || (layout->added[1] && layout->switch_mode[1]==2);
    return dm_botw_control_name(id)!=NULL;
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
    if (t.anchor==DM_BOTW_ANCHOR_LEFT || t.anchor==DM_BOTW_ANCHOR_RIGHT) {
        // A shared layout may meet a smaller pane after import or rotation.
        // Fit explicit edge distances in the actual drawing and hit-test pane.
        float side=fminf(fmaxf(0,t.x),fmaxf(0,width-t.size));
        float edge_bottom=fminf(fmaxf(0,t.y),fmaxf(0,height-t.size));
        return (dm_touchpad_rect){t.anchor==DM_BOTW_ANCHOR_RIGHT ? width-side-t.size : side,
            height-edge_bottom-t.size,t.size,t.size};
    }
    int at_right=id<4 || id==7 || id==9;
    // Normal left margins contract below 800pt, retaining at least 80%.
    // Only the base margin responds to width; user offsets stay in points.
    float side=a.side;
    if (!at_right && !layout->portrait) side*=fminf(1,fmaxf(.8f,width/800.f));
    // Anchor the outside edge first. Resizing keeps side/bottom margins;
    // independent point offsets translate drawing and input together.
    return (dm_touchpad_rect){(at_right ? width-side-t.size : side)+t.x,
        height-a.bottom-t.size+t.y,t.size,t.size};
}
