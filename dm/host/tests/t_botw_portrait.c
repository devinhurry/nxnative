// Rotation permission shares the control layout's 600pt usable-width boundary.
#include "../botw_touch_layout.h"
#include <assert.h>

int main(void) {
    const float cases[][5]={
        {390,844,0,0,0}, {844,390,59,34,0}, {599.9f,1000,0,0,0},
        {600,1000,0,0,1}, {1000,600,20,20,1}, {620,1000,10,10,1},
        {620,1000,10,11,0}, {744,1133,0,0,1}, {1133,744,0,0,1},
        {768,1024,0,0,1}, {1024,768,0,0,1}, {590,590,0,0,1}
    };
    for (int enabled=0;enabled<2;enabled++) {
        setenv("DM_BOTW_PORTRAIT",enabled ? "1" : "0",1);
        for (unsigned i=0;i<sizeof cases/sizeof *cases;i++) {
            const float *c=cases[i];
            assert(dm_botw_portrait_allowed(c[0],c[1],c[2],c[3])==(enabled || c[4]));
            if (c[1]>=c[0]) assert(dm_botw_compact_mode(c[0],c[1],c[2],c[3])==!c[4]);
        }
    }
    unsetenv("DM_BOTW_PORTRAIT");
    assert(!dm_botw_portrait_allowed(390,844,0,0));
    assert(dm_botw_portrait_allowed(768,1024,0,0));
    assert(!dm_botw_portrait_allowed(0,0,0,0));
    puts("BOTW portrait rotation: compact opt-in, wide default, both orientations and safe insets passed");
    return 0;
}
