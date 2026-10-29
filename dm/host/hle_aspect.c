// Native aspect: only publish display geometry from the front end. The game's projection-update gate applies it on the
// guest thread, before the matrix is calculated. UI content remains centered at
// 16:9; native full-width background panes can extend to the display edges.
#include "hle.h"
#include "botw_rune_icon.h"
#include <ctype.h>
#include <math.h>
#include <search.h>
#include <stdatomic.h>

static pthread_once_t g_config_once = PTHREAD_ONCE_INIT;
static int g_on;
static float g_custom;
static _Atomic float g_screen = 16.0f / 9.0f;
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
float dm_aspect_ratio(void) { return dm_aspect_native() ? (g_custom ? g_custom : atomic_load(&g_screen)) : 0; }
void dm_aspect_set_display(float ratio) {
    if (!isfinite(ratio) || ratio <= 0) die("[RED] invalid display aspect %g", ratio);
    atomic_store(&g_screen, ratio);
}

// The centered, undistorted UI region, including a custom aspect's bars. Touch input uses the same coordinates as UI replay.
void dm_aspect_touch_rect(float w, float h, float rect[4]) {
    float cw = w, ch = h, cr = dm_aspect_native() ? dm_aspect_custom_ratio() : 0;
    if (cr > 0) { if (cw / ch > cr) cw = ch * cr; else ch = cw / cr; }
    if (cw / ch > GAME_ASPECT) cw = ch * GAME_ASPECT; else ch = cw / GAME_ASPECT;
    rect[0] = (w - cw) / 2; rect[1] = (h - ch) / 2; rect[2] = cw; rect[3] = ch;
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
static int aspect_ui_background_pane(uint8_t *pane) {
    if (aspect_ui_title_shade(pane) || aspect_ui_title_art(pane)) return 1;
    if (!pane || !aspect_ui_background((char *)pane + 0xb8)) return 0;
    float width, height;
    memcpy(&width, pane + 0x50, 4); memcpy(&height, pane + 0x54, 4);
    if (!isfinite(width) || !isfinite(height) || width < 1280 || height <= 0) return 0;
    uintptr_t child; memcpy(&child, pane + 0x28, sizeof child);
    return !child || child == (uintptr_t)pane + 0x20;
}
static _Thread_local int g_ui_background_drawing;
int dm_aspect_ui_background_drawing(void) { return g_ui_background_drawing; }
static void aspect_ui_draw(const uint64_t *regs) {
    // x21 is Pane::Draw's saved this across the DrawSelf virtual call.
    g_ui_background_drawing = dm_aspect_ratio() > GAME_ASPECT &&
        aspect_ui_background_pane((uint8_t *)(uintptr_t)regs[21]);
    dm_botw_rune_icon_draw_begin((uint8_t *)(uintptr_t)regs[21]);
}
static void aspect_ui_draw_end(const uint64_t *regs) { (void)regs; g_ui_background_drawing = 0; dm_botw_rune_icon_draw_end(); }
void dm_aspect_ui_pane(uint8_t *pane) {
    if (!pane || strcmp(DM_GAME_ID, "01007EF00011E000") || !dm_aspect_native()) return;
    int title_shade = aspect_ui_title_shade(pane);
    int title_right = title_shade && (aspect_ui_named(pane, "FBLayout_02") || aspect_ui_named(pane, "FBLayout_03"));
    if (title_shade && !title_right) return;
    int title_art = aspect_ui_title_art(pane);
    if (title_art == 2) return;
    // A background must not resize a container that owns foreground content.
    if (!aspect_ui_background_pane(pane)) return;
    float width, height, x, y;
    memcpy(&width, pane + 0x50, 4); memcpy(&height, pane + 0x54, 4);
    memcpy(&x, pane + 0x30, 4); memcpy(&y, pane + 0x34, 4);
    aspect_ui_width key = {.pane = (uintptr_t)pane};
    pthread_mutex_lock(&g_ui_width_mu);
    aspect_ui_width **found = tfind(&key, &g_ui_widths, aspect_ui_width_order);
    float wide = fmaxf(1, dm_aspect_ratio() / GAME_ASPECT);
    if (!found && wide == 1) { pthread_mutex_unlock(&g_ui_width_mu); return; }
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
    }
    if (width != entry->written_width) entry->native_width = width;
    if (height != entry->written_height) entry->native_height = height;
    if (x != entry->written_x) entry->native_x = x;
    if (y != entry->written_y) entry->native_y = y;
    entry->written_width = entry->native_width * wide;
    // Title illustrations cover the display without distorting their artwork;
    // flat fills and Windows extend horizontally with their edge sizes intact.
    int cover = title_art == 1;
    entry->written_height = entry->native_height * (cover ? wide : 1);
    entry->written_x = entry->native_x;
    entry->written_y = entry->native_y;
    if (cover) { entry->written_x *= wide; entry->written_y *= wide; }
    if (title_right) {
        // The native origin is the right edge. Extending width and moving that
        // edge together preserves the seam with the unchanged left panel.
        float margin = 640 * (wide - 1);
        entry->written_width = entry->native_width + margin;
        entry->written_x += margin;
    }
    if (width != entry->written_width || height != entry->written_height ||
        ((title_right || cover) && x != entry->written_x) || (cover && y != entry->written_y)) {
        memcpy(pane + 0x50, &entry->written_width, 4);
        memcpy(pane + 0x54, &entry->written_height, 4);
        if (title_right || cover) memcpy(pane + 0x30, &entry->written_x, 4);
        if (cover) memcpy(pane + 0x34, &entry->written_y, 4);
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
