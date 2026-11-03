#pragma once
#import <UIKit/UIKit.h>
#include "touchpad_geometry.h"

// Shared by the play surface and the full-screen layout editor. UIKit tracks
// reserved-region reads during updateConstraints, including folds at fixed size.
static inline CGRect dm_botw_touch_division(UIView *view) {
#if defined(__IPHONE_27_1) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_27_1
    if (@available(iOS 27.1, *)) {
        for (UIViewReservedRegion *region in [view reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]]) {
            dm_touchpad_rect picture, controls;
            CGRect r = region.frame, b = view.bounds;
            if (dm_touchpad_seated_split((dm_touchpad_rect){b.origin.x,b.origin.y,b.size.width,b.size.height},
                (dm_touchpad_rect){r.origin.x,r.origin.y,r.size.width,r.size.height}, &picture, &controls)) return r;
        }
    }
#endif
    (void)view;
    return CGRectNull;
}
