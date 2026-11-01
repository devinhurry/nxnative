// Exercise the loader's actual frame-step state, including capability failure.
#include "../dm.h"
#include "../hle.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
struct dm_flags g_flag;
uint64_t now_ns(void) { return 0; }
void gate_register(uint64_t a,const char *k,int n,uint64_t o) { (void)a; (void)k; (void)n; (void)o; }
void hlecount_seal(void) {}
void *hlecount_wrap(const char *k,const char *n,void *f) { (void)k; (void)n; return f; }
uint64_t resolve_import(module_t *m,const char *n) { (void)m; (void)n; return 0; }
int hle_implements(const char *n) { (void)n; return 0; }
int svc_nro_deactivate(module_t *m) { (void)m; return 1; }
static int supported;
int dm_fg_enabled(void) { return supported; } // replaces loader's CPU-only weak definition
extern uint8_t *dm_fps_state;
extern void dm_fps_state_apply(void);
static void expect_target(float expected) {
    dm_fps_state_apply(); float target; memcpy(&target,dm_fps_state,sizeof target); assert(target==expected);
}
int main(void) {
    uint8_t state[80]={0}; dm_fps_state=state;
    setenv("DM_FPS_TARGET","60",1); setenv("DM_OPMODE","1",1); unsetenv("DM_RENDER_SCALE");
    setenv("DM_FRAMEGEN","30",1); supported=0; expect_target(60);
    supported=1; expect_target(*DM_GAME_FRAMEGEN_SCENE?30:60);
    setenv("DM_FRAMEGEN","0",1); expect_target(60);
    unsetenv("DM_FRAMEGEN"); expect_target(60);
    setenv("DM_FRAMEGEN","30",1); setenv("DM_OPMODE","0",1); expect_target(*DM_GAME_FRAMEGEN_SCENE?30:60);
    for (const char **p=(const char *[]){"40","50","60","max",NULL};*p;p++) {
        setenv("DM_FRAMEGEN",*p,1); expect_target(*DM_GAME_FRAMEGEN_SCENE && strcmp(*p,"max")?atoi(*p):60);
    }
    extern void dm_framegen_mode_changed(int);
    setenv("DM_FRAMEGEN","0",1); setenv("DM_FPS_TARGET","30",1); expect_target(30);
    dm_framegen_mode_changed(50); float target,ratio;
    memcpy(&target,state,4); memcpy(&ratio,state+0x40,4); assert(target==50 && ratio==.6f);
    *(uint32_t *)(state+0x20)=3;
    dm_framegen_mode_changed(0); memcpy(&target,state,4); memcpy(&ratio,state+0x40,4); assert(target==30 && ratio==0);
    assert(*(uint32_t *)(state+0x20)==2); // the first ordinary frame cannot inherit the old step
    puts("framegen: unavailable, supported, off, default and handheld FPS state: OK");
    return 0;
}
