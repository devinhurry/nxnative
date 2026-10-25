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
#include "../../host/touchpad_geometry.h"
#include "front.h"
#include "../../host/botw_rune_icon.h"
UIView *dm_gamepad_view(CGRect frame);
void dm_test_motion_reset(void);
void dm_test_motion_recenter(void);
void dm_test_motion_publish(CMQuaternion q, CMAcceleration a, CMRotationRate r);
void dm_gamepad_geometry_changed(UIInterfaceOrientation orientation);
void front_look_mode_changed(void);
int dm_botw_touch_hud_available(void);
void dm_botw_touch_hud_publish(int active, float center_x, float center_y);

@interface DmGamepad : UIView
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)dm_testSetTouchHudModeFull:(BOOL)full tap:(BOOL)tap connected:(BOOL)connected;
- (void)setFull:(BOOL)full;
- (BOOL)dm_testDpadArtworkHidden;
- (BOOL)dm_testZLArtworkHidden;
- (BOOL)dm_testZLArtworkHidden;
- (BOOL)dm_testControlsHidden;
- (BOOL)dm_testL3ArtworkHidden;
- (BOOL)dm_testR3ArtworkHidden;
- (BOOL)dm_testMinusArtworkHidden;
- (BOOL)dm_testL3GestureEnabled;
- (BOOL)dm_testLeftStickOwnsPoint:(CGPoint)point;
- (BOOL)dm_testSetBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height;
- (int)dm_testBtnAt:(CGPoint)point;
- (BOOL)dm_testBotwMapOwnsPoint:(CGPoint)point;
- (CGPoint)dm_testShieldHome;
- (CGPoint)dm_testStickHome;
- (CGPoint)dm_testRuneButtonCenter;
- (CGPoint)dm_testMapBadgeCenter;
- (CGPoint)dm_testDropCenter:(int)button;
- (void)dm_testBotwTouchActionChanged;
- (void)dm_testPulseBotwL3;
- (void)reset;
- (void)padsChanged;
- (void)deviceOrientationChanged;
- (CGPoint)facePos:(int)button;
- (CGPoint)clickCenter:(int)button;
- (CGPoint)stickHome;
- (CGPoint)dpadCenter;
- (CGRect)pillRect:(int)button;
@end

@interface FakeTouch : UITouch
@property(nonatomic) CGPoint point;
@property(nonatomic) NSTimeInterval timeValue;
- (instancetype)initAt:(CGPoint)point;
@end
@implementation FakeTouch
- (instancetype)initAt:(CGPoint)point { if ((self = [super init])) _point = point; return self; }
- (CGPoint)locationInView:(UIView *)view { (void)view; return self.point; }
- (NSTimeInterval)timestamp { return self.timeValue; }
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
static int g_pad_player;
static int g_input_sets, g_pad_sets;
static int g_virtual_latch_cancels;
static uint64_t g_virtual_latch_cancel_mask;
static uint64_t g_input_history[512];
static dm_touch g_last_touch;
static int g_touch_count, g_touch_sets;
static dm_motion g_motion_samples[16];
static int g_motion_count;
static BOOL g_botw_touchhud_available;
static dm_botw_rune_icon_state g_botw_rune_icon_snapshot;
static BOOL g_botw_touch_actions_available;
static uint64_t g_botw_cancel_complete;
static uint64_t g_botw_cancel_requested;
static int g_botw_sprint_requested;

int dm_look_enabled(void) { return g_look_enabled; }
int dm_botw_touch_hud_available(void) { return g_botw_touchhud_available; }
int dm_botw_rune_icon_snapshot(dm_botw_rune_icon_state *out) { if (!out) return 0; *out = g_botw_rune_icon_snapshot; return 1; }
void dm_botw_touch_hud_publish(int active, float center_x, float center_y) { (void)active; (void)center_x; (void)center_y; }
void dm_botw_touch_hud_map_tapped(void) {}
int dm_botw_touch_actions_available(void) { return g_botw_touch_actions_available; }
void dm_botw_touch_sprint_request(int active) { g_botw_sprint_requested = active; }
void dm_botw_touch_cancel_trigger(uint64_t bit) { g_botw_cancel_requested |= bit; }
int dm_botw_touch_cancel_complete(uint64_t bit) { return (g_botw_cancel_complete & bit) != 0; }
void dm_botw_touch_actions_reset(void) { g_botw_sprint_requested=0; g_botw_cancel_requested=0; g_botw_cancel_complete=0; }
void dm_haptics_apple_controller(int player, GCController *controller) { (void)player; (void)controller; }
int dm_opmode(void) { return 0; }
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
    if (g_input_sets <= (int)(sizeof g_input_history / sizeof g_input_history[0])) g_input_history[g_input_sets - 1] = buttons;
    g_buttons = buttons; g_lx = lx; g_ly = ly; g_rx = rx; g_ry = ry;
}
void dm_input_cancel_virtual_latch(uint64_t buttons) { ++g_virtual_latch_cancels; g_virtual_latch_cancel_mask = buttons; }
void dm_pad_set_player(int player, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    ++g_pad_sets;
    g_pad_player = player;
    g_pad_buttons = buttons; g_pad_lx = lx; g_pad_ly = ly; g_pad_rx = rx; g_pad_ry = ry;
}
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    dm_pad_set_player(0, buttons, lx, ly, rx, ry);
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
static void beganAt(DmGamepad *view, FakeTouch *t, NSTimeInterval time) { t.timeValue = time; began(view, t); }
static void moved(DmGamepad *view, FakeTouch *t, CGFloat x, CGFloat y) { t.point = CGPointMake(x, y); [view touchesMoved:[NSSet setWithObject:t] withEvent:nil]; }
static void ended(DmGamepad *view, FakeTouch *t, CGFloat x, CGFloat y) { t.point = CGPointMake(x, y); [view touchesEnded:[NSSet setWithObject:t] withEvent:nil]; }
static void endedAt(DmGamepad *view, FakeTouch *t, CGFloat x, CGFloat y, NSTimeInterval time) { t.timeValue = time; ended(view, t, x, y); }
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

static void test_dpad_art_visibility(DmGamepad *view) {
    g_botw_touchhud_available = NO;
    [view setFull:NO];
    [view layoutIfNeeded];
    CHECK([view dm_testDpadArtworkHidden], "2D layout keeps the 3D D-pad artwork hidden when BOTW relocation is unavailable");
    CHECK(![view dm_testZLArtworkHidden], "ordinary 2D layout keeps ZL visible when BOTW relocation is unavailable");
    CHECK(![view dm_testZLArtworkHidden], "ordinary 2D layout keeps ZL visible when BOTW relocation is unavailable");
    [view setFull:YES];
    [view layoutIfNeeded];
    CHECK(![view dm_testDpadArtworkHidden], "ordinary 3D layout keeps D-pad artwork visible when BOTW relocation is unavailable");
    [view dm_testSetTouchHudModeFull:YES tap:YES connected:NO];
    [view layoutIfNeeded];
    CHECK([view dm_testDpadArtworkHidden], "Tap layout keeps the D-pad artwork hidden");
    CHECK([view dm_testZLArtworkHidden], "Tap layout keeps ZL hidden when BOTW relocation is unavailable");
    CHECK([view dm_testZLArtworkHidden], "Tap layout keeps ZL hidden when BOTW relocation is unavailable");

    g_botw_touchhud_available = YES;
    [view setFull:YES];
    CHECK([view dm_testDpadArtworkHidden], "active BOTW touch 3D mode hides D-pad artwork");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    CHECK([view dm_testDpadArtworkHidden] && [view dm_testControlsHidden],
          "a connected physical controller hides the touch overlay and keeps the D-pad artwork hidden");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    g_botw_touchhud_available = NO;
}

static void test_botw_virtual_buttons(DmGamepad *view) {
    g_botw_touchhud_available = NO;
    [view setFull:YES];
    CHECK(![view dm_testL3ArtworkHidden] && ![view dm_testR3ArtworkHidden] && ![view dm_testMinusArtworkHidden],
          "non-BOTW 3D layout keeps L3 and Minus artwork visible");
    CHECK(![view dm_testL3GestureEnabled], "non-BOTW 3D layout keeps L3 double-tap disabled");
    CHECK(![view dm_testLeftStickOwnsPoint:[view stickHome]],
          "BOTW stick double-tap recognition stays disabled when the BOTW hook is unavailable");
    int cancellations = g_virtual_latch_cancels;
    [view reset];
    CHECK(g_virtual_latch_cancels == cancellations,
          "non-BOTW reset does not touch pending virtual button edges");

    g_botw_touchhud_available = YES;
    [view setFull:YES];
    [view reset];
    CHECK(g_virtual_latch_cancels == cancellations + 1 &&
          g_virtual_latch_cancel_mask == (DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS),
          "BOTW reset cancels virtual stick-click and Minus edge latches");
    CGPoint stick = [view stickHome];
    CHECK([view dm_testL3ArtworkHidden] && [view dm_testR3ArtworkHidden] && ![view dm_testMinusArtworkHidden],
          "active BOTW mode hides both stick-click artworks and keeps Minus until map hit area is installed");
    CHECK([view dm_testL3GestureEnabled], "active BOTW 3D touch mode enables L3 double-tap");
    CHECK([view dm_testLeftStickOwnsPoint:stick],
          "left-stick double tap accepts the actual left stick owner area");
    CHECK(![view dm_testLeftStickOwnsPoint:[view dpadCenter]],
          "left-stick double tap rejects the D-pad area");
    CHECK(![view dm_testLeftStickOwnsPoint:[view facePos:0]],
          "left-stick double tap rejects the face-button area");
    CHECK(![view dm_testLeftStickOwnsPoint:[view clickCenter:4]],
          "left-stick double tap rejects the hidden L3 button area");

    g_input_sets = g_pad_sets = 0; g_input_history[0] = g_input_history[1] = 0;
    g_pad_buttons = 0;
    [view dm_testPulseBotwL3];
    CHECK(g_input_sets == 2 && (g_input_history[0] & DM_BTN_LS) && !(g_input_history[1] & DM_BTN_LS) &&
          !(g_buttons & DM_BTN_LS),
          "virtual L3 publishes one press edge and immediately releases its source");
    CHECK(!(g_pad_buttons & DM_BTN_LS) && g_pad_sets == 2,
          "virtual L3 pulse is not copied into the separate physical controller channel");

    CHECK([view dm_testSetBotwMapRectValid:YES x:0.05 y:0.16 width:0.36 height:0.40],
          "active BOTW mode accepts the live relocated-map clip as a hit region");
    CHECK([view dm_testMinusArtworkHidden], "valid visible map hides the standalone Minus artwork");
    CGRect minusRect = [view pillRect:11];
    CHECK([view dm_testBtnAt:CGPointMake(CGRectGetMidX(minusRect), CGRectGetMidY(minusRect))] < 0,
          "valid map mode removes the standalone Minus hit region");
    g_input_sets = 0; g_input_history[0] = g_input_history[1] = 0;
    int touch_sets_before = g_touch_sets, look_begins_before = g_begin_count;
    CGPoint mapPoint = CGPointMake(view.bounds.size.width * 0.23, view.bounds.size.height * 0.36);
    CHECK([view dm_testBotwMapOwnsPoint:mapPoint] &&
          ![view dm_testBotwMapOwnsPoint:CGPointMake(view.bounds.size.width * 0.8, view.bounds.size.height * 0.36)],
          "map ownership follows the published normalized clip rectangle only");
    FakeTouch *mapTouch = touch(mapPoint.x, mapPoint.y); began(view, mapTouch);
    CHECK(g_input_sets >= 2 && (g_input_history[0] & DM_BTN_MINUS) && !(g_input_history[1] & DM_BTN_MINUS),
          "map tap publishes one Minus press edge and releases the virtual source");
    CHECK(g_touch_sets == touch_sets_before && g_begin_count == look_begins_before,
          "map tap is consumed without entering game touch or camera look");
    ended(view, mapTouch, mapPoint.x, mapPoint.y);
    int afterMapPulse = g_input_sets;
    CHECK(![view dm_testBotwMapOwnsPoint:mapPoint] && [view dm_testMinusArtworkHidden],
          "consuming a map tap disables stale map hits while Minus stays hidden during Slate transition");
    FakeTouch *secondMapTouch = touch(mapPoint.x, mapPoint.y); began(view, secondMapTouch); ended(view, secondMapTouch, mapPoint.x, mapPoint.y);
    BOOL repeatedMinus = NO;
    for (int i = afterMapPulse; i < g_input_sets; i++) repeatedMinus |= (g_input_history[i] & DM_BTN_MINUS) != 0;
    CHECK(!repeatedMinus,
          "a second tap cannot issue another Minus edge before the collapsed map is republished");
    CHECK(![view dm_testSetBotwMapRectValid:NO x:0 y:0 width:0 height:0] && [view dm_testMinusArtworkHidden],
          "native map invalidation keeps the consumed Slate transition from restoring a stale Minus control");
    CHECK([view dm_testSetBotwMapRectValid:YES x:0.05 y:0.16 width:0.36 height:0.40] &&
          [view dm_testMinusArtworkHidden] && [view dm_testBotwMapOwnsPoint:mapPoint],
          "a fresh collapsed-map publication rearms map taps");
    CGPoint badge = [view dm_testMapBadgeCenter]; CGRect oldPlus = [view pillRect:10];
    CHECK([view dm_testBtnAt:badge] == 10 &&
          [view dm_testBtnAt:CGPointMake(CGRectGetMidX(oldPlus),CGRectGetMidY(oldPlus))] < 0,
          "the live-map + badge owns the relocated hit and removes the old + hit");
    CHECK([view dm_testBtnAt:CGPointMake(badge.x + DM_TP_MAP_BADGE_RADIUS * dm_touchpad_u(view.bounds.size.height) + 1, badge.y)] < 0,
          "the relocated + hit stays within its displayed badge circle");

    g_botw_touch_actions_available = YES;
    CGPoint shield = [view dm_testShieldHome]; FakeTouch *shieldTouch=touch(shield.x+30,shield.y+5); began(view,shieldTouch);
    CHECK((g_buttons & DM_BTN_ZL) && g_lx == 0 && g_ly == 0,
          "off-center stationary shield-stick press holds ZL with a neutral axis");
    moved(view,shieldTouch,shield.x+85,shield.y+5);
    CHECK((g_buttons & DM_BTN_ZL) && g_lx > 0,
          "shield-stick drag publishes ZL and the left-stick axis together");
    ended(view,shieldTouch,shield.x+85,shield.y+5);
    CHECK(!(g_buttons & DM_BTN_ZL) && g_lx == 0,
          "lifting the shield stick releases ZL and its axis");

    CGPoint stickHome=[view dm_testStickHome], shieldHome=[view dm_testShieldHome];
    FakeTouch *ordinaryStick=touch(stickHome.x,stickHome.y), *shieldConcurrent=touch(shieldHome.x+25,shieldHome.y);
    began(view,ordinaryStick); moved(view,ordinaryStick,stickHome.x+110,stickHome.y);
    CHECK(g_botw_sprint_requested && g_lx > 0,
          "ordinary left-stick overshoot requests sprint independently");
    began(view,shieldConcurrent); moved(view,shieldConcurrent,shieldHome.x+75,shieldHome.y);
    CHECK((g_buttons&DM_BTN_ZL) && g_lx > 0 && !g_botw_sprint_requested,
          "shield-stick movement owns the left axis and clears the suspended ordinary-stick sprint request");
    ended(view,shieldConcurrent,shieldHome.x+75,shieldHome.y);
    CHECK(!(g_buttons&DM_BTN_ZL) && g_lx > 0 && g_botw_sprint_requested,
          "lifting the shield stick restores the still-held ordinary left-stick axis and its overshoot sprint request");
    ended(view,ordinaryStick,stickHome.x+110,stickHome.y);
    CHECK(g_lx == 0 && !g_botw_sprint_requested,
          "lifting the ordinary left stick clears its axis and sprint request");

    CGPoint shoulder=[view dm_testDropCenter:7]; FakeTouch *trigger=touch(shoulder.x,shoulder.y); began(view,trigger);
    moved(view,trigger,shoulder.x+150,shoulder.y);
    CHECK(g_botw_cancel_requested==DM_BTN_R && (g_buttons&DM_BTN_R),
          "dragging outside R requests native cancel while retaining the trigger until acknowledgement");
    g_botw_cancel_complete=DM_BTN_R; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_R),
          "native cancel acknowledgement releases R while its touch remains latched");
    ended(view,trigger,shoulder.x+100,shoulder.y);
    CHECK(!(g_buttons&DM_BTN_R), "lifting after cancel acknowledgement does not reassert R");
    g_botw_cancel_complete=0;
    CGPoint zrCenter=[view dm_testDropCenter:9]; FakeTouch *earlyLift=touch(zrCenter.x,zrCenter.y); began(view,earlyLift);
    moved(view,earlyLift,zrCenter.x+150,zrCenter.y); ended(view,earlyLift,zrCenter.x+150,zrCenter.y);
    CHECK(g_botw_cancel_requested==DM_BTN_ZR && (g_buttons&DM_BTN_ZR),
          "lifting before the first native sample keeps the canceled ZR published for acknowledgement");
    g_botw_cancel_complete=DM_BTN_ZR; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_ZR), "an acknowledgement after finger-up releases the retained ZR source");
    g_botw_cancel_complete=0; g_botw_cancel_requested=0;

    CGPoint rCenter=[view dm_testDropCenter:7], zrCenter2=[view dm_testDropCenter:9];
    FakeTouch *r2=touch(rCenter.x,rCenter.y), *zr2=touch(zrCenter2.x,zrCenter2.y);
    began(view,r2); began(view,zr2); moved(view,r2,rCenter.x+150,rCenter.y); moved(view,zr2,zrCenter2.x+150,zrCenter2.y);
    CHECK((g_botw_cancel_requested & (DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR) &&
          (g_buttons & (DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR),
          "simultaneous R and ZR cancel requests keep both triggers pending");
    g_botw_cancel_complete=DM_BTN_R; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_R) && (g_buttons&DM_BTN_ZR),
          "R acknowledgement releases only R while ZR cancellation remains pending");
    g_botw_cancel_complete=DM_BTN_R|DM_BTN_ZR; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&(DM_BTN_R|DM_BTN_ZR)),
          "the independent ZR acknowledgement releases the remaining trigger");
    ended(view,r2,rCenter.x+150,rCenter.y); ended(view,zr2,zrCenter2.x+150,zrCenter2.y);
    g_botw_touch_actions_available=NO; g_botw_cancel_complete=0; g_botw_cancel_requested=0;

    g_look_enabled = YES; reset_look(); g_input_sets = 0; g_input_history[0] = g_input_history[1] = 0;
    CGPoint camera = CGPointMake(view.bounds.size.width * .82, view.bounds.size.height * .38);
    CHECK([view dm_testBtnAt:camera] < 0, "BOTW camera area has no visible or active R3 button hit region");
    FakeTouch *cameraTap = touch(camera.x,camera.y); beganAt(view,cameraTap,1.0); endedAt(view,cameraTap,camera.x,camera.y,1.08);
    BOOL r3Pressed = NO, r3Released = NO;
    for (int i=0; i<g_input_sets; i++) { r3Pressed |= (g_input_history[i] & DM_BTN_RS) != 0; r3Released |= !(g_input_history[i] & DM_BTN_RS); }
    CHECK(!r3Pressed && !(g_buttons & DM_BTN_RS), "one short camera-area tap is silent");
    FakeTouch *cameraTap2 = touch(camera.x+2,camera.y+2); beganAt(view,cameraTap2,1.20); endedAt(view,cameraTap2,camera.x+2,camera.y+2,1.28);
    for (int i=0; i<g_input_sets; i++) { r3Pressed |= (g_input_history[i] & DM_BTN_RS) != 0; r3Released |= !(g_input_history[i] & DM_BTN_RS); }
    CHECK(r3Pressed && r3Released && !(g_buttons & DM_BTN_RS),
          "two nearby short camera-area taps emit one R3 press and release");

    reset_look(); g_input_sets = 0; g_input_history[0] = g_input_history[1] = 0;
    FakeTouch *pendingTap = touch(camera.x,camera.y); beganAt(view,pendingTap,2.0); endedAt(view,pendingTap,camera.x,camera.y,2.08);
    FakeTouch *cameraDrag = touch(camera.x,camera.y); began(view,cameraDrag);
    moved(view,cameraDrag,camera.x+40,camera.y); moved(view,cameraDrag,camera.x,camera.y);
    ended(view,cameraDrag,camera.x,camera.y);
    BOOL dragR3 = NO; for (int i=0; i<g_input_sets; i++) dragR3 |= (g_input_history[i] & DM_BTN_RS) != 0;
    CHECK(g_look_count >= 4 && g_look_events[g_look_count-1].phase == DM_LOOK_END && !dragR3,
          "camera drag cancels a pending tap sequence and returning to start never emits R3");

    reset_look(); g_input_sets = 0; FakeTouch *pendingTap2 = touch(camera.x,camera.y); beganAt(view,pendingTap2,3.0); endedAt(view,pendingTap2,camera.x,camera.y,3.08);
    FakeTouch *cameraCancel = touch(camera.x,camera.y); began(view,cameraCancel);
    cancelled(view,cameraCancel,camera.x,camera.y);
    BOOL cancelR3 = NO; for (int i=0; i<g_input_sets; i++) cancelR3 |= (g_input_history[i] & DM_BTN_RS) != 0;
    CHECK(g_look_events[g_look_count-1].phase == DM_LOOK_CANCEL && !cancelR3,
          "cancelled gesture clears pending R3 tap and does not leave look active");

    reset_look(); g_input_sets = 0;
    FakeTouch *pendingTap3 = touch(camera.x,camera.y); beganAt(view,pendingTap3,4.0); endedAt(view,pendingTap3,camera.x,camera.y,4.08);
    FakeTouch *mapAgain = touch(mapPoint.x,mapPoint.y); began(view,mapAgain); ended(view,mapAgain,mapPoint.x,mapPoint.y);
    FakeTouch *afterMap = touch(camera.x,camera.y); beganAt(view,afterMap,4.2); endedAt(view,afterMap,camera.x,camera.y,4.28);
    BOOL mapSequenceR3 = NO; for (int i=0; i<g_input_sets; i++) mapSequenceR3 |= (g_input_history[i] & DM_BTN_RS) != 0;
    CHECK(!mapSequenceR3, "map tap has priority and invalidates the pending camera double tap");

    reset_look(); g_input_sets = 0;
    FakeTouch *pendingBeforeController = touch(camera.x,camera.y);
    beganAt(view,pendingBeforeController,5.0); endedAt(view,pendingBeforeController,camera.x,camera.y,5.08);
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    FakeTouch *afterController = touch(camera.x,camera.y);
    beganAt(view,afterController,5.2); endedAt(view,afterController,camera.x,camera.y,5.28);
    BOOL controllerSequenceR3 = NO; for (int i=0; i<g_input_sets; i++) controllerSequenceR3 |= (g_input_history[i] & DM_BTN_RS) != 0;
    CHECK(!controllerSequenceR3, "controller connection clears an incomplete camera double tap");
    g_look_enabled = NO;

    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    CHECK(![view dm_testL3GestureEnabled] && ![view dm_testR3ArtworkHidden] && ![view dm_testMinusArtworkHidden],
          "connected physical controller restores Minus and disables L3 double-tap");
    CHECK(![view dm_testLeftStickOwnsPoint:stick],
          "connected physical controller disables BOTW double-tap recognition");
    int before = g_input_sets;
    [view dm_testPulseBotwL3];
    CHECK(g_input_sets == before, "connected physical controller cancels virtual L3 pulses");
    [view dm_testSetTouchHudModeFull:YES tap:YES connected:NO];
    CHECK(![view dm_testL3GestureEnabled], "Tap layout disables L3 double-tap");
    CHECK(![view dm_testLeftStickOwnsPoint:stick], "Tap layout disables BOTW double-tap recognition");
    g_botw_touchhud_available = NO;
}

static void test_look_drag(DmGamepad *view) {
    g_look_enabled = YES; [view setFull:YES];
    reset_look();
    FakeTouch *t = touch(600, 150);
    began(view, t); moved(view, t, 615, 165);
    CHECK(g_rx > 0 && g_ry < 0 && abs(g_rx + g_ry) <= 1 && g_rx < 32767 && -g_ry < 32767,
          "moderate look drag keeps the proportional virtual right-stick magnitude");
    ended(view, t, 620, 170);
    CHECK(g_look_count == 4 && g_look_events[0].phase == DM_LOOK_BEGIN &&
          g_look_events[1].phase == DM_LOOK_MOVE && g_look_events[2].phase == DM_LOOK_MOVE &&
          g_look_events[3].phase == DM_LOOK_END, "look receives BEGIN, relative MOVE samples, final release MOVE, then END");
    near_value(g_look_events[1].dx, 15.0f / 390.0f, "rightward delta is normalized by the logical short edge");
    near_value(g_look_events[1].dy, 15.0f / 390.0f, "downward delta is positive and normalized by the logical short edge");
    near_value(g_look_events[2].dx, 5.0f / 390.0f, "release-only horizontal displacement is delivered");
    near_value(g_look_events[2].dy, 5.0f / 390.0f, "release-only vertical displacement is delivered");
    CHECK(g_pad_player == 0 && g_pad_buttons == 0 && g_pad_lx == 0 && g_pad_ly == 0 && g_pad_rx == 0 && g_pad_ry == 0,
          "virtual touch right-stick axes stay separate from the physical-pad channel");
    CHECK(g_touch_count == 0, "look drag does not become a game touchscreen touch");
    float split_x, split_y; sum_moves(&split_x, &split_y);

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 620, 170); ended(view, t, 620, 170);
    float one_x, one_y; sum_moves(&one_x, &one_y);
    near_value(one_x, split_x, "one and many move events have the same horizontal total");
    near_value(one_y, split_y, "one and many move events have the same vertical total");

    reset_look(); t = touch(600, 150); began(view, t); moved(view, t, 602, 150);
    CHECK(g_rx == 0 && g_ry == 0 && g_look_count == 2 && g_look_events[1].phase == DM_LOOK_MOVE,
          "movement inside the stick dead zone stays zero while relative look still receives it");
    ended(view, t, 602, 150);

    reset_look(); t = touch(600, 150); began(view, t);
    CGFloat radius = 60.0 * fmin(view.bounds.size.height / 430.0, 1.3);
    moved(view, t, 600 + radius * 0.45, 150);
    CHECK(abs(g_rx - 16384) <= 2 && g_ry == 0,
          "a drag at 45 percent of the virtual-stick radius produces half tilt");
    ended(view, t, 600 + radius * 0.45, 150);

    reset_look(); t = touch(600, 150); began(view, t);
    moved(view, t, 700, 150);
    CHECK(g_rx == 32767 && g_ry == 0, "look right-stick value clamps at full tilt when the finger passes its radius");
    moved(view, t, 701, 150);
    CHECK(g_rx == 32767 && g_ry == 0, "look right-stick centre recentres with the finger beyond its radius");
    int input_sets_before_republish = g_input_sets, pad_sets_before_republish = g_pad_sets;
    front_look_mode_changed();
    CHECK(g_input_sets == input_sets_before_republish + 1 && g_pad_sets == pad_sets_before_republish + 1 &&
          g_rx == 32767 && g_pad_player == 0 && g_pad_rx == 0,
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
          "non-BOTW R3 button priority keeps the hit out of the look region");
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
    CHECK(g_look_count == held_look_count + 2 && g_look_events[g_look_count - 1].phase == DM_LOOK_END,
          "an inert second finger does not take over after the owner lifts");
    FakeTouch *next = touch(650, 180); began(view, next);
    CHECK(g_look_count == held_look_count + 3 && g_look_events[g_look_count - 1].phase == DM_LOOK_BEGIN, "a fresh finger can begin look after the old gesture ends");
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
    test_dpad_art_visibility(view);
    test_botw_virtual_buttons(view);
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
