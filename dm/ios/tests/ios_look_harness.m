#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
UIView *dm_gamepad_view(CGRect frame);
void dm_test_motion_reset(void);
void dm_test_motion_recenter(void);
void dm_test_motion_publish(CMQuaternion q, CMAcceleration a, CMRotationRate r);
void dm_gamepad_geometry_changed(UIInterfaceOrientation orientation);
void front_look_mode_changed(void);

@interface DmGamepad : UIView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)setFull:(BOOL)full;
- (void)reset;
- (void)padsChanged;
- (void)deviceOrientationChanged;
- (CGPoint)facePos:(int)button;
- (CGPoint)clickCenter:(int)button;
@end

@interface FakeTouch : UITouch
@property(nonatomic) CGPoint point;
- (instancetype)initAt:(CGPoint)point;
@end
@implementation FakeTouch
- (instancetype)initAt:(CGPoint)point { if ((self = [super init])) _point = point; return self; }
- (CGPoint)locationInView:(UIView *)view { (void)view; return self.point; }
@end

static BOOL g_look_enabled = YES, g_look_held;
typedef struct { int phase; float dx, dy; } look_event;
static look_event g_look_events[512];
static int g_look_count, g_failures, g_begin_count;
static float g_queued_dx, g_queued_dy;
static uint64_t g_buttons;
static int32_t g_lx, g_ly, g_rx, g_ry;
static uint64_t g_pad_buttons;
static int32_t g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static int g_input_sets, g_pad_sets;
static dm_touch g_last_touch;
static int g_touch_count, g_touch_sets;
static dm_motion g_motion_samples[16];
static int g_motion_count;

int dm_look_enabled(void) { return g_look_enabled; }
void dm_look_input(int phase, float dx, float dy) {
    if (g_look_count >= (int)(sizeof g_look_events / sizeof g_look_events[0])) abort();
    g_look_events[g_look_count++] = (look_event){phase, dx, dy};
    if (phase == DM_LOOK_BEGIN) {
        if (g_look_held) { fprintf(stderr, "FAIL: nested DM_LOOK_BEGIN\n"); ++g_failures; }
        g_look_held = YES; ++g_begin_count; g_queued_dx = g_queued_dy = 0;
    } else if (phase == DM_LOOK_MOVE) {
        if (!g_look_held) { fprintf(stderr, "FAIL: DM_LOOK_MOVE without BEGIN\n"); ++g_failures; }
        g_queued_dx += dx; g_queued_dy += dy;
    } else if (phase == DM_LOOK_END) {
        if (!g_look_held) { fprintf(stderr, "FAIL: DM_LOOK_END without BEGIN\n"); ++g_failures; }
        g_look_held = NO;
    } else if (phase == DM_LOOK_CANCEL) {
        g_look_held = NO; g_queued_dx = g_queued_dy = 0;
    }
}
void dm_input_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    ++g_input_sets;
    g_buttons = buttons; g_lx = lx; g_ly = ly; g_rx = rx; g_ry = ry;
}
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    ++g_pad_sets;
    g_pad_buttons = buttons; g_pad_lx = lx; g_pad_ly = ly; g_pad_rx = rx; g_pad_ry = ry;
}
void dm_touch_set(const dm_touch *touches, int count) {
    g_touch_count = count; ++g_touch_sets;
    if (count > 0 && touches) g_last_touch = touches[0];
}
void dm_aspect_touch_rect(float w, float h, float rect[4]) { rect[0] = rect[1] = 0; rect[2] = w; rect[3] = h; }
void dm_motion_set(const dm_motion *motion) {
    if (g_motion_count >= (int)(sizeof g_motion_samples / sizeof g_motion_samples[0])) abort();
    g_motion_samples[g_motion_count++] = *motion;
}

#define CHECK(condition, description) do { \
    if (condition) printf("PASS: %s\n", description); \
    else { fprintf(stderr, "FAIL: %s\n", description); ++g_failures; } \
} while (0)

static FakeTouch *touch(CGFloat x, CGFloat y) { return [[FakeTouch alloc] initAt:CGPointMake(x, y)]; }
static void began(DmGamepad *view, FakeTouch *t) { [view touchesBegan:[NSSet setWithObject:t] withEvent:nil]; }
static void moved(DmGamepad *view, FakeTouch *t, CGFloat x, CGFloat y) { t.point = CGPointMake(x, y); [view touchesMoved:[NSSet setWithObject:t] withEvent:nil]; }
static void ended(DmGamepad *view, FakeTouch *t, CGFloat x, CGFloat y) { t.point = CGPointMake(x, y); [view touchesEnded:[NSSet setWithObject:t] withEvent:nil]; }
static void cancelled(DmGamepad *view, FakeTouch *t, CGFloat x, CGFloat y) { t.point = CGPointMake(x, y); [view touchesCancelled:[NSSet setWithObject:t] withEvent:nil]; }
static void reset_look(void) {
    if (g_look_held) { fprintf(stderr, "FAIL: test left look session held\n"); ++g_failures; g_look_held = NO; }
    g_look_count = 0; g_queued_dx = g_queued_dy = 0;
}
static void near_value(float got, float want, const char *description) {
    CHECK(fabsf(got - want) < 1e-6f, description);
}
static CMQuaternion motion_mul(CMQuaternion a, CMQuaternion b) {
    return (CMQuaternion){
        .w = a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z,
        .x = a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
        .y = a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
        .z = a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
    };
}
static BOOL motion_quaternion_matches(CMQuaternion got, CMQuaternion expected) {
    double gn = sqrt(got.w*got.w + got.x*got.x + got.y*got.y + got.z*got.z);
    double en = sqrt(expected.w*expected.w + expected.x*expected.x + expected.y*expected.y + expected.z*expected.z);
    double dot = (got.w*expected.w + got.x*expected.x + got.y*expected.y + got.z*expected.z) / (gn * en);
    return fabs(fabs(dot) - 1.0) < 1e-6;
}
static void sum_moves(float *dx, float *dy) {
    *dx = *dy = 0;
    for (int i = 0; i < g_look_count; i++) if (g_look_events[i].phase == DM_LOOK_MOVE) {
        *dx += g_look_events[i].dx; *dy += g_look_events[i].dy;
    }
}

static void test_look_drag(DmGamepad *view) {
    g_look_enabled = YES; [view setFull:YES];
    reset_look();
    FakeTouch *t = touch(600, 150);
    began(view, t); moved(view, t, 615, 165);
    CHECK(g_rx > 0 && g_ry < 0 && abs(g_rx - 23170) <= 1 && abs(g_ry + 23170) <= 1,
          "the owning look finger also publishes its legacy full-tilt right-stick direction");
    ended(view, t, 620, 170);
    CHECK(g_look_count == 4 && g_look_events[0].phase == DM_LOOK_BEGIN &&
          g_look_events[1].phase == DM_LOOK_MOVE && g_look_events[2].phase == DM_LOOK_MOVE &&
          g_look_events[3].phase == DM_LOOK_END, "look receives BEGIN, relative MOVE samples, final release MOVE, then END");
    near_value(g_look_events[1].dx, 15.0f / 390.0f, "rightward delta is normalized by the logical short edge");
    near_value(g_look_events[1].dy, 15.0f / 390.0f, "downward delta is positive and normalized by the logical short edge");
    near_value(g_look_events[2].dx, 5.0f / 390.0f, "release-only horizontal displacement is delivered");
    near_value(g_look_events[2].dy, 5.0f / 390.0f, "release-only vertical displacement is delivered");
    CHECK(g_pad_buttons == 0 && g_pad_lx == 0 && g_pad_ly == 0 && g_pad_rx == 0 && g_pad_ry == 0,
          "virtual touch right-stick axes stay separate from the physical-pad channel");
    CHECK(g_touch_count == 0, "look drag does not become a game touchscreen touch");
    float split_x, split_y; sum_moves(&split_x, &split_y);

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 620, 170); ended(view, t, 620, 170);
    float one_x, one_y; sum_moves(&one_x, &one_y);
    near_value(one_x, split_x, "one and many move events have the same horizontal total");
    near_value(one_y, split_y, "one and many move events have the same vertical total");

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 700, 150);
    CHECK(g_rx == 32767 && g_ry == 0, "look right-stick value clamps at full tilt when the finger passes its radius");
    moved(view, t, 701, 150);
    CHECK(g_rx == 32767 && g_ry == 0, "look right-stick centre recentres with the finger beyond its radius");
    int input_sets_before_republish = g_input_sets, pad_sets_before_republish = g_pad_sets;
    front_look_mode_changed();
    CHECK(g_input_sets == input_sets_before_republish + 1 && g_pad_sets == pad_sets_before_republish + 1 &&
          g_rx == 32767 && g_pad_rx == 0,
          "look-mode installation republishes the current virtual and physical source split");
    ended(view, t, 701, 150);
    CHECK(g_rx == 0 && g_ry == 0, "ending look clears the virtual right-stick axes after the final relative delta");

    reset_look(); t = touch(600, 150); began(view, t);
    moved(view, t, 600, 150); moved(view, t, 600, 150); ended(view, t, 600, 150);
    int move_count = 0; for (int i = 0; i < g_look_count; i++) move_count += g_look_events[i].phase == DM_LOOK_MOVE;
    CHECK(move_count == 0 && g_look_count == 2 && g_look_events[1].phase == DM_LOOK_END,
          "stationary held finger sends no MOVE and does not duplicate BEGIN");
}

static void test_priority_and_multitouch(DmGamepad *view) {
    reset_look(); g_look_enabled = YES; [view setFull:YES];
    CGPoint a = [view facePos:0];
    FakeTouch *look = touch(600, 150), *face = touch(a.x, a.y), *stick = touch(100, 250);
    [view touchesBegan:[NSSet setWithObjects:look, face, stick, nil] withEvent:nil];
    CHECK(g_look_count == 1 && g_look_events[0].phase == DM_LOOK_BEGIN, "one-finger look begins alongside face-button and left-stick owners");
    CHECK((g_buttons & DM_BTN_A) != 0, "face button retains priority and remains pressed during look");
    moved(view, stick, 150, 250); moved(view, look, 610, 160);
    CHECK(g_lx != 0 && g_look_count == 2 && g_look_events[1].phase == DM_LOOK_MOVE,
          "left stick and relative look can move at the same time");
    ended(view, face, a.x, a.y); ended(view, stick, 150, 250); ended(view, look, 610, 160);
    CHECK(!g_look_held && g_look_events[g_look_count - 1].phase == DM_LOOK_END,
          "ending the look finger ends its session after other controls release");

    reset_look();
    CGPoint r3point = [view clickCenter:5];
    FakeTouch *r3 = touch(r3point.x, r3point.y); began(view, r3);
    CHECK(g_look_count == 0 && (g_buttons & DM_BTN_RS) != 0,
          "R3 button priority keeps the hit out of the look region");
    ended(view, r3, r3point.x, r3point.y);

    reset_look();
    int prior_begins = g_begin_count;
    FakeTouch *first = touch(600, 150), *second = touch(700, 180);
    began(view, first); moved(view, first, 620, 150); int held_rx = g_rx, held_look_count = g_look_count;
    began(view, second);
    CHECK(g_begin_count == prior_begins + 1 && g_look_count == held_look_count, "a second right-region finger is inert while look is owned");
    moved(view, second, 740, 220);
    CHECK(g_rx == held_rx && g_look_count == held_look_count,
          "an inert second finger cannot change the owner right-stick axes or relative look stream");
    ended(view, first, 600, 150);
    CHECK(g_rx == 0 && g_ry == 0, "lifting the look owner clears its virtual right-stick axes immediately");
    moved(view, second, 720, 200); ended(view, second, 720, 200);
    CHECK(g_look_count == held_look_count + 1 && g_look_events[g_look_count - 1].phase == DM_LOOK_END,
          "an inert second finger does not take over after the owner lifts");
    FakeTouch *next = touch(650, 180); began(view, next);
    CHECK(g_look_count == held_look_count + 2 && g_look_events[g_look_count - 1].phase == DM_LOOK_BEGIN, "a fresh finger can begin look after the old gesture ends");
    ended(view, next, 650, 180);
}

static void test_cancel_and_modes(DmGamepad *view) {
    reset_look(); g_look_enabled = YES; [view setFull:YES];
    FakeTouch *t = touch(600, 150); began(view, t); moved(view, t, 620, 170);
    cancelled(view, t, 640, 190);
    CHECK(g_look_count == 3 && g_look_events[2].phase == DM_LOOK_CANCEL && !g_look_held,
          "UIKit cancellation clears look without applying its final unreported point");
    CHECK(g_rx == 0 && g_ry == 0, "cancelling look clears its virtual right-stick axes immediately");
    moved(view, t, 650, 200); ended(view, t, 650, 200);
    CHECK(g_look_count == 3 && g_touch_count == 0, "cancelled owner stays inert until lift");

    reset_look(); t = touch(600, 150); began(view, t); g_look_enabled = NO;
    moved(view, t, 620, 170);
    CHECK(g_look_count == 2 && g_look_events[1].phase == DM_LOOK_CANCEL && !g_look_held,
          "disabling look mid-gesture cancels and suppresses release tail");
    CHECK(g_rx == 0 && g_ry == 0, "disabling look immediately clears its virtual right-stick axes");
    ended(view, t, 630, 180);
    g_look_enabled = YES;

    reset_look(); [view setFull:NO]; t = touch(600, 150); int touch_sets_before = g_touch_sets;
    began(view, t); moved(view, t, 620, 170);
    CHECK(g_look_count == 0 && g_touch_sets > touch_sets_before && g_touch_count == 1,
          "2D layout keeps game-touch routing instead of look");
    ended(view, t, 620, 170);
    [view setFull:YES];

    reset_look(); g_look_enabled = NO; t = touch(600, 150); began(view, t); moved(view, t, 650, 150);
    CHECK(g_look_count == 0 && g_rx > 30000 && g_ry == 0,
          "disabled feature preserves the existing fully deflected horizontal right-stick behavior");
    CHECK(g_pad_rx == 0 && g_pad_ry == 0,
          "legacy LOOK=0 routing keeps right-region touch in the original input channel");
    ended(view, t, 650, 150);
    g_look_enabled = YES;

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 620, 150);
    [view setValue:@YES forKey:@"padOff"];
    [view reset];
    CHECK(g_look_count == 3 && g_look_events[2].phase == DM_LOOK_CANCEL && g_rx == 0 && g_ry == 0,
          "pad-off/reset cancels the current look session");
    reset_look(); g_look_enabled = YES;
    [view setValue:@YES forKey:@"padOff"];
    t = touch(600, 150); began(view, t);
    CHECK(g_look_count == 0 && g_touch_count > 0, "physical-controller mode routes right-region touches to game touch");
    ended(view, t, 610, 160); [view setValue:@NO forKey:@"padOff"];

    reset_look(); t = touch(600, 150); began(view, t); [view setFull:NO];
    CHECK(g_look_count == 2 && g_look_events[1].phase == DM_LOOK_CANCEL,
          "switching pad layout cancels the current look session");
    ended(view, t, 610, 160); [view setFull:YES];

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 620, 150);
    CGRect bounds = view.bounds; bounds.size.height += 10; view.bounds = bounds; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(g_look_count == 3 && g_look_events[2].phase == DM_LOOK_CANCEL && g_rx == 0 && g_ry == 0,
          "bounds resize cancels look and clears virtual axes immediately");
    moved(view, t, 610, 160); ended(view, t, 610, 160);
    CHECK(g_look_count == 3, "resized gesture cannot resume or add a release delta");

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 620, 150);
    bounds = view.bounds; bounds.size.height += 10; view.bounds = bounds;
    moved(view, t, 800, 250); ended(view, t, 810, 260);
    CHECK(g_look_count == 3 && g_look_events[2].phase == DM_LOOK_CANCEL && g_rx == 0 && g_ry == 0,
          "geometry change detected before layout cancels and clears axes without a later event");
    [view layoutIfNeeded]; [view setFull:YES];
}

static void test_motion_orientation(void) {
    dm_test_motion_reset(); g_motion_count = 0;
    // An upright landscape pose (world up is device X) with a nonzero arbitrary heading.
    CMQuaternion right = {.w = 0.3535534, .x = 0.3535534, .y = -0.6123724, .z = 0.6123724};
    CMQuaternion quarter_turn = motion_mul(right, (CMQuaternion){.w = M_SQRT1_2, .z = M_SQRT1_2});
    CMQuaternion inverted = motion_mul(right, (CMQuaternion){.z = 1});
    CMAcceleration accel = {.x = 0.25, .y = -0.5, .z = -1};
    CMRotationRate rate = {.x = 0.1, .y = 0.2, .z = 0.3};

    // Model a physical 180-degree handset turn: the interface flips halfway through,
    // then the pose settles. A frame change remaps samples but is not a new neutral pose.
    dm_gamepad_geometry_changed(UIInterfaceOrientationLandscapeRight);
    dm_test_motion_publish(right, accel, rate);
    dm_test_motion_publish(quarter_turn, accel, rate); // before UIKit reports the new geometry
    dm_gamepad_geometry_changed(UIInterfaceOrientationLandscapeLeft);
    dm_test_motion_publish(quarter_turn, accel, rate); // first sample with the refreshed frame
    dm_test_motion_publish(inverted, accel, rate);     // physical turn settles at 180 degrees
    CHECK(g_motion_count == 4, "motion pipeline publishes the right-to-left physical rotation sequence");
    CHECK(g_motion_samples[0].flags == DM_MOTION_RESET && g_motion_samples[1].flags == 0 &&
          g_motion_samples[2].flags == 0 && g_motion_samples[3].flags == 0,
          "landscape frame changes do not recenter at an intermediate physical angle");
    CMQuaternion mapped_pose = {.w = g_motion_samples[3].quat[0], .x = g_motion_samples[3].quat[1],
                                .y = g_motion_samples[3].quat[2], .z = g_motion_samples[3].quat[3]};
    CHECK(motion_quaternion_matches(mapped_pose, right),
          "settled inverted-landscape pose maps back to the original neutral frame");
    CHECK(fabsf(g_motion_samples[3].acc[0] + 0.25f) < 1e-6f && fabsf(g_motion_samples[3].acc[1] - 0.5f) < 1e-6f &&
          fabsf(g_motion_samples[3].gyro[0] + (float)(0.1 / (2 * M_PI))) < 1e-6f &&
          fabsf(g_motion_samples[3].gyro[1] + (float)(0.2 / (2 * M_PI))) < 1e-6f,
          "settled sample acceleration and angular rate use the refreshed landscape frame");

    // Reverse transition, including a physical quarter-turn before the UI frame changes.
    dm_test_motion_reset(); g_motion_count = 0;
    dm_gamepad_geometry_changed(UIInterfaceOrientationLandscapeLeft);
    dm_test_motion_publish(inverted, accel, rate);
    dm_test_motion_publish(quarter_turn, accel, rate);
    dm_gamepad_geometry_changed(UIInterfaceOrientationLandscapeRight);
    dm_test_motion_publish(quarter_turn, accel, rate);
    dm_test_motion_publish(right, accel, rate);
    CHECK(g_motion_count == 4 && g_motion_samples[0].flags == DM_MOTION_RESET &&
          g_motion_samples[1].flags == 0 && g_motion_samples[2].flags == 0 && g_motion_samples[3].flags == 0,
          "left-to-right rotation also preserves the existing neutral frame");
    mapped_pose = (CMQuaternion){.w = g_motion_samples[3].quat[0], .x = g_motion_samples[3].quat[1],
                                 .y = g_motion_samples[3].quat[2], .z = g_motion_samples[3].quat[3]};
    CHECK(motion_quaternion_matches(mapped_pose, right),
          "settled right-landscape pose after reverse rotation remains neutral");

    g_motion_count = 4;
    dm_test_motion_recenter();
    dm_test_motion_publish(right, accel, rate);
    dm_test_motion_publish(right, accel, rate);
    CHECK(g_motion_samples[4].flags == DM_MOTION_RESET && g_motion_samples[5].flags == 0,
          "requested recenter remains one-shot and independent of orientation changes");
}

static void run_tests(DmGamepad *view) {
    test_motion_orientation();
    test_look_drag(view);
    test_priority_and_multitouch(view);
    test_cancel_and_modes(view);
    reset_look(); g_look_enabled = YES;
    [view setFull:YES];
    FakeTouch *t = touch(600, 150); began(view, t); moved(view, t, 620, 150);
    UIInterfaceOrientation current = view.window.windowScene.effectiveGeometry.interfaceOrientation;
    if (current != UIInterfaceOrientationUnknown) {
        UIInterfaceOrientation stale = current == UIInterfaceOrientationLandscapeLeft ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationLandscapeLeft;
        [view setValue:@(stale) forKey:@"lookOrientation"];
        [view deviceOrientationChanged];
        CHECK(g_look_count == 3 && g_look_events[2].phase == DM_LOOK_CANCEL && g_rx == 0 && g_ry == 0,
              "interface-orientation notification cancels look and clears its virtual axes immediately");
    } else CHECK(NO, "simulator reports a known interface orientation for the orientation-cancel check");
    reset_look();
    t = touch(600, 150); began(view, t);
    [view padsChanged];
    dispatch_async(dispatch_get_main_queue(), ^{
        CHECK(g_look_count == 2 && g_look_events[1].phase == DM_LOOK_CANCEL,
              "controller-change reset cancels an active look session");
        reset_look(); g_look_enabled = YES;
        NSString *report = [NSString stringWithFormat:@"UIKit handler regression: %d failures; %d look BEGIN sessions\n", g_failures, g_begin_count];
        printf("%s", report.UTF8String);
        fflush(stdout); fflush(stderr);
        [report writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/result.txt"]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
        exit(g_failures ? 1 : 0);
    });
}

@interface HarnessDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation HarnessDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"DmPadLayout"];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root = [UIViewController new]; self.window.rootViewController = root; [self.window makeKeyAndVisible];
    UIView *raw = dm_gamepad_view(CGRectMake(0, 0, 844, 390));
    [root.view addSubview:raw]; [raw setFrame:CGRectMake(0, 0, 844, 390)]; [raw layoutIfNeeded];
    DmGamepad *view = (DmGamepad *)raw;
    dispatch_async(dispatch_get_main_queue(), ^{ run_tests(view); });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *log = [documents stringByAppendingPathComponent:@"details.log"];
        if (!freopen(log.fileSystemRepresentation, "w", stdout) || dup2(STDOUT_FILENO, STDERR_FILENO) < 0) abort();
        setvbuf(stdout, NULL, _IOLBF, 0);
        setvbuf(stderr, NULL, _IOLBF, 0);
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(HarnessDelegate.class));
    }
}
