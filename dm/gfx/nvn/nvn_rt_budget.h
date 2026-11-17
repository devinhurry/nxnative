// Per-thread CPU demand, sampled once per frame. No wall-clock pacing or GPU wait is counted.
#ifndef NVN_RT_BUDGET_H
#define NVN_RT_BUDGET_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef struct { uint64_t last,period,epoch,win[120];unsigned n;int seeded; } nvn_rt_budget;
static int nvn_rt_cmp(const void *a,const void *b) { uint64_t x=*(const uint64_t *)a,y=*(const uint64_t *)b;return (x>y)-(x<y); }
static uint64_t nvn_rt_clamp(uint64_t value,uint64_t period) {
    if(value<1000000)value=1000000;
    return value>period*9/10?period*9/10:value;
}
static uint64_t nvn_rt_next(nvn_rt_budget *s,uint64_t cpu,uint64_t period,uint64_t epoch,uint64_t current) {
    if(!period)return 0;
    if(!s->seeded || s->period!=period || s->epoch!=epoch || cpu<s->last) {
        s->last=cpu;s->period=period;s->epoch=epoch;s->n=0;s->seeded=1;return 0;
    }
    uint64_t cost=cpu-s->last;s->last=cpu;s->win[s->n++]=cost;
    uint64_t wanted=0;int full=s->n==120;
    if(full) {
        uint64_t v[120];memcpy(v,s->win,sizeof v);qsort(v,120,sizeof *v,nvn_rt_cmp);s->n=0;
        wanted=v[107]*5/4;if(v[119]*11/10>wanted)wanted=v[119]*11/10;
    }
    // Raise on the first over-budget frame; only a complete window can lower it.
    if(cost>current && cost*11/10>wanted)wanted=cost*11/10;
    if(!wanted)return 0;
    wanted=nvn_rt_clamp(wanted,period);
    return wanted!=current && (cost>current || wanted>current*115/100 || (full && wanted<current*85/100))?wanted:0;
}
#endif
