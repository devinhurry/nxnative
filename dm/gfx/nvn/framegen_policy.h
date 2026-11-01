// Experimental frame generation is available only to a profile with validated scene/camera inputs.
#pragma once
#include <stdlib.h>
#include <string.h>
#include "game_profile.h"
// Values are source rates; -1 inserts a picture for every uncapped real pair.
static inline int dm_framegen_parse(const char *value) {
    if (!value || !strcmp(value,"0")) return 0;
    if (!strcmp(value,"max")) return -1;
    if (!strcmp(value,"30")) return 30;
    if (!strcmp(value,"40")) return 40;
    if (!strcmp(value,"50")) return 50;
    if (!strcmp(value,"60")) return 60;
    return 0;
}
static inline int dm_framegen_requested(void) {
    return *DM_GAME_FRAMEGEN_SCENE && dm_framegen_parse(getenv("DM_FRAMEGEN"))!=0;
}
extern int dm_fg_enabled(void);
extern int dm_fg_mode(void);
extern int dm_fg_requested_mode(void);
extern int dm_fg_set_mode(int mode); // request from any front end; applied at a real-frame boundary
extern int dm_fg_latch(void);        // NVN present thread only
static inline int dm_framegen_active(void) {
    return *DM_GAME_FRAMEGEN_SCENE && dm_fg_enabled();
}
