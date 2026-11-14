#import "DmTouchFeedback.h"
#import <CoreHaptics/CoreHaptics.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <AVFAudio/AVFAudio.h>
#endif

@interface DmTouchFeedback ()
@property(nonatomic, strong) CHHapticEngine *engine;
@property(nonatomic, strong) id<CHHapticPatternPlayer> player;
@property(nonatomic) BOOL active;
@property(nonatomic) NSUInteger generation;
- (CHHapticEngine *)makeEngine:(NSError **)error;
@end

@implementation DmTouchFeedback
static void reportTouchHapticError(NSString *stage, NSError *error) {
    NSLog(@"[RED] touch haptics: %@: %@", stage, error);
}
- (CHHapticEngine *)makeEngine:(NSError **)error {
#if TARGET_OS_IPHONE
    if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) return nil;
    return [[CHHapticEngine alloc] initWithAudioSession:AVAudioSession.sharedInstance error:error];
#else
    (void)error; return nil; // Host fixtures inject their engine without opening hardware.
#endif
}
- (void)prepareEngine:(CHHapticEngine *)engine {
    self.player = nil;
    NSUInteger generation = ++self.generation;
    __weak DmTouchFeedback *weak = self;
    [engine startWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DmTouchFeedback *feedback = weak;
            if (!feedback.active || feedback.engine != engine || feedback.generation != generation) return;
            if (error) { reportTouchHapticError(@"start engine", error); return; }
            NSError *creationError = nil;
            CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                parameters:@[
                    // UIKit Light's intensity is not the same scale as a raw transient.
                    [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:0.32f],
                    [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5f]
                ] relativeTime:0];
            CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&creationError];
            if (!pattern) { reportTouchHapticError(@"create pattern", creationError); return; }
            feedback.player = [engine createPlayerWithPattern:pattern error:&creationError];
            if (!feedback.player) reportTouchHapticError(@"create player", creationError);
        });
    }];
}
- (void)setActive:(BOOL)active {
    NSAssert(NSThread.isMainThread, @"Touch feedback must run on the main thread");
    if (_active == active) return;
    _active = active;
    if (!active) {
        self.generation++;
        self.player = nil;
        CHHapticEngine *engine = self.engine;
        self.engine = nil;
        [engine stopWithCompletionHandler:^(NSError *error) {
            if (error) reportTouchHapticError(@"stop engine", error);
        }];
        return;
    }
    if (self.engine) return;
    NSError *error = nil;
    CHHapticEngine *engine = [self makeEngine:&error];
    if (!engine) {
        if (error) reportTouchHapticError(@"create engine", error);
        return;
    }
    self.engine = engine;
    engine.playsHapticsOnly = YES;
    engine.autoShutdownEnabled = NO;
    __weak DmTouchFeedback *weak = self;
    __weak CHHapticEngine *expected = engine;
    engine.resetHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            DmTouchFeedback *feedback = weak;
            if (feedback.active && expected && feedback.engine == expected) [feedback prepareEngine:expected];
        });
    };
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            DmTouchFeedback *feedback = weak;
            if (!expected || feedback.engine != expected) return;
            feedback.generation++;
            feedback.player = nil;
            NSLog(@"touch haptics: engine stopped (reason %ld)", (long)reason);
        });
    };
    [self prepareEngine:engine];
}
- (BOOL)play {
    NSAssert(NSThread.isMainThread, @"Touch feedback must run on the main thread");
    if (!self.active || !self.player) return NO;
    NSError *error = nil;
    if (![self.player startAtTime:CHHapticTimeImmediate error:&error]) {
        reportTouchHapticError(@"play transient", error);
        self.player = nil;
        return NO;
    }
    return YES;
}
- (void)dealloc {
    [_engine stopWithCompletionHandler:nil];
}
@end
