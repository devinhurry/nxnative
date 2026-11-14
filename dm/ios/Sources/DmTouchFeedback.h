#pragma once
#import <Foundation/Foundation.h>

// Replacement for late UIKit playback reported on iPhone; device feedback confirms prompt playback.
// A prepared transient player: button presses never start an engine or queue a replay.
@interface DmTouchFeedback : NSObject
- (void)setActive:(BOOL)active;
- (BOOL)play;
@end
