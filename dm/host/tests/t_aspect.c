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
#include "../botw_touch_layout.h"
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
static int test_inventory_active;
int dm_botw_touch_inventory_active(void) { return test_inventory_active; }
static int test_keep_native_loadout, test_loadout_visible=1;
int dm_botw_touch_hud_relocates_loadout(void) { return test_touch_active && !test_keep_native_loadout; }
int dm_botw_touch_loadout_visible(void) { return test_loadout_visible; }
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
static void test_inventory_footer(void) {
    uint8_t root[0x100],inout[0x100],down[0x100],row[0x100],title[0x100];
    uint8_t bg[0x100],slide[0x100],base[0x100],line[0x100],black[0x100],capture[0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(inout,"N_InOut_00",0,30,40); pane_child(root,inout);
    pane_init(down,"N_TitleBarDown_00",0,30,40); pane_child(inout,down);
    pane_init(title,"N_TitleBar_00",0,30,40); pane_child(inout,title);
    pane_init(row,"N_Align_00",48,1044,40); pane_child(down,row); *(float *)(row+0x34)=-318;
    pane_init(bg,"RootPane",0,1280,720); pane_init(slide,"N_Slide_01",0,64,69); pane_child(bg,slide);
    pane_init(base,"N_InOut_01",0,30,40); pane_child(slide,base);
    pane_init(capture,"N_InCap_00",0,30,40); pane_child(bg,capture);
    pane_init(black,"W_BlackBG_00",0,4788,758); pane_child(base,black);
    pane_init(line,"W_Line_00",0,4590,574); pane_child(base,line); *(float *)(line+0x34)=-19;
    test_touch_active=test_inventory_active=1;
    const float sizes[][2]={{932,430},{1280,720},{390,844},{1024,768}};
    for (unsigned i=0;i<sizeof sizes/sizeof *sizes;i++) {
        float w=sizes[i][0],h=sizes[i][1];
        dm_aspect_set_display(w/h); dm_aspect_set_safe_area(w,h,0,0,0);
        float unit=dm_aspect_ui_point_scale();
        for (int frame=0;frame<20;frame++) { dm_aspect_ui_pane(row); dm_aspect_ui_pane(line); }
        assert(fabsf((574-*(float *)(line+0x54))/unit-16)<.001f);
        assert(fabsf(*(float *)(line+0x34)+*(float *)(line+0x54)*.5f-268)<.001f);
        assert(fabsf((*(float *)(row+0x34)+318)/unit-8)<.001f);
        assert(fabsf(*(float *)(row+0x48)-1.4f)<.001f && *(float *)(row+0x48)==*(float *)(row+0x4c));
        assert(*(float *)(row+0x50)==1044);
    }
    // Quest/System, touch disabled and unrelated similarly named trees restore native geometry.
    for (int mode=1;mode<3;mode++) {
        test_touch_active=mode!=1; test_inventory_active=mode!=0;
        if (mode==2) { memset(title+0xb8,0,16); strcpy((char *)title+0xb8,"OtherBar"); }
        dm_aspect_ui_pane(row);
        if (mode<2) dm_aspect_ui_pane(line);
        assert(*(float *)(row+0x48)==1 && *(float *)(row+0x30)==48 && *(float *)(row+0x34)==-318);
        assert(*(float *)(line+0x54)==574 && *(float *)(line+0x34)==-19);
    }
    test_touch_active=test_inventory_active=0;
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
}
static void test_slate_footer(void) {
    uint8_t root[0x100],slate[0x100],capture[0x100],boot[0x100],deco[0x100],timeline[0x100];
    uint8_t row[0x100],inout[0x100],wall[0x100],moya[0x100],text[0x100],upper[0x100],camera[0x100];
    uint8_t scan[0x100],left[0x100],next[0x100],right[0x100],seam[0x100],stone[0x100];
    uint8_t upper_moya[0x100],upper_text[0x100],upper_seam[0x100];
    uint8_t soft_seams[4][0x100];
    uint8_t bar_shades[2][0x100];
    uint8_t key_capture[2][0x100],key_icon[2][0x100];
    uint8_t key_draw[2][0x100],key_picture[2][0x100],key_glow[2][0x100];
    uint16_t glyphs[]={0xe05e,0xe05d}; // live map Move and Zoom glyphs
    pane_init(root,"RootPane",0,1280,720);
    pane_init(slate,"Pa_ScanningLine_00",0,1302,720); pane_child(root,slate);
    pane_init(capture,"N_CaptureText_01",0,696,36); pane_child(slate,capture);
    pane_init(boot,"P_BootBG_00",0,1280,720); pane_child(slate,boot);
    pane_init(deco,"N_Deco_00",0,30,40); pane_child(slate,deco);
    pane_init(timeline,"N_TimeLineDemo_00",0,30,40); pane_child(deco,timeline);
    pane_init(row,"N_Align_00",48,800,40); pane_child(timeline,row); *(float *)(row+0x34)=-320;
    pane_init(left,"Pa_Guide_05",-256,360,40); pane_child(row,left);
    pane_init(next,"Pa_Guide_04",-127,360,40); pane_child(row,next);
    pane_init(right,"Pa_Guide_00",389,360,40); pane_child(row,right);
    uint8_t *keys[]={left,right};
    for (int i=0;i<2;i++) {
        keys[i][0x59]=255;
        pane_init(key_capture[i],"N_CaptureText_00",-80,200,40); pane_child(keys[i],key_capture[i]);
        pane_init(key_icon[i],"T_Icon_00",80,34,34); pane_child(key_capture[i],key_icon[i]);
        memcpy(key_icon[i]+0xe0,&(uintptr_t){(uintptr_t)&glyphs[i]},sizeof(uintptr_t));
        pane_init(key_draw[i],"N_InOut_00",0,30,40); pane_child(keys[i],key_draw[i]);
        pane_init(key_picture[i],"P_Text_00",-80,200,40); pane_child(key_draw[i],key_picture[i]); key_picture[i][0x59]=255;
        pane_init(key_glow[i],"P_Sh_00",-80,200,40); pane_child(key_draw[i],key_glow[i]); key_glow[i][0x59]=180;
    }
    next[0x59]=255;
    pane_init(inout,"N_InOut_00",0,30,40); pane_child(slate,inout);
    pane_init(wall,"P_WallD_00",0,1280,56); pane_child(inout,wall); *(float *)(wall+0x34)=-360;
    pane_init(moya,"P_MoyaD_00",0,1280,64); pane_child(inout,moya); *(float *)(moya+0x34)=-304;
    pane_init(text,"T_DecoD_00",4,1280,14); pane_child(deco,text); *(float *)(text+0x34)=-296;
    pane_init(upper,"P_WallU_00",0,1280,56); pane_child(inout,upper); *(float *)(upper+0x34)=360;
    for(int i=0;i<2;i++) {
        pane_init(bar_shades[i],i?"P_MoyaD_01":"P_MoyaU_01",0,1280,58);
        pane_child(inout,bar_shades[i]);*(float *)(bar_shades[i]+0x34)=i?-360:360;
    }
    pane_init(scan,"P_ScanningLine_00",0,1280,608); pane_child(inout,scan);
    pane_init(seam,"P_Core_06",-550,1098,58); pane_child(deco,seam); seam[0x59]=159;
    pane_init(stone,"P_Alb_09",543,908,26); pane_child(deco,stone); stone[0x59]=255;
    pane_init(upper_seam,"P_Core_01",-505,997,58); pane_child(deco,upper_seam); upper_seam[0x59]=200;
    const char *soft_names[]={"P_BlurSh_01","P_BlurSh_06","P_Abst_01","P_Abst_06"};
    for(int i=0;i<4;i++) {
        pane_init(soft_seams[i],soft_names[i],-496,979,68);pane_child(deco,soft_seams[i]);
        soft_seams[i][0x59]=128+i;
    }
    uint8_t *panes[]={row,wall,moya,text,upper,scan,left,next,right,seam,stone,upper_seam,
        key_picture[0],key_picture[1],key_glow[0],key_glow[1],soft_seams[0],soft_seams[1],soft_seams[2],soft_seams[3],bar_shades[0],bar_shades[1]};
    pane_init(upper_moya,"P_MoyaU_00",0,1280,26); pane_child(deco,upper_moya); *(float *)(upper_moya+0x34)=304;
    pane_init(upper_text,"T_DecoU_00",0,1280,20); pane_child(deco,upper_text); *(float *)(upper_text+0x34)=296;
    const float sizes[][2]={{932,430},{1280,720},{390,844},{1024,768}};
    test_touch_active=1;
    for (unsigned i=0;i<sizeof sizes/sizeof *sizes;i++) {
        dm_aspect_set_display(sizes[i][0]/sizes[i][1]);
        dm_aspect_set_safe_area(sizes[i][0],sizes[i][1],0,0,0);
        float unit=dm_aspect_ui_point_scale();
        // AppHome keeps the same row across map, runes, album and compendium.
        for (int frame=0;frame<80;frame++) for (unsigned n=0;n<sizeof panes/sizeof *panes;n++) dm_aspect_ui_pane(panes[n]);
        assert(fabsf(*(float *)(row+0x48)-1.4f)<.001f && *(float *)(row+0x48)==*(float *)(row+0x4c));
        assert(fabsf((*(float *)(row+0x34)+320)/unit-8)<.001f);
        assert(fabsf((*(float *)(wall+0x54)-56)/unit-16)<.001f && *(float *)(wall+0x34)==-360);
        assert(fabsf((*(float *)(moya+0x34)+304)/unit-16)<.001f);
        assert(fabsf((*(float *)(text+0x34)+296)/unit-16)<.001f && *(float *)(text+0x50)==1280);
        assert(fabsf((*(float *)(upper+0x54)-56)/unit-16)<.001f && *(float *)(upper+0x34)==360);
        for(int s=0;s<2;s++) {
            assert(fabsf(*(float *)(bar_shades[s]+0x54)-58-16*unit)<.001f);
            assert(fabsf(*(float *)(bar_shades[s]+0x50)-1280*fmaxf(1,dm_aspect_ratio()/GAME_ASPECT))<.001f);
            assert(*(float *)(bar_shades[s]+0x34)==(s?-360:360));
        }
        dm_aspect_ui_pane(upper_moya); dm_aspect_ui_pane(upper_text);
        assert(fabsf((304-*(float *)(upper_moya+0x34))/unit-16)<.001f);
        assert(fabsf((296-*(float *)(upper_text+0x34))/unit-16)<.001f && *(float *)(upper_text+0x50)==1280);
        // Suppress only the luminous bottom seam, preserving the scan area,
        // stone artwork and native geometry (including the glow's dimensions).
        assert(seam[0x59]==0 && upper_seam[0x59]==0 && stone[0x59]==255 && *(float *)(stone+0x54)==26);
        for(int s=0;s<4;s++)assert(soft_seams[s][0x59]==0);
        assert(fabsf(*(float *)(seam+0x50)-(1098+1280*(fmaxf(1,dm_aspect_ratio()/GAME_ASPECT)-1)))<.001f && *(float *)(seam+0x54)==58);
        assert(*(float *)(scan+0x34)==0 && *(float *)(scan+0x54)==608);
        assert(*(float *)(left+0x30)==-226 && *(float *)(next+0x30)==-103 && *(float *)(right+0x30)==389);
        assert(*(float *)(left+0x48)==1 && *(float *)(left+0x4c)==1 && *(float *)(left+0x34)==0);
        assert(left[0x59]==255 && right[0x59]==255 && next[0x59]==255); // native Locater inputs remain unchanged
        for(int k=0;k<2;k++) assert(key_picture[k][0x59]==0 && key_glow[k][0x59]==0);
    }
    // The same rightmost slot becomes Select in Album; hiding must not stick.
    glyphs[1]=0xe040; dm_aspect_ui_pane(key_picture[1]); dm_aspect_ui_pane(key_glow[1]);
    assert(key_picture[1][0x59]==255 && key_glow[1][0x59]==180);
    glyphs[1]=0xe057; dm_aspect_ui_pane(key_picture[1]); assert(key_picture[1][0x59]==255); // press-stick is a real action
    glyphs[1]=0xe05d; dm_aspect_ui_pane(key_picture[1]); assert(key_picture[1][0x59]==0);
    seam[0x59]=77; dm_aspect_ui_pane(seam); assert(seam[0x59]==0); // native animation still updates
    test_touch_active=0;
    for (unsigned n=0;n<sizeof panes/sizeof *panes;n++) dm_aspect_ui_pane(panes[n]);
    assert(*(float *)(row+0x48)==1 && *(float *)(row+0x30)==48 && *(float *)(row+0x34)==-320);
    assert(*(float *)(wall+0x54)==56 && *(float *)(wall+0x34)==-360);
    assert(*(float *)(moya+0x34)==-304 && *(float *)(text+0x34)==-296);
    assert(*(float *)(scan+0x34)==0 && *(float *)(scan+0x54)==608 && *(float *)(left+0x30)==-256);
    for(int s=0;s<2;s++)assert(*(float *)(bar_shades[s]+0x54)==58);
    assert(seam[0x59]==77 && upper_seam[0x59]==200);
    for(int s=0;s<4;s++)assert(soft_seams[s][0x59]==128+s);
    assert(left[0x59]==255 && right[0x59]==255);
    for(int k=0;k<2;k++) assert(key_picture[k][0x59]==255 && key_glow[k][0x59]==180);
    // The telescope's nested copy must retain its gameplay layout.
    pane_init(camera,"Pa_CameraPointer_00",0,1280,720); pane_child(root,camera); pane_child(camera,slate);
    test_touch_active=1;
    for (unsigned n=0;n<sizeof panes/sizeof *panes;n++) dm_aspect_ui_pane(panes[n]);
    assert(*(float *)(row+0x48)==1 && *(float *)(row+0x34)==-320 && *(float *)(wall+0x54)==56);
    assert(seam[0x59]==77 && *(float *)(left+0x30)==-256);
    for(int s=0;s<2;s++)assert(*(float *)(bar_shades[s]+0x54)==58);
    test_touch_active=0;
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
}
static void test_slate_side_frames(void) {
    _Alignas(16) static uint8_t p[13][0x100];
    const char *names[]={"RootPane","N_InOut_00","Pa_ScanningLine_00","N_CaptureText_01",
        "P_BootBG_00","N_Deco_00","P_Core_00","P_Core_01","P_Core_02","P_Text_00",
        "N_Em_00","P_Em_00","Pa_CameraPointer_00"};
    int parents[]={-1,0,0,2,2,2,5,5,5,5,5,10,0};
    for(int i=0;i<13;i++) {pane_init(p[i],names[i],0,30,40); if(i) pane_child(p[parents[i]],p[i]);}
    *(float *)(p[6]+0x30)=-640; *(float *)(p[6]+0x50)=135;
    *(float *)(p[7]+0x30)=-505; *(float *)(p[7]+0x50)=997;
    *(float *)(p[8]+0x30)=640; *(float *)(p[8]+0x50)=148;
    *(float *)(p[9]+0x50)=696; *(float *)(p[11]+0x30)=-549;
    const float ratios[]={16.f/9,21.f/9,32.f/9,16.f/9};
    for(int camera=0;camera<2;camera++) {
        *(uint8_t **)(p[2]+0x18)=p[camera ? 1 : 0];
        for(unsigned r=0;r<sizeof ratios/sizeof *ratios;r++) {
            dm_aspect_set_display(ratios[r]); float margin=640*(fmaxf(1,ratios[r]/GAME_ASPECT)-1);
            for(int n=0;n<20;n++) for(int i=6;i<12;i++) dm_aspect_ui_pane(p[i]);
            assert(fabsf(*(float *)(p[6]+0x30)-(-640-margin))<.001f && *(float *)(p[6]+0x50)==135);
            assert(fabsf(*(float *)(p[8]+0x30)-(640+margin))<.001f && *(float *)(p[8]+0x50)==148);
            assert(fabsf(*(float *)(p[7]+0x50)-(997+2*margin))<.001f);
            assert(fabsf(*(float *)(p[6]+0x30)+135-*(float *)(p[7]+0x30))<.001f);
            assert(fabsf(*(float *)(p[7]+0x30)+*(float *)(p[7]+0x50)-(*(float *)(p[8]+0x30)-148))<.001f);
            assert(*(float *)(p[9]+0x30)==0 && *(float *)(p[9]+0x50)==696); // foreground unchanged
            assert(fabsf(*(float *)(p[11]+0x30)-(-549-margin))<.001f);
            uint64_t regs[31]={0}; regs[21]=(uintptr_t)p[7]; aspect_ui_draw(regs);
            assert(dm_aspect_ui_background_drawing()==(ratios[r]>GAME_ASPECT)); aspect_ui_draw_end(regs);
        }
    }
    // MainScreen's telescope shares the art but not the fullscreen frame.
    *(uint8_t **)(p[2]+0x18)=p[12]; dm_aspect_set_display(32.f/9);
    for(int i=6;i<12;i++) dm_aspect_ui_pane(p[i]);
    assert(*(float *)(p[6]+0x30)==-640 && *(float *)(p[7]+0x50)==997);
    dm_aspect_set_display(GAME_ASPECT);
}

static void test_menu_headers(void) {
    _Alignas(16) static uint8_t p[13][0x100];
    const char *names[]={"RootPane","Pa_ScanningLine_00","N_CaptureText_01","P_BootBG_00",
        "N_Deco_00","N_TimeLineDemo_00","P_Text_00","P_Sh_00",
        "N_InOut_00","N_TitleBar_00","N_TitleBarUp_00","Pa_BtnZL_00","Pa_BtnZR_00"};
    int parents[]={-1,0,1,1,1,4,5,5,0,8,9,10,10};
    for(int i=0;i<13;i++) { pane_init(p[i],names[i],0,40,36); if(i) pane_child(p[parents[i]],p[i]); }
    *(float *)(p[6]+0x34)=*(float *)(p[7]+0x34)=320;
    const float sizes[][2]={{932,430},{390,844},{1280,720},{1024,768}};
    for(unsigned n=0;n<sizeof sizes/sizeof *sizes;n++) {
        dm_aspect_set_display(sizes[n][0]/sizes[n][1]); dm_aspect_set_safe_area(sizes[n][0],sizes[n][1],0,0,0);
        test_touch_active=1;
        for(int repeat=0;repeat<20;repeat++) for(int i=6;i<13;i++) dm_aspect_ui_pane(p[i]);
        for(int i=6;i<8;i++) {
            assert(fabsf(*(float *)(p[i]+0x48)-1.4f)<.001f);
            assert(fabsf(*(float *)(p[i]+0x34)-(320-8*dm_aspect_ui_point_scale()))<.001f);
        }
        for(int i=11;i<13;i++) assert(fabsf(*(float *)(p[i]+0x48)-1.4f)<.001f);
        assert(*(float *)(p[9]+0x54)==36 && *(float *)(p[9]+0x4c)==1); // + top bar unchanged
        test_touch_active=0;
        for(int i=6;i<13;i++) dm_aspect_ui_pane(p[i]);
        for(int i=6;i<13;i++) assert(*(float *)(p[i]+0x48)==1);
        assert(*(float *)(p[6]+0x34)==320);
    }
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
}
static void test_dungeon_controls(void) {
    _Alignas(16) static uint8_t p[22][0x140];
    const char *names[]={"RootPane","N_Born_00","N_InOut_00","N_MiniMap_01",
        "N_GuidePos_01","N_Device_03","N_GuidePos_00","P_Text_01","P_Sh_01",
        "P_IconClear_01","P_IconSh_01","N_PosBase_00","N_CaptureText_01",
        "T_A_00","T_GuideA_00","T_B_00","T_GuideB_00","W_SubTitleLineA_02",
        "T_A_00_KR","T_B_00_KR","PaFireBtnNextMove_00","T_Guide_00"};
    const int parents[]={-1,0,1,2,3,4,5,6,6,6,6,0,0,12,12,12,12,12,12,12,4,0};
    for (int i=0;i<22;i++) {
        pane_init(p[i],names[i],0,40,29);
        if (i) pane_child(p[parents[i]],p[i]);
    }
    for (int i=7;i<=10;i++) {
        *(float *)(p[i]+0x30)=i<=8 ? 194 : 169;
        *(float *)(p[i]+0x34)=i<=8 ? -6 : 30;
        *(float *)(p[i]+0x50)=i<=8 ? 400 : 250;
        *(float *)(p[i]+0x54)=i<=8 ? 74 : 40;
    }
    for (int i=13;i<=19;i++) *(float *)(p[i]+0x34)=i==17 ? 20 : (i==15 || i==16 || i==19) ? -20 : 5;
    *(float *)(p[14]+0x34)=6;
    *(float *)(p[14]+0x54)=*(float *)(p[16]+0x54)=20;
    *(float *)(p[17]+0x54)=20;
    for (int i=13;i<=19;i++) if (i!=17) p[i][0x11e]=i>=18 ? 1 : 5;
    const float sizes[][2]={{1280,720},{932,430},{2560,720},{390,844},{1024,768}};
    for (unsigned n=0;n<sizeof sizes/sizeof *sizes;n++) {
        dm_aspect_set_display(sizes[n][0]/sizes[n][1]);
        dm_aspect_set_safe_area(sizes[n][0],sizes[n][1],0,0,0);
        test_touch_active=1;
        for (int repeat=0;repeat<20;repeat++) for (int i=7;i<22;i++) dm_aspect_ui_pane(p[i]);
        for (int i=7;i<=10;i++) {
            float scale=i<=8 ? 1.8f : 1.4f;
            assert(fabsf(*(float *)(p[i]+0x48)-scale)<.001f);
            assert(fabsf(*(float *)(p[i]+0x4c)-scale)<.001f);
            assert(fabsf(*(float *)(p[i]+0x34)-((i<=8 ? -6 : 68)+16*dm_aspect_ui_point_scale()))<.001f);
            assert(fabsf(*(float *)(p[i]+0x30)-(i<=8 ? 246.4f : 169))<.001f);
            assert(*(float *)(p[i]+0x50)==(i<=8 ? 400 : 250));
        }
        float a=*(float *)(p[13]+0x34), b=*(float *)(p[15]+0x34);
        assert(a==7 && b==-22 && (a-b)*1.8f>25*1.4f);
        assert(*(float *)(p[14]+0x34)==a-2 && *(float *)(p[16]+0x34)==b-2);
        assert(29*1.8f>=34*1.4f && 29*1.8f<34*1.4f*1.15f); // comparable to footer glyph
        assert(fabsf((246.4f-131*1.8f)-(194-131*1.4f))<.001f);
        float row_top=*(float *)(p[7]+0x34)+(a+29*.5f)*1.8f;
        float title_bottom=*(float *)(p[9]+0x34)-40*1.4f*.5f;
        assert(title_bottom-row_top>=7); // title stays clear of the enlarged A row
        assert(a+29*.5f<37 && b-29*.5f>-37); // no capture cropping
        assert(*(float *)(p[17]+0x34)==24 && 24+10<37);
        assert(*(float *)(p[18]+0x34)==a && *(float *)(p[19]+0x34)==b);
        for (int i=13;i<=19;i++) if (i!=17) {
            assert(p[i][0x11e]==1);
            if (i<18) assert(p[i][0x11c]&4);
            p[i][0x11c]&=~4;
            dm_aspect_ui_pane(p[i]);
            assert(!(p[i][0x11c]&4));
        }
        assert(*(float *)(p[20]+0x48)==1 && *(float *)(p[21]+0x34)==0); // model controls and bottom guide untouched
        test_touch_active=0;
        for (int i=7;i<22;i++) dm_aspect_ui_pane(p[i]);
        for (int i=7;i<=10;i++) {
            assert(*(float *)(p[i]+0x48)==1 && *(float *)(p[i]+0x4c)==1);
            assert(*(float *)(p[i]+0x34)==(i<=8 ? -6 : 30));
            assert(*(float *)(p[i]+0x30)==(i<=8 ? 194 : 169));
        }
        assert(*(float *)(p[13]+0x34)==5 && *(float *)(p[15]+0x34)==-20);
        assert(*(float *)(p[17]+0x34)==20);
        for (int i=13;i<=19;i++) if (i!=17) assert(p[i][0x11e]==(i>=18 ? 1 : 5));
    }
    // A source animation becomes the new native value, then restores exactly.
    test_touch_active=1; *(float *)(p[13]+0x34)=6;
    dm_aspect_ui_pane(p[13]); assert(*(float *)(p[13]+0x34)==8);
    dm_aspect_ui_pane(p[14]); assert(*(float *)(p[14]+0x34)==6);
    test_touch_active=0; dm_aspect_ui_pane(p[13]); assert(*(float *)(p[13]+0x34)==6);
    // Reused capture names outside the exact dungeon owner must not scale.
    strcpy((char *)p[11]+0xb8,"Other_00"); test_touch_active=1;
    dm_aspect_ui_pane(p[7]); dm_aspect_ui_pane(p[13]);
    assert(*(float *)(p[7]+0x48)==1 && *(float *)(p[13]+0x34)==6);
    test_touch_active=0;
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
}
static void test_right_hud_padding(void) {
    uint8_t root[0x100],all[0x100],state[0x100],heart[0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
    pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
    pane_init(heart,"Pa_HeartGauge_00",-434,312,50); pane_child(state,heart);
    dm_botw_touch_layout layout=dm_botw_layout_defaults();
    const float sizes[][2]={{932,430},{1280,720},{390,844},{795,1100}};
    const float insets[][2]={{0,0},{0,62},{62,0},{62,62},{10,4}};
    for(unsigned n=0;n<sizeof sizes/sizeof *sizes;n++) {
      float w=sizes[n][0],h=sizes[n][1],scale=fminf(w,h)/720;
      dm_aspect_set_display(w/h);
      for(unsigned i=0;i<sizeof insets/sizeof *insets;i++) {
        dm_aspect_set_safe_area(w, h, insets[i][0], 0, insets[i][1]);
        for(int touch=0;touch<2;touch++) {
            test_touch_active=touch;
            float rect[4]; dm_aspect_hud_rect(w,h,rect);
            assert(fabsf(rect[0])<.001f && fabsf(rect[0]+rect[2]-w)<.001f);
            dm_touchpad_rect plus=dm_botw_layout_control(&layout,10,w,h,insets[i][0],0,insets[i][1],0,
                (dm_touchpad_rect){rect[0],rect[1],rect[2],rect[3]});
            float glyph_right=plus.x+plus.width*(1+DM_TP_BOTW_MENU_GLYPH_SIZE/DM_TP_BOTW_MENU_SIZE)*.5f;
            float padding=(insets[i][1]>0 ? insets[i][1]+10*scale : 58*scale+2)+
                2*(1-DM_TP_BOTW_MENU_GLYPH_SIZE/DM_TP_BOTW_MENU_SIZE);
            assert(fabsf(w-glyph_right-padding)<.001f);
            if (insets[i][1]>0) assert(fabsf(w-plus.x-plus.width-insets[i][1])<.001f);
            assert(fabsf(plus.width-39*scale-4)<.001f);
            float extra=fmaxf(0,360*w/h-640),point_scale=1280/fminf(w,h*16.f/9);
            assert(fabsf(dm_aspect_hud_offset(1)-extra)<.001f);
            assert(fabsf(dm_aspect_hud_safe_right()-insets[i][1]*point_scale)<.001f);
            dm_aspect_ui_pane(heart);
            // This authored container's first visible edge is 148 units left
            // of its origin: at native x=-434 it has 58 units of edge padding.
            float visible_left=(*(float *)(heart+0x30)-148*dm_aspect_hud_gain()+640+extra)/point_scale;
            float want_left=insets[i][0]>0 ? insets[i][0] : 58*scale+2;
            assert(fabsf(visible_left-want_left)<.001f);
        }
      }
    }
    // Explicit aspect bars still bound the HUD to the actual game picture.
    float w=932,h=430; dm_aspect_set_display(w/h);
    g_custom=21.f/10; dm_aspect_set_safe_area(w, h, 62, 0, 62);
    float rect[4]; dm_aspect_hud_rect(w,h,rect);
    assert(fabsf(rect[0]+rect[2]-(w+h*g_custom)*.5f)<.001f);
    dm_touchpad_rect plus=dm_botw_layout_control(&layout,10,w,h,62,0,62,0,
        (dm_touchpad_rect){rect[0],rect[1],rect[2],rect[3]});
    assert(fabsf(plus.x+plus.width-(w-62))<.001f);
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
    assert(*(float *)(sensor+0x30)==392 && *(float *)(sensor+0x50)==582); // map cluster hook owns edge translation
    dm_aspect_ui_pane(glyph); assert(*(float *)(glyph+0x30)==20 && *(float *)(glyph+0x50)==32);
    uint64_t regs[31]={0}; regs[21]=(uintptr_t)glyph; draw_callback(regs);
    assert(dm_aspect_ui_hud_drawing() && !dm_aspect_ui_background_drawing());
    draw_end_callback(regs); assert(!dm_aspect_ui_hud_drawing());
    test_touch_active=1; dm_aspect_ui_pane(sensor); assert(*(float *)(sensor+0x30)==392);
    test_touch_active=0; dm_aspect_ui_pane(sensor); assert(*(float *)(sensor+0x30)==392);
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
    assert(fabsf(*(float *)(heart+0x30)+568)<.001f && fabsf(*(float *)(sensor+0x30)-392)<.001f);
    float rect[4]; dm_aspect_hud_rect(1512,720,rect);
    assert(fabsf(rect[0])<.001f && fabsf(rect[2]-1512)<.001f && rect[1]==0 && rect[3]==720);
    dm_aspect_touch_rect(1512,720,rect); assert(fabsf(rect[0]-116)<.001f && rect[2]==1280);
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
    dm_aspect_ui_pane(heart); dm_aspect_ui_pane(sensor);
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
    uint8_t root[0x100],all[0x100],state[0x100],heart[0x100],glyph[0x100],menu[0x100],equipment[0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
    pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
    pane_init(heart,"Pa_HeartGauge_00",-434,312,50); pane_child(state,heart); *(float *)(heart+0x34)=300;
    pane_init(glyph,"P_Heart_00",0,32,32); pane_child(heart,glyph);
    pane_init(menu,"T_Text_00",0,100,40); *(float *)(menu+0x34)=123;
    pane_init(equipment,"N_MainAll_00",-509,14,254); pane_child(all,equipment); *(float *)(equipment+0x34)=210;
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
    const float ratios[]={951.f/669,4.f/3,9.f/16}; uint64_t regs[31]={0};
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
        test_touch_active=1;
        for (int n=0;n<10;n++) dm_aspect_ui_pane(equipment);
        assert(fabsf(*(float *)(equipment+0x30)-(-509*gain))<.001f);
        assert(fabsf(*(float *)(equipment+0x34)-210*sy)<.001f);
        assert(fabsf(*(float *)(equipment+0x48)-gain)<.001f && fabsf(*(float *)(equipment+0x4c)-sy)<.001f);
        test_touch_active=0; dm_aspect_ui_pane(equipment);
        assert(fabsf(*(float *)(equipment+0x30)-(*(float *)(heart+0x30)-75*gain))<.001f);
        assert(fabsf(*(float *)(equipment+0x34)-(*(float *)(heart+0x34)-(25+10+98.35f)*sy))<.001f);
        assert(fabsf(*(float *)(equipment+0x48)-gain)<.001f && fabsf(*(float *)(equipment+0x4c)-sy)<.001f);
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

static void test_touch_hud_target(void) {
    const float sizes[][2]={{932,430},{1280,720},{951,669},{850,598},{390,844},{320,844},{795,1100}};
    const float scales[]={.65f,1,1.5f};
    for (unsigned i=0;i<sizeof sizes/sizeof *sizes;i++) for (int seated=0;seated<2;seated++) {
        float w=sizes[i][0],h=sizes[i][1],region[4];
        dm_aspect_set_display(w/h); dm_aspect_set_seated(seated?.49f:0,seated?.51f:0);
        dm_aspect_set_safe_area(w,h,40,30,40); dm_aspect_region(1,region);
        float aw=w*region[2],ah=h*region[3];
        dm_touchpad_rect canvas=dm_botw_layout_canvas(aw,ah);
        dm_botw_touch_layout layout=dm_botw_layout_defaults_for(dm_botw_compact_mode(aw,ah,40,40));
        for (unsigned n=0;n<sizeof scales/sizeof *scales;n++) {
            layout.control[12].size=96*scales[n];
            dm_touchpad_rect dpad=dm_botw_layout_control(&layout,12,aw,ah,40,30,40,0,canvas);
            float x=w*region[0]+dpad.x+dpad.width*.5f,y=h*region[1]+dpad.y+dpad.height*.5f,target[3];
            assert(dm_aspect_touch_hud_target(w,h,x,y,scales[n],target));
            // Reconstruct screen points from the final HUD canvas. Relocation
            // applies the configured point correction without changing native HUD scaling.
            float rw=fminf(aw,ah*GAME_ASPECT),rh=fmaxf(ah,aw/GAME_ASPECT);
            if (dm_aspect_control_ratio()>=GAME_ASPECT) rh=ah;
            else rw=aw;
            assert(fabsf((w*region[0]+(aw-rw)*.5f)+target[0]*rw-x)<.001f);
            assert(fabsf((h*region[1]+(ah-rh)*.5f)+target[1]*rh-(y+DM_BOTW_LOADOUT_Y_OFFSET_PT))<.001f);
            assert(fabsf(target[2]-scales[n])<.001f);
        }
    }
    float invalid[3]; assert(!dm_aspect_touch_hud_target(0,430,0,0,1,invalid));
    dm_aspect_set_seated(0,0); dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
}

static void test_left_hud_stack(void) {
    uint8_t root[0x100],all[0x100],state[0x100],heart[0x100],equipment[0x100],champions[4][0x100];
    pane_init(root,"RootPane",0,1280,720); pane_init(all,"N_All_00",0,30,30); pane_child(root,all);
    pane_init(state,"N_State_00",0,40,40); pane_child(all,state);
    pane_init(heart,"Pa_HeartGauge_00",-434,312,50); *(float *)(heart+0x34)=310; pane_child(state,heart);
    pane_init(equipment,"N_MainAll_00",-509,14,254); *(float *)(equipment+0x34)=210; pane_child(all,equipment);
    for (int i=0;i<4;i++) {
        char name[16]; snprintf(name,sizeof name,"Pa_SinJu_%02d",i);
        pane_init(champions[i],name,-557,128,124); *(float *)(champions[i]+0x34)=190-i*50;
        pane_child(all,champions[i]);
    }
    const float sizes[][2]={{932,430},{1280,720},{951,669},{669,951},{795,1100}};
    for (unsigned s=0;s<sizeof sizes/sizeof *sizes;s++) for (int safe=0;safe<2;safe++) {
        float w=sizes[s][0],h=sizes[s][1];
        dm_aspect_set_display(w/h); dm_aspect_set_safe_area(w,h,safe?40:0,safe?30:0,0);
        dm_aspect_ui_pane(heart);
        float sy=*(float *)(heart+0x4c),sx=*(float *)(heart+0x48);
        float heart_bottom=*(float *)(heart+0x34)-25*sy;
        for (int mode=0;mode<4;mode++) {
            test_touch_active=mode!=0; test_keep_native_loadout=mode==2;
            test_loadout_visible=mode!=3;
            int at_top=!dm_botw_touch_hud_relocates_loadout() && test_loadout_visible;
            dm_aspect_ui_pane(equipment);
            if (at_top) {
                assert(fabsf(*(float *)(equipment+0x30)-(*(float *)(heart+0x30)-75*sx))<.001f);
                assert(fabsf(heart_bottom-(*(float *)(equipment+0x34)+98.35f*sy)-10*sy)<.001f);
            }
            float bottom=at_top ? *(float *)(equipment+0x34)+19.854f*sy : heart_bottom;
            for (int i=0;i<4;i++) {
                for (int n=0;n<10;n++) dm_aspect_ui_pane(champions[i]);
                float y=*(float *)(champions[i]+0x34);
                assert(fabsf(bottom-(y+30*sy)-10*sy)<.001f);
                assert(fabsf(*(float *)(champions[i]+0x30)-(*(float *)(heart+0x30)-123*sx))<.001f);
                assert(*(float *)(champions[i]+0x48)==sx && *(float *)(champions[i]+0x4c)==sy);
                bottom=y-30*sy;
            }
        }
    }
    test_touch_active=test_keep_native_loadout=0; test_loadout_visible=1;
    dm_aspect_set_display(GAME_ASPECT); dm_aspect_set_safe_area(1280,720,0,0,0);
}

static void test_narrow_fullscreen_background(void) {
    // GameOver_00 keeps its full-canvas background separate from captured
    // lettering and native buttons. Only the background may stretch.
    uint8_t root[0x100],in[0x100],bg[0x100],text[0x100],capture[0x100],button[0x100],art[0x100];
    pane_init(root,"RootPane",0,1280,720);
    pane_init(in,"N_In_00",0,1280,720); pane_child(root,in);
    pane_init(bg,"P_BG_00",0,1280,720); pane_child(in,bg);
    pane_init(text,"T_GameOver_00",0,700,110); pane_child(root,text);
    pane_init(capture,"P_Capture_00",0,740,130); pane_child(in,capture);
    pane_init(button,"Pa_Btn_00",0,500,60); pane_child(root,button);
    pane_init(art,"N_0_MainV_00",0,1280,720); pane_child(root,art);
    const float ratios[]={4.f/3,1,9.f/16,GAME_ASPECT,21.f/10};
    uint64_t regs[31]={0};
    for (unsigned i=0;i<sizeof ratios/sizeof *ratios;i++) {
        dm_aspect_set_display(ratios[i]);
        regs[21]=(uintptr_t)bg; draw_callback(regs);
        assert(dm_aspect_ui_background_drawing()==(ratios[i]<GAME_ASPECT ? 2 : ratios[i]>GAME_ASPECT));
        draw_end_callback(regs); assert(!dm_aspect_ui_background_drawing());
        const uint8_t *foreground[]={text,capture,button};
        for (unsigned p=0;p<sizeof foreground/sizeof *foreground;p++) {
            regs[21]=(uintptr_t)foreground[p]; draw_callback(regs);
            assert(!dm_aspect_ui_background_drawing()); draw_end_callback(regs);
        }
    }
    dm_aspect_set_display(4.f/3);
    // A partial-height panel or a container is not a full-screen fill.
    *(float *)(bg+0x54)=360; regs[21]=(uintptr_t)bg; draw_callback(regs);
    assert(!dm_aspect_ui_background_drawing()); draw_end_callback(regs);
    *(float *)(bg+0x54)=720; pane_child(bg,text); draw_callback(regs);
    assert(!dm_aspect_ui_background_drawing()); draw_end_callback(regs);
    // Title artwork retains its centered proportions on narrow displays.
    strcpy((char *)in+0xb8,"N_InOut_00"); pane_child(in,art);
    pane_init(bg,"TitleBG_00",0,1280,720); pane_child(art,bg);
    draw_callback(regs); assert(!dm_aspect_ui_background_drawing()); draw_end_callback(regs);
    dm_aspect_set_display(GAME_ASPECT);
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
        assert(dm_aspect_ui_hud_drawing()==1); draw_end_callback(regs); // controller equipment stays in the upper picture
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
    test_narrow_fullscreen_background();
    test_seated_regions();
    test_left_hud_stack();
    test_touch_hud_target();
    test_inventory_footer();
    test_slate_footer();
    test_slate_side_frames();
    test_menu_headers();
    test_dungeon_controls();
    free(g_mod[0].base); puts("aspect: camera, centered content/hit regions and independent fullscreen backgrounds passed");
}
