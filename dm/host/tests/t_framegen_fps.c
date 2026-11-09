// Exercise the loader's actual frame-step state, including capability failure.
#include "../dm.h"
#include "../hle.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
struct dm_flags g_flag;
uint64_t now_ns(void) { return 0; }
void mtl_present_screen(uint32_t w, uint32_t h) { (void)w; (void)h; }
void gate_register(uint64_t a,const char *k,int n,uint64_t o) { (void)a; (void)k; (void)n; (void)o; }
void hlecount_seal(void) {}
void *hlecount_wrap(const char *k,const char *n,void *f) { (void)k; (void)n; return f; }
uint64_t resolve_import(module_t *m,const char *n) { (void)m; (void)n; return 0; }
int hle_implements(const char *n) { (void)n; return 0; }
int svc_nro_deactivate(module_t *m) { (void)m; return 1; }
static int supported, requested, has_request;
int dm_fg_set_mode(int mode) { if (mode && !supported) return 0; requested=mode; has_request=1; return 1; }
int dm_fg_requested_mode(void) { const char *e=getenv("DM_FRAMEGEN"); return has_request ? requested : (supported && e ? (!strcmp(e,"max") ? -1 : atoi(e)) : 0); }
int dm_fg_enabled(void) { return supported; } // replaces loader's CPU-only weak definition
extern uint8_t *dm_fps_state;
extern int dm_fps_realtime;
extern void dm_fps_state_apply(void);
static void expect_target(float expected) {
    dm_fps_state_apply(); float target; memcpy(&target,dm_fps_state,sizeof target); assert(target==expected);
}
int main(void) {
    uint8_t state[256]={0}; dm_fps_state=state; dm_fps_realtime=1;
    setenv("DM_FPS_TARGET","60",1); setenv("DM_OPMODE","1",1); unsetenv("DM_RENDER_SCALE");
    setenv("DM_FRAMEGEN","30",1); supported=0; expect_target(60);
    supported=1; expect_target(*DM_GAME_FRAMEGEN_SCENE?30:60);
    dm_fps_realtime=0; expect_target(60); dm_fps_realtime=1;
    setenv("DM_FRAMEGEN","0",1); expect_target(60);
    unsetenv("DM_FRAMEGEN"); expect_target(60);
    setenv("DM_FRAMEGEN","30",1); setenv("DM_OPMODE","0",1); expect_target(*DM_GAME_FRAMEGEN_SCENE?30:60);
    for (const char **p=(const char *[]){"40","50","60","max",NULL};*p;p++) {
        setenv("DM_FRAMEGEN",*p,1); expect_target(*DM_GAME_FRAMEGEN_SCENE && strcmp(*p,"max")?atoi(*p):60);
    }
    extern void dm_framegen_mode_changed(int);
    setenv("DM_FRAMEGEN","0",1); setenv("DM_FPS_TARGET","30",1); expect_target(30);
    *(uint32_t *)(state+0x40)=0x12345678;
    for (int rate=20;rate<=60;rate+=5) {
        dm_framegen_mode_changed(rate); float step;
        memcpy(&step,state+0xa0,4); assert(step==30.f/rate);
        assert(*(uint32_t *)(state+0x40)==0x12345678);
    }
    dm_framegen_mode_changed(50); float target,ratio;
    memcpy(&target,state,4); memcpy(&ratio,state+0xa0,4); assert(target==50 && ratio==.6f);
    *(uint32_t *)(state+0x20)=3;
    dm_framegen_mode_changed(0); memcpy(&target,state,4); memcpy(&ratio,state+0xa0,4); assert(target==30 && ratio==0);
    assert(*(uint32_t *)(state+0x20)==2); // the first ordinary frame cannot inherit the old step
    extern void dm_fps_live_update(void);
    extern int dm_fps_resolution_budget;
    setenv("DM_FRAMEGEN", "0", 1); setenv("DM_FPS_TARGET", "30", 1); expect_target(30);
    assert(!dm_fps_live_rate(21) && !dm_fps_live_rate(0) && dm_fps_live_rate(45));
    memcpy(&target,state,4); assert(target==30); // no mid-frame change
    dm_fps_live_update(); memcpy(&target,state,4); memcpy(&ratio,state+0xa0,4);
    assert(target==45 && ratio==30.f/45);
    assert(!dm_fps_live_scale(.49f) && !dm_fps_live_scale(1.01f));
    dm_fps_resolution_budget=1; *(uint32_t *)(state+0x40)=1;
    assert(dm_fps_live_scale(.5f)); dm_fps_live_update();
    memcpy(&ratio,state+0x10,4); assert(ratio==.5f); memcpy(&ratio,state+0x38,4); assert(ratio==0);
    assert(dm_fps_live_scale(1.f)); dm_fps_live_update(); memcpy(&ratio,state+0x38,4); assert(ratio==150.f);
    setenv("DM_FRAMEGEN", "30", 1); setenv("DM_DYNAMIC_RESOLUTION", "1", 1); supported=1; expect_target(30);
    assert(dm_fps_live_rate(50) && !strcmp(getenv("DM_FRAMEGEN"),"50"));
    dm_fps_live_update(); dm_framegen_mode_changed(50); memcpy(&target,state,4); assert(target==50);
    memcpy(&ratio,state+0x38,4); assert(ratio > 166.f && ratio < 167.f); // dynamic resolution follows the new FPS
    assert(dm_fps_live_rate(100) && !strcmp(getenv("DM_FRAMEGEN"),"0"));
    dm_fps_live_update(); memcpy(&target,state,4); assert(target==100);
    dm_fps_realtime=0; assert(!dm_fps_live_rate(45) && dm_fps_live_rate(60)); dm_fps_live_update(); dm_fps_realtime=1;
    assert(dm_fps_live_framegen(40) && !strcmp(getenv("DM_FRAMEGEN"),"40") && !strcmp(getenv("DM_FPS_TARGET"),"40"));
    dm_fps_live_update(); dm_framegen_mode_changed(40); memcpy(&target,state,4); assert(target==40);
    assert(dm_fps_live_framegen(0) && !strcmp(getenv("DM_FRAMEGEN"),"0"));
    dm_framegen_mode_changed(0); memcpy(&target,state,4); assert(target==40);
    supported=0; assert(!dm_fps_live_framegen(30));
    puts("framegen and live rate/scale state: OK");
    return 0;
}
