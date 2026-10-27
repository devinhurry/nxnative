// BOTW touch artwork only; ordinary gamepads keep their own style.
#pragma once
#import <Foundation/Foundation.h>
#include <stdlib.h>

#define DM_BOTW_BUTTON_GRAY .15
#define DM_BOTW_BUTTON_ALPHA .35
#define DM_BOTW_STROKE_GRAY .12
#define DM_BOTW_STROKE_ALPHA .40

static inline NSString *dm_botw_touch_y_icon_path(void) {
    const char *map = getenv("DM_NVN_SHMAP");
    NSString *folder = map && *map ? [[NSString stringWithUTF8String:map] stringByDeletingLastPathComponent] :
        [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"dm"];
    return [folder stringByAppendingPathComponent:@"touch_y.png"];
}
