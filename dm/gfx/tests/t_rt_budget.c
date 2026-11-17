#include "../nvn/nvn_rt_budget.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    const uint64_t ms=1000000,period=33333333;uint64_t cpu=0,current=2*ms;
    nvn_rt_budget replay={0},acquire={0};
    assert(!nvn_rt_next(&replay,cpu,period,0,current));
    cpu+=14*ms;uint64_t next=nvn_rt_next(&replay,cpu,period,0,current);
    assert(next==15400000);current=next; // first heavy frame raises immediately
    assert(!nvn_rt_next(&acquire,0,period,0,2*ms));
    for(int i=0;i<119;i++)assert(!nvn_rt_next(&acquire,(uint64_t)(i+1)*ms,period,0,ms));
    assert(nvn_rt_next(&acquire,120*ms,period,0,ms)==1250000);
    assert(replay.n==1 && replay.last==14*ms); // independent thread samples
    for(int i=0;i<119;i++){cpu+=ms;next=nvn_rt_next(&replay,cpu,period,0,current);}
    assert(next==0); // isolated 14 ms peak remains protected for its window
    for(int i=0;i<119;i++){cpu+=ms;assert(!nvn_rt_next(&replay,cpu,period,0,current));}
    cpu+=ms;next=nvn_rt_next(&replay,cpu,period,0,current);assert(next==1250000);
    current=next;cpu+=100*ms;next=nvn_rt_next(&replay,cpu,period,0,current);assert(next==period*9/10);
    assert(!nvn_rt_next(&replay,cpu+1000*ms,period,1,next)); // resume discards pre-pause history
    assert(replay.n==0);
    cpu+=1001*ms;assert(!nvn_rt_next(&replay,cpu,16666666,1,next)); // new rate starts a fresh window
    assert(replay.period==16666666 && replay.n==0);
    assert(!nvn_rt_next(&replay,1,16666666,1,next)); // clock reset cannot underflow
    assert(!nvn_rt_next(&replay,10,0,1,next));
    assert(nvn_rt_clamp(0,period)==ms && nvn_rt_clamp(100*ms,16666666)==14999999);
    puts("replay CPU budget: prompt raise, p90/peak window, independent threads, resume, rate changes and caps passed");
    return 0;
}
