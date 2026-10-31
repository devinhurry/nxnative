// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their size), plus a D-pad (inward of and below the left stick, 8-way), an invisible right stick
//     (a touch landing in the right half of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius; games may use relative camera look instead) and L3 / R3.
//     BOTW hides both stick-click keys: L3 is a left-stick double tap and R3 is a short camera-area double tap; R/ZR share a row above the face cluster. Other games keep the visible R3 key and right-stick behavior.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3 where visible), then the D-pad and the diamond, then the left stick for a touch in the
//     lower-left area (its centre is the touch-down point), then in 3D relative camera look when enabled or the right stick for a touch in the right half.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "../../host/botw_rune_icon.h"
#include "../../host/botw_touch_actions.h"
#include "../../host/botw_touch_menu.h"
#include "../../host/botw_touch_style.h"
#include "../../host/touchpad_geometry.h"
#include "../../host/botw_touch_trackpad.h"
#include "../../host/botw_stick_settings.h"
#include "../../host/botw_touch_layout.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include <stdatomic.h>

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME, C_LOOK, C_BOTW_MAP, C_SHIELD, C_MENU, C_MENU_EXTRA };

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static _Atomic int g_any_controller_connected;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// dm_look_install may run after GameController discovery published its first value. Republish
// the existing source split immediately so a connected controller is not lost until it moves.
void front_look_mode_changed(void) { publish(); }

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- Device motion (the six-axis sensor) ----
// CoreMotion's fused device motion at 100 Hz: rotation rate (radians/s), acceleration (G, gravity included) and attitude. Sent to the host through
// dm_device_motion_set; the host turns the first sample into the neutral pose and reports the controller relative to it, and takes the pose again on the
// player's first touch or controller press (when the phone is held as they play). DM_MOTION=0 turns it off (the host then keeps the synthetic
// at-rest / shake sensor). Motion data needs no permission prompt.
// The interface can face either landscape way. A 180-degree turn of the phone between them must not turn the virtual controller: the sample is
// rotated 180 degrees about the device's Z axis while the interface is in the left landscape orientation, so its frame stays fixed to the screen.
static CMMotionManager *g_devmotion;
static _Atomic int g_motion_flip = -1;     // -1 unknown; 0 landscape right, 1 landscape left, 2 portrait
static _Atomic int g_motion_recenter;      // the next sample becomes the neutral pose
static int g_motion_published_first;       // motion_publish runs on one serial queue
static void motion_update_flip_value(UIInterfaceOrientation o) {
    if (o == UIInterfaceOrientationLandscapeLeft) atomic_store(&g_motion_flip, 1);
    else if (o == UIInterfaceOrientationLandscapeRight) atomic_store(&g_motion_flip, 0);   // portrait during launch: wait for a landscape
    else if (o == UIInterfaceOrientationPortrait && !strcmp(DM_GAME_ID,"01007EF00011E000") && dm_botw_portrait_enabled())
        atomic_store(&g_motion_flip, 2);
}
static void motion_update_flip(UIWindowScene *scene) {
    if (scene) motion_update_flip_value(scene.effectiveGeometry.interfaceOrientation);
}
static void motion_first_input(void) {     // the player is holding the phone as they play: take that pose as neutral
    static _Atomic int done;
    if (!atomic_exchange(&done, 1)) atomic_store(&g_motion_recenter, 1);
}
static void motion_publish_values(CMQuaternion q, CMAcceleration a, CMRotationRate r, int flip) {
    double w = q.w, x = q.x, y = q.y, z = q.z;
    if (flip == 1) {   // q' = q * (0, 0, 1, 0); vectors turn with it: (x, y, z) -> (-x, -y, z)
        double w2 = -z, x2 = y, y2 = -x, z2 = w;
        w = w2; x = x2; y = y2; z = z2;
        a.x = -a.x; a.y = -a.y;
        r.x = -r.x; r.y = -r.y;
    } else if (flip == 2) {
        // Portrait is one quarter-turn from landscape right. Rotate both the
        // sample basis and its vectors, without resetting the neutral pose.
        double w2=(w+z)*M_SQRT1_2, x2=(x-y)*M_SQRT1_2, y2=(x+y)*M_SQRT1_2, z2=(z-w)*M_SQRT1_2;
        w=w2; x=x2; y=y2; z=z2;
        double ax=a.x, rx=r.x; a.x=-a.y; a.y=ax; r.x=-r.y; r.y=rx;
    }
    uint32_t flags = atomic_exchange(&g_motion_recenter, 0) ? DM_MOTION_RESET : 0;
    if (!g_motion_published_first) { g_motion_published_first = 1; flags |= DM_MOTION_RESET; }
    dm_motion mm = {{(float)a.x, (float)a.y, (float)a.z}, {(float)(r.x / (2 * M_PI)), (float)(r.y / (2 * M_PI)), (float)(r.z / (2 * M_PI))},
                    {(float)w, (float)x, (float)y, (float)z}, flags};
    dm_device_motion_set(&mm);
}
static void motion_publish(CMDeviceMotion *m) {
    int flip = atomic_load(&g_motion_flip);
    if (flip < 0) return;
    CMAcceleration a = {m.gravity.x + m.userAcceleration.x, m.gravity.y + m.userAcceleration.y, m.gravity.z + m.userAcceleration.z};
    motion_publish_values(m.attitude.quaternion, a, m.rotationRate, flip);
}
#ifdef DM_TEST_HOOKS
void dm_test_motion_reset(void) { g_motion_published_first = 0; atomic_store(&g_motion_flip, -1); atomic_store(&g_motion_recenter, 0); }
void dm_test_motion_recenter(void) { atomic_store(&g_motion_recenter, 1); }
void dm_test_motion_publish(CMQuaternion q, CMAcceleration a, CMRotationRate r) {
    int flip = atomic_load(&g_motion_flip);
    if (flip >= 0) motion_publish_values(q, a, r, flip);
}
#endif
static void motion_device_start(void) {
    const char *phone = getenv("DM_PHONE_MOTION");
    if (phone && !strcmp(phone, "0")) return;
    if (g_devmotion) return;
    const char *off = getenv("DM_MOTION");
    if (off && !strcmp(off, "0")) { LOG("front end: device motion off (DM_MOTION=0); the six-axis sensor stays synthetic"); return; }
    g_devmotion = [CMMotionManager new];
    if (!g_devmotion.deviceMotionAvailable) { LOG("front end: no device motion; the six-axis sensor stays synthetic"); return; }
    if (([CMMotionManager availableAttitudeReferenceFrames] & CMAttitudeReferenceFrameXArbitraryZVertical) == 0) {
        LOG("front end: no gyro reference frame; the six-axis sensor stays synthetic"); return;
    }
    g_devmotion.deviceMotionUpdateInterval = 1.0 / 100.0;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_devmotion startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical toQueue:q withHandler:^(CMDeviceMotion *m, NSError *err) {
        if (!err && m) motion_publish(m);
    }];
    LOG("front end: device motion for the six-axis sensor (100 Hz, gyro + accelerometer; like a Pro Controller, no magnetometer)");
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_publish_values(const float a[3], const float w[3], int body_frame, int orientation) {
    float as[3],ws[3];
    // Body-relative samples already use the picture's axes, including after a
    // display switch. Applying interface rotation again would swap those axes.
    int o=body_frame ? 1 : orientation;
    motion_phone_to_switch(o,a,as); motion_phone_to_switch(o,w,ws);
    dm_motion_set_switch(0,as,ws);
}
#ifdef DM_TEST_HOOKS
void dm_test_phone_motion_publish(const float a[3], const float w[3], int body_frame, int orientation) {
    phone_motion_publish_values(a,w,body_frame,orientation);
}
#endif
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
#if defined(__IPHONE_27_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_27_0
    if (@available(iOS 27.0, *)) { g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); }
#endif
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z};
        phone_motion_publish_values(a,w,g_motion_body,atomic_load(&g_iface_orient));
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = DM_TP_ZL_X, K_ZL_Y = DM_TP_ZL_Y, K_ZL_R = DM_TP_ZL_R,
    K_L_X = DM_TP_L_X, K_L_Y = DM_TP_L_Y, K_L_R = DM_TP_L_R,
    K_DROP_TIP = DM_TP_DROP_TIP, K_CORNER_IN = DM_TP_CORNER_IN,
    K_FACE_X = DM_TP_FACE_X, K_PAD_Y = DM_TP_PAD_Y,
    K_FACE_GAP = DM_TP_FACE_GAP, K_FACE_R = DM_TP_FACE_R,
    K_PILL_DX = DM_TP_PILL_DX, K_PILL_Y = DM_TP_PILL_Y,
    K_PILL_W = DM_TP_PILL_W, K_PILL_H = DM_TP_PILL_H, K_SWAP_R = DM_TP_SWAP_R,
    K_STICK_X = DM_TP_STICK_X, K_STICK_R = DM_TP_STICK_R, K_KNOB_R = DM_TP_KNOB_R,
    K_STICK_GRAB = DM_TP_STICK_GRAB, K_LSWIPE = DM_TP_LSWIPE,
    K_FULL = DM_TP_FULL, K_DEAD = DM_TP_DEAD,
    // controls only the 3D layout has
    K_LOW_X = DM_TP_LOW_X, K_LOW_Y = DM_TP_LOW_Y,
    K_DPAD_R = DM_TP_DPAD_R, K_ARM_W = DM_TP_ARM_W, K_ARM_IN = DM_TP_ARM_IN,
    K_DPAD_GRAB = DM_TP_DPAD_GRAB, K_RSTICK_R = DM_TP_RSTICK_R,
    K_RSWIPE = DM_TP_RSWIPE, K_CLICK_X = DM_TP_CLICK_X, K_CLICK_R = DM_TP_CLICK_R;
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld

@interface DmGamepad : UIView <UIGestureRecognizerDelegate>
- (void)checkLookGeometry;
- (void)cancelSurfaceInput;
- (void)publishTouchHudForController:(BOOL)connected;
- (void)refreshTouchHudMode;
- (BOOL)leftStickOwnsPoint:(CGPoint)p;
- (void)leftStickDoubleTapped:(UITapGestureRecognizer *)recognizer;
- (void)updateLeftStickTapAt:(CGPoint)p;
- (void)emitTouchFeedback;
- (BOOL)inSwap:(CGPoint)p;
- (BOOL)botwTouchControlsActive;
- (BOOL)botwMenuDpadActive;
- (CGRect)botwControlArea;
- (UIEdgeInsets)botwControlInsets;
- (void)setBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height;
- (BOOL)botwMapOwnsPoint:(CGPoint)p;
- (void)botwTouchActionChanged;
- (void)botwRuneIconChanged;
- (void)refreshBotwRuneIcon;
- (void)clearBotwRuneIcon;
- (void)refreshBotwTouchMenuMode;
- (void)cancelBotwMenuPointer;
- (void)sendBotwMenuPointer:(int)phase point:(CGPoint)p;
- (BOOL)manualPadGestureAllowed;
- (void)revealBotwMenuPad:(UITapGestureRecognizer *)recognizer;
@end
static __weak DmGamepad *g_view;
void front_botw_touch_hud_mode_changed(void) { dispatch_async(dispatch_get_main_queue(), ^{ [g_view refreshTouchHudMode]; }); }
void front_botw_touch_hud_map_region(int valid, float x, float y, float width, float height) {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view setBotwMapRectValid:valid x:x y:y width:width height:height]; });
}
void front_botw_touch_action_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view botwTouchActionChanged]; });
}
void front_botw_rune_icon_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view botwRuneIconChanged]; });
}
void front_botw_touch_menu_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view refreshBotwTouchMenuMode]; [g_view setNeedsLayout]; });
}
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    dm_touchpad_stick_response _moveResponse, _moveProfiles[2];
    dm_botw_touch_layout _touchLayout, _touchProfiles[2];
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    UITouch *_leftAxisTouch, *_shieldTouch; CGPoint _shieldNow, _shieldOrigin;
    uint64_t _botwCancelPending, _botwCancelLatched, _botwCancelOutside;
    CGPoint _lCentre, _rCentre;                    // the stick centres: where their touches landed (the left one returns to the ring's home on release)
    CGPoint _ringAt;                               // where the left stick's ring is drawn now
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N], *_keyBorder[B_N], *_botwMenuBg[B_N]; CATextLayer *_label[B_N];
    UIImage *_runeDefaultIcon; CALayer *_runeIconLayer; CAShapeLayer *_runeBadge; CATextLayer *_runeBadgeLabel;
    CALayer *_buttonIcon[B_N]; CAShapeLayer *_buttonBadge[B_N], *_buttonBadgeBorder[B_N];
    CAShapeLayer *_runeBadgeBorder;
    uint64_t _runeIconGeneration; BOOL _runeIconValid;
    CAShapeLayer *_ring, *_knob, *_stickDirection, *_shieldRing, *_shieldGraph, *_shieldDirection, *_cancelRing;
    CAShapeLayer *_menuDpad;
    CATextLayer *_cancelCue;
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld; CFTimeInterval _swapT0;
    UITapGestureRecognizer *_leftStickDoubleTap;
    UITapGestureRecognizer *_menuPadDoubleTap;
    NSMutableSet<UITouch *> *_menuPadChord;
    BOOL _manualMenuPad;
    NSTimeInterval _leftStickTapEnd, _leftStickTapGap;
    NSTimeInterval _leftStickDownTime; BOOL _leftStickUsed;
    CGRect _botwMapRect; BOOL _botwMapValid, _botwMapTapConsumed, _botwMapInvalidAfterTap;
    BOOL _botwMenuMode, _botwMenuPointerActive, _botwMapGestureSuppressed;
    BOOL _botwCameraPadVisible;
    UITouch *_botwMenuTouch; CGPoint _botwMenuLast, _botwMenuLastNorm;
    UITouch *_botwMapPinchTouch, *_botwCameraModifierTouch; CGFloat _botwMapPinchStart;
    dm_botw_camera_gesture _botwCameraGesture;
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    UITouch *_lookTouch; CGPoint _lookLast, _lookDown, _botwLookTapPoint; CGFloat _lookScale; CFTimeInterval _lookDownTime, _botwLookTapTime; BOOL _lookDragged, _botwLookTapPending;
    CGSize _lookBoundsSize; UIEdgeInsets _lookInsets; UIInterfaceOrientation _lookOrientation; BOOL _lookGeometryKnown;
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static UIColor *k_botwIdle, *k_botwOn, *k_botwLine;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CAShapeLayer *botwBorder(CALayer *parent) {
    CAShapeLayer *border = [CAShapeLayer layer];
    border.hidden = YES; border.strokeColor = nil;
    [parent insertSublayer:border atIndex:0]; return border;
}
static void refreshBotwBorder(CAShapeLayer *fill, CAShapeLayer *border, BOOL active) {
    border.hidden = !active;
    if (active) { border.fillColor = fill.strokeColor; fill.strokeColor = nil; }
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = parent.contentsScale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout
static BOOL botwTouchHudSupported(void) { return dm_botw_touch_hud_available(); }
static BOOL botwSeated(void) { float region[4]; return dm_aspect_region(1,region); }

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        [self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(id<UITraitEnvironment> view, UITraitCollection *previous) {
            (void)previous; [(UIView *)view setNeedsLayout];
        }];
        _moveResponse = dm_touchpad_botw_move_defaults();
        _touchLayout = dm_botw_layout_defaults();
        if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
            for (int p = 0; p < 2; p++) {
                if (!dm_botw_layout_read_for(&_touchProfiles[p],p)) die("[RED] invalid BOTW touch layout setting");
                const char *invalid = dm_botw_stick_settings_read_for(&_moveProfiles[p],p);
                if (invalid) die("[RED] %s: invalid touch left-stick setting", invalid);
            }
            _touchLayout = _touchProfiles[0]; _moveResponse = _moveProfiles[0];
        }
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.6]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
            k_botwIdle = [UIColor colorWithWhite:DM_BOTW_BUTTON_GRAY alpha:DM_BOTW_BUTTON_ALPHA];
            k_botwLine = [UIColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA];
            k_botwOn = [UIColor colorWithWhite:.40 alpha:DM_BOTW_BUTTON_ALPHA];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _menuDpad = shape(self.layer); _menuDpad.hidden = YES;
        _menuDpad.fillColor = [UIColor colorWithRed:226/255.0 green:222/255.0 blue:211/255.0 alpha:.8].CGColor;
        _menuDpad.strokeColor = nil; _menuDpad.shadowOpacity = 0;
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        _stickDirection = shape(_controls); _stickDirection.hidden = YES;
        _stickDirection.fillColor = [UIColor colorWithRed:226/255.0 green:222/255.0 blue:211/255.0 alpha:.8].CGColor;
        _stickDirection.strokeColor = nil; _stickDirection.shadowOpacity = 0;
        _shieldRing = shape(_controls); _shieldRing.fillColor = nil;
        _shieldGraph = shape(_controls); _shieldDirection = shape(_controls);
        for (CAShapeLayer *glyph in @[_shieldGraph, _shieldDirection]) {
            glyph.fillColor = [UIColor colorWithRed:226/255.0 green:222/255.0 blue:211/255.0 alpha:.8].CGColor;
            glyph.strokeColor = nil; glyph.shadowOpacity = 0;
        }
        _cancelRing = shape(_controls); _cancelRing.fillColor = nil; _cancelRing.strokeColor = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:.8].CGColor; _cancelRing.hidden = YES;
        _cancelCue = label(_controls, NSLocalizedString(@"Cancel", nil)); _cancelCue.hidden = YES;
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        for (int b = 10; b <= 11; b++) {
            _botwMenuBg[b] = shape(_controls);
            _botwMenuBg[b].fillColor = [UIColor colorWithWhite:0 alpha:.40].CGColor;
            _botwMenuBg[b].strokeColor = nil;
            _botwMenuBg[b].shadowOpacity = 0;
            _botwMenuBg[b].hidden = YES;
        }
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            _keyBorder[b] = botwBorder(_key[b]);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        for (int b = 0; b < B_N; b++) if (b != B_L && dm_botw_touch_button_icon_path(b)) {
            _buttonIcon[b] = [CALayer layer]; _buttonIcon[b].contentsGravity = kCAGravityResizeAspect;
            _buttonIcon[b].hidden = YES; [_key[b] addSublayer:_buttonIcon[b]];
            _buttonBadge[b] = shape(_key[b]); _buttonBadge[b].hidden = YES;
            _buttonBadgeBorder[b] = botwBorder(_buttonBadge[b]);
            [_label[b] removeFromSuperlayer]; [_key[b] addSublayer:_label[b]];
        }
        _runeDefaultIcon = [UIImage imageWithContentsOfFile:dm_botw_touch_button_icon_path(B_L)];
        _runeIconLayer = [CALayer layer];
        _runeIconLayer.contentsGravity = kCAGravityResizeAspect;
        _runeIconLayer.contentsScale = self.traitCollection.displayScale;
        _runeIconLayer.hidden = YES;
        // These layers use the full control-canvas coordinate system, like
        // the paths set in layoutSubviews. The button shape has no local frame.
        [_controls addSublayer:_runeIconLayer];
        _runeBadge = shape(_controls); _runeBadge.hidden = YES;
        _runeBadgeBorder = botwBorder(_runeBadge);
        _runeBadge.fillColor = [UIColor colorWithRed:.10 green:.12 blue:.12 alpha:.94].CGColor;
        _runeBadge.strokeColor = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:.98].CGColor;
        _runeBadgeLabel = label(_controls, @"L"); _runeBadgeLabel.hidden = YES;
        _leftStickDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(leftStickDoubleTapped:)];
        _leftStickDoubleTap.numberOfTapsRequired = 2;
        _leftStickDoubleTap.delegate = self;
        _leftStickDoubleTap.cancelsTouchesInView = NO;
        _leftStickDoubleTap.delaysTouchesBegan = NO;
        _leftStickDoubleTap.delaysTouchesEnded = NO;
        [self addGestureRecognizer:_leftStickDoubleTap];
        if (!strcmp(DM_GAME_ID, "01007EF00011E000")) {
            _menuPadDoubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(revealBotwMenuPad:)];
            _menuPadDoubleTap.numberOfTapsRequired = 2;
            _menuPadDoubleTap.numberOfTouchesRequired = 3;
            _menuPadDoubleTap.delegate = self;
            _menuPadDoubleTap.cancelsTouchesInView = YES;
            _menuPadDoubleTap.delaysTouchesBegan = NO;
            _menuPadDoubleTap.delaysTouchesEnded = NO;
            [self addGestureRecognizer:_menuPadDoubleTap];
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (botwTouchHudSupported()) l = 1;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        _botwMenuMode = !dm_botw_touch_controls_visible();
        _botwCameraPadVisible = _botwMenuMode && dm_botw_touch_camera_active();
        _controls.hidden = _botwMenuMode && !_botwCameraPadVisible && !_manualMenuPad && !botwSeated();
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        [nc addObserver:self selector:@selector(deviceOrientationChanged) name:UIDeviceOrientationDidChangeNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [self syncBotwTouchProfile];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    BOOL botwActive = [self botwTouchControlsActive];
    _key[B_ZL].hidden = _tap || botwActive;
    _shieldGraph.hidden = !botwActive;
    _shieldRing.hidden = !botwActive || !_shieldTouch;
    _shieldDirection.hidden = YES; // layout supplies a direction only for a non-neutral drag
    if (!botwActive) _botwLookTapPending = NO;
    _key[B_LS].hidden = botwActive || _tap || !_full;
    _key[B_RS].hidden = botwActive || _tap || !_full;
    [self refreshBotwRuneIcon];
    _key[B_MINUS].hidden = _tap || (botwActive && _botwMapValid);
    _leftStickDoubleTap.enabled = botwActive && !_botwMenuMode;
    BOOL hideDpadArt = ([self botwTouchControlsActive] && dm_botw_touch_loadout_visible()) || _padOff;
    _key[B_LEFT].hidden = _key[B_UP].hidden = _key[B_RIGHT].hidden = _key[B_DOWN].hidden = _tap || !_full || hideDpadArt;
    _ring.hidden = _tap || (botwActive && !_stick[0]); _knob.hidden = _tap;
    _stickDirection.hidden = YES;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    _swap.hidden = botwTouchHudSupported() || _manualMenuPad;
    [CATransaction commit];
    [self publishTouchHudForController:atomic_load(&g_any_controller_connected)];
}
- (void)publishTouchHudForController:(BOOL)connected {
    BOOL active = botwTouchHudSupported() && _full && !_tap && !connected;
    if (!active || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) {
        dm_botw_touch_hud_publish(0, 0, 0, 1);
        [self setBotwMapRectValid:NO x:0 y:0 width:0 height:0];
        return;
    }
    CGPoint c = self.dpadCenter;
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    float region[4];
    if (dm_aspect_region(1,region)) {
        CGRect area=[self botwControlArea]; dm_touchpad_rect canvas=dm_botw_layout_canvas(area.size.width,area.size.height);
        rect[0]=area.origin.x+canvas.x; rect[1]=area.origin.y+canvas.y; rect[2]=canvas.width; rect[3]=canvas.height;
    }
    if (dm_aspect_hud_y_scale()<1) dm_aspect_hud_rect(self.bounds.size.width,self.bounds.size.height,rect);
    float x = (float)((c.x - rect[0]) / rect[2]);
    float y = (float)((c.y - rect[1]) / rect[3]);
    dm_botw_touch_hud_publish(1, x, y, _touchLayout.control[B_LEFT].scale);
}
- (void)refreshTouchHudMode {
    if (botwTouchHudSupported() && (!_full || _tap)) {
        // Capability may become available after init because host preload runs
        // in parallel. Force the required local BOTW layout without rewriting
        // the user's shared layout preference.
        [self reset];
        _full = YES; _tap = NO;
        [self applyLayout];
    }
    BOOL botwActive = [self botwTouchControlsActive];
    if (!botwActive) _botwLookTapPending = NO;
    BOOL hideDpadArt = (botwActive && dm_botw_touch_loadout_visible()) || _padOff;
    _key[B_ZL].hidden = _tap || botwActive;
    _shieldGraph.hidden = !botwActive;
    _shieldRing.hidden = !botwActive || !_shieldTouch;
    _shieldDirection.hidden = YES;
    _key[B_LS].hidden = botwActive || _tap || !_full;
    _key[B_RS].hidden = botwActive || _tap || !_full;
    [self refreshBotwRuneIcon];
    _key[B_MINUS].hidden = _tap || (botwActive && _botwMapValid);
    _leftStickDoubleTap.enabled = botwActive;
    _key[B_LEFT].hidden = _key[B_UP].hidden = _key[B_RIGHT].hidden = _key[B_DOWN].hidden = _tap || !_full || hideDpadArt;
    _swap.hidden = botwTouchHudSupported() || _manualMenuPad;
    [self publishTouchHudForController:atomic_load(&g_any_controller_connected)];
    [self refreshBotwTouchMenuMode];
    [self setNeedsLayout];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    if (botwTouchHudSupported() || _manualMenuPad) return;
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_rect r = dm_touchpad_corner_rect(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGRectMake(r.x, r.y, r.width, r.height); }   // the rectangle the bottom-corner controls use
- (CGRect)botwControlArea {
    float r[4]; dm_aspect_region(1,r); CGRect b=self.bounds;
    return CGRectMake(b.origin.x+b.size.width*r[0],b.origin.y+b.size.height*r[1],b.size.width*r[2],b.size.height*r[3]);
}
- (UIEdgeInsets)botwControlInsets {
    CGRect a=[self botwControlArea]; UIEdgeInsets i=self.safeAreaInsets;
    i.top=MAX(0,i.top-CGRectGetMinY(a));
    i.bottom=MAX(0,CGRectGetMaxY(a)-(self.bounds.size.height-i.bottom));
    return i;
}
- (void)syncBotwTouchProfile {
    if (strcmp(DM_GAME_ID, "01007EF00011E000")) return;
    UIEdgeInsets insets=[self botwControlInsets]; CGRect area=[self botwControlArea];
    int portrait = botwTouchHudSupported() && _full && !_tap && !_padOff &&
        dm_botw_compact_mode(area.size.width,area.size.height,insets.left,insets.right);
    if (_touchLayout.portrait == portrait) return;
    _touchLayout = _touchProfiles[portrait]; _moveResponse = _moveProfiles[portrait];
    [self cancelSurfaceInput];
}
- (CGFloat)u { CGRect a=[self botwControlArea]; return ([self botwTouchControlsActive] || [self botwMenuDpadActive]) ?
    dm_botw_layout_unit(&_touchLayout,a.size.width,a.size.height) : dm_touchpad_u((float)self.bounds.size.height); }
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGRect)botwLayoutRect:(int)control {
    UIEdgeInsets i = [self botwControlInsets]; float canvas[4],region[4]; CGRect area=[self botwControlArea];
    if (dm_aspect_region(1,region)) {
        dm_touchpad_rect a={area.origin.x,area.origin.y,area.size.width,area.size.height};
        if (control==B_PLUS || control==B_MINUS) {
            dm_touchpad_rect r=dm_touchpad_seated_menu(a,control==B_MINUS);
            return CGRectMake(r.x,r.y,r.width,r.height);
        }
        dm_touchpad_rect c=dm_botw_layout_canvas(a.width,a.height);
        dm_touchpad_rect r=dm_botw_layout_control(&_touchLayout,control,a.width,a.height,i.left,i.top,i.right,i.bottom,c);
        return CGRectMake(a.x+r.x,a.y+r.y,r.width,r.height);
    }
    if (control == B_PLUS || control == B_MINUS) dm_aspect_hud_rect(self.bounds.size.width,self.bounds.size.height,canvas);
    else dm_aspect_touch_rect(self.bounds.size.width,self.bounds.size.height,canvas);
    dm_touchpad_rect r = dm_botw_layout_control(&_touchLayout,control,self.bounds.size.width,self.bounds.size.height,
        i.left,i.top,i.right,i.bottom,(dm_touchpad_rect){canvas[0],canvas[1],canvas[2],canvas[3]});
    return CGRectMake(r.x,r.y,r.width,r.height);
}
- (CGFloat)botwLayoutScale:(int)control { return [self botwTouchControlsActive] ? _touchLayout.control[control].scale : 1; }
- (CGPoint)botwLayoutCenter:(int)control { CGRect r=[self botwLayoutRect:control]; return CGPointMake(CGRectGetMidX(r),CGRectGetMidY(r)); }
- (CGPoint)faceCenter { if ([self botwTouchControlsActive]) return [self botwLayoutCenter:0]; UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_face_center(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u * ([self botwTouchControlsActive] ? _touchLayout.face_gap*_touchLayout.control[0].scale : 1); }
- (CGFloat)faceR { return K_FACE_R * self.u * [self botwLayoutScale:0]; }
- (CGFloat)faceRadiusForButton:(int)b {
    return [self botwTouchControlsActive] && _touchLayout.portrait ? [self botwLayoutRect:b].size.width*.5 : self.faceR;
}
- (CGPoint)facePos:(int)b {
    if ([self botwTouchControlsActive] && _touchLayout.portrait) return [self botwLayoutCenter:b];
    CGPoint c=self.faceCenter; CGFloat gap=self.faceGap;
    if ([self botwTouchControlsActive]) {
        dm_touchpad_point d=dm_botw_layout_face_offset(&_touchLayout,b,self.u);
        return CGPointMake(c.x+d.x,c.y+d.y);
    }
    if (b==B_A) c.x+=gap; else if (b==B_B) c.y+=gap; else if (b==B_X) c.y-=gap; else c.x-=gap;
    return c;
}
- (CGPoint)stickHome {
    if ([self botwTouchControlsActive]) return [self botwLayoutCenter:4];
    UIEdgeInsets i = self.safeAreaInsets;
    dm_touchpad_point p = dm_touchpad_stick_home(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom);
    return CGPointMake(p.x, p.y);
}
- (CGPoint)shieldHome { if ([self botwTouchControlsActive]) return [self botwLayoutCenter:B_ZL]; UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_shield_stick_home(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }
- (CGPoint)mapBadgeCenter {
    CGRect r = [self pillRect:B_PLUS];
    return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
}
- (CGPoint)runeButtonCenter {
    if ([self botwTouchControlsActive]) return [self botwLayoutCenter:B_L];
    UIEdgeInsets i=self.safeAreaInsets;
    dm_touchpad_point p=dm_touchpad_rune_button(self.bounds.size.width,self.bounds.size.height,i.left,i.top,i.right,i.bottom);
    return CGPointMake(p.x,p.y);
}
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : (_stick[0] ? _lCentre : self.stickHome); }
- (CGFloat)stickR:(int)i {
    CGRect a=[self botwControlArea];
    if (!i && [self botwTouchControlsActive]) return dm_botw_layout_stick_radius(&_touchLayout,a.size.width,a.size.height) * _moveResponse.size;
    return (i ? K_RSTICK_R : K_STICK_R) * self.u;
}
- (CGFloat)shieldR { CGRect a=[self botwControlArea]; return dm_botw_layout_stick_radius(&_touchLayout,a.size.width,a.size.height) * [self botwLayoutScale:B_ZL]; }
- (BOOL)inLeftArea:(CGPoint)p { CGRect b = [self botwTouchControlsActive] ? [self botwControlArea] : self.bounds; return CGRectContainsPoint(b,p) && p.x < CGRectGetMinX(b)+b.size.width * K_LSWIPE && p.y > CGRectGetMidY(b); }   // lower-left: the left stick starts where the touch lands
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { if ([self botwTouchControlsActive] || [self botwMenuDpadActive]) return [self botwLayoutCenter:B_LEFT]; UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_dpad_center(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }
- (CGFloat)dpadR {
    if (_touchLayout.portrait && ([self botwTouchControlsActive] || [self botwMenuDpadActive])) return [self botwLayoutRect:B_LEFT].size.width*.5;
    return K_DPAD_R * self.u * ([self botwMenuDpadActive] ? _touchLayout.control[B_LEFT].scale : [self botwLayoutScale:B_LEFT]);
}
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { if ([self botwTouchControlsActive]) return [self botwLayoutCenter:b]; CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b {
    if ([self botwTouchControlsActive] && _touchLayout.portrait && b == B_L) return [self botwLayoutRect:b].size.width*.5;
    return (b == B_ZL || b == B_ZR || (b == B_R && [self botwTouchControlsActive]) ? K_ZL_R : K_L_R) * self.u * [self botwLayoutScale:b];
}
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    if ([self botwTouchControlsActive]) return [self botwLayoutRect:b];
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (BOOL)botwTouchControlsActive {
    return botwTouchHudSupported() && _full && !_tap && !_padOff &&
        (!_botwMenuMode || _botwCameraPadVisible || botwSeated()) && !atomic_load(&g_any_controller_connected);
}
- (BOOL)botwMenuDpadActive { return !botwSeated() && botwTouchHudSupported() && _full && !_tap && !_padOff && _botwMenuMode && !_manualMenuPad && !atomic_load(&g_any_controller_connected) && dm_botw_touch_menu_dpad_visible(); }

- (void)sendBotwMenuPointer:(int)phase point:(CGPoint)p {
    if (phase == DM_BOTW_MENU_CANCEL) {
        dm_botw_touch_menu_pointer(phase, (float)_botwMenuLastNorm.x, (float)_botwMenuLastNorm.y);
        return;
    }
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    if (rect[2] <= 0 || rect[3] <= 0) return;
    _botwMenuLastNorm = CGPointMake((p.x - rect[0]) / rect[2], (p.y - rect[1]) / rect[3]);
    dm_botw_touch_menu_pointer(phase, (float)_botwMenuLastNorm.x, (float)_botwMenuLastNorm.y);
}
- (void)cancelBotwMenuPointer {
    if (!_botwMenuPointerActive) return;
    [self sendBotwMenuPointer:DM_BOTW_MENU_CANCEL point:_botwMenuLast];
    _botwMenuPointerActive = NO;
}
- (void)cancelBotwCameraGesture {
    dm_botw_touch_camera_pose_modifier(0);
    _botwCameraModifierTouch = nil;
    if (!_botwCameraGesture.active) return;
    if (_botwCameraGesture.kind == DM_BOTW_CAMERA_GESTURE_ZOOM) dm_botw_touch_menu_pinch(0.0f);
    if (_botwCameraGesture.kind == DM_BOTW_CAMERA_GESTURE_POSE) dm_botw_touch_camera_pose(0.0f, 0.0f);
    dm_botw_camera_gesture_end(&_botwCameraGesture);
}
- (void)updateBotwCameraGesture:(NSSet<UITouch *> *)changedTouches {
    if (!_botwCameraGesture.active || !_botwMenuTouch || !_botwMapPinchTouch) return;
    if (!dm_botw_touch_camera_active()) { [self cancelBotwCameraGesture]; return; }
    CGPoint a = [_botwMenuTouch locationInView:self], b = [_botwMapPinchTouch locationInView:self];
    CGPoint middle = CGPointMake((a.x + b.x) * .5, (a.y + b.y) * .5);
    int changedFingers = (_botwMenuTouch && [changedTouches containsObject:_botwMenuTouch] ? 1 : 0) +
        (_botwMapPinchTouch && [changedTouches containsObject:_botwMapPinchTouch] ? 1 : 0);
    float ratio = 1.0f, pose_x = 0, pose_y = 0;
    int kind = dm_botw_camera_gesture_update(&_botwCameraGesture, (float)middle.x,
        (float)middle.y, (float)dist(a, b), changedFingers, &ratio, &pose_x, &pose_y);
    if (kind == DM_BOTW_CAMERA_GESTURE_ZOOM) dm_botw_touch_menu_pinch(ratio);
    else if (kind == DM_BOTW_CAMERA_GESTURE_POSE) dm_botw_touch_camera_pose(pose_x, pose_y);
    dm_botw_touch_camera_pose_modifier(kind == DM_BOTW_CAMERA_GESTURE_POSE &&
                                        _botwCameraModifierTouch != nil);
}
- (BOOL)manualPadGestureAllowed {
    // This escape path must also work when the menu/HUD adapter has no target.
    return !strcmp(DM_GAME_ID, "01007EF00011E000") && _controls.hidden && !_padOff && _botwMenuMode &&
        !_manualMenuPad && !atomic_load(&g_any_controller_connected);
}
- (void)revealBotwMenuPad:(UITapGestureRecognizer *)recognizer {
    [self refreshBotwTouchMenuMode];
    if (recognizer.state != UIGestureRecognizerStateRecognized || ![self manualPadGestureAllowed]) return;
    [self reset];
    dm_botw_touch_menu_pointer(DM_BOTW_MENU_CANCEL, 0, 0);
    dm_input_cancel_virtual_latch(0xffffull);
    _manualMenuPad = YES;
    _full = YES; _tap = NO;
    [self applyLayout];
    _controls.hidden = NO;
    [self setNeedsLayout];
    LOG("BOTW touch: temporary full gamepad shown for this menu visit");
}
- (void)refreshBotwTouchMenuMode {
    BOOL active = !atomic_load(&g_any_controller_connected) && !dm_botw_touch_controls_visible();
    BOOL cameraPadVisible = active && botwTouchHudSupported() && _full && !_tap && !_padOff &&
        !atomic_load(&g_any_controller_connected) && dm_botw_touch_camera_active();
    BOOL cameraPadChanged = _botwCameraPadVisible != cameraPadVisible;
    if (_botwMenuMode == active && !cameraPadChanged) {
        if (!_menuDpad.hidden && ![self botwMenuDpadActive]) {
            for (UITouch *t in _owner.keyEnumerator.allObjects)
                if (([_owner objectForKey:t].unsignedLongLongValue & 0xff) == C_DPAD) [_owner removeObjectForKey:t];
            [self recompute];
        }
        _menuDpad.hidden = ![self botwMenuDpadActive];
        _controls.hidden = _padOff || (_botwMenuMode && !_botwCameraPadVisible && !_manualMenuPad && !botwSeated());
        [self setNeedsLayout];
        return;
    }
    _botwCameraPadVisible = cameraPadVisible;
    [self reset];
    if (botwTouchHudSupported()) dm_input_cancel_virtual_latch(0xffffull);
    _botwMenuMode = active;
    if (!active) _botwMapTapConsumed = _botwMapInvalidAfterTap = NO;
    // Menu mode participates in every BOTW button's visibility predicate.
    // Restore those child layers as well as the parent after loading/menus.
    [self applyLayout];
    _controls.hidden = _padOff || (_botwMenuMode && !_botwCameraPadVisible && !_manualMenuPad && !botwSeated());
    [self setNeedsLayout];
}
- (void)clearBotwRuneIcon {
    _runeIconLayer.contents = nil; _runeIconLayer.hidden = YES;
    _runeBadge.hidden = YES; _runeBadgeLabel.hidden = YES;
    _runeIconValid = NO;
    _label[B_L].hidden = NO;
}
- (void)refreshBotwRuneIcon {
    [self clearBotwRuneIcon];
    if (![self botwTouchControlsActive]) return;
    _runeIconLayer.contents = (__bridge id)_runeDefaultIcon.CGImage;
    _runeIconLayer.hidden = NO;
    _runeBadge.hidden = _runeBadgeLabel.hidden = !_touchLayout.badges;
    _label[B_L].hidden = YES;
}
- (void)botwRuneIconChanged {
    [self refreshBotwRuneIcon]; [self setNeedsLayout];
}
- (void)setBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height {
    CGRect oldRect = _botwMapRect;
    BOOL oldValid = _botwMapValid, oldConsumed = _botwMapTapConsumed, oldInvalidAfterTap = _botwMapInvalidAfterTap;
    BOOL active = [self botwTouchControlsActive];
    if (!active) { _botwMapTapConsumed = NO; _botwMapInvalidAfterTap = NO; }
    // Keep the native snapshot even while a menu hides gameplay controls.
    // The restored map can publish before the menu-close notification, and
    // unchanged bounds are not sent again. Hit testing still requires active
    // BOTW controls in botwMapOwnsPoint:.
    if (!valid || !isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) {
        valid = NO; _botwMapRect = CGRectZero;
        if (active && _botwMapTapConsumed) _botwMapInvalidAfterTap = YES;
    } else {
        if (_botwMapTapConsumed && !_botwMapInvalidAfterTap) {
            _botwMapValid = NO;
            _botwMapRect = CGRectZero;
            _key[B_MINUS].hidden = _tap || (active && _botwMapTapConsumed);
            return;
        }
        _botwMapTapConsumed = NO; _botwMapInvalidAfterTap = NO;
        _botwMapRect = CGRectMake(x, y, width, height);
    }
    _botwMapValid = valid;
    _key[B_MINUS].hidden = _tap || (active && (_botwMapValid || _botwMapTapConsumed));
    if (oldValid != _botwMapValid || !CGRectEqualToRect(oldRect, _botwMapRect) ||
        oldConsumed != _botwMapTapConsumed || oldInvalidAfterTap != _botwMapInvalidAfterTap)
        [self setNeedsLayout];
}
- (BOOL)botwMapOwnsPoint:(CGPoint)p {
    if (![self botwTouchControlsActive] || !_botwMapValid) return NO;
    float rect[4]; dm_aspect_hud_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    if (rect[2] <= 0 || rect[3] <= 0) return NO;
    CGPoint normalized = CGPointMake((p.x - rect[0]) / rect[2], (p.y - rect[1]) / rect[3]);
    return CGRectContainsPoint(_botwMapRect, normalized);
}
- (BOOL)botwScopePromptOwnsPoint:(CGPoint)p {
    if (![self botwTouchControlsActive]) return NO;
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    return rect[2] > 0 && rect[3] > 0 &&
        dm_botw_touch_scope_prompt_at((p.x-rect[0])/rect[2],(p.y-rect[1])/rect[3]);
}
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    if ([self botwTouchControlsActive] && dist(p, [self runeButtonCenter]) <= [self dropR:B_L] * 1.45) return B_L;
    if ([self botwTouchControlsActive] && dist(p, self.shieldHome) <= self.shieldR * 1.35) return B_ZL;
    if ([self botwTouchControlsActive]) {
        CGRect r = [self pillRect:B_PLUS];
        if (dist(p, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r))) <= r.size.width*.5) return B_PLUS;
    }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        if ([self botwTouchControlsActive] && b == B_L) continue;
        if ([self botwTouchControlsActive] && b == B_PLUS) continue;
        if ([self botwTouchControlsActive] && (b == B_R || b == B_ZR) && (_botwCancelLatched & (1ull << b))) continue;
        if ([self botwTouchControlsActive] && b == B_LS) continue;
        if ([self botwTouchControlsActive] && b == B_RS) continue;
        if ([self botwTouchControlsActive] && (_botwMapValid || _botwMapTapConsumed) && b == B_MINUS) continue;
        if ([self botwTouchControlsActive] && b == B_MINUS) {
            CGRect r = [self pillRect:b];
            if (dist(p, CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r))) <= r.size.width*.5) return b;
            continue;
        }
        BOOL botwRightShoulder = [self botwTouchControlsActive] && (b == B_ZR || b == B_R);
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * (botwRightShoulder ? DM_TP_SHOULDER_HIT_SCALE : 1.35)
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (botwRightShoulder && _touchLayout.badges) hit |= dm_botw_button_badge_contains(p, [self dropCenter:b], [self dropR:b]);
        if (hit) return b; }
    return -1;
}
- (BOOL)compactDpadOwnsPoint:(CGPoint)p {
    return [self botwTouchControlsActive] && _touchLayout.portrait && _full &&
        dist(p,self.dpadCenter) <= self.dpadR*K_DPAD_GRAB;
}
- (BOOL)leftStickOwnsPoint:(CGPoint)p {
    if (![self botwTouchControlsActive] || _tap || [self btnAt:p] >= 0 || [self inSwap:p]) return NO;
    if (dist(p,self.shieldHome) <= self.shieldR*K_STICK_GRAB) return NO;
    if ([self compactDpadOwnsPoint:p]) return NO;
    if (_touchLayout.portrait && [self faceAt:p]) return NO;
    CGFloat best = 1;
    int kind = C_NONE;
    CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6);
    if ([self faceAt:p] && f <= best) { best = f; kind = C_FACE; }
    if (_full) {
        CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB);
        if (d < best) { best = d; kind = C_DPAD; }
    }
    if (!_stick[0]) {
        CGFloat sl = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB);
        if (sl < best) { kind = C_STICK; }
    }
    if (kind == C_STICK) return YES;
    // Empty space between controls can start the floating stick outside its home circle.
    return kind == C_NONE && !_stick[0] && ![self faceAt:p] && [self inLeftArea:p] &&
        ![self botwMapOwnsPoint:p] && ![self botwScopePromptOwnsPoint:p] &&
        (!_botwCameraPadVisible || botwSeated());
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == _menuPadDoubleTap) {
        [self refreshBotwTouchMenuMode];
        return [self manualPadGestureAllowed];
    }
    if (gestureRecognizer == _leftStickDoubleTap) {
        _leftStickTapGap = _leftStickTapEnd > 0 ? touch.timestamp - _leftStickTapEnd : INFINITY;
        return [self leftStickOwnsPoint:[touch locationInView:self]];
    }
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer == _menuPadDoubleTap) return [self manualPadGestureAllowed];
    return recognizer != _leftStickDoubleTap ||
        ([self botwTouchControlsActive] && !_leftStickUsed && dm_touchpad_stick_double_tap_gap(_leftStickTapGap));
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return gestureRecognizer == _leftStickDoubleTap || otherGestureRecognizer == _leftStickDoubleTap;
}
- (void)pulseBotwTouchButton:(int)button {
    if (![self botwTouchControlsActive]) return;
    uint64_t mask = 1ull << button;
    pthread_mutex_lock(&g_mu); g_touch_btn |= mask; pthread_mutex_unlock(&g_mu); publish();
    pthread_mutex_lock(&g_mu); g_touch_btn &= ~mask; pthread_mutex_unlock(&g_mu); publish();
}
- (void)emitTouchFeedback {
    [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
}
- (void)leftStickDoubleTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized && [self botwTouchControlsActive] &&
        !_leftStickUsed && dm_touchpad_stick_double_tap_gap(_leftStickTapGap))
        [self pulseBotwTouchButton:B_LS];
}
- (void)updateLeftStickTapAt:(CGPoint)p {
    if (![self botwTouchControlsActive] || !_stick[0] || _leftStickUsed) return;
    if (dist(p, _lCentre) <= [self stickR:0] * _moveResponse.deadzone) return;
    // A gesture used for movement cannot be the first tap of L3, even if
    // UIKit still considers its small displacement a tap. Reset its tap count.
    _leftStickUsed = YES; _leftStickTapEnd = 0; _leftStickTapGap = INFINITY;
    _leftStickDoubleTap.enabled = NO;
}
- (BOOL)inSwap:(CGPoint)p { return !botwTouchHudSupported() && !_manualMenuPad && dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    if ([self botwTouchControlsActive] && _touchLayout.badges)
        for (int b = B_A; b <= B_Y; b++)
            if (dm_botw_button_badge_contains(p, [self facePos:b], [self faceRadiusForButton:b])) return 1ull << b;
    if ([self botwTouchControlsActive] && _touchLayout.portrait) {
        uint64_t bits = 0;
        for (int b = B_A; b <= B_Y; b++)
            if (dist(p,[self facePos:b]) <= [self faceRadiusForButton:b]*1.25) bits |= 1ull << b;
        return bits;
    }
    CGPoint c = self.faceCenter;
    if ([self botwTouchControlsActive]) return dm_botw_layout_face_buttons(&_touchLayout,p.x,p.y,c.x,c.y,self.u);
    return dm_touchpad_face_buttons((float)p.x, (float)p.y, (float)c.x, (float)c.y,
                                    (float)self.faceGap, (float)(self.faceR * 1.25));
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter;
    return dm_touchpad_dpad_buttons((float)p.x, (float)p.y, (float)c.x, (float)c.y, (float)self.dpadR);
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) {
            uint64_t bit = 1ull << (v >> 8);
            if ((_botwCancelPending & bit) || !(_botwCancelLatched & bit)) btn |= bit;
        } else if (c == C_SHIELD) btn |= 1ull << B_ZL;
        else if (c == C_DPAD) dpad |= ([self botwTouchControlsActive] || dm_botw_touch_menu_dpad_visible()) ? v >> 8 : [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    // Keep a canceled trigger published even after its finger lifts. The native
    // sequencer needs one or more real Npad samples to observe R/ZR with B.
    btn |= _botwCancelPending;
    int32_t ax[4] = {0};
    float leftDead = [self botwTouchControlsActive] ? DM_TP_BOTW_STICK_DEAD : DM_TP_DEAD;
    if (_leftAxisTouch) {
        uint64_t own = [_owner objectForKey:_leftAxisTouch].unsignedLongLongValue;
        CGPoint p = (own & 0xff) == C_SHIELD ? _shieldNow : _stickNow[0];
        CGPoint h = (own & 0xff) == C_SHIELD ? _shieldOrigin : [self stickCentre:0];
        BOOL ordinaryLeftStickOwnsAxis = [self botwTouchControlsActive] &&
            (own & 0xff) == C_STICK && (own >> 8) == 0 && _stick[0] == _leftAxisTouch;
        CGFloat radius = (own & 0xff) == C_SHIELD ? self.shieldR : [self stickR:0];
        if (ordinaryLeftStickOwnsAxis)
            dm_touchpad_stick_axis_with_response((float)(p.x-h.x), (float)(p.y-h.y), (float)radius, _moveResponse, &ax[0], &ax[1]);
        else dm_touchpad_stick_axis_with_deadzone((float)(p.x-h.x), (float)(p.y-h.y), (float)radius, 0, leftDead, &ax[0], &ax[1]);
    } else if (_stick[0]) {
        CGPoint o = [self knobOffset:0];
        if ([self botwTouchControlsActive]) dm_touchpad_stick_axis_with_response((float)o.x,(float)o.y,(float)[self stickR:0],_moveResponse,&ax[0],&ax[1]);
        else dm_touchpad_stick_axis_with_deadzone((float)o.x,(float)o.y,(float)[self stickR:0],0,leftDead,&ax[0],&ax[1]);
    }
    CGPoint o = [self knobOffset:1]; CGFloat R = [self stickR:1];
    dm_touchpad_stick_axis((float)o.x, (float)o.y, (float)R, _manualMenuPad || !dm_look_enabled(), &ax[2], &ax[3]);
    if (_lookTouch && [self botwTouchControlsActive] && dm_botw_touch_quick_select_active()) {
        ax[2] = -ax[2]; ax[3] = -ax[3];
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] && !botwTouchHudSupported() ? 1u : 0) |
        (_stick[1] && ![self botwTouchControlsActive] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [self emitTouchFeedback];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil || _shieldTouch != nil;
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// ---- Relative camera look ----
- (void)cancelLook {   // Keep the owner's C_LOOK entry until lift; it cannot turn into a stick mid-gesture.
    UITouch *owner = _lookTouch;
    if (owner) dm_look_input(DM_LOOK_CANCEL, 0, 0);
    _botwLookTapPending = NO;
    _lookTouch = nil; _lookScale = 0;
    if (owner && _stick[1] == owner) _stick[1] = nil;
    if (owner) [self recompute];  // Publish zero virtual RS immediately, even without another touch event.
}
- (void)checkLookGeometry {
    CGSize size = self.bounds.size;
    UIEdgeInsets insets=self.safeAreaInsets;
    UIInterfaceOrientation orientation = self.window.windowScene.effectiveGeometry.interfaceOrientation;
    if (!_lookGeometryKnown) { _lookBoundsSize = size; _lookInsets=insets; _lookOrientation = orientation; _lookGeometryKnown = YES; return; }
    BOOL resized = !CGSizeEqualToSize(size, _lookBoundsSize);
    BOOL safeChanged=!UIEdgeInsetsEqualToEdgeInsets(insets,_lookInsets);
    BOOL rotated = orientation != UIInterfaceOrientationUnknown && _lookOrientation != UIInterfaceOrientationUnknown && orientation != _lookOrientation;
    _lookBoundsSize = size; _lookInsets=insets;
    if (orientation != UIInterfaceOrientationUnknown) _lookOrientation = orientation;
    if (!strcmp(DM_GAME_ID,"01007EF00011E000")) {
        if (resized || rotated || safeChanged) [self cancelSurfaceInput];
    } else if (resized || rotated) {
        BOOL cameraGesture=_botwCameraGesture.active;
        [self cancelLook]; [self cancelBotwMenuPointer]; [self cancelBotwCameraGesture];
        if (_botwMapPinchTouch) {
            if (!cameraGesture) dm_botw_touch_menu_pinch(0.0f);
            _botwMapPinchTouch=nil; _botwMapPinchStart=0; _botwMapGestureSuppressed=NO;
        }
    }
}
- (void)beginLook:(UITouch *)t at:(CGPoint)p {
    [self checkLookGeometry];
    [_owner setObject:@(C_LOOK) forKey:t];
    if (_lookTouch) { _botwLookTapPending = NO; _lookDragged = YES; return; } // overlapping camera fingers cancel tap recognition
    if (!dm_look_enabled()) return;
    float picture[4]; dm_aspect_region(0,picture);
    CGFloat scale = MIN(self.bounds.size.width*picture[2], self.bounds.size.height*picture[3]);
    if (scale <= 0) return;
    _lookTouch = t; _lookLast = _lookDown = p; _lookDownTime = t.timestamp; _lookDragged = NO; _lookScale = scale;
    _stick[1] = t; _stickNow[1] = p; _rCentre = p;
    dm_look_input(DM_LOOK_BEGIN, 0, 0);
}
- (void)moveLook:(UITouch *)t to:(CGPoint)p {
    [self checkLookGeometry];
    if (t != _lookTouch) return;
    if (!dm_look_enabled() || _lookScale <= 0) { [self cancelLook]; return; }
    float dx = (float)((p.x - _lookLast.x) / _lookScale);
    float dy = (float)((p.y - _lookLast.y) / _lookScale);
    _lookDragged |= dm_touchpad_look_dragged((float)_lookDown.x, (float)_lookDown.y,
                                              (float)p.x, (float)p.y, DM_TP_LOOK_TAP_SLOP * self.u);
    if (_lookDragged) _botwLookTapPending = NO;
    _lookLast = p;
    _stickNow[1] = p;
    CGFloat d = dist(p, _rCentre), R = [self stickR:1];
    if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d);
    if ([self botwTouchControlsActive] && dm_botw_touch_quick_select_active()) { dx=-dx; dy=-dy; }
    if (dx != 0 || dy != 0) dm_look_input(DM_LOOK_MOVE, dx, dy);
}
- (void)endLook:(UITouch *)t at:(CGPoint)p cancelled:(BOOL)cancelled {
    if (t != _lookTouch) return;
    if (cancelled || !dm_look_enabled()) { [self cancelLook]; return; }
    [self moveLook:t to:p];   // UIKit may deliver a final location only in touchesEnded.
    if (t == _lookTouch) {
        BOOL tap = dm_touchpad_look_tap((float)(t.timestamp - _lookDownTime), _lookDragged);
        dm_look_input(DM_LOOK_END, 0, 0); _lookTouch = nil; _lookScale = 0;
        if (tap && [self botwTouchControlsActive]) {
            CGFloat u = self.u;
            if (_botwLookTapPending && dm_touchpad_look_double_tap((double)_botwLookTapTime, (double)t.timestamp,
                    (float)_botwLookTapPoint.x, (float)_botwLookTapPoint.y, (float)_lookDown.x, (float)_lookDown.y, (float)u)) {
                _botwLookTapPending = NO;
                [self pulseBotwTouchButton:B_RS];
            } else {
                _botwLookTapPending = YES; _botwLookTapTime = t.timestamp; _botwLookTapPoint = _lookDown;
            }
        } else _botwLookTapPending = NO;
    }
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    float rect[4]; dm_aspect_touch_rect(w, h, rect);
    CGFloat x0 = rect[0], y0 = rect[1]; w = rect[2]; h = rect[3];
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    motion_first_input();
    [self refreshBotwTouchMenuMode];
    if (_menuPadChord.count) { [_menuPadChord unionSet:ts]; return; }
    if ([self manualPadGestureAllowed]) {
        NSMutableSet<UITouch *> *active = [NSMutableSet new];
        for (UITouch *touch in e.allTouches ?: ts)
            if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) [active addObject:touch];
        if (active.count >= 3) {
            // Reserve the three-finger chord before any of its releases can
            // activate a native menu target. Ordinary combat chords are untouched.
            [self reset]; _menuPadChord = active;
            return;
        }
    }
    if (ts.count > 1) _botwLookTapPending = NO;
    BOOL game = NO;
    for (UITouch *t in ts) {
        BOOL nativeMenuArea=botwSeated() ? [t locationInView:self].y<CGRectGetMinY([self botwControlArea]) : !_botwCameraPadVisible;
        if (_botwMenuMode && !_manualMenuPad && nativeMenuArea) {
            if ([self botwMenuDpadActive]) {
                CGPoint p=[t locationInView:self];
                uint64_t direction = dist(p,self.dpadCenter)<=self.dpadR*K_DPAD_GRAB ? [self dpadAt:p] : 0;
                if (direction) { [_owner setObject:@(C_DPAD | direction << 8) forKey:t]; continue; }
            }
            // The host owns menu hit testing and gestures. Keep only one primary
            // pointer and never let extra touches fall through to gameplay.
            if (_botwCameraGesture.active && !_botwCameraModifierTouch) {
                // A third finger is the native ZL modifier for weapon poses.
                _botwCameraModifierTouch = t;
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
                dm_botw_touch_camera_pose_modifier(_botwCameraGesture.kind == DM_BOTW_CAMERA_GESTURE_POSE);
            } else if (_botwMapGestureSuppressed) {
                // A pinch remains one gesture until every finger lifts. Do not
                // let a replacement finger become a new pointer mid-gesture.
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
            } else if (!_botwMenuTouch) {
                CGPoint p = [t locationInView:self];
                _botwMenuPointerActive = YES; _botwMenuTouch = t; _botwMenuLast = p;
                [_owner setObject:@(C_MENU) forKey:t];
                [self sendBotwMenuPointer:DM_BOTW_MENU_BEGIN point:p];
            } else if (_botwMenuPointerActive && (dm_botw_touch_map_active() || dm_botw_touch_camera_active()) &&
                       !_botwMapPinchTouch && !_botwMapGestureSuppressed) {
                // A second finger on a live map or camera owns the gesture;
                // only AppCamera distinguishes pinch zoom from pose movement.
                _botwMapPinchTouch = t;
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
                _botwMapGestureSuppressed = YES;
                CGPoint a = [_botwMenuTouch locationInView:self], b = [t locationInView:self];
                _botwMapPinchStart = fmax(1.0, dist(a, b));
                if (dm_botw_touch_camera_active()) {
                    CGPoint middle = CGPointMake((a.x + b.x) * .5, (a.y + b.y) * .5);
                    dm_botw_camera_gesture_begin(&_botwCameraGesture, (float)middle.x,
                        (float)middle.y, (float)_botwMapPinchStart);
                }
                if (_botwMenuPointerActive) {
                    [self sendBotwMenuPointer:DM_BOTW_MENU_CANCEL point:_botwMenuLast];
                    _botwMenuPointerActive = NO;
                }
                if (!_botwCameraGesture.active) dm_botw_touch_menu_pinch(1.0f);
            } else {
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
            }
            continue;
        }
        if (_padOff) { _botwLookTapPending = NO; game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        int hit = _tap ? -1 : [self btnAt:p];
        if ([self botwTouchControlsActive] && hit != B_L && !_shieldTouch && dist(p, self.shieldHome) <= self.shieldR * K_STICK_GRAB) {
            _botwLookTapPending = NO; _shieldTouch = _leftAxisTouch = t; _shieldNow = _shieldOrigin = p;
            [_owner setObject:@(C_SHIELD) forKey:t]; [self setNeedsLayout]; continue;
        }
        if (hit >= 0) {
            _botwLookTapPending = NO; [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t];
            if ([self botwTouchControlsActive] && (hit == B_R || hit == B_ZR)) [self setNeedsLayout];
            continue;
        }
        if ([self inSwap:p]) { _botwLookTapPending = NO; [_owner setObject:@(C_SWAP) forKey:t]; _swapT0 = CACurrentMediaTime(); continue; }
        if ([self leftStickOwnsPoint:p]) {
            _botwLookTapPending = NO;
            // Keep the existing dynamic left-stick grab ahead of the map clip
            // where their rectangular bounds meet near the lower-left edge.
            [_owner setObject:@(C_STICK) forKey:t]; _stick[0] = t; _stickNow[0] = p; _lCentre = p; _leftAxisTouch = t;
            _leftStickDownTime = t.timestamp; _leftStickUsed = NO; continue;
        }
        if (!_botwCameraPadVisible && [self botwMapOwnsPoint:p]) {
            _botwLookTapPending = NO;
            [_owner setObject:@(C_BOTW_MAP) forKey:t];
            dm_botw_touch_hud_map_tapped();
            _botwMapValid = NO; _botwMapRect = CGRectZero; _botwMapTapConsumed = YES; _botwMapInvalidAfterTap = NO;
            _key[B_MINUS].hidden = YES;
            [self setNeedsLayout];
            [self pulseBotwTouchButton:B_MINUS]; continue;
        }
        if (_tap) { _botwLookTapPending = NO; game |= [self gameBegin:t]; continue; }
        // Choose the nearest control in its grab radius, then route the open right half to relative look or the native right stick.
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        BOOL scopePrompt = [self botwScopePromptOwnsPoint:p];
        // BOTW's face buttons own their individual hit areas, never the gaps.
        if ([self botwTouchControlsActive]) {
            for (int b = B_A; b <= B_Y; b++) {
                CGPoint center = [self facePos:b];
                CGFloat radius = [self faceRadiusForButton:b];
                CGFloat faceHit = dist(p, center) / (radius * 1.25);
                if (_touchLayout.badges && dm_botw_button_badge_contains(CGPointMake(p.x,p.y),
                        CGPointMake(center.x,center.y),radius)) faceHit = fmin(faceHit, .5);
                if (faceHit <= best) { best = faceHit; kind = C_FACE; }
            }
        } else {
            CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6);
            if (f <= best) { best = f; kind = C_FACE; }
        }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        // Compact Rune owns its grab region before the floating movement stick.
        if (kind != C_FACE && [self compactDpadOwnsPoint:p]) { best = 0; kind = C_DPAD; }
        if (!_stick[0]) { CGFloat sl = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (sl < best) { best = sl; kind = C_STICK; } }
        if (scopePrompt && kind != C_FACE && kind != C_DPAD && kind != C_STICK) {
            _botwLookTapPending = NO;
            if (!_botwMenuTouch) {
                _botwMenuTouch = t; _botwMenuLast = p; _botwMenuPointerActive = YES;
                [_owner setObject:@(C_MENU) forKey:t];
                [self sendBotwMenuPointer:DM_BOTW_MENU_BEGIN point:p];
            } else [_owner setObject:@(C_MENU_EXTRA) forKey:t];
            continue;
        }
        if ([self botwTouchControlsActive] && _botwCameraPadVisible && !botwSeated() &&
            kind != C_FACE && kind != C_DPAD && kind != C_STICK) {
            _botwLookTapPending = NO;
            if (_botwCameraGesture.active && !_botwCameraModifierTouch) {
                _botwCameraModifierTouch = t;
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
                dm_botw_touch_camera_pose_modifier(_botwCameraGesture.kind == DM_BOTW_CAMERA_GESTURE_POSE);
            } else if (_botwMenuTouch && !_botwMapPinchTouch && !_botwMapGestureSuppressed) {
                _botwMapPinchTouch = t;
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
                _botwMapGestureSuppressed = YES;
                CGPoint a = [_botwMenuTouch locationInView:self], b = [t locationInView:self];
                _botwMapPinchStart = fmax(1.0, dist(a, b));
                CGPoint middle = CGPointMake((a.x + b.x) * .5, (a.y + b.y) * .5);
                dm_botw_camera_gesture_begin(&_botwCameraGesture, (float)middle.x,
                    (float)middle.y, (float)_botwMapPinchStart);
                if (_botwMenuPointerActive) {
                    [self sendBotwMenuPointer:DM_BOTW_MENU_CANCEL point:_botwMenuLast];
                    _botwMenuPointerActive = NO;
                }
            } else if (!_botwMenuTouch && !_botwMapGestureSuppressed) {
                _botwMenuTouch = t; _botwMenuLast = p; _botwMenuPointerActive = YES;
                [_owner setObject:@(C_MENU) forKey:t];
                [self sendBotwMenuPointer:DM_BOTW_MENU_BEGIN point:p];
            } else {
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
            }
            continue;
        }
        if (kind == C_NONE && _full && [self inRightArea:p]) {
            if (dm_look_enabled() && !_manualMenuPad) { [self beginLook:t at:p]; continue; }
            if (!_stick[1]) { kind = C_STICK; idx = 1; _rCentre = p; }
        }
        _botwLookTapPending = NO;
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD |
            ([self botwTouchControlsActive] ? [self dpadAt:p] << 8 : 0)) forKey:t];
        else if (kind == C_STICK) {
            [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p;
            if (!idx) { _leftAxisTouch = t; _leftStickDownTime = t.timestamp; _leftStickUsed = NO; }
            if (idx) _rCentre = p; else _lCentre = p;   // both sticks start where the finger lands
        }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [self refreshBotwTouchMenuMode];
    if (_menuPadChord.count) return;
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_MENU && t == _botwMenuTouch) {
            _botwMenuLast = p;
            if (_botwMapGestureSuppressed && _botwMapPinchTouch) {
                if (_botwCameraGesture.active) [self updateBotwCameraGesture:ts];
                else {
                    CGPoint a = [_botwMenuTouch locationInView:self], b = [_botwMapPinchTouch locationInView:self];
                    dm_botw_touch_menu_pinch((float)(dist(a, b) / _botwMapPinchStart));
                }
            } else if (_botwMenuPointerActive && !_botwMapGestureSuppressed) [self sendBotwMenuPointer:DM_BOTW_MENU_MOVE point:p];
        }
        else if (t == _botwMapPinchTouch && _botwMenuTouch) {
            if (_botwCameraGesture.active) [self updateBotwCameraGesture:ts];
            else {
                CGPoint a = [_botwMenuTouch locationInView:self], b = [t locationInView:self];
                dm_botw_touch_menu_pinch((float)(dist(a, b) / _botwMapPinchStart));
            }
        }
        else if (t == _botwCameraModifierTouch) {
            dm_botw_touch_camera_pose_modifier(_botwCameraGesture.kind == DM_BOTW_CAMERA_GESTURE_POSE);
        }
        else if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_SHIELD) { _shieldNow = p; [self setNeedsLayout]; }
        else if (c == C_BTN && [self botwTouchControlsActive] && ((v >> 8) == B_R || (v >> 8) == B_ZR)) {
            uint64_t bit = 1ull << (v >> 8);
            CGPoint center = [self dropCenter:(int)(v >> 8)];
            BOOL outside = dm_touchpad_cancel_outside(p.x,p.y,center.x,center.y,
                DM_TP_CANCEL_RADIUS*self.u*[self botwLayoutScale:(int)(v >> 8)]);
            if (outside != !!(_botwCancelOutside & bit)) [self emitTouchFeedback];
            if (outside) _botwCancelOutside |= bit; else _botwCancelOutside &= ~bit;
            [self setNeedsLayout];
        }
        else if (c == C_STICK) {
            _stickNow[v >> 8] = p;
            if ((v >> 8) == 0) [self updateLeftStickTapAt:p];
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_LOOK) [self moveLook:t to:p];
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    [self refreshBotwTouchMenuMode];
    if (_menuPadChord.count) { [_menuPadChord minusSet:ts]; return; }
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (t == _botwCameraModifierTouch) {
            dm_botw_touch_camera_pose_modifier(0);
            _botwCameraModifierTouch = nil;
        }
        if ((v & 0xff) == C_STICK && (v >> 8) == 0 && [self botwTouchControlsActive]) {
            [self updateLeftStickTapAt:[t locationInView:self]];
            _leftStickTapEnd = ended && dm_touchpad_look_tap((float)(t.timestamp-_leftStickDownTime), _leftStickUsed) ? t.timestamp : 0;
        }
        if (t == _botwMapPinchTouch) {
            if (_botwCameraGesture.active) [self cancelBotwCameraGesture];
            else dm_botw_touch_menu_pinch(0.0f);
            _botwMapPinchTouch = nil; _botwMapPinchStart = 0;
        }
        if ((v & 0xff) == C_MENU && t == _botwMenuTouch) {
            if (_botwMapPinchTouch) {
                if (_botwCameraGesture.active) [self cancelBotwCameraGesture];
                else dm_botw_touch_menu_pinch(0.0f);
                _botwMapPinchTouch = nil; _botwMapPinchStart = 0;
            }
            if (_botwMenuPointerActive) {
                CGPoint p = [t locationInView:self]; _botwMenuLast = p;
                [self sendBotwMenuPointer:ended ? DM_BOTW_MENU_END : DM_BOTW_MENU_CANCEL point:p];
            }
            _botwMenuPointerActive = NO; _botwMenuTouch = nil;
        }
        if ((v & 0xff) == C_LOOK) [self endLook:t at:[t locationInView:self] cancelled:!ended];
        if ((v & 0xff) == C_BTN && [self botwTouchControlsActive] && ((v >> 8) == B_R || (v >> 8) == B_ZR)) {
            // Input can remain held until native cancel acknowledgement, but
            // the guide belongs to the finger and ends on this release.
            [self setNeedsLayout];
            uint64_t bit = 1ull << (v >> 8);
            CGPoint p = [t locationInView:self], center = [self dropCenter:(int)(v >> 8)];
            if (ended && dm_botw_touch_actions_available() && !((_botwCancelPending | _botwCancelLatched) & bit) &&
                dm_touchpad_cancel_outside((float)p.x, (float)p.y, (float)center.x, (float)center.y, DM_TP_CANCEL_RADIUS * self.u * [self botwLayoutScale:(int)(v >> 8)])) {
                _botwCancelLatched |= bit; _botwCancelPending |= bit; dm_botw_touch_cancel_trigger(bit);
            }
            _botwCancelOutside &= ~bit;
            if (_botwCancelPending & bit) {
                if (dm_botw_touch_cancel_complete(bit)) { _botwCancelPending &= ~bit; _botwCancelLatched &= ~bit; }
            } else _botwCancelLatched &= ~bit;
        }
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) {   // layout button: counts only when released on the button
            if (CACurrentMediaTime() - _swapT0 >= 0.8) { atomic_store(&g_motion_recenter, 1); LOG("front end: motion recentered by a long press on the layout button"); }
            else swap = YES;
        }
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
        if (t == _shieldTouch) { _shieldTouch = nil; _shieldNow = _shieldOrigin = CGPointZero; [self setNeedsLayout]; }
        if (t == _leftAxisTouch) {
            _leftAxisTouch = nil;
            for (UITouch *other in _owner) {
                uint64_t ov = [_owner objectForKey:other].unsignedLongLongValue;
                if ((ov & 0xff) == C_SHIELD || ((ov & 0xff) == C_STICK && (ov >> 8) == 0)) { _leftAxisTouch = other; break; }
            }
        }
    }
    BOOL menuTouchRemains = NO;
    for (UITouch *touch in _owner) {
        int owner = (int)([_owner objectForKey:touch].unsignedLongLongValue & 0xff);
        if (owner == C_MENU || owner == C_MENU_EXTRA) { menuTouchRemains = YES; break; }
    }
    if (!menuTouchRemains) _botwMapGestureSuppressed = NO;
    _leftStickDoubleTap.enabled = [self botwTouchControlsActive] && !_botwMenuMode && !(_stick[0] && _leftStickUsed);
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)cancelSurfaceInput {
    // A cancelled menu gesture still owns its fingers until UIKit releases
    // them. Release virtual buttons/axes, while preserving that ownership so
    // resize cannot turn a held finger into a fresh click or pinch.
    NSMutableArray<UITouch *> *menu=[NSMutableArray new];
    for (UITouch *touch in _owner) {
        int kind=(int)([_owner objectForKey:touch].unsignedLongLongValue&0xff);
        if (kind==C_MENU || kind==C_MENU_EXTRA) [menu addObject:touch];
    }
    UITouch *primary=_botwMenuTouch; BOOL suppressed=_botwMapGestureSuppressed;
    [self reset];
    _botwMenuTouch=primary; _botwMapGestureSuppressed=suppressed;
    for (UITouch *touch in menu) [_owner setObject:@(touch==primary ? C_MENU : C_MENU_EXTRA) forKey:touch];
}
- (void)reset {
    uint64_t cancelMask = DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS;
    if (_btnBits & DM_BTN_L) cancelMask |= DM_BTN_L;
    BOOL hadManualPad = _manualMenuPad;
    _manualMenuPad = NO; _menuPadChord = nil;
    if (hadManualPad) {
        _controls.hidden = _padOff || (_botwMenuMode && !_botwCameraPadVisible && !_manualMenuPad && !botwSeated());
        [self setNeedsLayout];
    }
    [self cancelBotwMenuPointer];
    [self cancelBotwCameraGesture];
    _botwMenuTouch = nil;
    _botwMapGestureSuppressed = NO;
    if (_botwMapPinchTouch) { dm_botw_touch_menu_pinch(0.0f); _botwMapPinchTouch = nil; _botwMapPinchStart = 0; }
    if (botwTouchHudSupported()) dm_botw_touch_actions_reset();
    if (botwTouchHudSupported()) dm_input_cancel_virtual_latch(cancelMask);
    [self cancelLook]; [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil;
    _leftAxisTouch = _shieldTouch = nil; _shieldNow = _shieldOrigin = CGPointZero; _botwCancelPending = _botwCancelLatched = _botwCancelOutside = 0;
    _leftStickTapEnd = 0; _leftStickTapGap = INFINITY;
    _leftStickDownTime = 0; _leftStickUsed = NO;
    _leftStickDoubleTap.enabled = [self botwTouchControlsActive] && !_botwMenuMode;
    for (int i = 0; i < 16; i++) _game[i] = nil;
    [self pushGame]; [self recompute];
    [self setNeedsLayout];
}

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}
static CGImageRef botwRuneImage(const dm_botw_rune_icon_state *snapshot) {
    if (!snapshot || !snapshot->valid || snapshot->width != DM_BOTW_RUNE_ICON_SIDE ||
        snapshot->height != DM_BOTW_RUNE_ICON_SIDE || snapshot->stride != DM_BOTW_RUNE_ICON_STRIDE) return NULL;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, snapshot->rgba, sizeof snapshot->rgba);
    CGDataProviderRef provider = data ? CGDataProviderCreateWithCFData(data) : NULL;
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // The provider publishes RGBA with premultiplied alpha.
    CGImageRef image = provider && color ? CGImageCreate(snapshot->width, snapshot->height, 8, 32,
        snapshot->stride, color, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, provider, NULL, false,
        kCGRenderingIntentDefault) : NULL;
    if (color) CGColorSpaceRelease(color);
    if (provider) CGDataProviderRelease(provider);
    if (data) CFRelease(data);
    return image;
}

static void layerDisplayScale(CALayer *layer, CGFloat scale) {
    layer.contentsScale=scale;
    for (CALayer *child in layer.sublayers) layerDisplayScale(child,scale);
}
- (void)deviceOrientationChanged { motion_update_flip(self.window.windowScene); [self checkLookGeometry]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    motion_update_flip(self.window.windowScene);
    [self checkLookGeometry];
    [self syncBotwTouchProfile];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat displayScale=fmax(1,self.traitCollection.displayScale);
    self.contentScaleFactor=displayScale;
    layerDisplayScale(self.layer,displayScale);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    _menuDpad.hidden = ![self botwMenuDpadActive];
    if (!_menuDpad.hidden) {
        CGMutablePathRef path = CGPathCreateMutable();
        for (int b=B_LEFT;b<=B_DOWN;b++) {
            CGPathRef key = dm_botw_dpad_key_path(self.dpadCenter,self.dpadR,b);
            CGPathAddPath(path,NULL,key); CGPathRelease(key);
        }
        setPath(_menuDpad,path);
    }
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, [self faceRadiusForButton:b])); placeLabel(_label[b], c, 20 * u); }
    BOOL botw = [self botwTouchControlsActive];
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (b == B_L && [self botwTouchControlsActive]) {
            CGPoint c=[self runeButtonCenter]; CGFloat r=[self dropR:B_L];
            setPath(_key[b],circlePath(c,r)); placeLabel(_label[b],c,15*u);
            _key[b].lineWidth=1.5*DM_BOTW_STROKE_WIDTH_SCALE;
            CGFloat iconScale = _runeIconValid ? .68 : .5;
            _runeIconLayer.frame=CGRectMake(c.x-iconScale*r,c.y-iconScale*r,2*iconScale*r,2*iconScale*r);
            if (!_runeIconValid) _runeIconLayer.contents = (__bridge id)_runeDefaultIcon.CGImage;
            CGFloat br=.30*r; CGPoint bc=CGPointMake(c.x+M_SQRT1_2*r,c.y-M_SQRT1_2*r);
            setPath(_runeBadge,circlePath(bc,br)); _runeBadge.lineWidth=1.15*u*DM_BOTW_STROKE_WIDTH_SCALE;
            placeLabel(_runeBadgeLabel,bc,9*u);
            _runeIconLayer.hidden=NO; _runeBadge.hidden=_runeBadgeLabel.hidden=!_touchLayout.badges;
            _label[B_L].hidden=YES; continue;
        }
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], botw && right ? circlePath(c, [self dropR:b]) :
                dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u));
            placeLabel(_label[b], c, 16 * u);
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            if (botw && (b == B_PLUS || b == B_MINUS)) {
                CGRect rc = [self pillRect:b];
                CGPoint c = CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc));
                setPath(_botwMenuBg[b], circlePath(c, rc.size.width * .5));
                _botwMenuBg[b].hidden = _key[b].hidden;
                CGFloat glyphSize = rc.size.width * DM_TP_BOTW_MENU_GLYPH_SIZE / DM_TP_BOTW_MENU_SIZE;
                setPath(_key[b], dm_botw_menu_key_path(c, glyphSize, rc.size.width, b == B_PLUS));
            } else {
                if (b == B_PLUS || b == B_MINUS) _botwMenuBg[b].hidden = YES;
                CGRect rc = [self pillRect:b];
                setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
                _key[b].fillColor = k_idle.CGColor; _key[b].strokeColor = k_line.CGColor; _key[b].lineWidth = 1.5;
            }
        }
    }
    for (int b = 0; b < B_N; b++) if (_buttonIcon[b] && botw) {
        if (!_buttonIcon[b].contents)
            _buttonIcon[b].contents = (__bridge id)[UIImage imageWithContentsOfFile:dm_botw_touch_button_icon_path(b)].CGImage;
        CGRect disk = CGPathGetPathBoundingBox(_key[b].path);
        CGFloat size = disk.size.width * .5;
        _buttonIcon[b].frame = CGRectMake(CGRectGetMidX(disk)-size*.5, CGRectGetMidY(disk)-size*.5, size, size);
        CGRect badge = dm_botw_button_badge_rect(CGPointMake(CGRectGetMidX(disk),CGRectGetMidY(disk)), disk.size.width*.5);
        setPath(_buttonBadge[b], CGPathCreateWithEllipseInRect(badge, NULL));
        _buttonBadge[b].lineWidth = 1.15*u*DM_BOTW_STROKE_WIDTH_SCALE;
        placeLabel(_label[b], CGPointMake(CGRectGetMidX(badge),CGRectGetMidY(badge)), 9*u);
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], botw ? dm_botw_dpad_key_path(self.dpadCenter,self.dpadR,arms[i].b) :
        armPath(self.dpadCenter, self.dpadR, K_ARM_W * u * [self botwLayoutScale:B_LEFT], K_ARM_IN * u * [self botwLayoutScale:B_LEFT], arms[i].angle, 6 * u * [self botwLayoutScale:B_LEFT]));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    CGFloat stickUnit = u * (botw ? _moveResponse.size : 1);
    CGFloat k = K_KNOB_R * stickUnit; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject;
    CGPathRef ip = botw ? dm_botw_four_arrows_path(CGPointMake(k,k),17*stickUnit,12*stickUnit) : circlePath(CGPointMake(k,k),k*.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    CGPoint sh = _shieldTouch ? _shieldOrigin : self.shieldHome; CGFloat sr = self.shieldR;
    setPath(_shieldRing, circlePath(sh, sr));
    setPath(_shieldGraph, dm_botw_shield_graph_path(sh, u * [self botwLayoutScale:B_ZL]));
    CGPathRef direction = _shieldTouch ? dm_botw_stick_direction_path(sh, _shieldNow, sr, u * [self botwLayoutScale:B_ZL]) : NULL;
    _shieldRing.hidden = ![self botwTouchControlsActive] || !_shieldTouch;
    _shieldDirection.hidden = _shieldRing.hidden || !direction;
    if (direction) setPath(_shieldDirection, direction);
    int triggerHeld = -1;
    CGMutablePathRef cancelPath = CGPathCreateMutable();
    for (UITouch *t in _owner) {
        uint64_t v=[_owner objectForKey:t].unsignedLongLongValue;
        if ((v&0xff)==C_BTN && ((v>>8)==B_R || (v>>8)==B_ZR)) {
            int b=(int)(v>>8); if (triggerHeld < 0) triggerHeld=b;
            CGPoint c=[self dropCenter:b]; CGFloat r=DM_TP_CANCEL_RADIUS*u*[self botwLayoutScale:b];
            CGPathAddEllipseInRect(cancelPath, NULL, CGRectMake(c.x-r,c.y-r,2*r,2*r));
        }
    }
    _cancelRing.hidden = !(triggerHeld >= 0 && [self botwTouchControlsActive] && dm_botw_touch_actions_available());
    _cancelCue.hidden = _cancelRing.hidden;
    if (triggerHeld >= 0) {
        _cancelRing.path = cancelPath; _cancelRing.shadowPath = cancelPath;
        CGPoint c=[self dropCenter:triggerHeld]; CGFloat r=DM_TP_CANCEL_RADIUS*u*[self botwLayoutScale:triggerHeld], fs=10*u;
        _cancelCue.fontSize=fs; _cancelCue.frame=CGRectMake(c.x-3.2*fs,c.y-r-1.35*fs,6.4*fs,1.5*fs);
    }
    CGPathRelease(cancelPath);
    if (botw) {
        for (int b = 0; b < B_N; b++)
            if (b != B_PLUS && b != B_MINUS)
                setPath(_keyBorder[b], dm_botw_outer_border_path(_key[b].path, 1.5*DM_BOTW_STROKE_WIDTH_SCALE));
        for (int b = 0; b < B_N; b++) if (_buttonBadge[b])
            setPath(_buttonBadgeBorder[b], dm_botw_outer_border_path(_buttonBadge[b].path, _buttonBadge[b].lineWidth));
        setPath(_runeBadgeBorder, dm_botw_outer_border_path(_runeBadge.path, _runeBadge.lineWidth));
    }
    BOOL hideDpadArt = (botw && dm_botw_touch_loadout_visible()) || _padOff;
    _key[B_LEFT].hidden = _key[B_UP].hidden = _key[B_RIGHT].hidden = _key[B_DOWN].hidden = _tap || !_full || hideDpadArt;
    [CATransaction commit];
    [self publishTouchHudForController:atomic_load(&g_any_controller_connected)];
    [self refresh];
}
- (void)botwTouchActionChanged {
    if (![self botwTouchControlsActive]) return;
    for (uint64_t bit = DM_BTN_R; bit <= DM_BTN_ZR; bit <<= 1) {
        if ((_botwCancelPending & bit) && dm_botw_touch_cancel_complete(bit)) {
            _botwCancelPending &= ~bit;
            BOOL held = NO;
            for (UITouch *t in _owner) {
                uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
                if ((v & 0xff) == C_BTN && (1ull << (v >> 8)) == bit) held = YES;
            }
            if (!held) _botwCancelLatched &= ~bit;
        }
    }
    [self recompute];
}
#ifdef DM_TEST_HOOKS
- (void)dm_testSetTouchHudModeFull:(BOOL)full tap:(BOOL)tap connected:(BOOL)connected {
    _full = full; _tap = tap; _padOff = connected; _controls.hidden = connected;
    atomic_store(&g_any_controller_connected, connected);
    [self applyLayout];
    [self refreshBotwTouchMenuMode];
}
- (void)dm_testRefreshTouchHudMode { [self refreshTouchHudMode]; }
- (BOOL)dm_testIsFull { return _full; }
- (BOOL)dm_testIsTap { return _tap; }
- (BOOL)dm_testLeftStickRingHidden { return _ring.hidden; }
- (void)setFull:(BOOL)full {
    if (_full != full || _tap) [self reset];
    _full = full; _tap = NO; [self applyLayout];
}
- (BOOL)dm_testDpadArtworkHidden {
    return _key[B_LEFT].hidden && _key[B_UP].hidden && _key[B_RIGHT].hidden && _key[B_DOWN].hidden;
}
- (BOOL)dm_testMenuDpadHidden { return _menuDpad.hidden; }
- (BOOL)dm_testZLArtworkHidden { return _key[B_ZL].hidden; }
- (BOOL)dm_testL3ArtworkHidden { return _key[B_LS].hidden; }
- (BOOL)dm_testR3ArtworkHidden { return _key[B_RS].hidden; }
- (BOOL)dm_testMinusArtworkHidden { return _key[B_MINUS].hidden; }
- (BOOL)dm_testL3GestureEnabled { return _leftStickDoubleTap.enabled; }
- (BOOL)dm_testL3ReceiveTouch:(UITouch *)touch { return [self gestureRecognizer:_leftStickDoubleTap shouldReceiveTouch:touch]; }
- (BOOL)dm_testL3MayBegin { return [self gestureRecognizerShouldBegin:_leftStickDoubleTap]; }
- (BOOL)dm_testLeftStickOwnsPoint:(CGPoint)p { return [self leftStickOwnsPoint:p]; }
- (BOOL)dm_testSetBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height {
    [self setBotwMapRectValid:valid x:x y:y width:width height:height]; return _botwMapValid;
}
- (int)dm_testBtnAt:(CGPoint)p { return [self btnAt:p]; }
- (BOOL)dm_testBotwMapOwnsPoint:(CGPoint)p { return [self botwMapOwnsPoint:p]; }
- (CGPoint)dm_testShieldHome { return self.shieldHome; }
- (CAShapeLayer *)dm_testShieldGraphLayer { return _shieldGraph; }
- (CAShapeLayer *)dm_testShieldRingLayer { return _shieldRing; }
- (CAShapeLayer *)dm_testShieldDirectionLayer { return _shieldDirection; }
- (CAShapeLayer *)dm_testStickGraphLayer { return _knob; }
- (CAShapeLayer *)dm_testStickRingLayer { return _ring; }
- (CAShapeLayer *)dm_testStickDirectionLayer { return _stickDirection; }
- (BOOL)dm_testCancelGuideHidden { return _cancelRing.hidden && _cancelCue.hidden; }
- (CAShapeLayer *)dm_testRuneBadgeLayer { return _runeBadge; }
- (CALayer *)dm_testRuneIconLayer { return _runeIconLayer; }
- (void)dm_testSetTouchFeedback:(UIImpactFeedbackGenerator *)feedback { _touchFeedback = feedback; }
- (CGPoint)dm_testShieldRingCenter {
    CGRect r = CGPathGetBoundingBox(_shieldRing.path);
    return CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r));
}
- (CGPoint)dm_testStickHome { return self.stickHome; }
- (CGPoint)dm_testRuneButtonCenter { return [self runeButtonCenter]; }
- (CGPoint)dm_testMapBadgeCenter { return [self mapBadgeCenter]; }
- (CGPoint)dm_testDropCenter:(int)b { return [self dropCenter:b]; }
- (void)dm_testBotwTouchActionChanged { [self botwTouchActionChanged]; }
- (void)dm_testPulseBotwL3 { [self pulseBotwTouchButton:B_LS]; }
- (BOOL)dm_testControlsHidden { return _controls.hidden; }
- (UITapGestureRecognizer *)dm_testMenuPadGesture { return _menuPadDoubleTap; }
- (BOOL)dm_testManualMenuPad { return _manualMenuPad; }
- (CAShapeLayer *)dm_testButtonLayer:(int)b { return _key[b]; }
- (CAShapeLayer *)dm_testButtonBorder:(int)b { return _keyBorder[b]; }
- (CATextLayer *)dm_testButtonLabel:(int)b { return _label[b]; }
- (CAShapeLayer *)dm_testYBadgeBorder { return _buttonBadgeBorder[B_Y]; }
- (CAShapeLayer *)dm_testRuneBadgeBorder { return _runeBadgeBorder; }
- (CALayer *)dm_testYIconLayer { return _buttonIcon[B_Y]; }
- (CALayer *)dm_testButtonIcon:(int)b { return _buttonIcon[b]; }
- (CAShapeLayer *)dm_testYBadge { return _buttonBadge[B_Y]; }
- (CAShapeLayer *)dm_testButtonBadge:(int)b { return _buttonBadge[b]; }
- (CATextLayer *)dm_testYLabel { return _label[B_Y]; }
- (BOOL)dm_testSwapHidden { return _swap.hidden; }
- (BOOL)dm_testInSwap:(CGPoint)p { return [self inSwap:p]; }
- (void)dm_testNextLayout { [self nextLayout]; }
#endif
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    BOOL botw = [self botwTouchControlsActive];
    UIColor *idle = botw ? k_botwIdle : k_idle, *line = botw ? k_botwLine : k_line;
    UIColor *pressed = botw ? k_botwOn : k_on;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].shadowOpacity = botw ? 0 : .2;
        BOOL zeldaBadge = botw && b == B_L;
        if (zeldaBadge) {
            UIColor *cream = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:.98];
            UIColor *dark = [UIColor colorWithRed:.10 green:.12 blue:.12 alpha:on ? .98 : .82];
            _key[b].fillColor = (on ? pressed : idle).CGColor;
            _key[b].strokeColor = line.CGColor;
            _key[b].lineWidth = 1.5 * DM_BOTW_STROKE_WIDTH_SCALE;
            _label[b].foregroundColor = on ? dark.CGColor : cream.CGColor;
        } else {
            _key[b].fillColor = (on ? pressed : idle).CGColor;
            _key[b].strokeColor = line.CGColor;
            _key[b].lineWidth = 1.5 * (botw ? DM_BOTW_STROKE_WIDTH_SCALE : 1);
            _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor;
        }
        if (botw && (b == B_PLUS || b == B_MINUS)) {
            _key[b].fillColor = UIColor.whiteColor.CGColor;
            _key[b].strokeColor = nil;
            _label[b].foregroundColor = UIColor.whiteColor.CGColor;
        }
        if (botw && b >= B_LEFT && b <= B_DOWN) {
            _key[b].fillColor = [UIColor colorWithRed:226/255.0 green:222/255.0 blue:211/255.0 alpha:on ? 1 : .8].CGColor;
            _key[b].strokeColor = nil;
        }
        if (b == B_PLUS || b == B_MINUS) _label[b].hidden = botw;
    }
    for (int b = 0; b < B_N; b++) if (_buttonIcon[b]) {
        _buttonIcon[b].hidden = !botw;
        _buttonBadge[b].hidden = !botw || !_touchLayout.badges;
        _buttonBadge[b].shadowOpacity = 0;
        _buttonBadge[b].fillColor = [UIColor colorWithWhite:.20 alpha:1].CGColor;
        _buttonBadge[b].strokeColor = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:1].CGColor;
        _label[b].hidden = botw && !_touchLayout.badges;
        if (botw) _label[b].foregroundColor = _buttonBadge[b].strokeColor;
    }
    if (botw) _label[B_Y].foregroundColor = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:1].CGColor;
    CAShapeLayer *shapes[] = {_ring, _knob, _shieldRing, _runeBadge, _cancelRing};
    for (int i = 0; i < sizeof shapes / sizeof *shapes; i++) shapes[i].shadowOpacity = botw ? 0 : .2;
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0];
    if (!CGPointEqualToPoint(h, _ringAt)) { _ringAt = h; setPath(_ring, circlePath(h, [self stickR:0])); }
    _knob.position = botw ? h : CGPointMake(h.x+o.x,h.y+o.y);
    _knob.fillColor = botw ? NULL : (_stick[0] ? pressed : idle).CGColor;
    CGColorRef faint = [UIColor colorWithWhite:1 alpha:DM_BOTW_STICK_GRAPH_ALPHA].CGColor;
    _knob.strokeColor = botw ? faint : line.CGColor;
    CAShapeLayer *arrows = (CAShapeLayer *)_knob.sublayers.firstObject;
    arrows.strokeColor = botw ? NULL : line.CGColor; arrows.fillColor = botw ? faint : NULL;
    _ring.fillColor = botw ? NULL : k_ringFill.CGColor;
    _ring.strokeColor = line.CGColor;
    _ring.hidden = _tap || (botw && !_stick[0]);
    CGPathRef direction = botw && _stick[0] ? dm_botw_stick_direction_path(h,_stickNow[0],[self stickR:0],self.u*_moveResponse.size) : NULL;
    _stickDirection.hidden = !direction;
    if (direction) setPath(_stickDirection,direction);
    _shieldRing.fillColor = nil;
    _shieldRing.strokeColor = line.CGColor;
    _shieldRing.lineWidth = botw ? DM_BOTW_STICK_RING_WIDTH : 1.5;
    _ring.lineWidth = _shieldRing.lineWidth;
    if (botw) {
        _runeBadge.fillColor = _buttonBadge[B_Y].fillColor; _runeBadge.strokeColor = _buttonBadge[B_Y].strokeColor;
        _runeBadgeLabel.foregroundColor = _buttonBadge[B_Y].strokeColor;
        _cancelRing.strokeColor = line.CGColor;
    }
    for (int b = 0; b < B_N; b++)
        refreshBotwBorder(_key[b], _keyBorder[b], botw && b < B_LEFT && b != B_PLUS && b != B_MINUS);
    for (int b = 0; b < B_N; b++) if (_buttonBadge[b])
        refreshBotwBorder(_buttonBadge[b], _buttonBadgeBorder[b], botw);
    refreshBotwBorder(_runeBadge, _runeBadgeBorder, botw);
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO, anyConnected = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone) anyConnected = YES;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    atomic_store(&g_any_controller_connected, anyConnected);
    if (anyConnected && botwTouchHudSupported()) dm_input_cancel_virtual_latch(DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS);
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    BOOL anyConnected = now.count != 0;
    atomic_store(&g_any_controller_connected, anyConnected);
    if (anyConnected && botwTouchHudSupported()) dm_input_cancel_virtual_latch(DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS);
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    _botwLookTapPending = NO;
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    [self publishTouchHudForController:atomic_load(&g_any_controller_connected)];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any || (self->_botwMenuMode && !self->_botwCameraPadVisible && !self->_manualMenuPad && !botwSeated()); [self reset]; [self applyLayout]; [self refreshBotwTouchMenuMode]; [self setNeedsLayout]; });   // the touch gamepad hides while a controller is in use
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_geometry_changed(UIInterfaceOrientation orientation) {
    motion_update_flip_value(orientation);
    [g_view checkLookGeometry];
}
// Main-thread surface changes release only virtual input. Physical controller
// state belongs to its own connection/lifecycle path.
void dm_gamepad_surface_changed(void) {
    if (!strcmp(DM_GAME_ID,"01007EF00011E000")) {
        [g_view cancelSurfaceInput]; [g_view refreshBotwTouchMenuMode];
    }
}
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
