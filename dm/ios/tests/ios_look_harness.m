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
void dm_gamepad_surface_changed(void);
void dm_test_phone_motion_publish(const float a[3],const float w[3],int body_frame,int orientation);
void front_look_mode_changed(void);
int dm_botw_touch_hud_available(void);
void dm_botw_touch_hud_publish(int active, float center_x, float center_y, float dpad_scale);

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
- (BOOL)dm_testMenuDpadHidden;
- (BOOL)dm_testZLArtworkHidden;
- (BOOL)dm_testControlsHidden;
- (UITapGestureRecognizer *)dm_testMenuPadGesture;
- (BOOL)dm_testManualMenuPad;
- (void)revealBotwMenuPad:(UITapGestureRecognizer *)recognizer;
- (CAShapeLayer *)dm_testButtonLayer:(int)button;
- (CAShapeLayer *)dm_testButtonBorder:(int)button;
- (CATextLayer *)dm_testButtonLabel:(int)button;
- (CAShapeLayer *)dm_testYBadgeBorder;
- (CAShapeLayer *)dm_testRuneBadgeBorder;
- (CALayer *)dm_testYIconLayer;
- (CALayer *)dm_testButtonIcon:(int)button;
- (CAShapeLayer *)dm_testYBadge;
- (CAShapeLayer *)dm_testButtonBadge:(int)button;
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
- (BOOL)dm_testCancelGuideHidden;
- (CAShapeLayer *)dm_testRuneBadgeLayer;
- (CALayer *)dm_testRuneIconLayer;
- (void)dm_testSetTouchFeedback:(UIImpactFeedbackGenerator *)feedback;
- (void)botwRuneIconChanged;
- (CGPoint)dm_testStickHome;
- (CGPoint)dm_testRuneButtonCenter;
- (CGPoint)dm_testMapBadgeCenter;
- (CGPoint)dm_testDropCenter:(int)button;
- (void)dm_testBotwTouchActionChanged;
- (void)dm_testPulseBotwL3;
- (void)reset;
- (void)padsChanged:(NSNotification *)note;
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

@interface FakeTouchEvent : UIEvent
@property(nonatomic, copy) NSSet<UITouch *> *activeTouches;
@end
@implementation FakeTouchEvent
- (NSSet<UITouch *> *)allTouches { return self.activeTouches; }
@end
@interface RecognizedMenuTap : UITapGestureRecognizer
@end
@implementation RecognizedMenuTap
- (UIGestureRecognizerState)state { return UIGestureRecognizerStateRecognized; }
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
typedef struct { uint64_t buttons; int32_t lx, ly, rx, ry; } test_pad_source;
static test_pad_source g_pad_sources[DM_PLAYERS];
static uint32_t g_pad_player_mask;
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
static BOOL g_botw_loadout_visible = YES;
static BOOL g_botw_quick_select;
static BOOL g_botw_hero_path;
static BOOL g_force_controls_hidden;
static BOOL g_botw_touch_map_active;
static BOOL g_botw_touch_camera_active;
static BOOL g_botw_scope_active;
static float g_botw_scope_prompts[3][4];
typedef struct { int phase; float x, y; } menu_pointer_event;
static menu_pointer_event g_menu_pointer_events[64];
static int g_menu_pointer_count;
typedef struct { float x, y; } camera_pose_event;
static camera_pose_event g_camera_pose_events[64];
static int g_camera_pose_count;
static int g_camera_pose_modifier;
static int g_camera_pose_modifier_events[32];
static int g_camera_pose_modifier_count;

int dm_look_enabled(void) { return g_look_enabled; }
int dm_botw_touch_hud_available(void) { return g_botw_touchhud_available; }
int dm_botw_touch_menu_active(void) { return g_botw_touch_menu_active; }
int dm_botw_touch_menu_visible(void) { return (g_botw_touch_menu_active && !g_botw_scope_active) || g_botw_touch_menu_presented; }
int dm_botw_touch_loadout_visible(void) { return g_botw_loadout_visible; }
int dm_botw_touch_quick_select_active(void) { return g_botw_quick_select; }
int dm_botw_touch_menu_dpad_visible(void) { return g_botw_hero_path; }
int dm_botw_touch_controls_visible(void) {
    if (g_force_controls_hidden) return 0;
    return !g_botw_touchhud_available || (g_botw_gameplay_ready && !dm_botw_touch_menu_visible());
}
int dm_botw_touch_map_active(void) { return g_botw_touch_map_active; }
int dm_botw_touch_camera_active(void) { return g_botw_touch_camera_active; }
int dm_botw_touch_scope_prompt_at(float x, float y) {
    if (!g_botw_scope_active) return 0;
    for (int i = 0; i < 3; i++) {
        const float *r = g_botw_scope_prompts[i];
        if (x >= r[0] && x < r[0] + r[2] && y >= r[1] && y < r[1] + r[3]) return 1;
    }
    return 0;
}
void dm_botw_touch_camera_pose(float x, float y) {
    if (g_camera_pose_count < (int)(sizeof g_camera_pose_events / sizeof g_camera_pose_events[0]))
        g_camera_pose_events[g_camera_pose_count++] = (camera_pose_event){x, y};
}
void dm_botw_touch_camera_pose_modifier(int held) {
    g_camera_pose_modifier = held != 0;
    if (g_camera_pose_modifier_count < (int)(sizeof g_camera_pose_modifier_events / sizeof g_camera_pose_modifier_events[0]))
        g_camera_pose_modifier_events[g_camera_pose_modifier_count++] = g_camera_pose_modifier;
}
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
static float g_published_dpad_scale;
void dm_botw_touch_hud_publish(int active, float center_x, float center_y, float dpad_scale) { (void)center_x; (void)center_y; if (active) g_published_dpad_scale=dpad_scale; }
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
    if (player >= 0 && player < DM_PLAYERS)
        g_pad_sources[player] = (test_pad_source){buttons, lx, ly, rx, ry};
}
void dm_pad_players(uint32_t mask) { g_pad_player_mask = mask; }
uint32_t dm_player_npad(int player) { return player == 0 ? 0x20u : (uint32_t)(player - 1); }
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    dm_pad_set_player(0, buttons, lx, ly, rx, ry);
}
void dm_touch_set(const dm_touch *touches, int count) {
    g_touch_count = count; ++g_touch_sets;
    if (count > 0 && touches) g_last_touch = touches[0];
}
static int g_seated;
void dm_aspect_touch_rect(float w, float h, float rect[4]) {
    rect[0]=rect[1]=0; rect[2]=w; rect[3]=h;
    if (g_seated) {
        float cw=fminf(w,h*.49f*16/9),ch=cw*9/16;
        rect[0]=(w-cw)*.5f; rect[1]=(h*.49f-ch)*.5f; rect[2]=cw; rect[3]=ch;
    }
}
void dm_aspect_hud_rect(float w, float h, float rect[4]) {
    rect[0]=0; rect[1]=g_seated ? h*.51f : 0; rect[2]=w; rect[3]=g_seated ? h*.49f : h;
}
int dm_aspect_region(int controls,float rect[4]) {
    rect[0]=rect[1]=0; rect[2]=rect[3]=1;
    if (g_seated) { rect[1]=controls ? .51f : 0; rect[3]=.49f; }
    return g_seated;
}
float dm_aspect_hud_y_scale(void) { return 1; }
void dm_motion_set(int p, const float acc[3], const float rot[3]) { (void)p; (void)acc; (void)rot; }
void dm_motion_clear(int p) { (void)p; }
static float g_phone_acc[3],g_phone_rot[3];
void dm_motion_set_switch(int p, const float acc[3], const float rot[3]) {
    (void)p; memcpy(g_phone_acc,acc,sizeof g_phone_acc); memcpy(g_phone_rot,rot,sizeof g_phone_rot);
}
void dm_device_motion_set(const dm_motion *motion) {
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
static void movedTogether(DmGamepad *view, FakeTouch *a, CGPoint ap, FakeTouch *b, CGPoint bp) {
    a.point = ap; b.point = bp;
    [view touchesMoved:[NSSet setWithObjects:a, b, nil] withEvent:nil];
}
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
    g_botw_loadout_visible=NO; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(![view dm_testDpadArtworkHidden],"BOTW gameplay without the native loadout shows the round direction-key fallback");
    CAShapeLayer *leftKey=[view dm_testButtonLayer:12];
    CHECK(CGPathGetPathBoundingBox(leftKey.path).size.width < 30 && !leftKey.strokeColor &&
          [view dm_testButtonBorder:12].hidden,"fallback keys use pale round silhouettes without the ordinary pad border");
    g_botw_loadout_visible=YES; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK([view dm_testDpadArtworkHidden],"native loadout restoration hides the fallback immediately");
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
    CALayer *fallback=[view dm_testRuneIconLayer];
    CGRect lDisk=CGPathGetPathBoundingBox([view dm_testButtonLayer:6].path);
    CHECK(fallback.contents && !fallback.hidden && fabs(fallback.frame.size.width-lDisk.size.width*.5)<.01,
          "hidden native rune uses the packaged L icon at half button diameter");
    CHECK([view dm_testButtonLayer:6].lineWidth==y.lineWidth,
          "L and face buttons use the same exterior border width");
    CHECK(fabs(CGPathGetPathBoundingBox([view dm_testButtonLayer:7].path).size.width-CGPathGetPathBoundingBox([view dm_testButtonLayer:9].path).size.width)<.01,
          "R and ZR have the same default diameter");
    CALayer *icon = [view dm_testYIconLayer]; CAShapeLayer *badge = [view dm_testYBadge];
    CGRect button = CGPathGetBoundingBox(y.path), circle = CGPathGetBoundingBox(badge.path);
    CHECK(gray_matches(y.fillColor,.35,.20) && !y.strokeColor &&
          gray_matches([view dm_testButtonBorder:3].fillColor,.52,.40) && y.shadowOpacity == 0,
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
    CHECK(overlapping==0,"exterior borders do not cover the button backgrounds");
    const int iconButtons[]={0,1,2,3,7,9};
    for (unsigned i=0;i<sizeof iconButtons/sizeof *iconButtons;i++) {
        int b=iconButtons[i]; CGRect disk=CGPathGetPathBoundingBox([view dm_testButtonLayer:b].path);
        CALayer *art=[view dm_testButtonIcon:b];
        CHECK(!art.hidden && art.contents && fabs(art.frame.size.width-disk.size.width*.5)<.01,
              "all six BOTW action buttons use their packaged icons at half diameter");
        CHECK(fabs(disk.size.width-disk.size.height)<.01 &&
              !CGPathContainsPoint([view dm_testButtonLayer:b].path,NULL,
                  CGPointMake(disk.origin.x+1,disk.origin.y+1),NO),
              "BOTW face and right shoulder buttons are circular");
        CAShapeLayer *tag=[view dm_testButtonBadge:b];
        CGRect circle=CGPathGetPathBoundingBox(tag.path);
        CGPoint center=CGPointMake(CGRectGetMidX(disk),CGRectGetMidY(disk));
        CGPoint tagCenter=CGPointMake(CGRectGetMidX(circle),CGRectGetMidY(circle));
        CHECK(!tag.hidden && gray_matches(tag.fillColor,.20,1) &&
              tagCenter.x>center.x && tagCenter.y<center.y &&
              fabs(hypot(tagCenter.x-center.x,tagCenter.y-center.y)-disk.size.width*.5)<.01 &&
              fabs(CGRectGetMidX([view dm_testButtonLabel:b].frame)-tagCenter.x)<.01 &&
              ![view dm_testButtonLabel:b].hidden,
              "all six action labels share Y's upper-right gray badge at the button edge");
        CGPoint outer=CGPointMake(tagCenter.x+circle.size.width*.2,tagCenter.y-circle.size.height*.2);
        FakeTouch *tap=touch(outer.x,outer.y); began(view,tap);
        CHECK(g_buttons==(1ull<<b),"the outer half of each action badge presses its own button");
        ended(view,tap,outer.x,outer.y);
    }
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
    g_botw_loadout_visible=NO; [view setNeedsLayout]; [view layoutIfNeeded];
    save_pad_preview(view, @"botw-dpad-fallback.png");
    g_botw_loadout_visible=YES; [view setNeedsLayout]; [view layoutIfNeeded];
    g_botw_rune_icon_snapshot.valid=1; g_botw_rune_icon_snapshot.generation=1;
    g_botw_rune_icon_snapshot.width=g_botw_rune_icon_snapshot.height=DM_BOTW_RUNE_ICON_SIDE;
    g_botw_rune_icon_snapshot.stride=DM_BOTW_RUNE_ICON_STRIDE;
    id fixedLIcon=[view dm_testRuneIconLayer].contents;
    [view botwRuneIconChanged]; [view layoutIfNeeded];
    CHECK([view dm_testRuneIconLayer].contents==fixedLIcon,
          "L keeps its packaged icon when the current native rune changes");
    CAShapeLayer *runeBadge=[view dm_testRuneBadgeLayer];
    CHECK(!runeBadge.hidden && CGColorEqualToColor(runeBadge.fillColor,badge.fillColor) &&
          CGColorEqualToColor([view dm_testRuneBadgeBorder].fillColor,[view dm_testYBadgeBorder].fillColor) &&
          !runeBadge.strokeColor && !badge.strokeColor && runeBadge.shadowOpacity==0,
          "the rune L badge shares Y's opaque gray fill, gold outline and shadow-free style");
    for (int b=10;b<=11;b++) {
        CHECK(gray_matches([view dm_testButtonLayer:b].fillColor,1,1) && ![view dm_testButtonLayer:b].strokeColor &&
              [view dm_testButtonBorder:b].hidden && [view dm_testButtonLabel:b].hidden,
              "BOTW plus and minus use a white cross over the translucent circular fill without a border");
        CGPathRef path=[view dm_testButtonLayer:b].path;
        CGRect bg=[view pillRect:b]; CGPoint p=CGPointMake(CGRectGetMidX(bg),CGRectGetMidY(bg));
        CGFloat edge=bg.size.width*.11*.5;
        CHECK(CGPathContainsPoint(path,NULL,CGPointMake(p.x+5,p.y+edge-.02),NO) &&
              !CGPathContainsPoint(path,NULL,CGPointMake(p.x+5,p.y+edge+.02),NO),
              "menu cross thickness is eleven percent of its button diameter");
    }
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view setNeedsLayout]; [view layoutIfNeeded];
    for (unsigned i=0;i<sizeof iconButtons/sizeof *iconButtons;i++)
        CHECK([view dm_testButtonBadge:iconButtons[i]].hidden,"controller mode hides every action badge");
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
    float lHitRadius = CGRectGetWidth(CGPathGetPathBoundingBox([view dm_testButtonLayer:6].path)) * .5f * 1.45f;
    float towardShieldX = lOverlapShieldHome.x-lCenter.x, towardShieldY = lOverlapShieldHome.y-lCenter.y;
    float towardShieldD = hypotf(towardShieldX,towardShieldY);
    CGPoint lOverlapEdge = CGPointMake(lCenter.x+towardShieldX/towardShieldD*lHitRadius*.9f,
                                       lCenter.y+towardShieldY/towardShieldD*lHitRadius*.9f);
    CHECK([view dm_testBtnAt:lOverlapEdge] == 6,
          "the resized L hit region owns its edge toward the shield stick");
    g_buttons=0; g_lx=g_ly=0;
    FakeTouch *lEdgeTouch=touch(lOverlapEdge.x,lOverlapEdge.y); began(view,lEdgeTouch);
    CHECK((g_buttons&DM_BTN_L) && !(g_buttons&(DM_BTN_ZL|DM_BTN_UP)) && g_lx==0 && g_ly==0,
          "the L edge presses immediately without capturing the shield stick");
    ended(view,lEdgeTouch,lOverlapEdge.x,lOverlapEdge.y);

    g_input_sets = 0; g_input_history[0] = g_input_history[1] = 0;
    g_pad_sets = 0;
    dm_pad_set_player(0, DM_BTN_A, 1234, -2345, 3456, -4567);
    int physical_sets_before = g_pad_sets;
    [view dm_testPulseBotwL3];
    CHECK(g_input_sets == 2 && (g_input_history[0] & DM_BTN_LS) && !(g_input_history[1] & DM_BTN_LS) &&
          !(g_buttons & DM_BTN_LS),
          "virtual L3 publishes one press edge and immediately releases its source");
    CHECK(g_pad_sets == physical_sets_before && g_pad_sources[0].buttons == DM_BTN_A &&
          g_pad_sources[0].lx == 1234 && g_pad_sources[0].ly == -2345 &&
          !(g_pad_sources[0].buttons & DM_BTN_LS),
          "virtual L3 pulse leaves player 1's physical controller channel untouched");
    dm_pad_set_player(0, 0, 0, 0, 0, 0);

    CHECK([view dm_testSetBotwMapRectValid:YES x:0.05 y:0.16 width:0.36 height:0.40],
          "active BOTW mode accepts the live relocated-map clip as a hit region");
    CHECK([view dm_testMinusArtworkHidden], "valid visible map hides the standalone Minus artwork");
    CGRect minusRect = [view pillRect:11];
    CHECK([view dm_testBtnAt:CGPointMake(CGRectGetMidX(minusRect), CGRectGetMidY(minusRect))] != 11,
          "valid map mode removes Minus ownership even if another visible control occupies its old position");
    g_input_sets = 0; g_input_history[0] = g_input_history[1] = 0;
    int touch_sets_before = g_touch_sets, look_begins_before = g_begin_count;
    // Inside the published map, clear of the ZL grab region with either
    // landscape safe-area inset (the fixture also runs on notched devices).
    CGPoint mapPoint = CGPointMake(view.bounds.size.width * 0.36, view.bounds.size.height * 0.20);
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

    DmFeedbackSpy *cancelFeedback=[[DmFeedbackSpy alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [view dm_testSetTouchFeedback:cancelFeedback];
    CGPoint shoulder=[view dm_testDropCenter:7]; NSUInteger beforePress=cancelFeedback.count;
    FakeTouch *trigger=touch(shoulder.x,shoulder.y); began(view,trigger);
    CHECK(cancelFeedback.count==beforePress+1,"R touch-down keeps its press haptic");
    [view layoutIfNeeded];
    CHECK(![view dm_testCancelGuideHidden], "R shows its cancel guide while a finger owns it");
    NSUInteger pressedFeedback=cancelFeedback.count;
    moved(view,trigger,shoulder.x+150,shoulder.y);
    CHECK(g_botw_cancel_requested==0 && (g_buttons&DM_BTN_R),
          "crossing the R cancel boundary while held does not cancel or release the trigger");
    CHECK(cancelFeedback.count==pressedFeedback+1,"crossing outside the cancel circle pulses once");
    moved(view,trigger,shoulder.x+160,shoulder.y);
    CHECK(cancelFeedback.count==pressedFeedback+1,"moving farther outside adds no duplicate crossing pulse");
    moved(view,trigger,shoulder.x+20,shoulder.y);
    ended(view,trigger,shoulder.x+20,shoulder.y);
    CHECK(g_botw_cancel_requested==0 && !(g_buttons&DM_BTN_R),
          "dragging out and back before an inside release fires R normally without cancel");
    CHECK(cancelFeedback.count==pressedFeedback+2,"crossing back inside pulses once; inside release adds no pulse");
    FakeTouch *releaseOutside=touch(shoulder.x,shoulder.y); began(view,releaseOutside);
    pressedFeedback=cancelFeedback.count;
    ended(view,releaseOutside,shoulder.x+150,shoulder.y);
    [view layoutIfNeeded];
    CHECK(g_botw_cancel_requested==DM_BTN_R && (g_buttons&DM_BTN_R),
          "an outside release requests native cancel even when no move event crossed the boundary");
    CHECK([view dm_testCancelGuideHidden] && cancelFeedback.count==pressedFeedback,
          "R outside release hides the guide without a release haptic");
    g_botw_cancel_complete=DM_BTN_R; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_R),
          "native cancel acknowledgement releases R while its touch remains latched");
    CHECK(cancelFeedback.count==pressedFeedback,"native cancel acknowledgement adds no haptic");
    g_botw_cancel_complete=0; g_botw_cancel_requested=0;
    FakeTouch *cancelledOutside=touch(shoulder.x,shoulder.y); began(view,cancelledOutside);
    pressedFeedback=cancelFeedback.count;
    cancelled(view,cancelledOutside,shoulder.x+150,shoulder.y);
    CHECK(g_botw_cancel_requested==0 && !(g_buttons&DM_BTN_R),
          "UIKit touch cancellation outside the circle releases R without requesting its cancel action");
    CHECK(cancelFeedback.count==pressedFeedback,"system-cancelled touches add no cancel haptic");
    g_botw_cancel_complete=0;
    CGPoint zrCenter=[view dm_testDropCenter:9]; FakeTouch *earlyLift=touch(zrCenter.x,zrCenter.y); began(view,earlyLift);
    moved(view,earlyLift,zrCenter.x+150,zrCenter.y);
    CHECK(g_botw_cancel_requested==0, "ZR boundary crossing alone does not request cancellation");
    pressedFeedback=cancelFeedback.count;
    ended(view,earlyLift,zrCenter.x+150,zrCenter.y);
    [view layoutIfNeeded];
    CHECK(g_botw_cancel_requested==DM_BTN_ZR && (g_buttons&DM_BTN_ZR),
          "lifting before the first native sample keeps the canceled ZR published for acknowledgement");
    CHECK([view dm_testCancelGuideHidden] && cancelFeedback.count==pressedFeedback,
          "ZR outside release immediately hides the guide without a release haptic");
    g_botw_cancel_complete=DM_BTN_ZR; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_ZR), "an acknowledgement after finger-up releases the retained ZR source");
    g_botw_cancel_complete=0; g_botw_cancel_requested=0;
    FakeTouch *insideLift=touch(zrCenter.x,zrCenter.y); beforePress=cancelFeedback.count;
    began(view,insideLift); NSUInteger insidePress=cancelFeedback.count;
    CHECK(insidePress==beforePress+1,"ZR touch-down keeps its press haptic");
    ended(view,insideLift,zrCenter.x+20,zrCenter.y);
    CHECK(cancelFeedback.count==insidePress && !(g_buttons&DM_BTN_ZR),
          "in-radius ZR release clears the button without an extra haptic");

    CGPoint rCenter=[view dm_testDropCenter:7], zrCenter2=[view dm_testDropCenter:9];
    FakeTouch *r2=touch(rCenter.x,rCenter.y), *zr2=touch(zrCenter2.x,zrCenter2.y);
    began(view,r2); began(view,zr2); moved(view,r2,rCenter.x+150,rCenter.y); moved(view,zr2,zrCenter2.x+150,zrCenter2.y);
    CHECK(g_botw_cancel_requested==0 && (g_buttons&(DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR),
          "simultaneous R/ZR drags keep both actions held until release without early cancellation");
    ended(view,r2,rCenter.x+150,rCenter.y); [view layoutIfNeeded];
    CHECK(![view dm_testCancelGuideHidden],"lifting R keeps the guide for the ZR finger that is still down");
    ended(view,zr2,zrCenter2.x+150,zrCenter2.y); [view layoutIfNeeded];
    CHECK([view dm_testCancelGuideHidden],"lifting both fingers hides all guides while both cancellations remain pending");
    CHECK((g_botw_cancel_requested & (DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR) &&
          (g_buttons & (DM_BTN_R|DM_BTN_ZR))==(DM_BTN_R|DM_BTN_ZR),
          "simultaneous outside releases keep both native cancel requests pending");
    g_botw_cancel_complete=DM_BTN_R; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&DM_BTN_R) && (g_buttons&DM_BTN_ZR),
          "R acknowledgement releases only R while ZR cancellation remains pending");
    g_botw_cancel_complete=DM_BTN_R|DM_BTN_ZR; [view dm_testBotwTouchActionChanged];
    CHECK(!(g_buttons&(DM_BTN_R|DM_BTN_ZR)),
          "the independent ZR acknowledgement releases the remaining trigger");
    FakeTouch *resetTrigger=touch(zrCenter.x,zrCenter.y); began(view,resetTrigger); [view layoutIfNeeded];
    [view reset]; [view layoutIfNeeded];
    CHECK([view dm_testCancelGuideHidden],"reset removes a held shoulder cancel guide");
    [view dm_testSetTouchFeedback:nil];
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

static void test_botw_map_menu_return(DmGamepad *view) {
    g_botw_touchhud_available=YES; g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view reset];
    CGPoint map=CGPointMake(view.bounds.size.width*.36,view.bounds.size.height*.20);
    for(int sourceFirst=0;sourceFirst<2;sourceFirst++) {
        g_botw_touch_menu_presented=YES; [view refreshBotwTouchMenuMode];
        [view dm_testSetBotwMapRectValid:NO x:0 y:0 width:0 height:0];
        if(sourceFirst) g_botw_touch_menu_presented=NO;
        // The host publishes only changed rectangles. This one notification
        // arrives before the frontend has left its inventory/menu mode.
        [view dm_testSetBotwMapRectValid:YES x:.05 y:.16 width:.36 height:.40];
        CHECK(![view dm_testBotwMapOwnsPoint:map] && [view dm_testControlsHidden],
              "a map update during a menu cannot activate hidden gameplay controls");
        g_botw_touch_menu_presented=NO; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
        CHECK([view dm_testBotwMapOwnsPoint:map] && [view dm_testMinusArtworkHidden],
              "inventory return restores the map hit and hides Minus without a second native publication");
        g_input_sets=0; FakeTouch *t=touch(map.x,map.y); began(view,t); ended(view,t,map.x,map.y);
        int presses=0; for(int i=0;i<g_input_sets;i++) presses+=(g_input_history[i]&DM_BTN_MINUS)!=0;
        CHECK(presses==1,"the restored minimap tap publishes exactly one native Minus press");
    }
    g_botw_touch_menu_presented=YES; [view refreshBotwTouchMenuMode];
    [view dm_testSetBotwMapRectValid:YES x:.05 y:.16 width:.36 height:.40];
    [view dm_testSetBotwMapRectValid:NO x:0 y:0 width:0 height:0];
    g_botw_touch_menu_presented=NO; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK(![view dm_testBotwMapOwnsPoint:map] && ![view dm_testMinusArtworkHidden],
          "a later native invalidation keeps map taps disabled and Minus available after return");
    [view reset];
}

static void test_botw_rune_press(DmGamepad *view) {
    g_botw_touchhud_available=YES; g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view reset];
    CGPoint point=[view dm_testRuneButtonCenter];
    FakeTouch *tap=touch(point.x,point.y); g_input_sets=0;
    beganAt(view,tap,10);
    CHECK((g_buttons&DM_BTN_L) && !(g_buttons&DM_BTN_UP),"BOTW L presses on touch-down before release");
    endedAt(view,tap,point.x,point.y,10.1);
    int presses=0; for(int i=0;i<g_input_sets;i++) presses+=(g_input_history[i]&DM_BTN_L)!=0;
    CHECK(presses==1 && !(g_buttons&(DM_BTN_L|DM_BTN_UP)),"L release clears its source without a second press");
    tap=touch(point.x,point.y); beganAt(view,tap,20);
    moved(view,tap,point.x+60,point.y); tap.timeValue=21;
    CHECK((g_buttons&DM_BTN_L) && !(g_buttons&DM_BTN_UP),"holding and dragging L keeps L held and never substitutes rune-selection Up");
    endedAt(view,tap,point.x+60,point.y,21);
    CHECK(!(g_buttons&(DM_BTN_L|DM_BTN_UP)),"lifting outside L releases the original button");
    tap=touch(point.x,point.y); began(view,tap); cancelled(view,tap,point.x,point.y);
    CHECK(!(g_buttons&(DM_BTN_L|DM_BTN_UP)),"system cancellation releases L without a trailing action");
    tap=touch(point.x,point.y); began(view,tap); [view reset];
    CHECK(!(g_buttons&(DM_BTN_L|DM_BTN_UP)) && (g_virtual_latch_cancel_mask&DM_BTN_L),
          "reset releases held L and clears its unread press edge");
    ended(view,tap,point.x,point.y);
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    tap=touch(point.x,point.y); began(view,tap);
    CHECK(!(g_buttons&DM_BTN_L),"a connected controller prevents BOTW touch L input");
    ended(view,tap,point.x,point.y);
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; g_botw_touchhud_available=NO; [view reset];
    point=[view dm_testDropCenter:6]; tap=touch(point.x,point.y); began(view,tap);
    CHECK(g_buttons&DM_BTN_L,"ordinary game L still presses immediately on touch-down");
    ended(view,tap,point.x,point.y); g_botw_touchhud_available=YES; [view reset];
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
    // Even an 8pt drag can move Link while UIKit still considers it a tap.
    // Returning to the origin, final-release-only moves and holds cannot seed L3.
    for (int i=0;i<3;i++) {
        [view reset]; g_botw_touchhud_available=YES;
        [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
        CGPoint home=[view dm_testStickHome];
        FakeTouch *first=touch(home.x,home.y); beganAt(view,first,20);
        if (i==0) { moved(view,first,home.x+8,home.y); moved(view,first,home.x,home.y); }
        endedAt(view,first,home.x+(i==1?8:0),home.y,i==2?20.5:20.05);
        FakeTouch *next=touch(home.x,home.y); next.timeValue=first.timeValue+.05;
        CHECK([view dm_testL3ReceiveTouch:next] && ![view dm_testL3MayBegin],
              "movement or a hold followed by one tap never triggers L3");
        began(view,next); endedAt(view,next,home.x,home.y,next.timeValue+.05);
        FakeTouch *second=touch(home.x,home.y); second.timeValue=next.timeValue+.1;
        CHECK([view dm_testL3ReceiveTouch:second] && [view dm_testL3MayBegin],
              "two fresh short taps still permit L3 after movement");
    }
    [view reset]; [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    CGPoint dc=[view dpadCenter];
    FakeTouch *direction=touch(dc.x,dc.y-25); began(view,direction);
    CHECK((g_buttons&DM_BTN_UP) && !(g_buttons&DM_BTN_RIGHT),"BOTW D-pad begins on Up");
    moved(view,direction,dc.x+25,dc.y);
    CHECK((g_buttons&DM_BTN_UP) && !(g_buttons&DM_BTN_RIGHT),"BOTW D-pad keeps its initial direction while sliding");
    ended(view,direction,dc.x+25,dc.y);
    CGPoint a=[view facePos:0], b=[view facePos:1];
    FakeTouch *face=touch(a.x,a.y); began(view,face); moved(view,face,b.x,b.y);
    CHECK((g_buttons&DM_BTN_B) && !(g_buttons&DM_BTN_A),"BOTW face-button sliding is preserved");
    ended(view,face,b.x,b.y);
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
        CHECK(fabs(CGPathGetPathBoundingBox([view dm_testStickRingLayer].path).size.width-2*radius*.8)<.01 &&
              fabs(CGPathGetPathBoundingBox([view dm_testShieldRingLayer].path).size.width-2*radius)<.01,
              "BOTW movement uses eighty-percent size while ZL keeps its independent diameter");
        CGFloat baseRadius=radius;
        for (int shield=0;shield<2;shield++) {
            radius=baseRadius*(shield ? 1 : .8);
            CGPoint home=shield ? [view dm_testShieldHome] : [view dm_testStickHome];
            FakeTouch *t=touch(home.x,home.y); began(view,t);
            moved(view,t,home.x+radius*.06,home.y);
            CHECK(g_lx==0,"BOTW movement and ZL remain neutral inside seven percent");
            moved(view,t,home.x+radius*.08,home.y);
            CHECK(g_lx>0 && (!shield || (g_buttons&DM_BTN_ZL)),
                  "both BOTW sticks respond before ten percent, preserving ZL while moving");
            moved(view,t,home.x+radius*.2,home.y);
            CHECK(shield ? g_lx>DM_STICK_MAX*.17 && g_lx<DM_STICK_MAX*.19 :
                           g_lx>DM_STICK_MAX*.619 && g_lx<DM_STICK_MAX*.621,
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
    CGPoint face=[view facePos:0]; NSUInteger beforeButton=feedback.count;
    FakeTouch *button=touch(face.x,face.y); began(view,button);
    CHECK(feedback.count==beforeButton+1 && (g_buttons&DM_BTN_A),
          "BOTW face-button press keeps its touch haptic");
    ended(view,button,face.x,face.y);
    CHECK(feedback.count==beforeButton+1,"BOTW face-button release adds no haptic");
    CGPoint shieldHome=[view dm_testShieldHome]; beforeButton=feedback.count;
    FakeTouch *shield=touch(shieldHome.x,shieldHome.y); began(view,shield);
    CHECK(feedback.count==beforeButton+1 && (g_buttons&DM_BTN_ZL),
          "BOTW shield-stick grab keeps its ZL press haptic");
    ended(view,shield,shieldHome.x,shieldHome.y);
    CHECK(feedback.count==beforeButton+1,"BOTW shield-stick release adds no haptic");
    UIEdgeInsets insets=view.safeAreaInsets;
    dm_touchpad_point original=dm_touchpad_stick_home(view.bounds.size.width,view.bounds.size.height,
        insets.left,insets.top,insets.right,insets.bottom);
    CGPoint home=[view dm_testStickHome];
    float canvas[4]; dm_aspect_touch_rect(view.bounds.size.width,view.bounds.size.height,canvas);
    CHECK(fabs(home.x-original.x-10)<.01 && fabs(home.y-original.y+10-canvas[3]*.023)<.01,
          "BOTW movement-stick home includes the configured default vertical offset");
    CAShapeLayer *graph=[view dm_testStickGraphLayer], *ring=[view dm_testStickRingLayer];
    CHECK(ring.hidden && !graph.fillColor && gray_matches(graph.strokeColor,1,.15) &&
          gray_matches(((CAShapeLayer *)graph.sublayers.firstObject).fillColor,1,.15),
          "idle left stick has only a white circle and four arrows at fifteen percent opacity");
    CGPoint start=CGPointMake(home.x+3,home.y+2);
    CGFloat radius=dm_touchpad_botw_stick_radius(view.bounds.size.height)*dm_touchpad_botw_move_defaults().size;
    NSUInteger beforeStickGrab=feedback.count;
    FakeTouch *stick=touch(start.x,start.y); began(view,stick);
    CHECK(feedback.count==beforeStickGrab,
          "BOTW movement-stick grab is silent while button feedback remains enabled");
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
    CHECK(feedback.count==0 && r3,"camera double tap emits R3 without a touch haptic");
    g_input_sets=0; [view dm_testPulseBotwL3];
    BOOL l3=NO; for (int i=0;i<g_input_sets;i++) l3|=(g_input_history[i]&DM_BTN_LS)!=0;
    CHECK(l3 && feedback.count==0,"movement-stick L3 pulse remains silent");
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
    g_botw_hero_path=YES; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK(![view dm_testMenuDpadHidden] && [view dm_testControlsHidden],
          "Hero's Path shows only menu direction keys while combat controls stay hidden");
    CGPoint d=[view dpadCenter]; FakeTouch *hero=touch(d.x+32,d.y);
    began(view,hero); CHECK(g_buttons==DM_BTN_RIGHT,"Hero's Path right key holds the native direction");
    moved(view,hero,d.x-32,d.y);
    CHECK(g_buttons==DM_BTN_RIGHT,"Hero's Path direction remains locked to touch-down");
    g_botw_hero_path=NO; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK([view dm_testMenuDpadHidden] && !g_buttons,"leaving Hero's Path releases held direction keys");
    ended(view,hero,d.x-32,d.y);
    g_botw_hero_path=YES; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    FakeTouch *outside=touch(422,195); int menuBefore=g_menu_pointer_count;
    began(view,outside); ended(view,outside,422,195);
    CHECK(!g_buttons && g_menu_pointer_count==menuBefore+2,"map touches outside Hero's Path keys retain menu routing");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view layoutIfNeeded];
    CHECK([view dm_testMenuDpadHidden],"connecting a controller hides Hero's Path touch keys");
    g_botw_hero_path=NO; [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    g_menu_pointer_count=0;

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

    // A live AppCamera makes a two-finger touch exclusive: midpoint motion is
    // left-stick selfie pose, span motion is the native D-pad zoom pulse.
    g_menu_pointer_count = g_pinch_count = g_camera_pose_count = g_camera_pose_modifier_count = 0;
    g_camera_pose_modifier = 0;
    g_botw_touch_camera_active = YES;
    [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK(![view dm_testControlsHidden],
          "live AppCamera keeps the normal virtual gamepad artwork visible behind native hints");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view layoutIfNeeded];
    CHECK([view dm_testControlsHidden],
          "a connected physical controller suppresses the AppCamera touch gamepad");
    int controllerPointerCount = g_menu_pointer_count, controllerTouchSets = g_touch_sets;
    primary = touch(422,195); began(view,primary); ended(view,primary,422,195);
    CHECK(g_menu_pointer_count == controllerPointerCount && g_touch_sets > controllerTouchSets,
          "controller mode sends touch through its existing game-touch path instead of camera gestures");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view layoutIfNeeded];
    CHECK(![view dm_testControlsHidden],
          "disconnecting the controller restores controls for the safe AppCamera viewfinder");
    CGPoint faceA = [view facePos:0]; FakeTouch *gamepadTap = touch(faceA.x,faceA.y);
    int menuBeforeControl = g_menu_pointer_count; began(view,gamepadTap);
    CHECK((g_buttons & DM_BTN_A) && g_menu_pointer_count == menuBeforeControl,
          "AppCamera hit routing gives a gamepad control first refusal over the camera pointer");
    ended(view,gamepadTap,faceA.x,faceA.y);
    const CGPoint nativeFooter[] = {{.8615,.945},{.772,.945},{.670,.945},{.5605,.945}};
    const char *footerNames[] = {"A","B","X","Minus"};
    float picture[4]; dm_aspect_touch_rect((float)view.bounds.size.width,
        (float)view.bounds.size.height,picture);
    for (unsigned i=0;i<sizeof nativeFooter/sizeof nativeFooter[0];i++) {
        CGPoint p = CGPointMake(picture[0]+nativeFooter[i].x*picture[2],
                                picture[1]+nativeFooter[i].y*picture[3]);
        int before = g_menu_pointer_count; FakeTouch *footer = touch(p.x,p.y); began(view,footer);
        BOOL nativeOwns = g_menu_pointer_count==before+1 &&
            g_menu_pointer_events[before].phase==DM_BOTW_MENU_BEGIN && !g_buttons;
        ended(view,footer,p.x,p.y);
        char message[128]; snprintf(message,sizeof message,
            "AppCamera %s footer label remains a native touch target",footerNames[i]);
        CHECK(nativeOwns && g_menu_pointer_count==before+2 &&
              g_menu_pointer_events[before+1].phase==DM_BOTW_MENU_END,message);
    }
    menuBeforeControl = g_menu_pointer_count;
    primary = touch(422,195); began(view,primary); ended(view,primary,422,195);
    CHECK(g_menu_pointer_count == menuBeforeControl+2 &&
          g_menu_pointer_events[menuBeforeControl].phase == DM_BOTW_MENU_BEGIN &&
          g_menu_pointer_events[menuBeforeControl+1].phase == DM_BOTW_MENU_END,
          "unclaimed AppCamera touch area retains native pointer framing input");
    g_botw_touch_camera_active = NO; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK([view dm_testControlsHidden],
          "captured-photo modal owner hides the gamepad while native menu input remains available");
    menuBeforeControl = g_menu_pointer_count;
    primary = touch(422,195); began(view,primary); ended(view,primary,422,195);
    CHECK(g_menu_pointer_count == menuBeforeControl+2,
          "captured-photo modal continues to receive native pointer input");
    g_botw_touch_camera_active = YES; [view refreshBotwTouchMenuMode];
    CGPoint stickHome=[view dm_testStickHome], heldFace=[view facePos:0];
    FakeTouch *heldButton=touch(heldFace.x,heldFace.y), *heldStick=touch(stickHome.x,stickHome.y);
    began(view,heldButton); began(view,heldStick); moved(view,heldStick,stickHome.x+80,stickHome.y);
    CHECK((g_buttons&DM_BTN_A) && g_lx!=0,
          "AppCamera permits simultaneous virtual button and stick input");
    g_botw_touch_camera_active=NO; [view refreshBotwTouchMenuMode];
    CHECK(!(g_buttons&DM_BTN_A) && g_lx==0 && [view dm_testControlsHidden],
          "viewfinder-to-photo-modal transition cancels held controls and hides the gamepad");
    g_botw_touch_camera_active=YES; [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK(![view dm_testControlsHidden] && [view dm_testZLArtworkHidden] &&
          [view dm_testL3ArtworkHidden] && [view dm_testR3ArtworkHidden],
          "returning to AppCamera restores the BOTW control artwork");
    ended(view,heldButton,heldFace.x,heldFace.y); ended(view,heldStick,stickHome.x+80,stickHome.y);
    g_menu_pointer_count = 0;
    primary = touch(422,195); secondary = touch(600,195);
    FakeTouch *modifier = touch(510,300);
    began(view,primary); began(view,secondary); began(view,modifier);
    CHECK(g_camera_pose_modifier == 0,
          "third camera finger does not assert ZL before a pose gesture is selected");
    movedTogether(view,primary,CGPointMake(462,175),secondary,CGPointMake(640,175));
    CHECK(g_menu_pointer_count == 2 && g_menu_pointer_events[1].phase == DM_BOTW_MENU_CANCEL,
          "AppCamera second finger cancels the one-finger framing pointer");
    CHECK(g_camera_pose_count > 0 && g_pinch_count == 0 &&
          g_camera_pose_events[g_camera_pose_count-1].x > 0 &&
          g_camera_pose_events[g_camera_pose_count-1].y > 0,
          "parallel two-finger translation sends selfie pose only");
    CHECK(g_camera_pose_modifier == 1,
          "third held camera finger enables ZL for the selected weapon pose");
    ended(view,modifier,510,300);
    CHECK(g_camera_pose_modifier == 0 && g_camera_pose_events[g_camera_pose_count-1].x != 0,
          "releasing the third finger clears ZL while keeping pose active");
    ended(view,secondary,640,175);
    CHECK(g_camera_pose_events[g_camera_pose_count-1].x == 0 &&
          g_camera_pose_events[g_camera_pose_count-1].y == 0,
          "releasing either camera pose finger clears the native left stick");
    ended(view,primary,462,175);

    g_pinch_count = g_camera_pose_count = g_camera_pose_modifier_count = 0;
    primary = touch(422,195); secondary = touch(600,195);
    began(view,primary); began(view,secondary);
    movedTogether(view,primary,CGPointMake(402,195),secondary,CGPointMake(620,195));
    CHECK(g_pinch_count > 0 && g_pinch_ratios[g_pinch_count-1] > 1.2f &&
          g_camera_pose_count == 0,
          "AppCamera distance change selects zoom without sending pose");
    ended(view,primary,422,195);
    CHECK(g_pinch_ratios[g_pinch_count-1] == 0,
          "lifting a camera zoom finger cancels the held native zoom input");
    ended(view,secondary,640,195);

    g_pinch_count = g_camera_pose_count = g_camera_pose_modifier_count = 0;
    primary = touch(422,195); secondary = touch(600,195);
    began(view,primary); began(view,secondary);
    movedTogether(view,primary,CGPointMake(422,225),secondary,CGPointMake(600,225));
    cancelled(view,secondary,600,225);
    CHECK(g_camera_pose_events[g_camera_pose_count-1].x == 0 &&
          g_camera_pose_events[g_camera_pose_count-1].y == 0,
          "cancelled camera gesture clears selfie pose immediately");
    ended(view,primary,422,225);

    g_camera_pose_modifier = 0;
    primary = touch(422,195); secondary = touch(600,195); modifier = touch(510,300);
    began(view,primary); began(view,secondary); began(view,modifier);
    movedTogether(view,primary,CGPointMake(452,195),secondary,CGPointMake(630,195));
    CHECK(g_camera_pose_modifier == 1, "third finger can hold ZL through an active weapon pose");
    g_botw_touch_camera_active = NO; [view reset];
    CHECK(g_camera_pose_modifier == 0,
          "camera owner reset clears the third-finger ZL modifier");
    g_botw_touch_camera_active = NO;

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

static void test_botw_scope_pointer(DmGamepad *view) {
    [view reset];
    g_botw_touchhud_available = g_botw_gameplay_ready = g_botw_scope_active = YES;
    g_botw_touch_menu_active = YES; g_botw_touch_menu_presented = NO;
    g_botw_touch_camera_active = NO; g_look_enabled = YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view layoutIfNeeded];
    CHECK(![view dm_testControlsHidden] && [view dm_testL3GestureEnabled],
          "scope native hints leave the virtual gamepad and gameplay gestures visible");
    float picture[4]; dm_aspect_touch_rect((float)view.bounds.size.width,
        (float)view.bounds.size.height,picture);
    for (int i = 0; i < 3; i++) {
        float *r = g_botw_scope_prompts[i];
        r[0] = .75f - i * .11f; r[1] = .917f; r[2] = .105f; r[3] = .056f;
    }
    const char *checks[] = {
        "scope A hint uses the native pointer while the gamepad is visible",
        "scope B hint uses the native pointer while the gamepad is visible",
        "scope Minus hint uses the native pointer while the gamepad is visible"};
    for (int i = 0; i < 3; i++) {
        const float *r = g_botw_scope_prompts[i];
        CGPoint p = CGPointMake(picture[0] + (r[0] + r[2] * .5f) * picture[2],
                                picture[1] + (r[1] + r[3] * .5f) * picture[3]);
        int before = g_menu_pointer_count, lookBefore = g_look_count;
        FakeTouch *hint = touch(p.x,p.y); began(view,hint); ended(view,hint,p.x,p.y);
        CHECK(g_menu_pointer_count == before + 2 &&
              g_menu_pointer_events[before].phase == DM_BOTW_MENU_BEGIN &&
              g_menu_pointer_events[before + 1].phase == DM_BOTW_MENU_END &&
              !g_buttons && g_look_count == lookBefore,
              checks[i]);
    }
    CGPoint a = [view facePos:0];
    float saved[4]; memcpy(saved,g_botw_scope_prompts[0],sizeof saved);
    g_botw_scope_prompts[0][0] = (a.x - picture[0]) / picture[2] - .02f;
    g_botw_scope_prompts[0][1] = (a.y - picture[1]) / picture[3] - .02f;
    g_botw_scope_prompts[0][2] = g_botw_scope_prompts[0][3] = .04f;
    int before = g_menu_pointer_count;
    FakeTouch *button = touch(a.x,a.y); began(view,button);
    CHECK((g_buttons & DM_BTN_A) && g_menu_pointer_count == before,
          "a visible scope gamepad button keeps priority over an overlapping native hint");
    ended(view,button,a.x,a.y); memcpy(g_botw_scope_prompts[0],saved,sizeof saved);

    CGPoint home = [view dm_testStickHome];
    FakeTouch *stick = touch(home.x,home.y); began(view,stick); moved(view,stick,home.x+25,home.y);
    int heldLX = g_lx;
    FakeTouch *look = touch(600,150); began(view,look); moved(view,look,610,155);
    const float *r = g_botw_scope_prompts[1];
    CGPoint p = CGPointMake(picture[0] + (r[0] + r[2] * .5f) * picture[2],
                            picture[1] + (r[1] + r[3] * .5f) * picture[3]);
    FakeTouch *hint = touch(p.x,p.y); before = g_menu_pointer_count;
    int lookBefore = g_look_count, pinchBefore = g_pinch_count;
    began(view,hint); moved(view,look,615,157);
    CHECK(heldLX > 0 && g_lx == heldLX && g_menu_pointer_count == before + 1 &&
          g_look_count == lookBefore + 1 && g_pinch_count == pinchBefore,
          "scope hint, movement stick and existing relative camera drag keep independent touch owners");
    ended(view,hint,p.x,p.y);
    CHECK(g_lx == heldLX && g_menu_pointer_events[g_menu_pointer_count-1].phase == DM_BOTW_MENU_END,
          "releasing a scope hint preserves the held movement stick");
    ended(view,look,615,157); ended(view,stick,home.x+25,home.y);
    CHECK(!g_lx && !g_ly && !g_rx && !g_ry,
          "scope gameplay stick and drag release without latched input");
    g_input_sets = 0;
    FakeTouch *first = touch(600,150); beganAt(view,first,9.0); endedAt(view,first,600,150,9.08);
    FakeTouch *second = touch(600,150); beganAt(view,second,9.20); endedAt(view,second,600,150,9.28);
    BOOL r3 = NO; for (int i=0;i<g_input_sets;i++) r3 |= (g_input_history[i] & DM_BTN_RS) != 0;
    CHECK(r3,"scope free area retains the existing R3 double-tap gesture");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view layoutIfNeeded];
    before = g_menu_pointer_count;
    hint = touch(p.x,p.y); began(view,hint); ended(view,hint,p.x,p.y);
    CHECK([view dm_testControlsHidden] && g_menu_pointer_count == before,
          "scope native hint routing is suppressed with a physical controller connected");
    g_botw_scope_active = g_botw_touch_menu_active = NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view reset];
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
    dm_pad_set_player(0, DM_BTN_Y, -1111, 2222, -3333, 4444);
    int input_sets_before_republish = g_input_sets, pad_sets_before_republish = g_pad_sets;
    front_look_mode_changed();
    CHECK(g_input_sets == input_sets_before_republish + 1 && g_pad_sets == pad_sets_before_republish &&
          g_rx == 32767 && g_pad_sources[0].buttons == DM_BTN_Y && g_pad_sources[0].lx == -1111 &&
          g_pad_sources[0].ly == 2222 && g_pad_sources[0].rx == -3333 && g_pad_sources[0].ry == 4444,
          "look-mode installation republishes touch input while the physical player channel stays live");
    g_look_enabled = NO;
    input_sets_before_republish = g_input_sets; pad_sets_before_republish = g_pad_sets;
    front_look_mode_changed();
    CHECK(g_input_sets == input_sets_before_republish + 1 && g_pad_sets == pad_sets_before_republish &&
          g_rx == 32767 && g_pad_sources[0].buttons == DM_BTN_Y && g_pad_sources[0].rx == -3333,
          "look-mode removal republishes touch input without merging or dropping physical player input");
    g_look_enabled = YES;
    dm_pad_set_player(0, 0, 0, 0, 0, 0);
    ended(view, t, 701, 150);
    CHECK(g_rx == 0 && g_ry == 0, "ending look clears the virtual right-stick axes after the final relative delta");

    reset_look(); t = touch(600, 150); began(view, t);
    moved(view, t, 600, 150); moved(view, t, 600, 150); ended(view, t, 600, 150);
    int move_count = 0; for (int i = 0; i < g_look_count; i++) move_count += g_look_events[i].phase == DM_LOOK_MOVE;
    CHECK(move_count == 0 && g_look_count == 2 && g_look_events[1].phase == DM_LOOK_END,
          "stationary held finger sends no MOVE and does not duplicate BEGIN");
    g_botw_touchhud_available=YES; g_botw_quick_select=YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    reset_look(); t=touch(600,150); began(view,t); moved(view,t,615,165);
    CHECK(g_rx<0 && g_ry>0 && g_look_events[1].dx<0 && g_look_events[1].dy<0,
          "BOTW quick selection reverses only the touch stick and relative impulse");
    ended(view,t,615,165); g_botw_quick_select=NO;
    reset_look(); t=touch(600,150); began(view,t); moved(view,t,615,165);
    CHECK(g_rx>0 && g_look_events[1].dx>0,"closing quick selection restores ordinary look direction");
    ended(view,t,615,165);
    g_botw_touchhud_available=NO; [view reset];
}

static void test_botw_face_gaps(DmGamepad *view) {
    g_botw_touchhud_available = g_botw_gameplay_ready = YES;
    g_botw_touch_menu_active = g_botw_touch_menu_presented = NO;
    g_look_enabled = YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    [view setNeedsLayout]; [view layoutIfNeeded];
    CGPoint y = [view facePos:3];
    CGFloat radius = CGPathGetPathBoundingBox([view dm_testButtonLayer:3].path).size.width * .5;
    const CGPoint gaps[] = {
        {y.x, y.y + radius * 1.6},
        {y.x - radius * .55, y.y + radius * 1.45}
    };
    for (unsigned i = 0; i < sizeof gaps / sizeof *gaps; i++) {
        [view reset]; reset_look();
        FakeTouch *t = touch(gaps[i].x, gaps[i].y); began(view, t);
        CHECK(g_look_count == 1 && g_look_events[0].phase == DM_LOOK_BEGIN && !g_buttons,
              "BOTW blank space below Y starts look instead of an empty face-button owner");
        moved(view, t, gaps[i].x + 20, gaps[i].y - 10);
        CHECK(g_look_count == 2 && g_look_events[1].phase == DM_LOOK_MOVE && !g_buttons,
              "BOTW look begun below Y keeps receiving drag movement without pressing a button");
        ended(view, t, gaps[i].x + 20, gaps[i].y - 10);
        CHECK(!g_look_held && g_look_count == 3 && g_look_events[2].phase == DM_LOOK_END,
              "BOTW look begun below Y ends cleanly");
    }
    reset_look();
    FakeTouch *button = touch(y.x, y.y); began(view, button);
    CHECK(g_buttons == DM_BTN_Y && !g_look_count, "the actual Y button retains priority over camera drag");
    ended(view, button, y.x, y.y);
    g_botw_touchhud_available = NO; [view reset];
}

static void test_botw_left_stick_gaps(DmGamepad *view) {
    g_botw_touchhud_available = g_botw_gameplay_ready = YES;
    g_botw_touch_menu_active = g_botw_touch_menu_presented = NO;
    g_look_enabled = YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    [view setNeedsLayout]; [view layoutIfNeeded];
    CGPoint l = [view dm_testRuneButtonCenter], cross = view.dpadCenter;
    const CGFloat steps[] = {.35, .4, .45, .5};
    for (unsigned i = 0; i < sizeof steps / sizeof *steps; i++) {
        [view reset]; reset_look();
        CGPoint p = CGPointMake(l.x + (cross.x-l.x)*steps[i], l.y + (cross.y-l.y)*steps[i]);
        CHECK([view dm_testBtnAt:p] < 0, "the landscape L/Cross gap is outside button hit regions");
        CHECK([view dm_testLeftStickOwnsPoint:p], "the landscape L/Cross gap belongs to the floating left stick");
        FakeTouch *t = touch(p.x,p.y); began(view,t); moved(view,t,p.x+20,p.y-10);
        CHECK(g_lx > 0 && g_ly > 0 && !g_buttons && !g_touch_count && !g_look_held,
              "dragging the landscape L/Cross gap moves the left stick without a game touch or button press");
        ended(view,t,p.x+20,p.y-10);
        CHECK(!g_lx && !g_ly, "releasing a left-gap drag clears both movement axes");
    }
    FakeTouch *t = touch(l.x,l.y); began(view,t);
    CHECK(g_buttons == DM_BTN_L && !g_lx && !g_ly, "L keeps button priority beside the open movement area");
    ended(view,t,l.x,l.y);
    CGPoint up = CGPointMake(cross.x,cross.y-30); t = touch(up.x,up.y); began(view,t);
    CHECK((g_buttons & DM_BTN_UP) && !g_lx && !g_ly, "Cross keeps D-pad priority beside the open movement area");
    ended(view,t,up.x,up.y);
    g_botw_touchhud_available = NO; [view reset];
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
    setenv("DM_BOTW_PORTRAIT","1",1);
    dm_test_motion_reset(); g_motion_count=0;
    dm_gamepad_geometry_changed(UIInterfaceOrientationLandscapeRight); dm_test_motion_publish(right,accel,rate);
    dm_gamepad_geometry_changed(UIInterfaceOrientationPortrait); dm_test_motion_publish(quarter_turn,accel,rate);
    mapped_pose=(CMQuaternion){.w=g_motion_samples[1].quat[0],.x=g_motion_samples[1].quat[1],.y=g_motion_samples[1].quat[2],.z=g_motion_samples[1].quat[3]};
    CHECK(g_motion_count==2 && !g_motion_samples[1].flags && motion_quaternion_matches(mapped_pose,right),
          "opt-in portrait compensates a physical quarter-turn without changing the neutral pose");
    CHECK(fabsf(g_motion_samples[1].acc[0]-.5f)<1e-6f && fabsf(g_motion_samples[1].acc[1]-.25f)<1e-6f &&
          fabsf(g_motion_samples[1].gyro[0]+(float)(.2/(2*M_PI)))<1e-6f,
          "portrait motion rotates acceleration and angular rate together");
    dm_gamepad_geometry_changed(UIInterfaceOrientationLandscapeRight); dm_test_motion_publish(right,accel,rate);
    CHECK(!g_motion_samples[2].flags && fabsf(g_motion_samples[2].acc[0]-.25f)<1e-6f,
          "returning from portrait restores the original landscape motion frame");
    unsetenv("DM_BOTW_PORTRAIT");
}

static void test_botw_manual_menu_pad(DmGamepad *view) {
    [view reset]; g_botw_touchhud_available=YES; g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    UITapGestureRecognizer *gesture=[view dm_testMenuPadGesture];
    CHECK(gesture.numberOfTapsRequired==2 && gesture.numberOfTouchesRequired==3 &&
          !gesture.delaysTouchesBegan && !gesture.delaysTouchesEnded && gesture.cancelsTouchesInView,
          "menu backup uses a native three-finger double tap without delaying ordinary touches");
    FakeTouchEvent *event=[FakeTouchEvent new];
    CGPoint attack=[view facePos:0], shield=[view dm_testShieldHome], move=[view dm_testStickHome];
    NSSet *combat=[NSSet setWithObjects:touch(attack.x,attack.y),touch(shield.x,shield.y),touch(move.x,move.y),nil];
    event.activeTouches=combat;
    [view touchesBegan:combat withEvent:event];
    CHECK((g_buttons&(DM_BTN_A|DM_BTN_ZL))==(DM_BTN_A|DM_BTN_ZL) && ![view dm_testManualMenuPad],
          "ordinary three-finger combat chords are not intercepted by the backup gesture");
    [view touchesEnded:combat withEvent:event];
    g_botw_gameplay_ready=NO;
    CHECK([gesture.delegate gestureRecognizer:gesture shouldReceiveTouch:touch(330,150)],
          "the gesture refreshes stale presentation state before its first touch");
    CHECK([view dm_testControlsHidden],"unsupported menu starts with controls hidden");
    NSSet *three=[NSSet setWithObjects:touch(330,150),touch(420,150),touch(510,150),nil];
    event.activeTouches=three;
    int pointerCount=g_menu_pointer_count;
    [view touchesBegan:three withEvent:event]; [view touchesEnded:three withEvent:event];
    CHECK(g_menu_pointer_count==pointerCount && !g_buttons && ![view dm_testManualMenuPad],
          "the first three-finger tap does not activate menu targets or reveal the pad");
    [view touchesBegan:three withEvent:event];
    [view revealBotwMenuPad:[RecognizedMenuTap new]];
    [view touchesCancelled:three withEvent:event];
    [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK([view dm_testManualMenuPad],"recognized backup gesture activates the temporary menu pad");
    CHECK(![view dm_testControlsHidden],"the temporary menu pad is visible");
    CHECK(![view dm_testL3ArtworkHidden] && ![view dm_testR3ArtworkHidden] &&
          ![view dm_testZLArtworkHidden] && [view dm_testSwapHidden],
          "the temporary menu pad shows its full controls without the layout switcher");
    DmFeedbackSpy *manualStickFeedback=[[DmFeedbackSpy alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [view dm_testSetTouchFeedback:manualStickFeedback];
    CGPoint manualStickHome=[view dm_testStickHome];
    FakeTouch *manualStick=touch(manualStickHome.x,manualStickHome.y);
    began(view,manualStick);
    CHECK(manualStickFeedback.count==0,
          "BOTW temporary manual-menu movement-stick grab is also silent");
    ended(view,manualStick,manualStickHome.x,manualStickHome.y);
    [view dm_testSetTouchFeedback:nil];
    reset_look(); g_look_enabled=YES; pointerCount=g_menu_pointer_count;
    CGRect zlBounds=CGPathGetPathBoundingBox([view dm_testButtonLayer:8].path);
    CGPoint a=[view facePos:0], zl=CGPointMake(CGRectGetMidX(zlBounds),CGRectGetMidY(zlBounds));
    FakeTouch *ta=touch(a.x,a.y), *tz=touch(zl.x,zl.y), *tr=touch(610,170);
    NSSet *controls=[NSSet setWithObjects:ta,tz,tr,nil]; event.activeTouches=controls;
    [view touchesBegan:controls withEvent:event]; moved(view,tr,630,170);
    CHECK((g_buttons&(DM_BTN_A|DM_BTN_ZL))==(DM_BTN_A|DM_BTN_ZL) &&
          g_rx==DM_STICK_MAX && !g_look_count && g_menu_pointer_count==pointerCount,
          "backup accepts three simultaneous controls and uses native UI right stick instead of camera drag or menu hit tests");
    [view touchesEnded:controls withEvent:event];
    CHECK(!g_buttons && !g_rx,"backup releases its buttons and right stick");
    g_botw_gameplay_ready=YES; [view refreshBotwTouchMenuMode]; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(![view dm_testManualMenuPad] && [view dm_testL3ArtworkHidden],"leaving menus restores the usual BOTW touch layout");
    g_botw_gameplay_ready=NO; [view refreshBotwTouchMenuMode];
    CHECK([view dm_testControlsHidden] && ![view dm_testManualMenuPad],"a later menu starts hidden again");
    [view revealBotwMenuPad:[RecognizedMenuTap new]];
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES];
    [view revealBotwMenuPad:[RecognizedMenuTap new]];
    CHECK(![view dm_testManualMenuPad] && [view dm_testControlsHidden],"connecting a controller clears and blocks the temporary pad");
    g_botw_touchhud_available=NO; g_force_controls_hidden=YES;
    [view dm_testSetTouchHudModeFull:NO tap:NO connected:NO];
    [view revealBotwMenuPad:[RecognizedMenuTap new]]; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK([view dm_testManualMenuPad] && [view dm_testIsFull] && ![view dm_testControlsHidden] && [view dm_testSwapHidden],
          "escape gesture works without the native HUD adapter and never exposes the layout switcher");
    [view reset];
    CHECK(![view dm_testManualMenuPad] && [view dm_testControlsHidden],"an input reset ends the temporary override");
    g_force_controls_hidden=NO;
    g_botw_touchhud_available=NO; g_botw_gameplay_ready=YES;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    [view revealBotwMenuPad:[RecognizedMenuTap new]];
    CHECK(![view dm_testManualMenuPad],"ordinary-mode input does not enable the menu backup");
    [view reset];
}

static void test_botw_tunable_stick(DmGamepad *original) {
    g_botw_touchhud_available=YES; g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    setenv("DM_BOTW_MOVE_DEADZONE","0.15",1); setenv("DM_BOTW_MOVE_CURVE","1.00",1);
    setenv("DM_BOTW_MOVE_FULL","0.60",1); setenv("DM_BOTW_MOVE_SIZE","1.25",1);
    DmGamepad *view=(DmGamepad *)dm_gamepad_view(CGRectMake(0,0,844,390));
    unsetenv("DM_BOTW_MOVE_DEADZONE"); unsetenv("DM_BOTW_MOVE_CURVE");
    unsetenv("DM_BOTW_MOVE_FULL"); unsetenv("DM_BOTW_MOVE_SIZE");
    [original.superview addSubview:view];
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    CGFloat base=dm_touchpad_botw_stick_radius(390), radius=base*1.25;
    CHECK(fabs(CGPathGetPathBoundingBox([view dm_testStickRingLayer].path).size.width-2*radius)<.01,
          "saved stick size changes the movement ring");
    CHECK(fabs(CGPathGetPathBoundingBox([view dm_testShieldRingLayer].path).size.width-2*base)<.01,
          "saved movement size does not resize ZL");
    CGPoint home=[view dm_testStickHome]; FakeTouch *t=touch(home.x,home.y); began(view,t);
    moved(view,t,home.x+radius*.14,home.y); CHECK(!g_lx,"saved deadzone reaches the actual UIKit movement handler");
    moved(view,t,home.x+radius*.375,home.y);
    CHECK(abs(g_lx-DM_STICK_MAX/2)<=2 && !g_ly && !(g_buttons&DM_BTN_B),
          "saved curve, full travel and size reach UIKit without sprint");
    moved(view,t,home.x+radius*.6,home.y); CHECK(g_lx==DM_STICK_MAX,"saved full-travel endpoint reaches UIKit");
    ended(view,t,home.x,home.y);
    home=[view dm_testShieldHome]; t=touch(home.x,home.y); began(view,t);
    moved(view,t,home.x+base*.2,home.y);
    CHECK(g_lx>DM_STICK_MAX*.17 && g_lx<DM_STICK_MAX*.19 && (g_buttons&DM_BTN_ZL),
          "custom movement settings preserve ZL deadzone, linear curve and drag range");
    ended(view,t,home.x,home.y);
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(fabs(CGPathGetPathBoundingBox([view dm_testStickRingLayer].path).size.width-2*DM_TP_STICK_R*dm_touchpad_u(390))<.01,
          "custom movement size is ignored with a controller connected");
    g_botw_touchhud_available=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    home=[view dm_testStickHome]; t=touch(home.x,home.y); began(view,t);
    moved(view,t,home.x+DM_TP_STICK_R*dm_touchpad_u(390)*.08,home.y);
    CHECK(!g_lx,"custom BOTW movement settings do not change ordinary-mode deadzone");
    ended(view,t,home.x,home.y); [view reset]; [view removeFromSuperview];
}

static void test_botw_custom_layout(DmGamepad *original) {
    g_botw_touchhud_available=YES; g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    setenv("DM_BOTW_PAD_FACE_X","-0.1",1); setenv("DM_BOTW_PAD_FACE_SCALE","0.8",1);
    setenv("DM_BOTW_PAD_FACE_GAP","1.2",1); setenv("DM_BOTW_PAD_R_Y","0.1",1);
    DmGamepad *view=[[DmGamepad alloc] initWithFrame:CGRectMake(0,0,844,390)];
    [original.superview addSubview:view];
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    const int badged[]={0,1,2,3,7,9};
    for (unsigned i=0;i<sizeof badged/sizeof *badged;i++) {
        int b=badged[i];
        CHECK([view dm_testButtonBadge:b].hidden && [view dm_testButtonLabel:b].hidden && ![view dm_testButtonIcon:b].hidden,
              "badges default off while keeping the button icon");
    }
    CHECK([view dm_testRuneBadgeLayer].hidden && ![view dm_testRuneIconLayer].hidden,
          "badge switch applies to L without hiding its rune or fallback");
    float canvas[4]; dm_aspect_touch_rect(844,390,canvas);
    CGFloat u=dm_touchpad_u(390); dm_touchpad_point base=dm_touchpad_face_center(844,390,view.safeAreaInsets.left,view.safeAreaInsets.top,view.safeAreaInsets.right,view.safeAreaInsets.bottom);
    CGPoint expected=CGPointMake(base.x-canvas[2]*.1+50*u*.8*1.2,base.y-canvas[3]*.068);
    CGRect disk=CGPathGetPathBoundingBox([view dm_testButtonLayer:0].path);
    CHECK(fabs(CGRectGetMidX(disk)-expected.x)<.01 && fabs(CGRectGetMidY(disk)-expected.y)<.01 && fabs(disk.size.width-54*u*.8)<.01,
          "group offset, scale and gap all reach the actual A drawing");
    FakeTouch *t=touch(expected.x,expected.y); began(view,t);
    CHECK((g_buttons&DM_BTN_A) && !(g_buttons&(DM_BTN_B|DM_BTN_X|DM_BTN_Y)),"adjusted face drawing and real input hit testing agree"); ended(view,t,expected.x,expected.y);
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view setNeedsLayout]; [view layoutIfNeeded];
    disk=CGPathGetPathBoundingBox([view dm_testButtonLayer:0].path);
    CHECK(fabs(disk.size.width-54*u)<.01,"controller mode ignores the custom BOTW face scale");
    [view reset]; [view removeFromSuperview];
    const char *keys[]={"DM_BOTW_PAD_FACE_X","DM_BOTW_PAD_FACE_SCALE","DM_BOTW_PAD_FACE_GAP","DM_BOTW_PAD_R_Y","DM_BOTW_PAD_BADGES"};
    for(unsigned i=0;i<sizeof keys/sizeof *keys;i++) unsetenv(keys[i]);
}

@interface PortraitInsetGamepad : DmGamepad
@property(nonatomic) UIEdgeInsets testInsets;
@end
@implementation PortraitInsetGamepad
- (UIEdgeInsets)safeAreaInsets { return self.testInsets; }
@end

static void test_botw_portrait(DmGamepad *original) {
    g_botw_touchhud_available=g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    g_look_enabled=YES; setenv("DM_BOTW_PORTRAIT","0",1);
    setenv("DM_BOTW_PAD_DPAD_SCALE","0.9",1); setenv("DM_BOTW_PORTRAIT_PAD_DPAD_SCALE","1.2",1);
    PortraitInsetGamepad *view=[[PortraitInsetGamepad alloc] initWithFrame:CGRectMake(0,0,390,844)];
    [original.superview addSubview:view];
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO]; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK([view facePos:3].y>[view facePos:2].y,"a system-resized narrow view selects compact controls independently of orientation permission");
    setenv("DM_BOTW_PORTRAIT","1",1); [view setNeedsLayout]; [view layoutIfNeeded];
    CGPoint a=[view facePos:0], b=[view facePos:1], x=[view facePos:2], y=[view facePos:3];
    CGPoint r=[view dm_testDropCenter:7], zr=[view dm_testDropCenter:9];
    CHECK(b.x<a.x && b.y>a.y && y.x<x.x && y.y>x.y && zr.x<r.x && zr.y>r.y && y.y<b.y && zr.y<y.y,
          "portrait right controls form three upward-right B/A, Y/X and ZR/R pairs");
    CGPoint cross=view.dpadCenter, rune=[view dm_testRuneButtonCenter], shield=[view dm_testShieldHome];
    CHECK(fabs(cross.x-rune.x)<.01 && fabs(rune.x-shield.x)<.01 && cross.y<rune.y && rune.y<shield.y,
          "portrait D-pad, L and floating ZL homes align vertically");
    save_pad_preview(view,@"botw-portrait.png");
    for (int button=0;button<4;button++) {
        CGPoint p=[view facePos:button]; FakeTouch *t=touch(p.x,p.y); began(view,t);
        CHECK(g_buttons==(1ull<<button),"portrait face hit testing follows each drawn button"); ended(view,t,p.x,p.y);
    }
    reset_look(); FakeTouch *look=touch(210,190); began(view,look);
    FakeTouch *held=touch(b.x,b.y); began(view,held);
    CHECK(g_look_held && (g_buttons&DM_BTN_B),"portrait supports camera dragging alongside a held face button");
    view.frame=CGRectMake(0,0,844,390); [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(!g_look_held && !g_buttons && !g_lx && !g_ly && !g_rx && !g_ry,
          "rotation releases held controls and camera input before switching profiles");
    CHECK(fabs([view facePos:3].y-[view facePos:0].y)<.01,"enabling portrait mode leaves landscape's diamond unchanged");
    const CGFloat widths[]={599,600,626,744,599};
    for (unsigned i=0;i<sizeof widths/sizeof *widths;i++) {
        view.frame=CGRectMake(0,0,widths[i],1133); [view setNeedsLayout]; [view layoutIfNeeded];
        BOOL compact=fabs([view facePos:3].y-[view facePos:0].y)>.01;
        CHECK(compact==(widths[i]<600),"upright controls use the normal profile at 600pt and above");
        CHECK(fabs(g_published_dpad_scale-(compact?1.2:.9))<.001,"native D-pad publication follows the selected layout profile");
        CGPoint p=[view facePos:0]; FakeTouch *t=touch(p.x,p.y); began(view,t);
        CHECK(g_buttons==DM_BTN_A,"wide and compact portrait face positions retain matching touch targets"); ended(view,t,p.x,p.y);
    }
    view.frame=CGRectMake(0,0,640,1000); view.testInsets=UIEdgeInsetsMake(0,20,0,20);
    [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(fabs([view facePos:3].y-[view facePos:0].y)<.01,"600pt after horizontal safe insets uses the normal layout");
    view.testInsets=UIEdgeInsetsMake(0,20,0,21); [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(fabs([view facePos:3].y-[view facePos:0].y)>.01,"horizontal safe insets below 600pt select compact controls");
    view.testInsets=UIEdgeInsetsZero;
    view.frame=CGRectMake(0,0,390,844); [view setNeedsLayout]; [view layoutIfNeeded];
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view layoutIfNeeded];
    CHECK([view dm_testControlsHidden] && fabs([view facePos:3].y-[view facePos:0].y)<.01,
          "a connected controller suppresses portrait touch controls and their custom geometry");
    [view reset]; [view removeFromSuperview]; unsetenv("DM_BOTW_PORTRAIT");
    unsetenv("DM_BOTW_PAD_DPAD_SCALE"); unsetenv("DM_BOTW_PORTRAIT_PAD_DPAD_SCALE");
    g_botw_touchhud_available=NO; [original dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
}

static void test_resized_surface(DmGamepad *view) {
    CGRect original=view.frame;
    g_botw_touchhud_available=g_botw_gameplay_ready=YES;
    g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    view.frame=CGRectMake(0,0,795,1100); [view setNeedsLayout]; [view layoutIfNeeded]; reset_look();
    CGPoint a=[view facePos:0],stick=view.stickHome;
    FakeTouch *key=touch(a.x,a.y),*move=touch(stick.x,stick.y),*look=touch(500,200);
    began(view,key); began(view,move); moved(view,move,stick.x+15,stick.y); began(view,look);
    CHECK((g_buttons&DM_BTN_A) && g_lx>0 && g_look_held,"resizable surface starts independent button, movement and camera owners");
    dm_pad_set_player(0,DM_BTN_B,123,456,789,100); int pad_sets=g_pad_sets;
    view.frame=CGRectMake(0,0,805,1100); [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK(!g_buttons && !g_lx && !g_ly && !g_look_held,"same-profile resize releases all virtual owners");
    CHECK(g_pad_sets==pad_sets && g_pad_sources[0].buttons==DM_BTN_B && g_pad_sources[0].lx==123,
          "surface resize preserves physical controller state");
    g_seated=1; dm_gamepad_surface_changed(); [view setNeedsLayout]; [view layoutIfNeeded];
    CGPoint positions[]={view.stickHome,view.dpadCenter,[view dm_testShieldHome],[view dm_testRuneButtonCenter],
        [view dm_testDropCenter:7],[view dm_testDropCenter:9],[view facePos:0],[view facePos:1],[view facePos:2],[view facePos:3]};
    BOOL lower=YES; for (unsigned i=0;i<sizeof positions/sizeof *positions;i++) lower &= positions[i].y>1100*.51 && positions[i].y<1100;
    CHECK(lower,"Seated places every touch control below the horizontal division");
    a=[view facePos:0]; key=touch(a.x,a.y); began(view,key);
    CHECK(g_buttons==DM_BTN_A,"Seated button hit targets follow the lower-pane artwork"); ended(view,key,a.x,a.y);
    CGRect plus=[view pillRect:10]; dm_touchpad_rect map=dm_touchpad_seated_map((dm_touchpad_rect){0,561,805,539});
    CHECK(CGRectGetMinX(plus)>map.x+map.width && fabs(CGRectGetMinY(plus)-map.y)<.01,
          "Seated plus stays beside the lower map dock");
    CHECK(fabs(map.y-569)<.01,"Seated minimap anchors to the top of the lower pane");
    g_botw_gameplay_ready=NO; g_botw_touch_menu_active=g_botw_touch_menu_presented=YES;
    [view refreshBotwTouchMenuMode]; [view layoutIfNeeded];
    CHECK(![view dm_testControlsHidden],"Seated keeps the virtual gamepad visible below an open menu");
    int pointers=g_menu_pointer_count;
    a=[view facePos:0]; key=touch(a.x,a.y); began(view,key);
    CHECK(g_buttons==DM_BTN_A && g_menu_pointer_count==pointers,"Seated lower-pane buttons keep native controller input in menus");
    ended(view,key,a.x,a.y);
    float menu_rect[4]; dm_aspect_touch_rect(805,1100,menu_rect);
    key=touch(menu_rect[0]+menu_rect[2]*.5,menu_rect[1]+menu_rect[3]*.5); began(view,key); ended(view,key,key.point.x,key.point.y);
    CHECK(g_menu_pointer_count==pointers+2,"Seated upper-pane menu targets keep direct touch input beside the persistent pad");
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:YES]; [view layoutIfNeeded];
    CHECK([view dm_testControlsHidden],"Seated still hides virtual controls for a connected physical controller");
    g_botw_gameplay_ready=YES; g_botw_touch_menu_active=g_botw_touch_menu_presented=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
    g_seated=0; dm_gamepad_surface_changed(); view.frame=original; [view setNeedsLayout]; [view layoutIfNeeded];
    CHECK([view facePos:0].y<original.size.height,"unfolding restores controls inside the full surface");
    const float acc[]={.25f,.5f,.75f},rate[]={1,2,3};
    for (int orientation=1;orientation<=4;orientation++) {
        dm_test_phone_motion_publish(acc,rate,1,orientation);
        CHECK(!memcmp(g_phone_acc,acc,sizeof acc) && !memcmp(g_phone_rot,rate,sizeof rate),
              "view-relative motion is not rotated a second time after a display/orientation change");
    }
    dm_test_phone_motion_publish(acc,rate,0,UIInterfaceOrientationLandscapeRight);
    CHECK(g_phone_acc[0]==-.5f && g_phone_acc[1]==.25f && g_phone_rot[0]==-2 && g_phone_rot[1]==1,
          "older hardware-relative motion keeps its interface rotation");
    dm_pad_set_player(0,0,0,0,0,0); g_botw_touchhud_available=NO;
    [view dm_testSetTouchHudModeFull:YES tap:NO connected:NO];
}
static void run_tests(DmGamepad *view) {
    test_dpad_art_visibility(view);
    test_botw_button_artwork(view);
    test_botw_virtual_buttons(view);
    test_botw_map_menu_return(view);
    test_botw_rune_press(view);
    test_botw_l3_timing(view);
    test_botw_stick_response(view);
    test_botw_stick_feedback(view);
    test_botw_inventory_pointer(view);
    test_botw_scope_pointer(view);
    test_motion_orientation();
    test_look_drag(view);
    test_botw_face_gaps(view);
    test_botw_left_stick_gaps(view);
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
    [view padsChanged:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        CHECK(g_look_count == 2 && g_look_events[1].phase == DM_LOOK_CANCEL,
              "controller-change reset cancels an active look session");
        reset_look(); g_look_enabled = YES;
        test_botw_manual_menu_pad(view);
        test_botw_tunable_stick(view);
        test_botw_custom_layout(view);
        test_botw_portrait(view);
        test_resized_surface(view);
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
    // The artwork fixture covers enabled badges; the custom-layout test checks default-off.
    setenv("DM_BOTW_PAD_BADGES","1",1);
    UIView *raw = dm_gamepad_view(CGRectMake(0, 0, 844, 390));
    unsetenv("DM_BOTW_PAD_BADGES");
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
