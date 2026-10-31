// Current host implementation: display changes must affect the camera only at its guest projection gate.
#include "../hle.h"
// This fixture describes the camera under test, independent of the profile used to build the rest of the host tests.
#undef DM_GAME_ID
#undef DM_GAME_ASPECT_NATIVE
#undef DM_GAME_CAMERA_ASPECT
#undef DM_GAME_CAMERA_UI_ASPECT
#undef DM_GAME_CAMERA_WORLD_ASPECT
#define DM_GAME_ID "01007EF00011E000"
#define DM_GAME_ASPECT_NATIVE 1
#define DM_GAME_CAMERA_ASPECT "cd57b23fa4bbad65803d9788c01821ee:0x1e39d10:0x38:0x1d05380:0xb0:0x8"
#define DM_GAME_CAMERA_UI_ASPECT "19:0xa0:0xa8:0x74"
#define DM_GAME_CAMERA_WORLD_ASPECT "19:0x41c0"
#include "../hle_aspect.c"
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../touchpad_geometry.h"
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
    *(float *)(p+0x48)=*(float *)(p+0x4c)=1;
}
static void pane_child(uint8_t *parent, uint8_t *child) {
    uint8_t *next=*(uint8_t **)(parent+0x28);
    *(uint8_t **)(child+0x10)=next?next:parent+0x20;
    *(uint8_t **)(child+0x18)=parent; *(uint8_t **)(parent+0x28)=child+8;
}
static void test_right_hud_padding(void) {
    const float w=932, h=430, insets[][2]={{0,62},{62,0},{62,62}};
    dm_aspect_set_display(w/h);
    for(unsigned i=0;i<sizeof insets/sizeof *insets;i++) {
        dm_aspect_set_safe_area(w, h, insets[i][0], 0, insets[i][1]);
        for(int touch=0;touch<2;touch++) {
            test_touch_active=touch;
            float rect[4]; dm_aspect_hud_rect(w,h,rect);
            assert(fabsf(rect[0]+rect[2]-w)<.001f);
            dm_touchpad_rect plus=dm_touchpad_botw_menu_rect(rect[0],rect[1],rect[2],rect[3],0);
            float padding=DM_TP_BOTW_HEART_EDGE*rect[3]/720+DM_TP_BOTW_EDGE_EXTRA-
                (DM_TP_BOTW_MENU_SIZE-DM_TP_BOTW_MENU_GLYPH_SIZE)*rect[3]/1440;
            assert(fabsf(w-plus.x-plus.width-padding)<.001f);
        }
    }
    // Explicit aspect bars still bound the HUD to the actual game picture.
    g_custom=21.f/10; dm_aspect_set_safe_area(w, h, 62, 0, 62);
    float rect[4]; dm_aspect_hud_rect(w,h,rect);
    assert(fabsf(rect[0]+rect[2]-(w+h*g_custom)*.5f)<.001f);
    g_custom=0; test_touch_active=0;
}
static void test_edge_hud(void) {
    uint8_t root[0x100],all[0x100],state[0x100],heart[0x100],glyph[0x100],sensor[0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
    pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
    pane_init(heart,"Pa_HeartGauge_00",-434,312,50); pane_child(state,heart);
    pane_init(glyph,"P_Heart_00",20,32,32); pane_child(heart,glyph);
    pane_init(sensor,"Pa_Sensor_00",392,582,78); pane_child(all,sensor);
    dm_aspect_set_display(21.f/10); dm_aspect_set_safe_area(1512, 720, 0, 0, 0);
    for (int i=0;i<20;i++) { dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor); }
    assert(fabsf(*(float *)(heart+0x30)+548)<.001f && *(float *)(heart+0x50)==312);
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
    dm_aspect_set_safe_area(1512, 720, 40, 0, 20); dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor);
    assert(fabsf(*(float *)(heart+0x30)+548)<.001f && fabsf(*(float *)(sensor+0x30)-508)<.001f);
    float rect[4]; dm_aspect_hud_rect(1512,720,rect);
    assert(fabsf(rect[0]-40)<.001f && fabsf(rect[2]-1472)<.001f && rect[1]==0 && rect[3]==720);
    dm_aspect_touch_rect(1512,720,rect); assert(fabsf(rect[0]-116)<.001f && rect[2]==1280);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor);
    assert(*(float *)(heart+0x30)==-432 && *(float *)(sensor+0x30)==392);
    dm_aspect_set_safe_area(1280, 720, 0, 0, 0);
    uint8_t fade[0x100],logo[0x100],upper[0x100];
    pane_init(fade,"RootPane",0,1280,720); pane_init(logo,"N_LogoInOut_00",0,30,40); pane_child(fade,logo);
    pane_init(upper,"P_Capture_00",0,1280,275); pane_child(logo,upper);
    dm_aspect_set_display(21.f/10); dm_aspect_ui_pane(upper);
    assert(*(float *)(upper+0x50)==1280 && *(float *)(upper+0x54)==275);
    regs[21]=(uintptr_t)upper; draw_callback(regs); assert(dm_aspect_ui_background_drawing()==2); draw_end_callback(regs);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_ui_pane(upper); assert(*(float *)(upper+0x50)==1280);
}
static void test_narrow_hud(void) {
    uint8_t root[0x100],all[0x100],state[0x100],heart[0x100],glyph[0x100],menu[0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
    pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
    pane_init(heart,"Pa_HeartGauge_00",-434,312,50); pane_child(state,heart); *(float *)(heart+0x34)=300;
    pane_init(glyph,"P_Heart_00",0,32,32); pane_child(heart,glyph);
    pane_init(menu,"T_Text_00",0,100,40); *(float *)(menu+0x34)=123;
    uint8_t weather[0x100],weather_body[0x100],weather_icon[0x100];
    pane_init(weather,"Pa_Weather_00",0,899.5f,644); pane_child(all,weather);
    pane_init(weather_body,"N_InOut_00",362,30,30); pane_child(weather,weather_body);
    pane_init(weather_icon,"Nt_WeatherNow_00",0,32,32); pane_child(weather_body,weather_icon);
    uint8_t map[0x100],inout[0x100],cut[0x100],sibling[0x100],picture[0x100];
    pane_init(map,"RootPane",0,1280,720); pane_init(inout,"N_InOut_00",0,30,30); pane_child(map,inout);
    pane_init(cut,"N_Cut_00",0,166,166); pane_child(inout,cut);
    pane_init(sibling,"N_Cut_01",0,1500,1500); pane_child(inout,sibling);
    pane_init(picture,"P_MapCapture_00",0,192,192); pane_child(sibling,picture);
    uint8_t fade[0x100],logo[0x100],upper[0x100],black[0x100];
    pane_init(fade,"RootPane",0,1280,720); pane_init(logo,"N_LogoInOut_00",0,30,40); pane_child(fade,logo);
    pane_init(upper,"P_Capture_00",0,1280,275); pane_child(logo,upper);
    pane_init(black,"P_Black_00",0,1280,445); pane_child(fade,black);
    const float ratios[]={4.f/3,9.f/16}; uint64_t regs[31]={0};
    for (unsigned i=0;i<sizeof ratios/sizeof *ratios;i++) {
        float ratio=ratios[i], f=ratio/GAME_ASPECT, gain=GAME_ASPECT*fminf(1,1/ratio), rect[4];
        float sy=f*gain;
        dm_aspect_set_display(ratio); dm_aspect_set_safe_area(720*ratio,720,0,40,0);
        for (int n=0;n<10;n++) { dm_aspect_ui_pane(heart); dm_aspect_ui_pane(inout); }
        for (int n=0;n<10;n++) dm_aspect_ui_pane(weather);
        assert(*(float *)(weather+0x48)==1 && *(float *)(weather+0x4c)==1);
        regs[21]=(uintptr_t)weather_icon; draw_callback(regs);
        assert(dm_aspect_ui_hud_drawing()==3); draw_end_callback(regs);
        assert(fabsf(*(float *)(heart+0x34)-(300*sy+360*(1-sy)-40))<.001f);
        assert(fabsf(*(float *)(heart+0x30)-((-434+640)*gain-640+DM_TP_BOTW_EDGE_EXTRA*dm_aspect_ui_point_scale()))<.001f);
        assert(fabsf(*(float *)(heart+0x48)-gain)<.001f && fabsf(*(float *)(heart+0x4c)-sy)<.001f);
        assert(*(float *)(heart+0x50)==312);
        assert(fabsf(*(float *)(inout+0x48)-gain)<.001f && fabsf(*(float *)(inout+0x4c)-sy)<.001f);
        dm_aspect_hud_rect(720*ratio,720,rect); assert(fabsf(rect[1])<.001f && fabsf(rect[3]-720)<.001f);
        dm_aspect_touch_rect(720*ratio,720,rect); assert(rect[1]>0 && fabsf(rect[3]-720*f)<.001f);
        assert(fabsf(dm_aspect_hud_top()-(360-20*sy-40))<.001f);
        dm_aspect_ui_pane(menu); assert(*(float *)(menu+0x34)==123 && *(float *)(menu+0x4c)==1);
        regs[21]=(uintptr_t)glyph; draw_callback(regs); assert(dm_aspect_ui_hud_drawing()==1); draw_end_callback(regs);
        regs[21]=(uintptr_t)picture; draw_callback(regs); assert(dm_aspect_ui_hud_drawing()==2); draw_end_callback(regs);
        *(float *)(cut+0x50)=1500; *(float *)(cut+0x54)=720; dm_aspect_ui_pane(inout);
        assert(*(float *)(inout+0x48)==1 && *(float *)(inout+0x4c)==1);
        draw_callback(regs); assert(!dm_aspect_ui_hud_drawing()); draw_end_callback(regs);
        *(float *)(cut+0x50)=*(float *)(cut+0x54)=166;
        for (int b=0;b<2;b++) {
            regs[21]=(uintptr_t)(b?black:upper); draw_callback(regs);
            assert(dm_aspect_ui_background_drawing()==2); draw_end_callback(regs);
        }
    }
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
    dm_aspect_ui_pane(heart); dm_aspect_ui_pane(inout); dm_aspect_ui_pane(weather);
    assert(*(float *)(heart+0x34)==300 && *(float *)(heart+0x48)==1 && *(float *)(heart+0x4c)==1);
    assert(*(float *)(inout+0x48)==1 && *(float *)(inout+0x4c)==1);
    assert(*(float *)(weather+0x48)==1 && *(float *)(weather+0x4c)==1);
}

static void test_seated_regions(void) {
    const float widths[]={795,1200};
    for (unsigned n=0;n<2;n++) {
        float w=widths[n],h=1100,picture[4],dock[4],hit[4];
        dm_aspect_set_display(w/h); dm_aspect_set_seated(.49f,.51f);
        dm_aspect_set_safe_area(w,h,0,0,0);
        assert(dm_aspect_region(0,picture) && dm_aspect_region(1,dock));
        assert(fabsf(dm_aspect_ratio()-w/(h*.49f))<.00001f);
        assert(fabsf(dm_aspect_control_ratio()-w/(h*.49f))<.00001f);
        dm_aspect_touch_rect(w,h,hit);
        assert(hit[1]>=0 && hit[1]+hit[3]<=h*.49f+.001f);
        dm_aspect_hud_rect(w,h,hit);
        assert(fabsf(hit[1]-h*.51f)<.001f && fabsf(hit[3]-h*.49f)<.001f);
        dm_touchpad_rect map=dm_touchpad_seated_map((dm_touchpad_rect){0,h*.51f,w,h*.49f});
        float gain=dm_aspect_map_gain(),sy=dm_aspect_hud_y_scale();
        assert(fabsf(166*gain*sy*hit[3]/720-map.width)<.001f);
        assert(fabsf((360-dm_aspect_hud_top())*hit[3]/720-DM_TP_BOTW_DOCK_TOP)<.001f);
        uint8_t root[0x100],all[0x100],state[0x100],heart[0x100],weather[0x100],sensor[0x100],equipment[0x100];
        pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
        pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
        pane_init(heart,"Pa_HeartGauge_00",-434,312,50); pane_child(state,heart);
        pane_init(weather,"Pa_Weather_00",0,40,40); pane_child(all,weather);
        pane_init(sensor,"Pa_Sensor_00",0,40,40); pane_child(all,sensor);
        pane_init(equipment,"N_MainAll_00",0,40,40); pane_child(all,equipment);
        uint64_t regs[31]={0}; test_touch_active=1;
        uint8_t *panes[]={heart,sensor,weather,equipment}; const int scopes[]={1,4,3,5};
        for (unsigned i=0;i<4;i++) {
            dm_aspect_ui_pane(panes[i]); regs[21]=(uintptr_t)panes[i]; draw_callback(regs);
            assert(dm_aspect_ui_hud_drawing()==scopes[i]); draw_end_callback(regs);
        }
        assert(fabsf(*(float *)(sensor+0x48)-gain)<.001f);
        assert(*(float *)(weather+0x48)==1 && *(float *)(weather+0x4c)==1);
        test_touch_active=0; regs[21]=(uintptr_t)equipment; draw_callback(regs);
        assert(!dm_aspect_ui_hud_drawing()); draw_end_callback(regs);
        dm_aspect_set_seated(0,0); dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
        dm_aspect_ui_pane(sensor); assert(*(float *)(sensor+0x48)==1 && *(float *)(sensor+0x4c)==1);
        assert(!dm_aspect_region(1,dock) && dock[0]==0 && dock[1]==0 && dock[2]==1 && dock[3]==1);
    }
    // Fixed aspects fit only the upper picture; lower HUD and input remain full width.
    dm_aspect_set_display(795.f/1100); dm_aspect_set_seated(.49f,.51f);
    const float aspects[]={1,2.8f};
    for (unsigned i=0;i<2;i++) {
        g_custom=aspects[i]; float picture[4],dock[4],hit[4];
        dm_aspect_set_safe_area(795,1100,0,30,0);
        assert(dm_aspect_region(0,picture) && dm_aspect_region(1,dock));
        assert(fabsf(795*picture[2]/(1100*picture[3])-g_custom)<.00001f);
        assert(picture[1]>=0 && picture[1]+picture[3]<=.49f+.00001f);
        assert(dock[0]==0 && dock[2]==1 && dock[1]==.51f && dock[3]==1-.51f);
        dm_aspect_touch_rect(795,1100,hit);
        assert(hit[0]>=795*picture[0]-.001f && hit[1]>=1100*picture[1]-.001f);
        assert(hit[0]+hit[2]<=795*(picture[0]+picture[2])+.001f);
        assert(hit[1]+hit[3]<=1100*(picture[1]+picture[3])+.001f);
    }
    g_custom=0;
    dm_aspect_set_seated(.5f,.5f); float r[4]; assert(dm_aspect_region(0,r)); // zero-thickness division
    dm_aspect_set_seated(NAN,.6f); assert(!dm_aspect_region(0,r));
    dm_aspect_set_seated(.8f,.2f); assert(!dm_aspect_region(0,r));
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
    test_right_hud_padding();
    test_edge_hud();
    test_narrow_hud();
    test_seated_regions();
    free(g_mod[0].base); puts("aspect: camera, centered content/hit regions and independent fullscreen backgrounds passed");
}
