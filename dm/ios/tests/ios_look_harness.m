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
#include "../../host/botw_touch_menu.h"
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
- (void)dm_testRefreshTouchHudMode;
- (void)refreshBotwTouchMenuMode;
- (BOOL)dm_testIsFull;
- (BOOL)dm_testIsTap;
- (BOOL)dm_testLeftStickRingHidden;
- (void)setFull:(BOOL)full;
- (BOOL)dm_testDpadArtworkHidden;
- (BOOL)dm_testZLArtworkHidden;
- (BOOL)dm_testControlsHidden;
- (CAShapeLayer *)dm_testButtonLayer:(int)button;
- (CAShapeLayer *)dm_testButtonBorder:(int)button;
- (CATextLayer *)dm_testButtonLabel:(int)button;
- (CAShapeLayer *)dm_testYBadgeBorder;
- (CAShapeLayer *)dm_testRuneBadgeBorder;
- (CALayer *)dm_testYIconLayer;
- (CAShapeLayer *)dm_testYBadge;
- (CATextLayer *)dm_testYLabel;
- (BOOL)dm_testSwapHidden;
- (BOOL)dm_testInSwap:(CGPoint)point;
- (void)dm_testNextLayout;
- (BOOL)dm_testL3ArtworkHidden;
- (BOOL)dm_testR3ArtworkHidden;
- (BOOL)dm_testMinusArtworkHidden;
- (BOOL)dm_testL3GestureEnabled;
- (BOOL)dm_testL3ReceiveTouch:(UITouch *)touch;
- (BOOL)dm_testL3MayBegin;
- (BOOL)dm_testLeftStickOwnsPoint:(CGPoint)point;
- (BOOL)dm_testSetBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height;
- (int)dm_testBtnAt:(CGPoint)point;
- (BOOL)dm_testBotwMapOwnsPoint:(CGPoint)point;
- (CGPoint)dm_testShieldHome;
- (CGPoint)dm_testShieldRingCenter;
- (CAShapeLayer *)dm_testShieldGraphLayer;
- (CAShapeLayer *)dm_testShieldRingLayer;
- (CAShapeLayer *)dm_testShieldDirectionLayer;
- (CAShapeLayer *)dm_testStickGraphLayer;
- (CAShapeLayer *)dm_testStickRingLayer;
- (CAShapeLayer *)dm_testStickDirectionLayer;
- (CAShapeLayer *)dm_testRuneBadgeLayer;
- (void)dm_testSetTouchFeedback:(UIImpactFeedbackGenerator *)feedback;
- (void)botwRuneIconChanged;
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
static BOOL g_botw_touch_menu_active;
static BOOL g_botw_touch_menu_presented;
static BOOL g_botw_gameplay_ready = YES;
static BOOL g_botw_touch_map_active;
typedef struct { int phase; float x, y; } menu_pointer_event;
static menu_pointer_event g_menu_pointer_events[64];
static int g_menu_pointer_count;

int dm_look_enabled(void) { return g_look_enabled; }
int dm_botw_touch_hud_available(void) { return g_botw_touchhud_available; }
int dm_botw_touch_menu_active(void) { return g_botw_touch_menu_active; }
int dm_botw_touch_menu_visible(void) { return g_botw_touch_menu_active || g_botw_touch_menu_presented; }
int dm_botw_touch_controls_visible(void) {
    return !g_botw_touchhud_available || (g_botw_gameplay_ready && !dm_botw_touch_menu_visible());
}
int dm_botw_touch_map_active(void) { return g_botw_touch_map_active; }
static float g_pinch_ratios[64];
static int g_pinch_count;
void dm_botw_touch_menu_pinch(float ratio) {
    if (g_pinch_count < 64) g_pinch_ratios[g_pinch_count++] = ratio;
}
void dm_botw_touch_menu_pointer(int phase, float x, float y) {
    if (g_menu_pointer_count < (int)(sizeof g_menu_pointer_events / sizeof g_menu_pointer_events[0]))
        g_menu_pointer_events[g_menu_pointer_count++] = (menu_pointer_event){phase,x,y};
}
int dm_botw_rune_icon_snapshot(dm_botw_rune_icon_state *out) { if (!out) return 0; *out = g_botw_rune_icon_snapshot; return 1; }
void dm_botw_touch_hud_publish(int active, float center_x, float center_y) { (void)active; (void)center_x; (void)center_y; }
void dm_botw_touch_hud_map_tapped(void) {}
int dm_botw_touch_actions_available(void) { return g_botw_touch_actions_available; }
void dm_botw_touch_cancel_trigger(uint64_t bit) { g_botw_cancel_requested |= bit; }
int dm_botw_touch_cancel_complete(uint64_t bit) { return (g_botw_cancel_complete & bit) != 0; }
void dm_botw_touch_actions_reset(void) { g_botw_cancel_requested=0; g_botw_cancel_complete=0; }
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

    // Host preload can install the BOTW hook after the view read a stored Tap
    // or 2D preference. Mode refresh must force local 3D without rewriting it.
    [view dm_testSetTouchHudModeFull:NO tap:YES connected:NO];
    [NSUserDefaults.standardUserDefaults setObject:@0 forKey:@"DmPadLayout"];
    g_botw_touchhud_available = YES;
    [view dm_testRefreshTouchHudMode];
    CHECK([view dm_testIsFull] && ![view dm_testIsTap] && [view dm_testLeftStickRingHidden] && ![view dm_testStickGraphLayer].hidden,
          "late BOTW capability activation restores the local 3D center graph with its idle ring hidden");
    CHECK([[NSUserDefaults.standardUserDefaults objectForKey:@"DmPadLayout"] isEqual:@0],
          "late BOTW activation does not overwrite the shared layout preference");
    [view setFull:YES];
    CHECK([view dm_testDpadArtworkHidden], "active BOTW touch 3D mode hides D-pad artwork");
    CHECK([view dm_testSwapHidden] && ![view dm_testInSwap:CGPointMake(view.bounds.size.width*.5,20)],
          "BOTW touch removes both the visible layout toggle and its hit area");
    [view dm_testNextLayout];
    CHECK([view dm_testL3GestureEnabled], "BOTW supported touch remains in its required 3D control layout");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    CHECK([view dm_testDpadArtworkHidden] && [view dm_testControlsHidden],
          "a connected physical controller hides the touch overlay and keeps the D-pad artwork hidden");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    g_botw_touchhud_available = NO;
}

static BOOL gray_matches(CGColorRef color, CGFloat gray, CGFloat alpha) {
    CGFloat actual = 0, opacity = 0;
    return color && [[UIColor colorWithCGColor:color] getWhite:&actual alpha:&opacity] &&
        fabs(actual-gray) < .001 && fabs(opacity-alpha) < .001;
}
static void save_pad_preview(DmGamepad *view, NSString *name) {
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
    UIImage *preview=[renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor colorWithWhite:.55 alpha:1] setFill]; UIRectFill(view.bounds);
        [view.layer renderInContext:ctx.CGContext];
    }];
    [UIImagePNGRepresentation(preview) writeToFile:[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name] atomically:YES];
}
@interface DmFeedbackSpy : UIImpactFeedbackGenerator
@property(nonatomic) NSUInteger count;
@end
@implementation DmFeedbackSpy
- (void)prepare {}
- (void)impactOccurredWithIntensity:(CGFloat)intensity { (void)intensity; self.count++; }
@end
static void test_botw_button_artwork(DmGamepad *view) {
    g_botw_touchhud_available = YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    CAShapeLayer *y = [view dm_testButtonLayer:3];
    CALayer *icon = [view dm_testYIconLayer]; CAShapeLayer *badge = [view dm_testYBadge];
    CGRect button = CGPathGetBoundingBox(y.path), circle = CGPathGetBoundingBox(badge.path);
    CHECK(gray_matches(y.fillColor,.26,.20) && !y.strokeColor &&
          gray_matches([view dm_testButtonBorder:3].fillColor,.25,.40) && y.shadowOpacity == 0,
          "BOTW overrides the button fill, outline and shadow without changing ordinary defaults");
    CHECK(!icon.hidden && icon.contents && fabs(icon.frame.size.width-button.size.width*.5)<.01 &&
          fabs(icon.frame.size.height-button.size.height*.5)<.01,
          "BOTW Y uses the supplied image at half the button diameter");
    CGPoint center=CGPointMake(CGRectGetMidX(button),CGRectGetMidY(button));
    CGPoint badgeCenter=CGPointMake(CGRectGetMidX(circle),CGRectGetMidY(circle));
    CHECK(gray_matches(badge.fillColor,.20,1) && badgeCenter.x>center.x && badgeCenter.y<center.y &&
          fabs(hypot(badgeCenter.x-center.x,badgeCenter.y-center.y)-button.size.width*.5)<.01 &&
          fabs(CGRectGetMidX([view dm_testYLabel].frame)-badgeCenter.x)<.01,
          "Y label sits in a gray badge centered on the upper-right circle edge");
    int overlapping=0;
    const int buttons[]={0,1,2,3,6,7,9};
    for (unsigned i=0;i<sizeof buttons/sizeof *buttons;i++) {
        CAShapeLayer *fill=[view dm_testButtonLayer:buttons[i]], *border=[view dm_testButtonBorder:buttons[i]];
        CGRect bounds=CGPathGetPathBoundingBox(fill.path);
        for (int x=0;x<37;x++) for (int y=0;y<37;y++) {
            CGPoint p=CGPointMake(bounds.origin.x+(x+.37)*bounds.size.width/37,
                                  bounds.origin.y+(y+.61)*bounds.size.height/37);
            overlapping += CGPathContainsPoint(fill.path,NULL,p,NO) && CGPathContainsPoint(border.path,NULL,p,NO);
        }
        CHECK(!border.hidden && !fill.strokeColor && !CGPathIsEmpty(border.path),
              "BOTW buttons use a separate exterior border with centered strokes disabled");
    }
    CHECK(overlapping==0,"exterior borders do not cover the background of round or teardrop buttons");
    CAShapeLayer *a=[view dm_testButtonLayer:0], *aBorder=[view dm_testButtonBorder:0];
    CGRect disk=CGPathGetPathBoundingBox(a.path);
    CGFloat edge=CGRectGetMaxX(disk), cy=CGRectGetMidY(disk), width=a.lineWidth;
    CHECK(!CGPathContainsPoint(aBorder.path,NULL,CGPointMake(edge-.1,cy),NO) &&
          CGPathContainsPoint(aBorder.path,NULL,CGPointMake(edge+.1,cy),NO) &&
          CGPathContainsPoint(aBorder.path,NULL,CGPointMake(edge+width-.1,cy),NO) &&
          !CGPathContainsPoint(aBorder.path,NULL,CGPointMake(edge+width+.1,cy),NO),
          "the exterior circle border starts directly at the fill edge and retains its full width");
    FakeTouch *t=touch(badgeCenter.x,badgeCenter.y); began(view,t);
    CHECK((g_buttons & DM_BTN_Y) && !(g_buttons & DM_BTN_X), "the overlapping Y badge still presses Y");
    ended(view,t,badgeCenter.x,badgeCenter.y);
    save_pad_preview(view, @"botw-buttons.png");
    g_botw_rune_icon_snapshot.valid=1; g_botw_rune_icon_snapshot.generation=1;
    g_botw_rune_icon_snapshot.width=g_botw_rune_icon_snapshot.height=DM_BOTW_RUNE_ICON_SIDE;
    g_botw_rune_icon_snapshot.stride=DM_BOTW_RUNE_ICON_STRIDE;
    [view botwRuneIconChanged]; [view layoutIfNeeded];
    CAShapeLayer *runeBadge=[view dm_testRuneBadgeLayer];
    CHECK(!runeBadge.hidden && CGColorEqualToColor(runeBadge.fillColor,badge.fillColor) &&
          CGColorEqualToColor([view dm_testRuneBadgeBorder].fillColor,[view dm_testYBadgeBorder].fillColor) &&
          !runeBadge.strokeColor && !badge.strokeColor && runeBadge.shadowOpacity==0,
          "the rune L badge shares Y's opaque gray fill, gold outline and shadow-free style");
    for (int b=10;b<=11;b++) {
        CHECK(gray_matches([view dm_testButtonLayer:b].fillColor,1,1) && ![view dm_testButtonLayer:b].strokeColor &&
              [view dm_testButtonBorder:b].hidden && [view dm_testButtonLabel:b].hidden,
              "BOTW plus and minus use a white cross over the translucent circular fill without a border");
    }
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK([view dm_testControlsHidden] && icon.hidden && badge.hidden && y.shadowOpacity == .2f &&
          [view dm_testButtonBorder:3].hidden && gray_matches(y.strokeColor,1,.38) &&
          gray_matches(y.fillColor,1,.14), "controller mode hides BOTW art and restores ordinary button defaults");
    g_botw_touchhud_available=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(icon.hidden && badge.hidden && y.shadowOpacity == .2f && gray_matches(y.fillColor,1,.14) &&
          [view dm_testButtonBorder:3].hidden && gray_matches(y.strokeColor,1,.38) &&
          fabs(CGRectGetMidX([view dm_testYLabel].frame)-[view facePos:3].x)<.01,
          "other games keep their centered Y label, white fill and original shadow");
    memset(&g_botw_rune_icon_snapshot,0,sizeof g_botw_rune_icon_snapshot);
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

    CGPoint lCenter = [view dm_testRuneButtonCenter];
    CGPoint lOverlapShieldHome = [view dm_testShieldHome];
    float lHitRadius = DM_TP_L_R * dm_touchpad_u(view.bounds.size.height) * 1.45f;
    float towardShieldX = lOverlapShieldHome.x-lCenter.x, towardShieldY = lOverlapShieldHome.y-lCenter.y;
    float towardShieldD = hypotf(towardShieldX,towardShieldY);
    CGPoint lOverlapEdge = CGPointMake(lCenter.x+towardShieldX/towardShieldD*lHitRadius*.9f,
                                       lCenter.y+towardShieldY/towardShieldD*lHitRadius*.9f);
    CHECK(hypot(lOverlapEdge.x-lOverlapShieldHome.x,lOverlapEdge.y-lOverlapShieldHome.y) < DM_TP_STICK_R * dm_touchpad_u(view.bounds.size.height) * 1.4f &&
          [view dm_testBtnAt:lOverlapEdge] == 6,
          "the L button hit region takes priority where it overlaps the shield-stick grab area");
    g_buttons=0; g_lx=g_ly=0;
    FakeTouch *lEdgeTouch=touch(lOverlapEdge.x,lOverlapEdge.y); began(view,lEdgeTouch);
    CHECK((g_buttons&DM_BTN_L) && !(g_buttons&DM_BTN_ZL) && g_lx==0 && g_ly==0,
          "touching the overlapping L edge presses L instead of capturing the floating ZL stick");
    ended(view,lEdgeTouch,lOverlapEdge.x,lOverlapEdge.y);

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
    CHECK([view dm_testBtnAt:CGPointMake(CGRectGetMidX(minusRect), CGRectGetMidY(minusRect))] != 11,
          "valid map mode removes Minus ownership even if another visible control occupies its old position");
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
    CGPoint fixedPlus = [view dm_testMapBadgeCenter];
    g_botw_touch_menu_presented = YES; [view refreshBotwTouchMenuMode];
    g_botw_touch_menu_presented = NO; [view refreshBotwTouchMenuMode];
    [view layoutIfNeeded];
    CGRect noMapPlus = [view pillRect:10], noMapMinus = [view pillRect:11];
    CHECK(![view dm_testMinusArtworkHidden] && ![view dm_testButtonLayer:10].hidden &&
          [view dm_testBtnAt:CGPointMake(CGRectGetMidX(noMapMinus),CGRectGetMidY(noMapMinus))] == 11 &&
          [view dm_testBtnAt:fixedPlus] == 10,
          "returning to gameplay without a minimap restores both Plus and Minus, including in shrines");
    CHECK(CGRectGetMidX(noMapMinus) == CGRectGetMidX(noMapPlus) &&
          CGRectGetMinY(noMapMinus) > CGRectGetMaxY(noMapPlus),
          "the standalone Minus sits below the fixed Plus");
    CHECK([view dm_testSetBotwMapRectValid:YES x:0.05 y:0.16 width:0.36 height:0.40] &&
          [view dm_testMinusArtworkHidden] && [view dm_testBotwMapOwnsPoint:mapPoint],
          "a fresh collapsed-map publication rearms map taps");
    CGPoint badge = [view dm_testMapBadgeCenter];
    CGPoint oldPlus = CGPointMake(view.bounds.size.width*.5+DM_TP_PILL_DX*dm_touchpad_u(view.bounds.size.height),DM_TP_PILL_Y*dm_touchpad_u(view.bounds.size.height));
    CHECK([view dm_testBtnAt:badge] == 10 &&
          [view dm_testBtnAt:oldPlus] < 0 && CGPointEqualToPoint(badge,fixedPlus),
          "Plus keeps one position with or without the map, and removes the old centered hit");
    CGFloat badgeHalfW=noMapPlus.size.width*.5, badgeHalfH=noMapPlus.size.height*.5;
    CHECK([view dm_testBtnAt:CGPointMake(badge.x+badgeHalfW-1,badge.y)]==10 &&
          [view dm_testBtnAt:CGPointMake(badge.x+badgeHalfW+1,badge.y)]<0 &&
          [view dm_testBtnAt:CGPointMake(badge.x+badgeHalfW-1,badge.y+badgeHalfH-1)]<0,
          "the plain + keeps its generous circular hit region and rejects the corner");
    [view layoutIfNeeded];
    CGRect plusGlyph = CGPathGetBoundingBox([view dm_testButtonLayer:10].path);
    float menuCanvas[4]; dm_aspect_touch_rect(view.bounds.size.width,view.bounds.size.height,menuCanvas);
    CHECK(fabs(plusGlyph.size.width-19*menuCanvas[3]/720)<.01 &&
          fabs(plusGlyph.origin.y-(menuCanvas[1]+20*menuCanvas[3]/720+4+10*menuCanvas[3]/720))<.01,
          "Plus has a centered 19-unit cross in its 39-unit circle below the minimap top");
    CHECK(gray_matches([view dm_testButtonLayer:10].fillColor,1,1) && ![view dm_testButtonLayer:10].strokeColor &&
          [view dm_testButtonBorder:10].hidden,
          "the relocated map plus cross is white and has no border");

    g_botw_touch_actions_available = YES;
    CHECK(![view dm_testShieldGraphLayer].hidden && [view dm_testShieldRingLayer].hidden &&
          [view dm_testShieldDirectionLayer].hidden && ![view dm_testShieldGraphLayer].strokeColor,
          "idle BOTW shield shows only its shield and four arrows, without a ring or outline");
    CGPoint shield = [view dm_testShieldHome]; FakeTouch *shieldTouch=touch(shield.x+30,shield.y+5); began(view,shieldTouch);
    [view layoutIfNeeded]; CGPoint floatingRing=[view dm_testShieldRingCenter];
    CHECK(fabs(floatingRing.x-shieldTouch.point.x)<0.01 && fabs(floatingRing.y-shieldTouch.point.y)<0.01,
          "the ZL ring follows its touch-down point while its idle home remains fixed");
    CHECK((g_buttons & DM_BTN_ZL) && g_lx == 0 && g_ly == 0,
          "off-center stationary shield-stick press holds ZL with a neutral axis");
    moved(view,shieldTouch,shield.x+85,shield.y+5);
    CHECK((g_buttons & DM_BTN_ZL) && g_lx > 0,
          "shield-stick drag publishes ZL and the left-stick axis together");
    [view layoutIfNeeded];
    CGRect graph = CGPathGetPathBoundingBox([view dm_testShieldGraphLayer].path);
    CGRect ring = CGPathGetPathBoundingBox([view dm_testShieldRingLayer].path);
    CGRect direction = CGPathGetPathBoundingBox([view dm_testShieldDirectionLayer].path);
    CHECK(fabs(CGRectGetMidX(graph)-floatingRing.x)<.01 && fabs(CGRectGetMidY(graph)-floatingRing.y)<.01 &&
          ![view dm_testShieldRingLayer].hidden && ![view dm_testShieldRingLayer].fillColor,
          "dragging keeps the center graph at touch-down and reveals only the outer ring stroke");
    CHECK(![view dm_testShieldDirectionLayer].hidden &&
          fabs(CGRectGetMinX(direction)-CGRectGetMaxX(ring)-[view dm_testShieldRingLayer].lineWidth*.5)<.1 &&
          fabs(CGRectGetMidY(direction)-CGRectGetMidY(ring))<.1,
          "the rightward direction arrow meets the outside of the ring even for a shorter drag");
    save_pad_preview(view, @"botw-shield-drag.png");
    moved(view,shieldTouch,shield.x+30,shield.y-85); [view layoutIfNeeded];
    direction = CGPathGetPathBoundingBox([view dm_testShieldDirectionLayer].path);
    CHECK(fabs(CGRectGetMaxY(direction)-CGRectGetMinY(ring)+[view dm_testShieldRingLayer].lineWidth*.5)<.1 &&
          fabs(CGRectGetMidX(direction)-CGRectGetMidX(ring))<.1 && g_ly > 0,
          "the outside arrow follows an upward drag while the native movement axis stays correct");
    ended(view,shieldTouch,shield.x+85,shield.y+5);
    [view layoutIfNeeded]; CGPoint restoredRing=[view dm_testShieldRingCenter];
    CHECK(!(g_buttons & DM_BTN_ZL) && g_lx == 0,
          "lifting the shield stick releases ZL and its axis");
    CHECK(fabs(restoredRing.x-shield.x)<0.01 && fabs(restoredRing.y-shield.y)<0.01,
          "lifting the shield stick restores the ring to its idle home");
    CHECK([view dm_testShieldRingLayer].hidden && [view dm_testShieldDirectionLayer].hidden,
          "release hides the shield ring and moving arrow again");

    CGPoint stickHome=[view dm_testStickHome], shieldHome=[view dm_testShieldHome];
    FakeTouch *ordinaryStick=touch(stickHome.x,stickHome.y), *shieldConcurrent=touch(shieldHome.x+25,shieldHome.y);
    began(view,ordinaryStick); moved(view,ordinaryStick,stickHome.x+110,stickHome.y);
    CHECK(!(g_buttons&DM_BTN_B) && g_lx > 0,
          "ordinary left-stick overshoot remains movement without B");
    began(view,shieldConcurrent); moved(view,shieldConcurrent,shieldHome.x+75,shieldHome.y);
    CHECK((g_buttons&DM_BTN_ZL) && g_lx > 0 && !(g_buttons&DM_BTN_B),
          "shield-stick movement owns the left axis without B");
    ended(view,shieldConcurrent,shieldHome.x+75,shieldHome.y);
    CHECK(!(g_buttons&DM_BTN_ZL) && g_lx > 0 && !(g_buttons&DM_BTN_B),
          "lifting the shield stick restores the ordinary left-stick axis without B");
    ended(view,ordinaryStick,stickHome.x+110,stickHome.y);
    CHECK(g_lx == 0 && !(g_buttons&DM_BTN_B),
          "lifting the ordinary left stick clears its axis");

    CGPoint shoulder=[view dm_testDropCenter:7]; FakeTouch *trigger=touch(shoulder.x,shoulder.y); began(view,trigger);
    moved(view,trigger,shoulder.x+150,shoulder.y);
    CHECK(g_botw_cancel_requested==0 && (g_buttons&DM_BTN_R),
          "crossing the R cancel boundary while held does not cancel or release the trigger");
    moved(view,trigger,shoulder.x+20,shoulder.y);
    ended(view,trigger,shoulder.x+20,shoulder.y);
    CHECK(g_botw_cancel_requested==0 && !(g_buttons&DM_BTN_R),
          "dragging out and back before an inside release fires R normally without cancel");
    FakeTouch *releaseOutside=touch(shoulder.x,shoulder.y); began(view,releaseOutside);
    ended(view,releaseOutside,shoulder.x+150,shoulder.y);
    CHECK(g_botw_cancel_requested==DM_BTN_R && (g_buttons&DM_BTN_R),
          "an outside release requests native cancel even when no move event crossed the boundary");
    g_botw_cancel_complete=DM_BTN_R; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_R),
          "native cancel acknowledgement releases R while its touch remains latched");
    g_botw_cancel_complete=0; g_botw_cancel_requested=0;
    FakeTouch *cancelledOutside=touch(shoulder.x,shoulder.y); began(view,cancelledOutside);
    cancelled(view,cancelledOutside,shoulder.x+150,shoulder.y);
    CHECK(g_botw_cancel_requested==0 && !(g_buttons&DM_BTN_R),
          "UIKit touch cancellation outside the circle releases R without requesting its cancel action");
    g_botw_cancel_complete=0;
    CGPoint zrCenter=[view dm_testDropCenter:9]; FakeTouch *earlyLift=touch(zrCenter.x,zrCenter.y); began(view,earlyLift);
    moved(view,earlyLift,zrCenter.x+150,zrCenter.y);
    CHECK(g_botw_cancel_requested==0, "ZR boundary crossing alone does not request cancellation");
    ended(view,earlyLift,zrCenter.x+150,zrCenter.y);
    CHECK(g_botw_cancel_requested==DM_BTN_ZR && (g_buttons&DM_BTN_ZR),
          "lifting before the first native sample keeps the canceled ZR published for acknowledgement");
    g_botw_cancel_complete=DM_BTN_ZR; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_ZR), "an acknowledgement after finger-up releases the retained ZR source");
    g_botw_cancel_complete=0; g_botw_cancel_requested=0;

    CGPoint rCenter=[view dm_testDropCenter:7], zrCenter2=[view dm_testDropCenter:9];
    FakeTouch *r2=touch(rCenter.x,rCenter.y), *zr2=touch(zrCenter2.x,zrCenter2.y);
    began(view,r2); began(view,zr2); moved(view,r2,rCenter.x+150,rCenter.y); moved(view,zr2,zrCenter2.x+150,zrCenter2.y);
    CHECK(g_botw_cancel_requested==0 && (g_buttons&(DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR),
          "simultaneous R/ZR drags keep both actions held until release without early cancellation");
    ended(view,r2,rCenter.x+150,rCenter.y); ended(view,zr2,zrCenter2.x+150,zrCenter2.y);
    CHECK((g_botw_cancel_requested & (DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR) &&
          (g_buttons & (DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR),
          "simultaneous outside releases keep both native cancel requests pending");
    g_botw_cancel_complete=DM_BTN_R; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_R) && (g_buttons&DM_BTN_ZR),
          "R acknowledgement releases only R while ZR cancellation remains pending");
    g_botw_cancel_complete=DM_BTN_R|DM_BTN_ZR; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&(DM_BTN_R|DM_BTN_ZR)),
          "the independent ZR acknowledgement releases the remaining trigger");
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

static void test_botw_l3_timing(DmGamepad *view) {
    const double gaps[] = {.19, .21, .35};
    for (int i=0;i<3;i++) {
        [view reset]; g_botw_touchhud_available=YES;
        [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
        CGPoint home=[view dm_testStickHome];
        FakeTouch *first=touch(home.x,home.y); first.timeValue=10;
        CHECK([view dm_testL3ReceiveTouch:first] && ![view dm_testL3MayBegin],
              "one movement-stick tap cannot begin an L3 double tap");
        began(view,first); endedAt(view,first,home.x,home.y,10.05);
        FakeTouch *second=touch(home.x,home.y); second.timeValue=10.05+gaps[i];
        CHECK([view dm_testL3ReceiveTouch:second] && [view dm_testL3MayBegin] == (i==0),
              "L3 permits a 190ms gap but rejects 210ms and 350ms gaps");
        began(view,second); endedAt(view,second,home.x,home.y,second.timeValue+.05);
    }
    [view reset];
    CHECK(![view dm_testL3MayBegin], "reset clears the left-stick double-tap timing");
    g_botw_touchhud_available=NO;
}

static void test_botw_stick_response(DmGamepad *view) {
    CGRect saved=view.bounds;
    const CGFloat heights[]={390,540};
    for (int i=0;i<2;i++) {
        [view reset]; g_botw_touchhud_available=YES;
        view.bounds=CGRectMake(0,0,844,heights[i]);
        [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
        CGFloat radius=dm_touchpad_botw_stick_radius(heights[i]);
        CHECK(fabs(CGPathGetPathBoundingBox([view dm_testStickRingLayer].path).size.width-2*radius)<.01 &&
              fabs(CGPathGetPathBoundingBox([view dm_testShieldRingLayer].path).size.width-2*radius)<.01,
              "BOTW movement and ZL rings share the requested diameter on short and tall canvases");
        for (int shield=0;shield<2;shield++) {
            CGPoint home=shield ? [view dm_testShieldHome] : [view dm_testStickHome];
            FakeTouch *t=touch(home.x,home.y); began(view,t);
            moved(view,t,home.x+radius*.06,home.y);
            CHECK(g_lx==0,"BOTW movement and ZL remain neutral inside seven percent");
            moved(view,t,home.x+radius*.08,home.y);
            CHECK(g_lx>0 && (!shield || (g_buttons&DM_BTN_ZL)),
                  "both BOTW sticks respond before ten percent, preserving ZL while moving");
            moved(view,t,home.x+radius*.2,home.y);
            CHECK(shield ? g_lx>DM_STICK_MAX*.17 && g_lx<DM_STICK_MAX*.19 :
                           g_lx>DM_STICK_MAX*.29 && g_lx<DM_STICK_MAX*.31,
                  "only BOTW movement gets the stronger short-drag response; ZL stays linear");
            moved(view,t,home.x+radius*.8,home.y);
            CHECK(g_lx==DM_STICK_MAX && !(g_buttons&DM_BTN_B),
                  "eighty-percent travel remains full movement without B");
            ended(view,t,home.x+radius*.8,home.y);
        }
        [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view setNeedsLayout]; [view layoutIfNeeded];
        CGFloat original=DM_TP_STICK_R*dm_touchpad_u(heights[i]);
        CHECK(fabs(CGPathGetPathBoundingBox([view dm_testStickRingLayer].path).size.width-2*original)<.01,
              "controller mode restores the ordinary stick geometry");
        g_botw_touchhud_available=NO;
        [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
        CGPoint home=[view dm_testStickHome]; FakeTouch *t=touch(home.x,home.y); began(view,t);
        moved(view,t,home.x+original*.08,home.y);
        CHECK(!g_lx,"other games retain their ten-percent deadzone"); ended(view,t,home.x,home.y);
    }
    [view reset]; view.bounds=saved; [view setNeedsLayout]; [view layoutIfNeeded];
}

static void test_botw_stick_feedback(DmGamepad *view) {
    [view reset]; g_botw_touchhud_available=YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    DmFeedbackSpy *feedback=[[DmFeedbackSpy alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [view dm_testSetTouchFeedback:feedback];
    UIEdgeInsets insets=view.safeAreaInsets;
    dm_touchpad_point original=dm_touchpad_stick_home(view.bounds.size.width,view.bounds.size.height,
        insets.left,insets.top,insets.right,insets.bottom);
    CGPoint home=[view dm_testStickHome];
    CHECK(fabs(home.x-original.x-10)<.01 && fabs(home.y-original.y+10)<.01,
          "BOTW alone shifts the default movement-stick home ten points up and right");
    CAShapeLayer *graph=[view dm_testStickGraphLayer], *ring=[view dm_testStickRingLayer];
    CHECK(ring.hidden && !graph.fillColor && gray_matches(graph.strokeColor,1,.15) &&
          gray_matches(((CAShapeLayer *)graph.sublayers.firstObject).fillColor,1,.15),
          "idle left stick has only a white circle and four arrows at fifteen percent opacity");
    CGPoint start=CGPointMake(home.x+3,home.y+2);
    CGFloat radius=dm_touchpad_botw_stick_radius(view.bounds.size.height);
    FakeTouch *stick=touch(start.x,start.y); began(view,stick);
    NSUInteger grip=feedback.count;
    moved(view,stick,start.x+radius*1.1,start.y);
    CHECK(feedback.count==grip,"ordinary stick movement adds no haptic pulses");
    CGRect walkDirection=CGPathGetPathBoundingBox([view dm_testStickDirectionLayer].path);
    moved(view,stick,start.x+radius*1.21,start.y);
    CHECK(feedback.count==grip && !(g_buttons&DM_BTN_B),"moving outside the ring adds neither haptics nor B");
    CGRect direction=CGPathGetPathBoundingBox([view dm_testStickDirectionLayer].path);
    CHECK(!ring.hidden && !ring.fillColor && ![view dm_testStickDirectionLayer].hidden &&
          fabs(graph.position.x-start.x)<.01 && fabs(graph.position.y-start.y)<.01 &&
          fabs(CGRectGetMinX(direction)-start.x-radius-ring.lineWidth*.5)<.1 &&
          fabs(direction.size.width-walkDirection.size.width)<.1,
          "dragging beyond the ring retains the touch-down center and one direction arrow");
    save_pad_preview(view,@"botw-left-drag.png");
    moved(view,stick,start.x+radius*1.3,start.y);
    CHECK(feedback.count==grip,"remaining outside the ring adds no haptics");
    moved(view,stick,start.x+radius*1.1,start.y);
    CHECK(feedback.count==grip && !(g_buttons&DM_BTN_B),"moving back toward the ring adds neither haptics nor B");
    direction=CGPathGetPathBoundingBox([view dm_testStickDirectionLayer].path);
    CHECK(fabs(direction.size.width-walkDirection.size.width)<.1,
          "moving inward keeps the same single direction arrow");
    moved(view,stick,start.x+radius*1.21,start.y);
    NSUInteger beforeRelease=feedback.count; ended(view,stick,start.x+radius*1.21,start.y);
    CHECK(feedback.count==beforeRelease && ring.hidden && [view dm_testStickDirectionLayer].hidden,
          "release restores the idle graph without an extra haptic");

    g_look_enabled=YES; reset_look(); feedback.count=0;
    CGPoint camera=CGPointMake(view.bounds.size.width*.82,view.bounds.size.height*.38);
    FakeTouch *drag=touch(camera.x,camera.y); beganAt(view,drag,5.0);
    moved(view,drag,camera.x+40,camera.y); endedAt(view,drag,camera.x+40,camera.y,5.1);
    CHECK(feedback.count==0,"BOTW camera dragging produces no touch haptic");
    g_input_sets=0;
    FakeTouch *first=touch(camera.x,camera.y); beganAt(view,first,6.0); endedAt(view,first,camera.x,camera.y,6.08);
    FakeTouch *second=touch(camera.x,camera.y); beganAt(view,second,6.20); endedAt(view,second,camera.x,camera.y,6.28);
    BOOL r3=NO; for (int i=0;i<g_input_sets;i++) r3|=(g_input_history[i]&DM_BTN_RS)!=0;
    CHECK(feedback.count==1 && r3,"camera double tap still emits R3 with one haptic");
    [view reset]; g_botw_touchhud_available=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view layoutIfNeeded]; feedback.count=0;
    FakeTouch *ordinary=touch(camera.x,camera.y); beganAt(view,ordinary,7.0); endedAt(view,ordinary,camera.x,camera.y,7.08);
    CHECK(feedback.count==1,"other games keep their original right-stick grip haptic");
    [view dm_testSetTouchFeedback:nil]; [view reset];
}

static void test_botw_inventory_pointer(DmGamepad *view) {
    g_botw_touchhud_available = YES;
    g_botw_touch_menu_active = NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    g_menu_pointer_count = 0;
    g_botw_touch_menu_active = YES;
    [view refreshBotwTouchMenuMode];
    CHECK([view dm_testControlsHidden], "supported BOTW inventory mode hides the gameplay control artwork");
    CHECK(![view dm_testL3GestureEnabled], "inventory mode disables the gameplay L3 gesture recognizer");
    CHECK(g_virtual_latch_cancel_mask == 0xffffull,
          "inventory mode clears every pending virtual button edge without touching physical input sources");

    int touch_sets = g_touch_sets, look_events = g_look_count;
    uint64_t buttons = g_buttons; int32_t lx = g_lx, ly = g_ly, rx = g_rx, ry = g_ry;
    FakeTouch *primary = touch(422,195), *secondary = touch(600,180);
    began(view, primary);
    CHECK(g_menu_pointer_count == 1 && g_menu_pointer_events[0].phase == DM_BOTW_MENU_BEGIN,
          "inventory touch begins one native menu pointer session");
    near_value(g_menu_pointer_events[0].x, .5f, "inventory pointer x uses the normalized canvas");
    near_value(g_menu_pointer_events[0].y, .5f, "inventory pointer y uses the normalized canvas");
    began(view, secondary); moved(view, secondary, 610,190); moved(view, primary, 444,215);
    CHECK(g_menu_pointer_count == 2 && g_menu_pointer_events[1].phase == DM_BOTW_MENU_MOVE,
          "extra fingers are ignored while the primary inventory pointer pans");
    near_value(g_menu_pointer_events[1].x, 444.0f/844.0f, "inventory drag keeps normalized x coordinates");
    ended(view, secondary,610,190); ended(view, primary,444,215);
    CHECK(g_menu_pointer_count == 3 && g_menu_pointer_events[2].phase == DM_BOTW_MENU_END,
          "inventory release ends the native pointer session once");
    CHECK(g_touch_sets == touch_sets && g_look_count == look_events && g_buttons == buttons &&
          g_lx == lx && g_ly == ly && g_rx == rx && g_ry == ry,
          "inventory pointer gestures do not leak into game touch, look, buttons, or sticks");

    g_menu_pointer_count = 0; g_botw_touch_map_active = YES; g_pinch_count = 0;
    primary = touch(422,195); secondary = touch(600,180);
    began(view, primary); began(view, secondary);
    CHECK(g_menu_pointer_count == 2 && g_menu_pointer_events[1].phase == DM_BOTW_MENU_CANCEL,
          "map pinch cancels its primary pointer before zooming");
    moved(view, secondary, 640,180);
    CHECK(g_pinch_count == 2 && g_pinch_ratios[0] == 1 && g_pinch_ratios[1] > 1.2f,
          "two-finger spread sends the live map scale ratio");
    moved(view, secondary, 550,180);
    CHECK(g_pinch_ratios[g_pinch_count-1] < .8f,
          "two-finger contraction sends the reverse map scale ratio");
    ended(view, primary,422,195);
    CHECK(g_pinch_ratios[g_pinch_count-1] == 0, "lifting either pinch finger releases map zoom");
    FakeTouch *replacement = touch(500,250); began(view, replacement);
    ended(view, replacement,500,250); ended(view, secondary,600,180);
    CHECK(g_menu_pointer_count == 2,
          "replacement fingers cannot start or end a map pointer while pinch fingers remain");
    replacement = touch(500,250); began(view, replacement);
    CHECK(g_menu_pointer_count == 3 && g_menu_pointer_events[2].phase == DM_BOTW_MENU_BEGIN,
          "map pointer ownership resumes after every pinch finger lifts");
    ended(view, replacement,500,250);
    g_botw_touch_map_active = NO;

    g_menu_pointer_count = 0;
    CGRect oldBounds = view.bounds;
    primary = touch(CGRectGetMidX(oldBounds), CGRectGetMidY(oldBounds)); began(view,primary);
    CGRect resizedBounds = oldBounds; resizedBounds.size.width += 40; view.bounds = resizedBounds; [view layoutIfNeeded];
    CHECK(g_menu_pointer_count == 2 && g_menu_pointer_events[1].phase == DM_BOTW_MENU_CANCEL &&
          fabsf(g_menu_pointer_events[1].x-.5f)<1e-6f && fabsf(g_menu_pointer_events[1].y-.5f)<1e-6f,
          "resizing cancels the menu pointer with its cached normalized location");
    secondary = touch(CGRectGetMidX(resizedBounds), CGRectGetMidY(resizedBounds)); began(view,secondary);
    CHECK(g_menu_pointer_count == 2, "a replacement pointer waits until the resized gesture owner lifts");
    ended(view,primary,CGRectGetMidX(oldBounds),CGRectGetMidY(oldBounds));
    began(view,secondary);
    CHECK(g_menu_pointer_count == 3 && g_menu_pointer_events[2].phase == DM_BOTW_MENU_BEGIN,
          "menu pointer ownership can begin again after the cancelled touch lifts");
    ended(view,secondary,CGRectGetMidX(resizedBounds),CGRectGetMidY(resizedBounds));
    view.bounds = oldBounds; [view layoutIfNeeded];

    g_menu_pointer_count = 0;
    primary = touch(422,195); began(view,primary);
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    CHECK(g_menu_pointer_count == 2 && g_menu_pointer_events[1].phase == DM_BOTW_MENU_CANCEL,
          "controller connection cancels an active inventory pointer instead of leaking it");
    CHECK([view dm_testControlsHidden], "controller connection keeps the normal controller-mode overlay hidden");
    g_botw_touch_menu_active = NO;
    g_botw_touch_menu_presented = YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    CHECK([view dm_testControlsHidden], "tab-slide animation keeps gameplay artwork hidden without clickable targets");
    CHECK(![view dm_testL3GestureEnabled], "tab-slide animation keeps gameplay gestures disabled");
    g_botw_touch_menu_presented = NO;
    [view refreshBotwTouchMenuMode];
    CHECK(![view dm_testControlsHidden], "closing the native menu restores gameplay artwork");
    CHECK([view dm_testZLArtworkHidden] && [view dm_testL3ArtworkHidden] &&
          [view dm_testR3ArtworkHidden] && [view dm_testDpadArtworkHidden],
          "menu exit restores BOTW child-layer layout instead of the ordinary gamepad");
    g_botw_gameplay_ready = NO;
    [view refreshBotwTouchMenuMode];
    CHECK([view dm_testControlsHidden] && ![view dm_testL3GestureEnabled],
          "boot and loading keep gameplay artwork and gestures hidden without a menu");
    g_menu_pointer_count = 0;
    primary = touch(422,195); began(view, primary); ended(view, primary, 422, 195);
    CHECK(g_menu_pointer_count == 2, "loading touches remain on the menu path instead of combat controls");
    g_botw_gameplay_ready = YES;
    [view refreshBotwTouchMenuMode];
    CHECK(![view dm_testControlsHidden], "only confirmed gameplay restores the controls");
    CHECK([view dm_testZLArtworkHidden] && [view dm_testL3ArtworkHidden] &&
          [view dm_testR3ArtworkHidden] && [view dm_testL3GestureEnabled],
          "loading exit restores shield stick and double-tap L3 without ordinary ZL/L3/R3");
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
    test_botw_button_artwork(view);
    test_botw_virtual_buttons(view);
    test_botw_l3_timing(view);
    test_botw_stick_response(view);
    test_botw_stick_feedback(view);
    test_botw_inventory_pointer(view);
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
