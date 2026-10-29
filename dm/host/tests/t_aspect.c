// Current host implementation: display changes must affect the camera only at its guest projection gate.
#include "../hle.h"
// This fixture describes the camera under test, independent of the profile used to build the rest of the host tests.
#undef DM_GAME_ASPECT_NATIVE
#undef DM_GAME_CAMERA_ASPECT
#undef DM_GAME_CAMERA_UI_ASPECT
#define DM_GAME_ASPECT_NATIVE 1
#define DM_GAME_CAMERA_ASPECT "cd57b23fa4bbad65803d9788c01821ee:0x1e39d10:0x38:0x1d05380:0xb0:0x8"
#define DM_GAME_CAMERA_UI_ASPECT "19:0xa0:0xa8:0x74"
#define DM_GAME_CAMERA_WORLD_ASPECT "19:0x41c0"
#include "../hle_aspect.c"
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
static module_t test_modules[8];
module_t *g_mod = test_modules; int g_nmod = 1;
static void (*callback)(const uint64_t *);
static void (*ui_callback)(const uint64_t *);
static void (*screen_callback)(const uint64_t *);
static void (*draw_callback)(const uint64_t *), (*draw_end_callback)(const uint64_t *);
void dm_botw_rune_icon_draw_begin(uint8_t *pane) { (void)pane; }
void dm_botw_rune_icon_draw_end(void) {}
static int test_touch_active;
int dm_botw_touch_hud_active(void) { return test_touch_active; }
static int have_gate = 1;
void gate_obs_read_set(int id, void (*fn)(const uint64_t *)) {
    if (id == OBS_ASPECT_PROJECTION) callback = fn;
    else if (id == OBS_ASPECT_UI_CAMERA) ui_callback = fn;
    else if (id == OBS_BOTW_UI_DRAW) draw_callback = fn;
    else if (id == OBS_BOTW_UI_DRAW_END) draw_end_callback = fn;
    else { assert(id == OBS_ASPECT_WORLD_PROJECTION); screen_callback = fn; }
}
int gate_obs_present(int id) { return (id == OBS_ASPECT_PROJECTION || id == OBS_ASPECT_UI_CAMERA || id == OBS_ASPECT_WORLD_PROJECTION || id == OBS_BOTW_UI_DRAW || id == OBS_BOTW_UI_DRAW_END) && have_gate && !(id == OBS_ASPECT_UI_CAMERA && have_gate == 2) && !(id == OBS_ASPECT_WORLD_PROJECTION && have_gate == 3); }
static void pane_init(uint8_t *p, const char *name, float x, float w, float h) {
    memset(p,0,0x100); strcpy((char *)p+0xb8,name);
    *(float *)(p+0x30)=x; *(float *)(p+0x50)=w; *(float *)(p+0x54)=h;
}
static void pane_child(uint8_t *parent, uint8_t *child) {
    uint8_t *next=*(uint8_t **)(parent+0x28);
    *(uint8_t **)(child+0x10)=next?next:parent+0x20;
    *(uint8_t **)(child+0x18)=parent; *(uint8_t **)(parent+0x28)=child+8;
}
static void test_edge_hud(void) {
    uint8_t root[0x100],all[0x100],state[0x100],heart[0x100],glyph[0x100],sensor[0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
    pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
    pane_init(heart,"Pa_HeartGauge_00",-434,312,50); pane_child(state,heart);
    pane_init(glyph,"P_Heart_00",20,32,32); pane_child(heart,glyph);
    pane_init(sensor,"Pa_Sensor_00",392,582,78); pane_child(all,sensor);
    dm_aspect_set_display(21.f/10); dm_aspect_set_safe_area(1512,720,0,0);
    for (int i=0;i<20;i++) { dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor); }
    assert(fabsf(*(float *)(heart+0x30)+550)<.001f && *(float *)(heart+0x50)==312);
    assert(fabsf(*(float *)(sensor+0x30)-508)<.001f && *(float *)(sensor+0x50)==582);
    dm_aspect_ui_pane(glyph); assert(*(float *)(glyph+0x30)==20 && *(float *)(glyph+0x50)==32);
    uint64_t regs[31]={0}; regs[21]=(uintptr_t)glyph; draw_callback(regs);
    assert(dm_aspect_ui_hud_drawing() && !dm_aspect_ui_background_drawing());
    draw_end_callback(regs); assert(!dm_aspect_ui_hud_drawing());
    test_touch_active=1; dm_aspect_ui_pane(sensor); assert(*(float *)(sensor+0x30)==392);
    test_touch_active=0; dm_aspect_ui_pane(sensor); assert(fabsf(*(float *)(sensor+0x30)-508)<.001f);
    uint8_t map[0x100],inout[0x100],ornaments[0x100],cut[0x100],sibling[0x100],picture[0x100];
    pane_init(map,"RootPane",0,1280,720); pane_init(inout,"N_InOut_00",0,30,30); pane_child(map,inout);
    pane_init(ornaments,"N_InOut_01",0,30,30); pane_child(map,ornaments);
    pane_init(cut,"N_Cut_00",0,166,166); pane_child(inout,cut);
    pane_init(sibling,"N_Cut_01",0,1500,1500); pane_child(inout,sibling);
    pane_init(picture,"P_MapCapture_00",0,192,192); pane_child(sibling,picture);
    dm_aspect_ui_pane(inout); dm_aspect_ui_pane(ornaments);
    assert(*(float *)(inout+0x30)==0 && *(float *)(ornaments+0x30)==0);
    regs[21]=(uintptr_t)picture; draw_callback(regs); assert(dm_aspect_ui_hud_drawing()==2); draw_end_callback(regs);
    *(float *)(cut+0x50)=1500; *(float *)(cut+0x54)=720;
    dm_aspect_ui_pane(inout); dm_aspect_ui_pane(ornaments);
    assert(*(float *)(inout+0x30)==0 && *(float *)(ornaments+0x30)==0);
    draw_callback(regs); assert(!dm_aspect_ui_hud_drawing()); draw_end_callback(regs);
    dm_aspect_set_safe_area(1512,720,40,20); dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor);
    assert(fabsf(*(float *)(heart+0x30)+550)<.001f && fabsf(*(float *)(sensor+0x30)-488)<.001f);
    float rect[4]; dm_aspect_hud_rect(1512,720,rect);
    assert(fabsf(rect[0]-40)<.001f && fabsf(rect[2]-1452)<.001f && rect[1]==0 && rect[3]==720);
    dm_aspect_touch_rect(1512,720,rect); assert(fabsf(rect[0]-116)<.001f && rect[2]==1280);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor);
    assert(*(float *)(heart+0x30)==-434 && *(float *)(sensor+0x30)==392);
    dm_aspect_set_safe_area(1280,720,0,0);
    uint8_t fade[0x100],logo[0x100],upper[0x100];
    pane_init(fade,"RootPane",0,1280,720); pane_init(logo,"N_LogoInOut_00",0,30,40); pane_child(fade,logo);
    pane_init(upper,"P_Capture_00",0,1280,275); pane_child(logo,upper);
    dm_aspect_set_display(21.f/10); dm_aspect_ui_pane(upper);
    assert(*(float *)(upper+0x50)==1280 && *(float *)(upper+0x54)==275);
    regs[21]=(uintptr_t)upper; draw_callback(regs); assert(dm_aspect_ui_background_drawing()==2); draw_end_callback(regs);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(upper); assert(*(float *)(upper+0x50)==1280);
}
static void failure(const char *value, int bad_build, int stale) {
    pid_t pid = fork(); assert(pid >= 0);
    if (!pid) {
        freopen("/dev/null", "w", stderr);
        if (value) setenv("DM_ASPECT_RATIO", value, 1);
        if (bad_build) strcpy(g_mod[0].build_id, "00000000000000000000000000000000");
        if (stale) have_gate = stale == 1 ? 0 : stale == 2 ? 2 : 3;
        dm_aspect_install(); _exit(0);
    }
    int status; assert(waitpid(pid, &status, 0) == pid);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}
int main(void) {
    unsetenv("DM_ASPECT"); unsetenv("DM_ASPECT_RATIO");
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].size = 0x2000000; g_mod[0].base = calloc(1, g_mod[0].size); assert(g_mod[0].base);
    failure("20:0", 0, 0); failure("nan", 0, 0); failure("20:9junk", 0, 0); failure("2.2x", 0, 0);
    failure("20:9", 1, 0); failure("20:9", 0, 1); failure("20:9", 0, 2); failure("20:9", 0, 3);
    dm_aspect_install(); assert(callback && screen_callback);
    uint8_t object[512] = {0}; uint8_t *proj = object + 0x38;
    *(void **)(g_mod[0].base + g_single_off) = object;
    *(uintptr_t *)proj = (uintptr_t)(g_mod[0].base + g_vt_off);
    float *aspect = (float *)(proj + g_field_off); *aspect = GAME_ASPECT;
    uint64_t regs[31] = {(uint64_t)proj};
    dm_aspect_set_display(20.f / 9); assert(*aspect == GAME_ASPECT); // no asynchronous guest writes
    callback(regs); assert(*aspect == 20.f / 9 && proj[g_dirty_off]);
    proj[g_dirty_off] = 0; *aspect = GAME_ASPECT; callback(regs); assert(*aspect == 20.f / 9 && proj[g_dirty_off]);
    dm_aspect_set_display(GAME_ASPECT); callback(regs); assert(*aspect == GAME_ASPECT);
    dm_aspect_set_display(4.f / 3); callback(regs); assert(*aspect == 4.f / 3);
    *aspect = 2.4f; dm_aspect_set_display(GAME_ASPECT); callback(regs); assert(*aspect == GAME_ASPECT);
    uint8_t other[512] = {0}; regs[0] = (uint64_t)other; callback(regs); assert(!other[g_dirty_off]);
    // The world-UI screen copies its 16:9 source into this clone each frame. Correct every reset
    // immediately after the copy, marking the matrix dirty only when the target aspect differs.
    uint8_t screen[0x41c0 + 512] = {0}, *clone = screen + 0x41c0;
    *(uintptr_t *)clone = (uintptr_t)(g_mod[0].base + g_vt_off);
    float *clone_aspect = (float *)(clone + g_field_off);
    regs[0] = (uint64_t)clone; regs[19] = (uint64_t)screen;
    const float world_ratios[] = {20.f/9, GAME_ASPECT, 4.f/3, 20.f/9};
    for (unsigned i = 0; i < sizeof(world_ratios)/sizeof(world_ratios[0]); i++) {
        dm_aspect_set_display(world_ratios[i]);
        for (int frame = 0; frame < 3; frame++) {
            *clone_aspect = GAME_ASPECT; clone[g_dirty_off] = 0; // game recopied the 16:9 lens
            screen_callback(regs);
            assert(*clone_aspect == world_ratios[i]);
            assert(clone[g_dirty_off] == (world_ratios[i] != GAME_ASPECT));
        }
    }
    regs[0] = (uint64_t)other; callback(regs); assert(!other[g_dirty_off]);
    float r[4]; dm_aspect_touch_rect(1600, 720, r); assert(r[0] == 160 && r[1] == 0 && r[2] == 1280 && r[3] == 720);
    // The UI camera's source lens is rebuilt by the game on every update. Apply the same mapping as a 16:9 UI rectangle:
    // wide screens shrink clip x; narrow screens shrink clip y, including the optical center, without accumulating scaling.
    uint8_t owner[256] = {0}, source[256] = {0};
    *(void **)(owner + 0xa0) = source; *(void **)(owner + 0xa8) = proj; regs[19] = (uint64_t)owner;
    const float ratios[] = {20.f/9, 4.f/3, 16.f/9};
    for (int i=0; i<3; i++) for (int repeat=0; repeat<2; repeat++) {
        float original[3] = {0.5235988f, -0.295f, -0.005f};
        memcpy(source + 0x74, original, sizeof original); *aspect = GAME_ASPECT;
        dm_aspect_set_display(ratios[i]); ui_callback(regs);
        float lens[3]; memcpy(lens, source + 0x74, sizeof lens);
        float sx=fminf(1, GAME_ASPECT/ratios[i]), sy=fminf(1, ratios[i]/GAME_ASPECT);
        assert(*aspect == ratios[i]);
        assert(fabsf(tanf(original[0]/2)*GAME_ASPECT/(tanf(lens[0]/2)*ratios[i]) - sx) < 1e-6f);
        assert(fabsf(tanf(original[0]/2)/tanf(lens[0]/2) - sy) < 1e-6f);
        assert(fabsf(lens[1] - original[1]*sx) < 1e-6f && fabsf(lens[2] - original[2]*sy) < 1e-6f);
    }
    // Full-width backgrounds extend independently of any touch/controller state.
    // Repeated Calculate callbacks and display resizing must not multiply widths.
    uint8_t bg[0x100] = {0};
    strcpy((char *)bg + 0xb8, "P_BG_03");
    *(float *)(bg + 0x50) = 1280; *(float *)(bg + 0x54) = 720;
    *(uintptr_t *)(bg + 0x28) = (uintptr_t)bg + 0x20;
    dm_aspect_set_display(21.f/10);
    for (int i = 0; i < 20; i++) dm_aspect_ui_pane(bg);
    assert(fabsf(*(float *)(bg + 0x50) - 1512) < 0.001f);
    regs[21] = (uintptr_t)bg; draw_callback(regs);
    assert(dm_aspect_ui_background_drawing());
    draw_end_callback(regs); assert(!dm_aspect_ui_background_drawing());
    assert(*(float *)(bg + 0x54) == 720 && (bg[0x58] & 0x10));
    dm_aspect_set_display(32.f/9); dm_aspect_ui_pane(bg);
    assert(*(float *)(bg + 0x50) == 2560);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(bg);
    assert(*(float *)(bg + 0x50) == 1280);
    dm_aspect_set_display(21.f/10);
    const char *untouched[] = {"P_Capture_00", "P_CaptureMask_00", "P_MapCapture_00", "T_Text_00", "P_Icon_00"};
    for (unsigned i = 0; i < sizeof untouched / sizeof *untouched; i++) {
        memset(bg + 0xb8, 0, 16); strcpy((char *)bg + 0xb8, untouched[i]);
        dm_aspect_ui_pane(bg); assert(*(float *)(bg + 0x50) == 1280);
        draw_callback(regs); assert(!dm_aspect_ui_background_drawing());
    }
    strcpy((char *)bg + 0xb8, "W_Shadow_00");
    *(float *)(bg + 0x50) = 640;
    dm_aspect_ui_pane(bg); assert(*(float *)(bg + 0x50) == 640);
    *(float *)(bg + 0x50) = 1280;
    *(uintptr_t *)(bg + 0x28) = 0x1234; // Containers must not resize their children.
    dm_aspect_ui_pane(bg); assert(*(float *)(bg + 0x50) == 1280);
    *(uintptr_t *)(bg + 0x28) = (uintptr_t)bg + 0x20;
    dm_aspect_ui_pane(bg); assert(fabsf(*(float *)(bg + 0x50) - 1512) < 0.001f);
    *(float *)(bg + 0x50) = 1500; // The game replaces a pane's native size.
    dm_aspect_ui_pane(bg); assert(fabsf(*(float *)(bg + 0x50) - 1771.875f) < 0.001f);
    // Title's right-anchored gradient extends to the new right edge, keeping
    // its seam with the left panel and leaving foreground placement intact.
    uint8_t title[0x100] = {0}, inout[0x100] = {0}, all[0x100] = {0}, base[0x100] = {0}, shade[0x100] = {0};
    strcpy((char *)title + 0xb8, "RootPane"); strcpy((char *)inout + 0xb8, "N_InOut_00");
    strcpy((char *)all + 0xb8, "N_All_00"); strcpy((char *)base + 0xb8, "N_Base_00");
    *(uint8_t **)(inout + 0x18) = title; *(uint8_t **)(all + 0x18) = inout;
    *(uint8_t **)(base + 0x18) = all; *(uint8_t **)(shade + 0x18) = base;
    *(float *)(shade + 0x50) = 480; *(float *)(shade + 0x54) = 720;
    dm_aspect_set_display(21.f/10); regs[21] = (uintptr_t)shade;
    for (int i = 0; i < 4; i++) {
        snprintf((char *)shade + 0xb8, 16, "FBLayout_0%d", i);
        *(float *)(shade + 0x50) = 480; *(float *)(shade + 0x30) = i < 2 ? 160 : 640;
        for (int frame = 0; frame < 20; frame++) dm_aspect_ui_pane(shade);
        draw_callback(regs);
        assert(dm_aspect_ui_background_drawing());
        assert(*(float *)(shade + 0x54) == 720);
        if (i < 2) assert(*(float *)(shade + 0x50) == 480 && *(float *)(shade + 0x30) == 160);
        else {
            assert(fabsf(*(float *)(shade + 0x50) - 596) < 0.001f);
            assert(fabsf(*(float *)(shade + 0x30) - 756) < 0.001f);
            assert(*(float *)(shade + 0x30) - *(float *)(shade + 0x50) == 160);
        }
        draw_end_callback(regs);
    }
    dm_aspect_set_display(32.f/9); dm_aspect_ui_pane(shade);
    assert(*(float *)(shade + 0x50) == 1120 && *(float *)(shade + 0x30) == 1280);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(shade);
    assert(*(float *)(shade + 0x50) == 480 && *(float *)(shade + 0x30) == 640);
    dm_aspect_set_display(21.f/10);
    strcpy((char *)base + 0xb8, "Other_00"); draw_callback(regs);
    assert(!dm_aspect_ui_background_drawing());
    strcpy((char *)base + 0xb8, "N_Base_01"); draw_callback(regs);
    assert(dm_aspect_ui_background_drawing()); draw_end_callback(regs);
    uint8_t art_group[0x100] = {0}, art[0x100] = {0}, capture[0x100] = {0};
    strcpy((char *)art_group + 0xb8, "N_5_Gardian_00");
    strncpy((char *)art + 0xb8, "P_Image_Gurdian_00", 16);
    *(uint8_t **)(art_group + 0x18) = inout; *(uint8_t **)(art + 0x18) = art_group;
    *(float *)(art + 0x50) = 1000; *(float *)(art + 0x54) = 709;
    *(float *)(art + 0x30) = -196; *(float *)(art + 0x34) = -60;
    for (int i = 0; i < 20; i++) dm_aspect_ui_pane(art);
    float cover = (21.f / 10) / GAME_ASPECT;
    assert(fabsf(*(float *)(art + 0x50) - 1000 * cover) < 0.001f);
    assert(fabsf(*(float *)(art + 0x54) - 709 * cover) < 0.001f);
    assert(fabsf(*(float *)(art + 0x30) + 196 * cover) < 0.001f);
    assert(fabsf(*(float *)(art + 0x34) + 60 * cover) < 0.001f);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(art);
    assert(*(float *)(art + 0x50) == 1000 && *(float *)(art + 0x30) == -196);
    strcpy((char *)capture + 0xb8, "N_Capture_00"); *(uint8_t **)(capture + 0x18) = title;
    strcpy((char *)art_group + 0xb8, "N_5_00"); *(uint8_t **)(art_group + 0x18) = capture;
    dm_aspect_set_display(21.f / 10); dm_aspect_ui_pane(art);
    assert(*(float *)(art + 0x50) == 1000 && *(float *)(art + 0x54) == 709);
    float hit[4]; dm_aspect_touch_rect(1008, 480, hit);
    assert(fabsf(hit[0] - 77.3333f) < 0.001f && fabsf(hit[2] - 853.3333f) < 0.001f);
    test_edge_hud();
    free(g_mod[0].base); puts("aspect: camera, centered content/hit regions and independent fullscreen backgrounds passed");
}
