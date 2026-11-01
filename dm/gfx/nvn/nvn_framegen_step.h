// Real-frame time, in seconds. Adapted from MacNativeGames' BOTW real-time
// step (MIT): average intervals before limiting long interruptions. Generated
// pictures never call this. The game latches the result once per game frame.
#pragma once
#include <stdint.h>
#include <string.h>
typedef struct { uint64_t last; double samples[5]; unsigned count,next; int mode; } nvn_framegen_step;
static inline int nvn_framegen_set_mode(nvn_framegen_step *s,int mode) {
    if (s->mode==mode) return 0;
    memset(s,0,sizeof *s); s->mode=mode; return 1;
}
static inline double nvn_framegen_seconds(nvn_framegen_step *s,uint64_t now,int mode,int rate) {
    nvn_framegen_set_mode(s,mode);
    double dt=s->last && now>=s->last ? (now-s->last)*1e-9 : 0;
    s->last=now;
    if (dt<.001 || dt>.25) { s->count=s->next=0; return 1.0/(rate>0?rate:60); }
    s->samples[s->next++%5]=dt;
    if (s->count<5) s->count++;
    double sum=0; for (unsigned i=0;i<s->count;i++) sum+=s->samples[i];
    double seconds=sum/s->count;
    return seconds>1./15 ? 1./15 : seconds;
}
