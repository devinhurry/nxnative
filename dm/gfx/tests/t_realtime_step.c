// Functional game-clock controls: generated pictures never advance this clock.
#include "../nvn/nvn_realtime_step.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    for (int rate=30;rate<=120;rate+=10) {
        nvn_realtime_step step={0}; uint64_t now=1000000000ull; double seconds=0;
        (void)nvn_realtime_seconds(&step,now,rate,rate);
        for (int i=0;i<rate;i++) { now=1000000000ull+(uint64_t)llround((i+1)*1e9/rate); seconds+=nvn_realtime_seconds(&step,now,rate,rate); }
        assert(fabs(seconds-1)<1e-7); // one real second, independently of source rate
    }
    nvn_realtime_step step={0};
    assert(nvn_realtime_seconds(&step,1000000000ull,30,30)==1./30);
    assert(nvn_realtime_seconds(&step,2000000000ull,30,30)==1./30); // interruption is not replayed
    assert(nvn_realtime_seconds(&step,2000000000ull,40,40)==1./40); // rate change starts fresh
    assert(nvn_realtime_seconds(&step,2000000000ull,0,60)==1./60);
    assert(nvn_realtime_set_mode(&step,30));
    assert(nvn_realtime_seconds(&step,3000000000ull,30,30)==1./30);
    (void)nvn_realtime_seconds(&step,3050000000ull,30,30);
    assert(!nvn_realtime_set_mode(&step,30));
    assert(nvn_realtime_set_mode(&step,0));
    assert(nvn_realtime_set_mode(&step,30));
    assert(nvn_realtime_seconds(&step,3100000000ull,30,30)==1./30); // no sample crosses Off
    assert(nvn_realtime_wanted(1,0,45,0,0) && nvn_realtime_wanted(1,1,60,0,0));
    assert(!nvn_realtime_wanted(0,1,45,0,0) && !nvn_realtime_wanted(1,0,60,0,0));
    assert(!nvn_realtime_wanted(1,0,45,1,0) && !nvn_realtime_wanted(1,1,60,1,0));
    assert(!nvn_realtime_wanted(1,0,45,0,2) && !nvn_realtime_wanted(1,1,60,0,1));
    assert(nvn_realtime_rate_valid(20,1) && nvn_realtime_rate_valid(120,1));
    assert(!nvn_realtime_rate_valid(45,0) && !nvn_realtime_rate_valid(22,1) && !nvn_realtime_rate_valid(125,1));
    puts("real-time source clocks: 30..120, interruption and mode changes: OK");
}
