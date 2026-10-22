// Native aspect: only publish display geometry from the front end. The game's projection-update gate applies it on the
// guest thread, before the matrix is calculated. UI replay corrects the complete layout into a centered 16:9 region.
#include "hle.h"
#include <ctype.h>
#include <math.h>
#include <stdatomic.h>

static pthread_once_t g_config_once = PTHREAD_ONCE_INIT;
static int g_on;
static float g_custom;
static _Atomic float g_screen = 16.0f / 9.0f;
static module_t *g_main;
static uint64_t g_single_off, g_proj_off, g_vt_off, g_field_off, g_dirty_off;
static unsigned g_ui_reg; static uint64_t g_ui_source, g_ui_projection, g_ui_fovy;
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

static void aspect_projection(const uint64_t *regs) {
    uint8_t *singleton = *(uint8_t **)(g_main->base + g_single_off);
    uint8_t *proj = (uint8_t *)regs[0];
    if (!singleton || proj != singleton + g_proj_off) return;
    if (*(uint64_t *)proj != (uint64_t)(g_main->base + g_vt_off)) die("[RED] aspect: main camera projection vtable mismatch");
    float want = dm_aspect_ratio(), now;
    memcpy(&now, proj + g_field_off, sizeof now);
    if (now != want) { memcpy(proj + g_field_off, &want, sizeof want); proj[g_dirty_off] = 1; }
    static float logged;
    if (logged != want) { logged = want; LOG("aspect: camera %.4f at projection update; centered 16:9 UI", want); }
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
    gate_obs_set(OBS_ASPECT_PROJECTION, aspect_projection);
    if (*DM_GAME_CAMERA_UI_ASPECT) {
        unsigned long long source, projection, fovy;
        if (sscanf(DM_GAME_CAMERA_UI_ASPECT, "%u:%llx:%llx:%llx", &g_ui_reg, &source, &projection, &fovy) != 4 || g_ui_reg > 28 || source > 0x10000 || projection > 0x10000 || fovy > 0x10000)
            die("[RED] aspect: invalid camera_ui_aspect profile");
        if (!gate_obs_present(OBS_ASPECT_UI_CAMERA)) die("[RED] aspect: UI camera gate missing; rewrite main with the current patch_nso.py");
        g_ui_source = source; g_ui_projection = projection; g_ui_fovy = fovy;
        gate_obs_set(OBS_ASPECT_UI_CAMERA, aspect_ui_camera);
    }
    LOG("aspect: projection gate installed for main build %s", build);
}
