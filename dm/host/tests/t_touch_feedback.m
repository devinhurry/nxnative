// Exercise the production player lifecycle without an actuator or an audio session.
#import <Foundation/Foundation.h>
#include <assert.h>
#import "../../ios/Sources/DmTouchFeedback.m"

@interface FeedbackPlayer : NSObject
@property int plays;
@property BOOL fail;
@end
@implementation FeedbackPlayer
- (BOOL)startAtTime:(NSTimeInterval)time error:(NSError **)error {
    assert(time == CHHapticTimeImmediate);
    self.plays++;
    if (self.fail) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil];
    return !self.fail;
}
@end

@interface FeedbackEngine : NSObject
@property BOOL playsHapticsOnly, autoShutdownEnabled;
@property int starts, stops, players;
@property(nonatomic, copy) CHHapticCompletionHandler completion;
@property(nonatomic, copy) CHHapticEngineResetHandler resetHandler;
@property(nonatomic, copy) CHHapticEngineStoppedHandler stoppedHandler;
@property FeedbackPlayer *lastPlayer;
@end
@implementation FeedbackEngine
- (void)startWithCompletionHandler:(CHHapticCompletionHandler)completion {
    self.starts++; self.completion = completion;
}
- (void)stopWithCompletionHandler:(CHHapticCompletionHandler)completion {
    self.stops++; if (completion) completion(nil);
}
- (id)createPlayerWithPattern:(CHHapticPattern *)pattern error:(NSError **)error {
    (void)error;
    assert(pattern != nil);
    self.players++; self.lastPlayer = [FeedbackPlayer new]; return self.lastPlayer;
}
@end

@interface FeedbackFixture : DmTouchFeedback
@property FeedbackEngine *nextEngine;
@end
@implementation FeedbackFixture
- (CHHapticEngine *)makeEngine:(NSError **)error {
    (void)error; return (CHHapticEngine *)self.nextEngine;
}
@end

static void drain_main(void) {
    __block BOOL finished = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    assert(finished);
}

int main(void) { @autoreleasepool {
    FeedbackFixture *feedback = [FeedbackFixture new];
    FeedbackEngine *engine = [FeedbackEngine new]; feedback.nextEngine = engine;
    [feedback setActive:YES];
    [feedback setActive:YES];
    assert(engine.starts == 1 && engine.playsHapticsOnly && !engine.autoShutdownEnabled);
    assert(![feedback play]); // Starting does not enqueue an effect for later playback.
    engine.completion(nil); drain_main();
    assert(engine.players == 1 && engine.lastPlayer.plays == 0);
    for (int i = 0; i < 20; i++) assert([feedback play]);
    assert(engine.starts == 1 && engine.players == 1 && engine.lastPlayer.plays == 20);

    CHHapticEngineResetHandler reset = engine.resetHandler;
    reset(); drain_main();
    assert(![feedback play] && engine.starts == 2);
    engine.completion(nil); drain_main();
    assert(engine.players == 2 && engine.lastPlayer.plays == 0 && [feedback play]);

    // Disabling feedback invalidates callbacks from the old engine.
    reset(); drain_main();
    CHHapticCompletionHandler late = engine.completion;
    [feedback setActive:NO];
    assert(![feedback play] && engine.stops == 1);
    late(nil); reset(); drain_main();
    assert(feedback.player == nil && engine.starts == 3 && engine.players == 2);

    FeedbackEngine *next = [FeedbackEngine new]; feedback.nextEngine = next;
    [feedback setActive:YES];
    next.completion(nil); drain_main();
    assert([feedback play] && next.lastPlayer.plays == 1);
    next.lastPlayer.fail = YES;
    assert(![feedback play] && ![feedback play]);
    assert(next.starts == 1 && next.lastPlayer.plays == 2); // No hidden retry or delayed replay.
    [feedback setActive:NO];

    FeedbackEngine *failed = [FeedbackEngine new]; feedback.nextEngine = failed;
    [feedback setActive:YES];
    failed.completion([NSError errorWithDomain:@"fixture" code:2 userInfo:nil]); drain_main();
    assert(![feedback play] && failed.starts == 1 && !failed.players);
    [feedback setActive:NO];
    puts("touch feedback: prestarted player, immediate presses, reset and suspension passed");
} }
