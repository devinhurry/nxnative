// Native aspect: only publish display geometry from the front end. The game's projection-update gate applies it on the
// guest thread, before the matrix is calculated. Menus remain centered at
// 16:9; gameplay HUD and flat loading backgrounds can use the display edges.
#include "hle.h"
#include "botw_rune_icon.h"
#include "touchpad_geometry.h"
#include <ctype.h>
#include <math.h>
#include <search.h>
#include <stdatomic.h>

static pthread_once_t g_config_once = PTHREAD_ONCE_INIT;
static int g_on;
static float g_custom;
static _Atomic float g_screen = 16.0f / 9.0f;
static _Atomic float g_hud_safe_left;
static _Atomic float g_hud_safe_top;
static _Atomic float g_ui_point_scale = 1;
static _Atomic float g_display_height = 430;
static _Atomic int g_seated;
static pthread_mutex_t g_seated_mu=PTHREAD_MUTEX_INITIALIZER;
static float g_picture_end, g_controls_begin;
static module_t *g_main;
static uint64_t g_single_off, g_proj_off, g_vt_off, g_field_off, g_dirty_off;
static unsigned g_ui_reg; static uint64_t g_ui_source, g_ui_projection, g_ui_fovy;
static unsigned g_world_reg; static uint64_t g_world_projection;
static const float GAME_ASPECT = 16.0f / 9.0f;

static void aspect_config(void) {
    const char *e = getenv("DM_ASPECT");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_ASPECT must be 0 or 1");
    g_on = DM_GAME_ASPECT_NATIVE && !(e && !strcmp(e, "0"));
    e = getenv("DM_ASPECT_RATIO");
    if (!e || !*e) return;
    char *end;
    float a = strtof(e, &end), b = 1;
    if (end == e || !isfinite(a) || a <= 0) die("[RED] invalid DM_ASPECT_RATIO: %s", e);
    while (isspace((unsigned char)*end)) end++;
    if (*end == ':' || *end == '/' || *end == 'x') {
        const char *den = end + 1;
        b = strtof(den, &end);
        if (end == den || !isfinite(b) || b <= 0) die("[RED] invalid DM_ASPECT_RATIO: %s", e);
        while (isspace((unsigned char)*end)) end++;
    }
    float r = a / b;
    if (*end || !isfinite(r) || r < 0.1f || r > 10) die("[RED] DM_ASPECT_RATIO must be a ratio from 0.1 to 10: %s", e);
    g_custom = r;
}
int dm_aspect_native(void) { pthread_once(&g_config_once, aspect_config); return g_on; }
float dm_aspect_custom_ratio(void) { pthread_once(&g_config_once, aspect_config); return g_custom; }
void dm_aspect_set_seated(float picture_end, float controls_begin) {
    int active=!strcmp(DM_GAME_ID,"01007EF00011E000") && dm_aspect_native() &&
        isfinite(picture_end) && isfinite(controls_begin) && picture_end>0 && picture_end<=controls_begin && controls_begin<1;
    pthread_mutex_lock(&g_seated_mu);
    g_picture_end=picture_end; g_controls_begin=controls_begin;
    atomic_store_explicit(&g_seated,active,memory_order_release);
    pthread_mutex_unlock(&g_seated_mu);
}
int dm_aspect_region(int controls, float rect[4]) {
    rect[0]=rect[1]=0; rect[2]=rect[3]=1;
    if (!atomic_load_explicit(&g_seated,memory_order_acquire)) return 0;
    pthread_mutex_lock(&g_seated_mu);
    int active=atomic_load_explicit(&g_seated,memory_order_relaxed);
    if (active) {
        rect[1]=controls ? g_controls_begin : 0; rect[3]=controls ? 1-g_controls_begin : g_picture_end;
        // A fixed picture aspect belongs to the upper pane, not the combined
        // picture and control surface. Keep the lower pane at its real size.
        if (!controls && g_custom>0) {
            float ratio=atomic_load(&g_screen)/rect[3];
            if (ratio>g_custom) { rect[2]=g_custom/ratio; rect[0]=(1-rect[2])*.5f; }
            else { float height=atomic_load(&g_screen)/g_custom; rect[1]=(rect[3]-height)*.5f; rect[3]=height; }
        }
    }
    pthread_mutex_unlock(&g_seated_mu);
    return active;
}
float dm_aspect_ratio(void) {
    if (!dm_aspect_native()) return 0;
    if (g_custom) return g_custom;
    float region[4]; dm_aspect_region(0,region);
    return atomic_load(&g_screen)*region[2]/region[3];
}
float dm_aspect_control_ratio(void) {
    float region[4];
    return dm_aspect_region(1,region) ? atomic_load(&g_screen)*region[2]/region[3] : dm_aspect_ratio();
}
float dm_aspect_hud_y_scale(void) {
    float ratio = dm_aspect_control_ratio();
    return ratio > 0 && ratio < GAME_ASPECT ? ratio / GAME_ASPECT : 1;
}
float dm_aspect_hud_gain(void) {
    float ratio = dm_aspect_control_ratio();
    // Keep HUD size tied to the shorter display edge, rather than the height
    // of a tiny fitted 16:9 menu in portrait. 16:9 and wider stay unchanged.
    return ratio > 0 && ratio < GAME_ASPECT ? GAME_ASPECT*fminf(1,1/ratio) : 1;
}
float dm_aspect_map_gain(void) {
    float region[4];
    if (!dm_aspect_region(1,region)) return dm_aspect_hud_gain();
    // Keep the native map at its usual 430pt-landscape size in the dock,
    // independently of the lower pane's height.
    float height=atomic_load(&g_display_height)*region[3];
    float width=height*dm_aspect_control_ratio();
    dm_touchpad_rect map=dm_touchpad_seated_map((dm_touchpad_rect){0,0,width,height});
    return map.width*720/(166*height*dm_aspect_hud_y_scale());
}
float dm_aspect_hud_top(void) {
    float region[4];
    if (dm_aspect_region(1,region)) return 360-DM_TP_BOTW_DOCK_TOP*720/(atomic_load(&g_display_height)*region[3]);
    float scale = dm_aspect_hud_y_scale();
    return scale < 1 ? 360 - (360-DM_TP_BOTW_MAP_TOP)*scale*dm_aspect_hud_gain() - atomic_load(&g_hud_safe_top) : DM_TP_BOTW_MAP_TOP;
}
void dm_aspect_set_display(float ratio) {
    if (!isfinite(ratio) || ratio <= 0) die("[RED] invalid display aspect %g", ratio);
    atomic_store(&g_screen, ratio);
}

// The centered, undistorted UI region, including a custom aspect's bars. Touch input uses the same coordinates as UI replay.
void dm_aspect_touch_rect(float w, float h, float rect[4]) {
    float region[4]; dm_aspect_region(0,region);
    float x=w*region[0],y=h*region[1],cw=w*region[2],ch=h*region[3];
    float cr = dm_aspect_native() ? dm_aspect_custom_ratio() : 0;
    float ow=cw,oh=ch;
    if (cr > 0) { if (cw / ch > cr) cw = ch * cr; else ch = cw / cr; }
    if (cw / ch > GAME_ASPECT) cw = ch * GAME_ASPECT; else ch = cw / GAME_ASPECT;
    rect[0] = x+(ow-cw)/2; rect[1] = y+(oh-ch)/2; rect[2] = cw; rect[3] = ch;
}

// Extra logical space beside the centered UI. The right HUD already has its
// authored corner padding; adding the landscape safe inset leaves another
// notch-width gap. This display rule is independent of the input mode.
// The left side retains its safe inset. Menus still use touch_rect.
float dm_aspect_hud_offset(int right) {
    float extra = fmaxf(0, 360 * dm_aspect_control_ratio() - 640);
    float safe = right ? 0 : atomic_load(&g_hud_safe_left);
    return fmaxf(0, extra - safe);
}
float dm_aspect_ui_point_scale(void) { return atomic_load(&g_ui_point_scale); }
void dm_aspect_set_safe_area(float w, float h, float left, float top, float right) {
    if (!isfinite(w) || !isfinite(h) || !isfinite(left) || !isfinite(top) || !isfinite(right) || w <= 0 || h <= 0) return;
    atomic_store(&g_display_height,h);
    float canvas[4],region[4]; dm_aspect_touch_rect(w, h, canvas); int seated=dm_aspect_region(0,region);
    float frame_width = dm_aspect_native() ? (seated ? w*region[2] : fminf(w,h*dm_aspect_ratio())) : canvas[2];
    float bar = (w - frame_width) * .5f, scale = 720 / canvas[3];
    atomic_store(&g_ui_point_scale, scale);
    atomic_store(&g_hud_safe_left, fmaxf(0, left - bar) * scale);
    float picture_height = dm_aspect_native() ? fminf(h*region[3], w/dm_aspect_ratio()) : canvas[3];
    atomic_store(&g_hud_safe_top, fmaxf(0, top-h*region[1]-(h*region[3]-picture_height)*.5f)*720/picture_height);
}
void dm_aspect_hud_rect(float w, float h, float rect[4]) {
    float region[4];
    if (dm_aspect_region(1,region)) {
        float rw=w*region[2],rh=h*region[3],cw=fminf(rw,rh*GAME_ASPECT);
        rect[0]=w*region[0]+(rw-cw)*.5f; rect[1]=h*region[1]+(rh-cw/GAME_ASPECT)*.5f;
        rect[2]=cw; rect[3]=cw/GAME_ASPECT;
    } else dm_aspect_touch_rect(w,h,rect);
    float yscale = dm_aspect_hud_y_scale();
    if (yscale < 1) { rect[3] /= yscale; rect[1] = h*region[1]+(h*region[3]-rect[3])*.5f; }
    float scale = rect[3] / 720, left = dm_aspect_hud_offset(0) * scale;
    rect[0] -= left;
    rect[2] += left + dm_aspect_hud_offset(1) * scale;
}

static void aspect_apply_projection(uint8_t *proj) {
    if (*(uint64_t *)proj != (uint64_t)(g_main->base + g_vt_off)) die("[RED] aspect: main camera projection vtable mismatch");
    float want = dm_aspect_ratio(), now;
    memcpy(&now, proj + g_field_off, sizeof now);
    if (now != want) { memcpy(proj + g_field_off, &want, sizeof want); proj[g_dirty_off] = 1; }
    static float logged;
    if (logged != want) { logged = want; LOG("aspect: camera %.4f at projection update; centered 16:9 UI", want); }
}

static void aspect_projection(const uint64_t *regs) {
    uint8_t *singleton = *(uint8_t **)(g_main->base + g_single_off);
    uint8_t *proj = (uint8_t *)regs[0];
    if (!singleton || proj != singleton + g_proj_off) return;
    aspect_apply_projection(proj);
}

// MainScreen3D copies the camera projection every frame. Correct that clone immediately after the copy,
// before its matrix is rebuilt for world-space labels.
static void aspect_world_projection(const uint64_t *regs) {
    uint8_t *owner = (uint8_t *)regs[g_world_reg];
    if (!owner) die("[RED] aspect: missing world-UI projection owner");
    aspect_apply_projection(owner + g_world_projection);
}

// The game has rebuilt the UI model's source lens, and is about to copy it into its perspective projection.
// Adjust this lens instead of the post-processing picture, which also contains UI drawn earlier.
static void aspect_ui_camera(const uint64_t *regs) {
    uint8_t *owner = (uint8_t *)regs[g_ui_reg];
    uint8_t *proj = *(uint8_t **)(owner + g_ui_projection), *source = *(uint8_t **)(owner + g_ui_source);
    if (!proj || !source || *(uint64_t *)proj != (uint64_t)(g_main->base + g_vt_off)) die("[RED] aspect: UI camera projection vtable mismatch");
    float want = dm_aspect_ratio(), f = want / GAME_ASPECT;
    float lens[3]; memcpy(lens, source + g_ui_fovy, sizeof lens); // fovy radians, optical offset x/y
    if (f > 1) lens[1] /= f;
    else if (f < 1) { lens[0] = 2 * atanf(tanf(lens[0] / 2) / f); lens[2] *= f; }
    memcpy(source + g_ui_fovy, lens, sizeof lens);
    memcpy(proj + g_field_off, &want, sizeof want); proj[g_dirty_off] = 1;
}

// BOTW's full-width backgrounds are leaf Pictures/Windows, separate from its
// text, selectors and capture pictures. Resize these panes before Calculate:
// Window then keeps its native corner/edge sizes instead of stretching them.
// Remember native widths because Calculate does not reset Pane::m_Size, and a
// window resize must also restore the original width when returning to 16:9.
typedef struct {
    uintptr_t pane, parent, type;
    char name[16];
    float native_width, written_width, native_height, written_height, native_x, written_x, native_y, written_y;
    float native_scale_x, written_scale_x, native_scale_y, written_scale_y;
} aspect_ui_width;
static void *g_ui_widths;
static pthread_mutex_t g_ui_width_mu = PTHREAD_MUTEX_INITIALIZER;
static int aspect_ui_width_order(const void *a, const void *b) {
    uintptr_t x = ((const aspect_ui_width *)a)->pane, y = ((const aspect_ui_width *)b)->pane;
    return (x > y) - (x < y);
}
static int aspect_ui_background(const char *name) {
    static const char *const prefixes[] = {
        "P_BG_", "P_Black_", "P_BlackBG_", "Black8_", "White8_", "P_Grad_",
        "P_Abstract_", "P_BackGround_", "TitleBG_", "P_MainV", "P_BootBG_",
        "P_WallU_", "P_WallD_", "P_MoyaU_", "P_MoyaD_", "P_SSFrameCore_",
        "P_UeBlack_", "P_SitaBlack_", "W_Shadow_", "W_BlackBG_", "W_Line_"
    };
    for (unsigned i = 0; i < sizeof prefixes / sizeof *prefixes; i++)
        if (!strncmp(name, prefixes[i], strlen(prefixes[i]))) return 1;
    return 0;
}
static int aspect_ui_named(const uint8_t *pane, const char *name) {
    return pane && !strncmp((const char *)pane + 0xb8, name, 16);
}
// Read only live native lists while inside Pane's build-checked callbacks.
static uint8_t *aspect_ui_parent(uint8_t *pane) { return pane ? *(uint8_t **)(pane + 0x18) : NULL; }
static uint8_t *aspect_ui_child(uint8_t *parent, const char *name) {
    if (!parent) return NULL;
    uint8_t *sentinel = parent + 0x20, *link = *(uint8_t **)(parent + 0x28);
    for (int i = 0; link && link != sentinel && i < 64; i++) {
        uint8_t *child = link - 8;
        if (aspect_ui_parent(child) != parent) return NULL;
        if (aspect_ui_named(child, name)) return child;
        link = *(uint8_t **)(child + 0x10);
    }
    return NULL;
}
static uint8_t *aspect_ui_map_cut(uint8_t *pane) {
    if (!aspect_ui_named(pane, "N_InOut_00") && !aspect_ui_named(pane, "N_InOut_01")) return NULL;
    uint8_t *root = aspect_ui_parent(pane);
    if (!aspect_ui_named(root, "RootPane")) return NULL;
    uint8_t *inout = aspect_ui_child(root, "N_InOut_00");
    if (!aspect_ui_child(inout, "N_Cut_01")) return NULL;
    return aspect_ui_child(inout, "N_Cut_00");
}
static int aspect_ui_map_collapsed(uint8_t *cut) {
    if (!cut) return 0;
    float size[2]; memcpy(size, cut + 0x50, sizeof size);
    return fabsf(size[0] - 166) < 2 && fabsf(size[1] - 166) < 2;
}
// Move containers once so full/partial hearts and every map ornament retain
// their authored spacing. Map identity stays known while the Slate is open,
// allowing its native position to be restored immediately on expansion.
static int aspect_ui_hud_anchor(uint8_t *pane) {
    uint8_t *parent = aspect_ui_parent(pane), *all = aspect_ui_parent(parent);
    if (aspect_ui_named(pane, "Pa_HeartGauge_00") && aspect_ui_named(parent, "N_State_00") &&
        aspect_ui_named(all, "N_All_00") && aspect_ui_named(aspect_ui_parent(all), "RootPane")) return -1;
    if (aspect_ui_named(parent, "N_All_00") && aspect_ui_named(all, "RootPane")) {
        if (aspect_ui_named(pane,"N_MainAll_00")) return 3;
        const char *names[] = {"Pa_Sensor_00", "Pa_SoundGauge_00", "Pa_TempMeter_00", "Pa_Weather_00", "Pa_Time_00"};
        for (unsigned i=0;i<sizeof names/sizeof *names;i++) if (aspect_ui_named(pane,names[i])) return 1;
    }
    return aspect_ui_map_cut(pane) ? 2 : 0;
}
static int aspect_ui_hud_pane(uint8_t *pane) {
    float region[4]; int seated=dm_aspect_region(1,region);
    for (int i=0; pane && i<64; i++,pane=aspect_ui_parent(pane)) {
        int anchor=aspect_ui_hud_anchor(pane);
        if (anchor==3) {
            if (!dm_botw_touch_hud_active()) continue;
            if (seated) return 5;
            if (dm_aspect_hud_y_scale()==1) continue;
        }
        if (anchor==1 && aspect_ui_named(pane,"Pa_Weather_00") && (seated || dm_aspect_hud_y_scale()<1)) return 3;
        if (anchor==1 && seated) return 4;
        if (anchor && (anchor!=2 || aspect_ui_map_collapsed(aspect_ui_map_cut(pane)))) return anchor == 2 ? 2 : 1;
    }
    return 0;
}
static int aspect_ui_title_shade(uint8_t *pane) {
    if (!pane || !(aspect_ui_named(pane, "FBLayout_00") || aspect_ui_named(pane, "FBLayout_01") ||
                   aspect_ui_named(pane, "FBLayout_02") || aspect_ui_named(pane, "FBLayout_03"))) return 0;
    float size[2]; memcpy(size, pane + 0x50, sizeof size);
    if (!isfinite(size[0]) || size[0] < 480 || size[1] != 720) return 0;
    // Title_00 has two pairs of right-anchored gradient panels. Each pair
    // covers [-320,160] and [160,640] and contains no menu controls.
    uint8_t *p = *(uint8_t **)(pane + 0x18);
    if (!aspect_ui_named(p, "N_Base_00") && !aspect_ui_named(p, "N_Base_01")) return 0;
    p = *(uint8_t **)(p + 0x18); if (!aspect_ui_named(p, "N_All_00")) return 0;
    p = *(uint8_t **)(p + 0x18); if (!aspect_ui_named(p, "N_InOut_00")) return 0;
    p = *(uint8_t **)(p + 0x18); return aspect_ui_named(p, "RootPane");
}
// Keep the offscreen source artwork native; only its visible composition and
// glow/blur quads use proportional cover sizing.
static int aspect_ui_title_art(uint8_t *pane) {
    if (!pane) return 0;
    const char *name = (const char *)pane + 0xb8;
    if (strncmp(name, "TitleBG", 7) && strncmp(name, "P_MainV", 7) && strncmp(name, "P_Image", 7) &&
        strncmp(name, "P_Light_", 8) && strncmp(name, "P_Blur_", 7)) return 0;
    uint8_t *group = *(uint8_t **)(pane + 0x18);
    if (group && !strncmp((char *)group + 0xb8, "Null_", 5)) group = *(uint8_t **)(group + 0x18);
    static const char *const groups[] = {
        "N_0_MainV_00", "N_1_Arrow_00", "N_2_Horse_00", "N_3_Gake_00", "N_4_SenakaLink_00",
        "N_5_Gardian_00", "N_6_MainVE_00", "N_0_00", "N_1_00", "N_2_00", "N_3_00", "N_4_00", "N_5_00", "N_6_00"
    };
    int known = 0;
    for (unsigned i = 0; i < sizeof groups / sizeof *groups; i++) known |= aspect_ui_named(group, groups[i]);
    if (!known) return 0;
    uint8_t *owner = *(uint8_t **)(group + 0x18);
    int role = aspect_ui_named(owner, "N_InOut_00") ? 1 : aspect_ui_named(owner, "N_Capture_00") ? 2 : 0;
    return role && aspect_ui_named(*(uint8_t **)(owner + 0x18), "RootPane") ? role : 0;
}
static int aspect_ui_loading_fill(uint8_t *pane) {
    // Fade_00 projects its animated gradient onto this panel. Stretch the
    // completed native draw, keeping its geometry and texture projection in
    // the same coordinate system throughout the cream/black wipe.
    if (aspect_ui_named(pane, "P_Capture_00") && aspect_ui_named(aspect_ui_parent(pane), "N_LogoInOut_00") &&
        aspect_ui_named(aspect_ui_parent(aspect_ui_parent(pane)), "RootPane")) {
        float size[2]; memcpy(size, pane + 0x50, sizeof size);
        if (size[0] >= 1280 && fabsf(size[1] - 275) < .01f) return 1;
    }
    return 0;
}
static int aspect_ui_background_pane(uint8_t *pane) {
    if (aspect_ui_title_shade(pane) || aspect_ui_title_art(pane) || aspect_ui_loading_fill(pane)) return 1;
    if (!pane || !aspect_ui_background((char *)pane + 0xb8)) return 0;
    float width, height;
    memcpy(&width, pane + 0x50, 4); memcpy(&height, pane + 0x54, 4);
    if (!isfinite(width) || !isfinite(height) || width < 1280 || height <= 0) return 0;
    uintptr_t child; memcpy(&child, pane + 0x28, sizeof child);
    return !child || child == (uintptr_t)pane + 0x20;
}
static int aspect_ui_loading_background(uint8_t *pane) {
    if (aspect_ui_loading_fill(pane)) return 1;
    if (!pane || !aspect_ui_background((const char *)pane+0xb8)) return 0;
    // Only Fade's background leaves join the cream fill on narrow displays.
    for (int depth=0;pane && depth<64;depth++,pane=aspect_ui_parent(pane))
        if (aspect_ui_named(pane,"RootPane")) return aspect_ui_child(pane,"N_LogoInOut_00") != NULL;
    return 0;
}
static _Thread_local int g_ui_background_drawing, g_ui_hud_drawing;
int dm_aspect_ui_background_drawing(void) { return g_ui_background_drawing; }
int dm_aspect_ui_hud_drawing(void) { return g_ui_hud_drawing; } // 1 hearts/edge HUD, 2 map, 3 weather, 4 dock gauges, 5 dock equipment
static void aspect_ui_draw(const uint64_t *regs) {
    // x21 is Pane::Draw's saved this across the DrawSelf virtual call.
    uint8_t *pane=(uint8_t *)(uintptr_t)regs[21];
    float ratio=dm_aspect_ratio();
    g_ui_background_drawing = ratio > GAME_ASPECT && aspect_ui_background_pane(pane);
    if ((ratio > GAME_ASPECT && aspect_ui_loading_fill(pane)) ||
        (ratio > 0 && ratio < GAME_ASPECT && aspect_ui_loading_background(pane))) g_ui_background_drawing=2;
    float region[4];
    g_ui_hud_drawing = ratio > 0 && (ratio != GAME_ASPECT || dm_aspect_region(1,region)) ? aspect_ui_hud_pane(pane) : 0;
    dm_botw_rune_icon_draw_begin((uint8_t *)(uintptr_t)regs[21]);
}
static void aspect_ui_draw_end(const uint64_t *regs) { (void)regs; g_ui_background_drawing = g_ui_hud_drawing = 0; dm_botw_rune_icon_draw_end(); }
void dm_aspect_ui_pane(uint8_t *pane) {
    if (!pane || strcmp(DM_GAME_ID, "01007EF00011E000") || !dm_aspect_native()) return;
    if (aspect_ui_loading_fill(pane)) return;
    int hud = aspect_ui_hud_anchor(pane);
    int title_shade = aspect_ui_title_shade(pane);
    int title_right = title_shade && (aspect_ui_named(pane, "FBLayout_02") || aspect_ui_named(pane, "FBLayout_03"));
    if (title_shade && !title_right) return;
    int title_art = aspect_ui_title_art(pane);
    if (title_art == 2) return;
    // A background must not resize a container that owns foreground content.
    if (!hud && !aspect_ui_background_pane(pane)) return;
    float width, height, x, y, scale_x, scale_y;
    memcpy(&width, pane + 0x50, 4); memcpy(&height, pane + 0x54, 4);
    memcpy(&x, pane + 0x30, 4); memcpy(&y, pane + 0x34, 4);
    memcpy(&scale_x,pane+0x48,4); memcpy(&scale_y,pane+0x4c,4);
    aspect_ui_width key = {.pane = (uintptr_t)pane};
    pthread_mutex_lock(&g_ui_width_mu);
    aspect_ui_width **found = tfind(&key, &g_ui_widths, aspect_ui_width_order);
    float wide = fmaxf(1, dm_aspect_ratio() / GAME_ASPECT);
    float region[4]; int seated=dm_aspect_region(1,region);
    float ratio=hud==-1 ? dm_aspect_ratio() : dm_aspect_control_ratio();
    float hud_y=ratio>0 && ratio<GAME_ASPECT ? ratio/GAME_ASPECT : 1;
    float gain=ratio>0 && ratio<GAME_ASPECT ? GAME_ASPECT*fminf(1,1/ratio) : 1;
    int dock=seated && (hud==1 || hud==2);
    int narrow = hud && hud_y<1 && (hud!=3 || dm_botw_touch_hud_active());
    if (hud==2 && !aspect_ui_map_collapsed(aspect_ui_map_cut(pane))) narrow=0;
    if (hud==2 && !aspect_ui_map_collapsed(aspect_ui_map_cut(pane))) dock=0;
    float xscale=dock ? dm_aspect_map_gain() : narrow ? gain : 1;
    float yscale=(dock || narrow) ? hud_y*xscale : 1;
    // Weather's animated pictures do not inherit scale like the flat panes.
    // Leave the component's model geometry intact and resize the whole draw
    // in projection, so its pictures and background keep the same proportions.
    if (hud==1 && aspect_ui_named(pane,"Pa_Weather_00")) xscale=yscale=1;
    if (!found && wide == 1 && !narrow && !dock && hud != -1) { pthread_mutex_unlock(&g_ui_width_mu); return; }
    if (!found) {
        aspect_ui_width *entry = calloc(1, sizeof *entry);
        if (!entry) die("[RED] aspect: cannot allocate background pane state");
        *entry = key;
        found = tsearch(entry, &g_ui_widths, aspect_ui_width_order);
        if (!found) die("[RED] aspect: cannot register background pane state");
    }
    aspect_ui_width *entry = *found;
    uintptr_t parent, type;
    memcpy(&parent, pane + 0x18, sizeof parent); memcpy(&type, pane, sizeof type);
    if (entry->parent != parent || entry->type != type || memcmp(entry->name, pane + 0xb8, 16)) {
        entry->parent = parent; entry->type = type; memcpy(entry->name, pane + 0xb8, 16);
        entry->native_width = width; entry->native_height = height; entry->native_x = x; entry->native_y = y;
        entry->native_scale_x=scale_x; entry->native_scale_y=scale_y;
    }
    if (width != entry->written_width) entry->native_width = width;
    if (height != entry->written_height) entry->native_height = height;
    if (x != entry->written_x) entry->native_x = x;
    if (y != entry->written_y) entry->native_y = y;
    if (scale_x != entry->written_scale_x) entry->native_scale_x=scale_x;
    if (scale_y != entry->written_scale_y) entry->native_scale_y=scale_y;
    entry->written_width = entry->native_width * (hud ? 1 : wide);
    // Title illustrations cover the display without distorting their artwork;
    // flat fills and Windows extend horizontally with their edge sizes intact.
    int cover = !hud && title_art == 1;
    entry->written_height = entry->native_height * (cover ? wide : 1);
    entry->written_x = entry->native_x*(hud==3 ? 1 : xscale);
    entry->written_y = entry->native_y*(hud==3 ? 1 : yscale);
    entry->written_scale_x=entry->native_scale_x*xscale;
    entry->written_scale_y=entry->native_scale_y*yscale;
    if (cover) { entry->written_x *= wide; entry->written_y *= wide; }
    // Landscape's horizontal safe inset reserves the notch at mid-height.
    // Hearts sit above it, with their own authored top/corner padding; adding
    // the entire inset here leaves an unnecessary gap on iPhone.
    if (hud == -1) entry->written_x += DM_TP_BOTW_EDGE_EXTRA*dm_aspect_ui_point_scale() - fmaxf(0, 360 * dm_aspect_ratio() - 640);
    if (hud == -1 && narrow) {
        entry->written_x += 640*(xscale-1);
        entry->written_y += 360*(1-yscale)-atomic_load(&g_hud_safe_top);
    }
    // AppMap's ScissorPane::Draw rejects clips outside its native 16:9
    // target before submitting draws. Anchor that subtree during GPU replay.
    else if (hud == 1 && !dm_botw_touch_hud_active() && !seated)
        entry->written_x += dm_aspect_hud_offset(1);
    if (title_right) {
        // The native origin is the right edge. Extending width and moving that
        // edge together preserves the seam with the unchanged left panel.
        float margin = 640 * (wide - 1);
        entry->written_width = entry->native_width + margin;
        entry->written_x += margin;
    }
    if (width != entry->written_width || height != entry->written_height ||
        ((hud || title_right || cover) && x != entry->written_x) ||
        ((hud || cover) && y != entry->written_y) ||
        (hud && (scale_x != entry->written_scale_x || scale_y != entry->written_scale_y))) {
        memcpy(pane + 0x50, &entry->written_width, 4);
        memcpy(pane + 0x54, &entry->written_height, 4);
        if (hud || title_right || cover) memcpy(pane + 0x30, &entry->written_x, 4);
        if (hud || cover) memcpy(pane + 0x34, &entry->written_y, 4);
        if (hud) { memcpy(pane+0x48,&entry->written_scale_x,4); memcpy(pane+0x4c,&entry->written_scale_y,4); }
        pane[0x58] |= 0x10;
    }
    pthread_mutex_unlock(&g_ui_width_mu);
}

// After relocation and gate registration, before any guest code runs. Unsupported builds and stale rewrites fail before rendering.
void dm_aspect_install(void) {
    if (!dm_aspect_native()) return;
    char build[33]; unsigned long long a, b, c, d, e;
    if (sscanf(DM_GAME_CAMERA_ASPECT, "%32[0-9a-f]:%llx:%llx:%llx:%llx:%llx", build, &a, &b, &c, &d, &e) != 6)
        die("[RED] aspect: missing or invalid camera_aspect profile");
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_main = &g_mod[i];
    if (!g_main || strcmp(build, g_main->build_id)) die("[RED] aspect: camera_aspect requires main build %s (loaded %s)", build, dm_main_build());
    if (a + sizeof(void *) > g_main->size || c + sizeof(void *) > g_main->size || b > 0x10000 || d > 0x10000 || e > 0x10000)
        die("[RED] aspect: camera_aspect offsets out of range");
    if (!gate_obs_present(OBS_ASPECT_PROJECTION)) die("[RED] aspect: projection gate missing; rewrite main with the current patch_nso.py");
    g_single_off = a; g_proj_off = b; g_vt_off = c; g_field_off = d; g_dirty_off = e;
    gate_obs_read_set(OBS_ASPECT_PROJECTION, aspect_projection);
    if (*DM_GAME_CAMERA_WORLD_ASPECT) {
        if (sscanf(DM_GAME_CAMERA_WORLD_ASPECT, "%u:0x%llx", &g_world_reg, &g_world_projection) != 2 || g_world_reg > 28 || g_world_projection > 0x10000)
            die("[RED] aspect: invalid camera_world_aspect profile");
        if (!gate_obs_present(OBS_ASPECT_WORLD_PROJECTION)) die("[RED] aspect: world-UI projection gate missing; rewrite main with the current patch_nso.py");
        gate_obs_read_set(OBS_ASPECT_WORLD_PROJECTION, aspect_world_projection);
    }
    if (*DM_GAME_CAMERA_UI_ASPECT) {
        unsigned long long source, projection, fovy;
        if (sscanf(DM_GAME_CAMERA_UI_ASPECT, "%u:%llx:%llx:%llx", &g_ui_reg, &source, &projection, &fovy) != 4 || g_ui_reg > 28 || source > 0x10000 || projection > 0x10000 || fovy > 0x10000)
            die("[RED] aspect: invalid camera_ui_aspect profile");
        if (!gate_obs_present(OBS_ASPECT_UI_CAMERA)) die("[RED] aspect: UI camera gate missing; rewrite main with the current patch_nso.py");
        g_ui_source = source; g_ui_projection = projection; g_ui_fovy = fovy;
        gate_obs_read_set(OBS_ASPECT_UI_CAMERA, aspect_ui_camera);
    }
    if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
        if (!gate_obs_present(OBS_BOTW_UI_DRAW) || !gate_obs_present(OBS_BOTW_UI_DRAW_END))
            die("[RED] aspect: UI background draw gates missing; rewrite main with the current patches.py");
        gate_obs_read_set(OBS_BOTW_UI_DRAW, aspect_ui_draw);
        gate_obs_read_set(OBS_BOTW_UI_DRAW_END, aspect_ui_draw_end);
    }
    LOG("aspect: projection gate installed for main build %s", build);
}
