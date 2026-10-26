// Virtual gamepad (Nintendo button positions) + physical controllers (GameController). Tap keeps ordinary touches on the game's touch screen; BOTW relative-look mode separates the virtual and physical right-stick sources so the native scene observer can identify the sampled source.
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled "2D" / "3D" / "Tap") cycles layouts and persists the choice per game.
//   Tap sends non-layout touches to the game touch screen in handheld mode. 2D and 3D layouts follow the profile's default layout.
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their size), plus a D-pad (inward of and below the left stick, 8-way), an invisible right stick
//     (a touch landing in the right half of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius; games may use relative camera look instead) and L3 / R3.
//     BOTW hides both stick-click keys: L3 is a left-stick double tap and R3 is a short camera-area double tap; R/ZR share a row above the face cluster. Other games keep the visible R3 key and right-stick behavior.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3 where visible), then the D-pad and the diamond, then the left stick for a touch in the
//     lower-left area (its centre is the touch-down point), then in 3D relative camera look when enabled or the right stick for a touch in the right half.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (outside the left stick's area and, in 3D, the right half) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller).
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
#include "../../host/touchpad_geometry.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME, C_LOOK, C_BOTW_MAP, C_SHIELD, C_MENU, C_MENU_EXTRA };   // which control a touch holds; C_GAME uses a finger slot, C_LOOK is relative camera input

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_pad_btn, g_shake_btn;
static _Atomic int g_any_controller_connected;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry, g_pad_lx, g_pad_ly, g_pad_rx, g_pad_ry;
static int tilted(int32_t x, int32_t y) { return (int64_t)x * x + (int64_t)y * y > (int64_t)4000 * 4000; }
static void publish(void) {
    pthread_mutex_lock(&g_mu);
    int32_t lx = g_touch_lx, ly = g_touch_ly, rx = g_touch_rx, ry = g_touch_ry;
    if (dm_look_enabled()) {
        // Keep the legacy whole-vector left-stick choice and buttons on the ordinary input path.
        // Split only the right stick so BOTW can tell a virtual UI stick from a physical stick.
        if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }
        dm_input_set(g_touch_btn | g_shake_btn, lx, ly, g_touch_rx, g_touch_ry);
        dm_pad_set_player(0, g_pad_btn, 0, 0, g_pad_rx, g_pad_ry);
    } else {
        if (tilted(g_pad_lx, g_pad_ly)) { lx = g_pad_lx; ly = g_pad_ly; }   // a tilted physical stick wins
        if (tilted(g_pad_rx, g_pad_ry)) { rx = g_pad_rx; ry = g_pad_ry; }
        dm_input_set(g_touch_btn | g_pad_btn | g_shake_btn, lx, ly, rx, ry);
        dm_pad_set_player(0, 0, 0, 0, 0, 0);   // release a previously split physical source if look mode was disabled
    }
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
// dm_motion_set; the host turns the first sample into the neutral pose and reports the controller relative to it, and takes the pose again on the
// player's first touch or controller press (when the phone is held as they play). DM_MOTION=0 turns it off (the host then keeps the synthetic
// at-rest / shake sensor). Motion data needs no permission prompt.
// The interface can face either landscape way. A 180-degree turn of the phone between them must not turn the virtual controller: the sample is
// rotated 180 degrees about the device's Z axis while the interface is in the left landscape orientation, so its frame stays fixed to the screen.
static CMMotionManager *g_devmotion;
static _Atomic int g_motion_flip = -1;     // -1 = the interface orientation is not known yet, 0 = right, 1 = left
static _Atomic int g_motion_recenter;      // the next sample becomes the neutral pose
static int g_motion_published_first;       // motion_publish runs on one serial queue
static void motion_update_flip_value(UIInterfaceOrientation o) {
    if (o == UIInterfaceOrientationLandscapeLeft) atomic_store(&g_motion_flip, 1);
    else if (o == UIInterfaceOrientationLandscapeRight) atomic_store(&g_motion_flip, 0);   // portrait during launch: wait for a landscape
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
    if (flip) {   // q' = q * (0, 0, 1, 0); vectors turn with it: (x, y, z) -> (-x, -y, z)
        double w2 = -z, x2 = y, y2 = -x, z2 = w;
        w = w2; x = x2; y = y2; z = z2;
        a.x = -a.x; a.y = -a.y;
        r.x = -r.x; r.y = -r.y;
    }
    uint32_t flags = atomic_exchange(&g_motion_recenter, 0) ? DM_MOTION_RESET : 0;
    if (!g_motion_published_first) { g_motion_published_first = 1; flags |= DM_MOTION_RESET; }
    dm_motion mm = {{(float)a.x, (float)a.y, (float)a.z}, {(float)(r.x / (2 * M_PI)), (float)(r.y / (2 * M_PI)), (float)(r.z / (2 * M_PI))},
                    {(float)w, (float)x, (float)y, (float)z}, flags};
    dm_motion_set(&mm);
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
- (void)publishTouchHudForController:(BOOL)connected;
- (void)refreshTouchHudMode;
- (BOOL)leftStickOwnsPoint:(CGPoint)p;
- (void)leftStickDoubleTapped:(UITapGestureRecognizer *)recognizer;
- (BOOL)inSwap:(CGPoint)p;
- (BOOL)botwTouchControlsActive;
- (void)setBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height;
- (BOOL)botwMapOwnsPoint:(CGPoint)p;
- (void)botwTouchActionChanged;
- (void)botwRuneIconChanged;
- (void)refreshBotwRuneIcon;
- (void)clearBotwRuneIcon;
- (void)refreshBotwTouchMenuMode;
- (void)cancelBotwMenuPointer;
- (void)sendBotwMenuPointer:(int)phase point:(CGPoint)p;
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
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view refreshBotwTouchMenuMode]; });
}

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    UITouch *_leftAxisTouch, *_shieldTouch; CGPoint _shieldNow, _shieldOrigin;
    uint64_t _botwCancelPending, _botwCancelLatched;
    CGPoint _lCentre, _rCentre;                    // the stick centres: where their touches landed (the left one returns to the ring's home on release)
    CGPoint _ringAt;                               // where the left stick's ring is drawn now
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CALayer *_runeIconLayer; CAShapeLayer *_runeBadge; CATextLayer *_runeBadgeLabel;
    uint64_t _runeIconGeneration; BOOL _runeIconValid;
    CAShapeLayer *_ring, *_knob, *_shieldRing, *_shieldKnob, *_cancelRing; // the left stick and BOTW controls
    CATextLayer *_shieldLabel, *_cancelCue;
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld; CFTimeInterval _swapT0;
    UITapGestureRecognizer *_leftStickDoubleTap;
    CGRect _botwMapRect; BOOL _botwMapValid, _botwMapTapConsumed, _botwMapInvalidAfterTap;
    BOOL _botwMenuMode, _botwMenuPointerActive, _botwMapGestureSuppressed;
    UITouch *_botwMenuTouch; CGPoint _botwMenuLast, _botwMenuLastNorm;
    UITouch *_botwMapPinchTouch; CGFloat _botwMapPinchStart;
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    UITouch *_lookTouch; CGPoint _lookLast, _lookDown, _botwLookTapPoint; CGFloat _lookScale; CFTimeInterval _lookDownTime, _botwLookTapTime; BOOL _lookDragged, _botwLookTapPending;
    CGSize _lookBoundsSize; UIInterfaceOrientation _lookOrientation; BOOL _lookGeometryKnown;
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout
static BOOL botwTouchHudSupported(void) { return dm_botw_touch_hud_available(); }

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
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
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        _shieldRing = shape(_controls); _shieldRing.fillColor = k_ringFill.CGColor;
        _shieldKnob = shape(_controls);
        _shieldLabel = label(_controls, @"ZL"); _shieldLabel.hidden = YES;
        _cancelRing = shape(_controls); _cancelRing.fillColor = nil; _cancelRing.strokeColor = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:.8].CGColor; _cancelRing.hidden = YES;
        _cancelCue = label(_controls, @"Cancel"); _cancelCue.hidden = YES;
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _runeIconLayer = [CALayer layer];
        _runeIconLayer.contentsGravity = kCAGravityResizeAspect;
        _runeIconLayer.contentsScale = UIScreen.mainScreen.scale;
        _runeIconLayer.hidden = YES;
        // These layers use the full control-canvas coordinate system, like
        // the paths set in layoutSubviews. The button shape has no local frame.
        [_controls addSublayer:_runeIconLayer];
        _runeBadge = shape(_controls); _runeBadge.hidden = YES;
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
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (botwTouchHudSupported()) l = 1;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged) name:GCControllerDidDisconnectNotification object:nil];
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        [nc addObserver:self selector:@selector(deviceOrientationChanged) name:UIDeviceOrientationDidChangeNotification object:nil];
        [self padsChanged];
        motion_start();
        motion_device_start();
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    BOOL botwActive = [self botwTouchControlsActive];
    if (!botwActive && botwTouchHudSupported()) dm_botw_touch_sprint_request(0);
    _key[B_ZL].hidden = _tap || botwActive;
    _shieldRing.hidden = _shieldKnob.hidden = !botwActive;
    _shieldLabel.hidden = !botwActive;
    if (!botwActive) _botwLookTapPending = NO;
    _key[B_LS].hidden = botwActive || _tap || !_full;
    _key[B_RS].hidden = botwActive || _tap || !_full;
    [self refreshBotwRuneIcon];
    _key[B_MINUS].hidden = _tap || (botwActive && _botwMapValid);
    _leftStickDoubleTap.enabled = botwActive && !_botwMenuMode;
    BOOL hideDpadArt = [self botwTouchControlsActive] || _padOff;
    _key[B_LEFT].hidden = _key[B_UP].hidden = _key[B_RIGHT].hidden = _key[B_DOWN].hidden = _tap || !_full || hideDpadArt;
    _ring.hidden = _knob.hidden = _tap;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    _swap.hidden = botwTouchHudSupported();
    [CATransaction commit];
    [self publishTouchHudForController:atomic_load(&g_any_controller_connected)];
}
- (void)publishTouchHudForController:(BOOL)connected {
    BOOL active = botwTouchHudSupported() && _full && !_tap && !connected;
    if (!active || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) {
        dm_botw_touch_hud_publish(0, 0, 0);
        [self setBotwMapRectValid:NO x:0 y:0 width:0 height:0];
        return;
    }
    CGPoint c = self.dpadCenter;
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    float x = (float)((c.x - rect[0]) / rect[2]);
    float y = (float)((c.y - rect[1]) / rect[3]);
    dm_botw_touch_hud_publish(1, x, y);
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
    BOOL hideDpadArt = botwActive || _padOff;
    _key[B_ZL].hidden = _tap || botwActive;
    _shieldRing.hidden = _shieldKnob.hidden = !botwActive;
    _shieldLabel.hidden = !botwActive;
    _key[B_LS].hidden = botwActive || _tap || !_full;
    _key[B_RS].hidden = botwActive || _tap || !_full;
    [self refreshBotwRuneIcon];
    _key[B_MINUS].hidden = _tap || (botwActive && _botwMapValid);
    _leftStickDoubleTap.enabled = botwActive;
    _key[B_LEFT].hidden = _key[B_UP].hidden = _key[B_RIGHT].hidden = _key[B_DOWN].hidden = _tap || !_full || hideDpadArt;
    _swap.hidden = botwTouchHudSupported();
    [self publishTouchHudForController:atomic_load(&g_any_controller_connected)];
    [self refreshBotwTouchMenuMode];
    [self setNeedsLayout];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    if (botwTouchHudSupported()) return;
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_rect r = dm_touchpad_corner_rect(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGRectMake(r.x, r.y, r.width, r.height); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return dm_touchpad_u((float)self.bounds.size.height); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_face_center(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_face_button(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom, b); return CGPointMake(p.x, p.y); }
- (CGPoint)stickHome { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_stick_home(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }   // the left stick's ring centre
- (CGPoint)shieldHome { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_shield_stick_home(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }
- (CGPoint)mapBadgeCenter {
    if (![self botwTouchControlsActive] || !_botwMapValid) {
        CGRect r=[self pillRect:B_PLUS]; return CGPointMake(CGRectGetMidX(r),CGRectGetMidY(r));
    }
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    dm_touchpad_rect map = (dm_touchpad_rect){(float)_botwMapRect.origin.x, (float)_botwMapRect.origin.y,
                                              (float)_botwMapRect.size.width, (float)_botwMapRect.size.height};
    dm_touchpad_point p = dm_touchpad_map_badge(rect[0], rect[1], rect[2], rect[3], map,
                                                DM_TP_MAP_BADGE_WIDTH * self.u, DM_TP_MAP_BADGE_HEIGHT * self.u);
    return CGPointMake(p.x, p.y);
}
- (CGPoint)runeButtonCenter {
    UIEdgeInsets i=self.safeAreaInsets;
    dm_touchpad_point p=dm_touchpad_rune_button(self.bounds.size.width,self.bounds.size.height,i.left,i.top,i.right,i.bottom);
    return CGPointMake(p.x,p.y);
}
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : (_stick[0] ? _lCentre : self.stickHome); }
- (CGFloat)stickR:(int)i { return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (BOOL)inLeftArea:(CGPoint)p { CGRect b = self.bounds; return p.x < b.size.width * K_LSWIPE && p.y > CGRectGetMidY(b); }   // lower-left: the left stick starts where the touch lands
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { UIEdgeInsets i = self.safeAreaInsets; dm_touchpad_point p = dm_touchpad_dpad_center(self.bounds.size.width, self.bounds.size.height, i.left, i.top, i.right, i.bottom); return CGPointMake(p.x, p.y); }
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    if ([self botwTouchControlsActive] && b == B_ZL) return self.shieldHome;
    if ([self botwTouchControlsActive] && (b == B_ZR || b == B_R)) {
        dm_touchpad_point p = dm_touchpad_right_shoulder(self.bounds.size.width, self.bounds.size.height,
            s.origin.x, s.origin.y, CGRectGetMaxX(self.bounds)-CGRectGetMaxX(s), CGRectGetMaxY(self.bounds)-CGRectGetMaxY(s), b == B_ZR);
        return CGPointMake(p.x, p.y);
    }
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (BOOL)botwTouchControlsActive { return botwTouchHudSupported() && _full && !_tap && !_padOff && !_botwMenuMode && !atomic_load(&g_any_controller_connected); }

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
- (void)refreshBotwTouchMenuMode {
    BOOL active = botwTouchHudSupported() && !atomic_load(&g_any_controller_connected) && dm_botw_touch_menu_active();
    if (_botwMenuMode == active) return;
    [self reset];
    if (botwTouchHudSupported()) dm_input_cancel_virtual_latch(0xffffull);
    _botwMenuMode = active;
    _leftStickDoubleTap.enabled = !active && [self botwTouchControlsActive];
    _controls.hidden = _padOff || _botwMenuMode;
    [self setNeedsLayout];
}
- (void)clearBotwRuneIcon {
    _runeIconLayer.contents = nil; _runeIconLayer.hidden = YES;
    _runeBadge.hidden = YES; _runeBadgeLabel.hidden = YES;
    _runeIconValid = NO;
    _label[B_L].hidden = NO;
}
- (void)refreshBotwRuneIcon {
    if (![self botwTouchControlsActive]) {
        [self clearBotwRuneIcon]; _runeIconGeneration = 0; return;
    }
    dm_botw_rune_icon_state snapshot = {0};
    if (!dm_botw_rune_icon_snapshot(&snapshot) || snapshot.generation < _runeIconGeneration) return;
    if (snapshot.generation == _runeIconGeneration) return;
    _runeIconGeneration = snapshot.generation;
    [self clearBotwRuneIcon];
    CGImageRef image = botwRuneImage(&snapshot);
    if (!image) return;
    _runeIconLayer.contents = (__bridge id)image;
    _runeIconLayer.hidden = NO;
    _runeBadge.hidden = NO; _runeBadgeLabel.hidden = NO;
    _runeIconValid = YES;
    _label[B_L].hidden = YES;
    CGImageRelease(image);
}
- (void)botwRuneIconChanged {
    [self refreshBotwRuneIcon]; [self setNeedsLayout];
}
- (void)setBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height {
    CGRect oldRect = _botwMapRect;
    BOOL oldValid = _botwMapValid, oldConsumed = _botwMapTapConsumed, oldInvalidAfterTap = _botwMapInvalidAfterTap;
    BOOL active = [self botwTouchControlsActive];
    if (!active) { _botwMapTapConsumed = NO; _botwMapInvalidAfterTap = NO; }
    if (!valid || !active || !isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) {
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
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    if (rect[2] <= 0 || rect[3] <= 0) return NO;
    CGPoint normalized = CGPointMake((p.x - rect[0]) / rect[2], (p.y - rect[1]) / rect[3]);
    return CGRectContainsPoint(_botwMapRect, normalized);
}
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    if ([self botwTouchControlsActive] && dist(p, [self runeButtonCenter]) <= K_L_R * u * 1.45) return B_L;
    if ([self botwTouchControlsActive] && dist(p, self.shieldHome) <= DM_TP_STICK_R * u * 1.35) return B_ZL;
    if ([self botwTouchControlsActive]) {
        CGPoint c = [self mapBadgeCenter];
        dm_touchpad_rect r = dm_touchpad_map_badge_rect((float)c.x, (float)c.y, (float)u);
        if (dm_touchpad_rounded_rect_contains(r, DM_TP_MAP_BADGE_RADIUS*u, (float)p.x, (float)p.y)) return B_PLUS;
    }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        if ([self botwTouchControlsActive] && b == B_L) continue;
        if ([self botwTouchControlsActive] && b == B_PLUS) continue;
        if ([self botwTouchControlsActive] && (b == B_R || b == B_ZR) && (_botwCancelLatched & (1ull << b))) continue;
        if ([self botwTouchControlsActive] && b == B_LS) continue;
        if ([self botwTouchControlsActive] && b == B_RS) continue;
        if ([self botwTouchControlsActive] && (_botwMapValid || _botwMapTapConsumed) && b == B_MINUS) continue;
        BOOL botwRightShoulder = [self botwTouchControlsActive] && (b == B_ZR || b == B_R);
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * (botwRightShoulder ? DM_TP_SHOULDER_HIT_SCALE : 1.35)
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)leftStickOwnsPoint:(CGPoint)p {
    if (![self botwTouchControlsActive] || _tap || [self btnAt:p] >= 0 || [self inSwap:p]) return NO;
    CGFloat best = 1;
    int kind = C_NONE;
    CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6);
    if (f <= best) { best = f; kind = C_FACE; }
    if (_full) {
        CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB);
        if (d < best) { best = d; kind = C_DPAD; }
    }
    if (!_stick[0]) {
        CGFloat sl = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB);
        if (sl < best) { kind = C_STICK; }
    }
    return kind == C_STICK;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == _leftStickDoubleTap)
        return [self leftStickOwnsPoint:[touch locationInView:self]];
    return YES;
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
- (void)leftStickDoubleTapped:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized && [self botwTouchControlsActive])
        [self pulseBotwTouchButton:B_LS];
}
- (BOOL)inSwap:(CGPoint)p { return !botwTouchHudSupported() && dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    CGPoint c = self.faceCenter;
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
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    // Keep a canceled trigger published even after its finger lifts. The native
    // sequencer needs one or more real Npad samples to observe R/ZR with B.
    btn |= _botwCancelPending;
    int32_t ax[4] = {0};
    BOOL sprintRequested = NO;
    if (_leftAxisTouch) {
        uint64_t own = [_owner objectForKey:_leftAxisTouch].unsignedLongLongValue;
        CGPoint p = (own & 0xff) == C_SHIELD ? _shieldNow : _stickNow[0];
        CGPoint h = (own & 0xff) == C_SHIELD ? _shieldOrigin : [self stickCentre:0];
        dm_touchpad_stick_axis((float)(p.x-h.x), (float)(p.y-h.y), (float)[self stickR:0], 0, &ax[0], &ax[1]);
        BOOL ordinaryLeftStickOwnsAxis = [self botwTouchControlsActive] &&
            (own & 0xff) == C_STICK && (own >> 8) == 0 && _stick[0] == _leftAxisTouch;
        sprintRequested = ordinaryLeftStickOwnsAxis && dm_touchpad_sprint_requested(dist(p, h), [self stickR:0]);
    } else if (_stick[0]) {
        CGPoint o = [self knobOffset:0]; dm_touchpad_stick_axis((float)o.x,(float)o.y,(float)[self stickR:0],0,&ax[0],&ax[1]);
    }
    if (botwTouchHudSupported()) dm_botw_touch_sprint_request(sprintRequested);
    CGPoint o = [self knobOffset:1]; CGFloat R = [self stickR:1];
    dm_touchpad_stick_axis((float)o.x, (float)o.y, (float)R, !dm_look_enabled(), &ax[2], &ax[3]);
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
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
    UIInterfaceOrientation orientation = self.window.windowScene.effectiveGeometry.interfaceOrientation;
    if (!_lookGeometryKnown) { _lookBoundsSize = size; _lookOrientation = orientation; _lookGeometryKnown = YES; return; }
    BOOL resized = !CGSizeEqualToSize(size, _lookBoundsSize);
    BOOL rotated = orientation != UIInterfaceOrientationUnknown && _lookOrientation != UIInterfaceOrientationUnknown && orientation != _lookOrientation;
    _lookBoundsSize = size;
    if (orientation != UIInterfaceOrientationUnknown) _lookOrientation = orientation;
    if (resized || rotated) { [self cancelLook]; [self cancelBotwMenuPointer]; }
}
- (void)beginLook:(UITouch *)t at:(CGPoint)p {
    [self checkLookGeometry];
    [_owner setObject:@(C_LOOK) forKey:t];
    if (_lookTouch) { _botwLookTapPending = NO; _lookDragged = YES; return; } // overlapping camera fingers cancel tap recognition
    if (!dm_look_enabled()) return;
    CGFloat scale = MIN(self.bounds.size.width, self.bounds.size.height);
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
    if (ts.count > 1) _botwLookTapPending = NO;
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_botwMenuMode) {
            // The host owns menu hit testing and gestures. Keep only one primary
            // pointer and never let extra touches fall through to gameplay.
            if (_botwMapGestureSuppressed) {
                // A pinch remains one gesture until every finger lifts. Do not
                // let a replacement finger become a new pointer mid-gesture.
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
            } else if (!_botwMenuTouch) {
                CGPoint p = [t locationInView:self];
                _botwMenuPointerActive = YES; _botwMenuTouch = t; _botwMenuLast = p;
                [_owner setObject:@(C_MENU) forKey:t];
                [self sendBotwMenuPointer:DM_BOTW_MENU_BEGIN point:p];
            } else if (dm_botw_touch_map_active() && !_botwMapPinchTouch && !_botwMapGestureSuppressed) {
                // A second finger on the live map pinches: its spread drives
                // the native right-stick zoom, and the primary finger stops
                // panning until it lifts.
                _botwMapPinchTouch = t;
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
                _botwMapGestureSuppressed = YES;
                CGPoint a = [_botwMenuTouch locationInView:self], b = [t locationInView:self];
                _botwMapPinchStart = fmax(1.0, dist(a, b));
                if (_botwMenuPointerActive) {
                    [self sendBotwMenuPointer:DM_BOTW_MENU_CANCEL point:_botwMenuLast];
                    _botwMenuPointerActive = NO;
                }
                dm_botw_touch_menu_pinch(1.0f);
            } else {
                [_owner setObject:@(C_MENU_EXTRA) forKey:t];
            }
            continue;
        }
        if (_padOff) { _botwLookTapPending = NO; game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        int hit = _tap ? -1 : [self btnAt:p];
        if ([self botwTouchControlsActive] && hit == B_L) {
            _botwLookTapPending = NO; [_owner setObject:@(C_BTN | (uint64_t)B_L << 8) forKey:t]; continue;
        }
        if ([self botwTouchControlsActive] && !_shieldTouch && dist(p, self.shieldHome) <= [self stickR:0] * K_STICK_GRAB) {
            _botwLookTapPending = NO; _shieldTouch = _leftAxisTouch = t; _shieldNow = _shieldOrigin = p;
            [_owner setObject:@(C_SHIELD) forKey:t]; [self setNeedsLayout]; continue;
        }
        if (hit >= 0) { _botwLookTapPending = NO; [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { _botwLookTapPending = NO; [_owner setObject:@(C_SWAP) forKey:t]; _swapT0 = CACurrentMediaTime(); continue; }
        if ([self leftStickOwnsPoint:p]) {
            _botwLookTapPending = NO;
            // Keep the existing dynamic left-stick grab ahead of the map clip
            // where their rectangular bounds meet near the lower-left edge.
            [_owner setObject:@(C_STICK) forKey:t]; _stick[0] = t; _stickNow[0] = p; _lCentre = p; _leftAxisTouch = t; continue;
        }
        if ([self botwMapOwnsPoint:p]) {
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
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat sl = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (sl < best) { best = sl; kind = C_STICK; } }
        if (kind == C_NONE && _full && [self inRightArea:p]) {
            if (dm_look_enabled()) { [self beginLook:t at:p]; continue; }
            if (!_stick[1]) { kind = C_STICK; idx = 1; _rCentre = p; }
        }
        _botwLookTapPending = NO;
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) {
            [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p;
            if (!idx) _leftAxisTouch = t;
            if (idx) _rCentre = p; else _lCentre = p;   // both sticks start where the finger lands
        }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    [self refreshBotwTouchMenuMode];
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_MENU && t == _botwMenuTouch) {
            _botwMenuLast = p;
            if (_botwMapGestureSuppressed && _botwMapPinchTouch) {
                CGPoint a = [_botwMenuTouch locationInView:self], b = [_botwMapPinchTouch locationInView:self];
                dm_botw_touch_menu_pinch((float)(dist(a, b) / _botwMapPinchStart));
            } else if (_botwMenuPointerActive && !_botwMapGestureSuppressed) [self sendBotwMenuPointer:DM_BOTW_MENU_MOVE point:p];
        }
        else if (t == _botwMapPinchTouch && _botwMenuTouch) {
            CGPoint a = [_botwMenuTouch locationInView:self], b = [t locationInView:self];
            dm_botw_touch_menu_pinch((float)(dist(a, b) / _botwMapPinchStart));
        }
        else if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_SHIELD) { _shieldNow = p; [self setNeedsLayout]; }
        else if (c == C_BTN && [self botwTouchControlsActive] && ((v >> 8) == B_R || (v >> 8) == B_ZR)) [self setNeedsLayout];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
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
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (t == _botwMapPinchTouch) {
            dm_botw_touch_menu_pinch(0.0f);
            _botwMapPinchTouch = nil; _botwMapPinchStart = 0;
        }
        if ((v & 0xff) == C_MENU && t == _botwMenuTouch) {
            if (_botwMapPinchTouch) { dm_botw_touch_menu_pinch(0.0f); _botwMapPinchTouch = nil; _botwMapPinchStart = 0; }
            if (_botwMenuPointerActive) {
                CGPoint p = [t locationInView:self]; _botwMenuLast = p;
                [self sendBotwMenuPointer:ended ? DM_BOTW_MENU_END : DM_BOTW_MENU_CANCEL point:p];
            }
            _botwMenuPointerActive = NO; _botwMenuTouch = nil;
        }
        if ((v & 0xff) == C_LOOK) [self endLook:t at:[t locationInView:self] cancelled:!ended];
        if ((v & 0xff) == C_BTN && [self botwTouchControlsActive] && ((v >> 8) == B_R || (v >> 8) == B_ZR)) {
            uint64_t bit = 1ull << (v >> 8);
            CGPoint p = [t locationInView:self], center = [self dropCenter:(int)(v >> 8)];
            if (ended && dm_botw_touch_actions_available() && !((_botwCancelPending | _botwCancelLatched) & bit) &&
                dm_touchpad_cancel_outside((float)p.x, (float)p.y, (float)center.x, (float)center.y, DM_TP_CANCEL_RADIUS * self.u)) {
                _botwCancelLatched |= bit; _botwCancelPending |= bit; dm_botw_touch_cancel_trigger(bit);
            }
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
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset {
    [self cancelBotwMenuPointer];
    _botwMenuTouch = nil;
    _botwMapGestureSuppressed = NO;
    if (_botwMapPinchTouch) { dm_botw_touch_menu_pinch(0.0f); _botwMapPinchTouch = nil; _botwMapPinchStart = 0; }
    if (botwTouchHudSupported()) { dm_botw_touch_actions_reset(); dm_botw_touch_sprint_request(0); }
    if (botwTouchHudSupported()) dm_input_cancel_virtual_latch(DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS);
    [self cancelLook]; [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil;
    _leftAxisTouch = _shieldTouch = nil; _shieldNow = _shieldOrigin = CGPointZero; _botwCancelPending = _botwCancelLatched = 0;
    for (int i = 0; i < 16; i++) _game[i] = nil;
    [self pushGame]; [self recompute];
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

- (void)deviceOrientationChanged { motion_update_flip(self.window.windowScene); [self checkLookGeometry]; }
- (void)layoutSubviews {
    [super layoutSubviews];
    motion_update_flip(self.window.windowScene);
    [self checkLookGeometry];
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (b == B_L && [self botwTouchControlsActive]) {
            CGPoint c=[self runeButtonCenter]; CGFloat r=K_L_R*u;
            setPath(_key[b],circlePath(c,r)); placeLabel(_label[b],c,15*u);
            _key[b].fillColor=[UIColor colorWithRed:.10 green:.12 blue:.12 alpha:.82].CGColor;
            _key[b].strokeColor=[UIColor colorWithRed:.94 green:.88 blue:.70 alpha:.98].CGColor;
            _key[b].lineWidth=2*u;
            _runeIconLayer.frame=CGRectMake(c.x-.68*r,c.y-.68*r,1.36*r,1.36*r);
            CGFloat br=.29*r; CGPoint bc=CGPointMake(c.x+.63*r,c.y-.63*r);
            setPath(_runeBadge,circlePath(bc,br)); _runeBadge.lineWidth=1.15*u;
            placeLabel(_runeBadgeLabel,bc,7.5*u);
            _runeIconLayer.hidden=!_runeIconValid; _runeBadge.hidden=!_runeIconValid; _runeBadgeLabel.hidden=!_runeIconValid;
            _label[B_L].hidden=_runeIconValid; continue;
        }
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            if ((b == B_PLUS && [self botwTouchControlsActive]) ||
                (b == B_L && [self botwTouchControlsActive])) {
                CGPoint c = b == B_PLUS ? [self mapBadgeCenter] : [self runeButtonCenter];
                CGFloat r = (b == B_PLUS ? DM_TP_MAP_BADGE_RADIUS : K_L_R) * u;
                if (b == B_PLUS) {
                    dm_touchpad_rect badge = dm_touchpad_map_badge_rect((float)c.x,(float)c.y,(float)u);
                    setPath(_key[b], CGPathCreateWithRoundedRect(CGRectMake(badge.x,badge.y,badge.width,badge.height),DM_TP_MAP_BADGE_RADIUS*u,DM_TP_MAP_BADGE_RADIUS*u,NULL));
                } else setPath(_key[b], circlePath(c, r));
                placeLabel(_label[b], c, 15 * u);
                _key[b].fillColor = (b == B_PLUS ? UIColor.whiteColor : [UIColor colorWithRed:0.10 green:0.12 blue:0.12 alpha:0.82]).CGColor;
                _key[b].strokeColor = (b == B_PLUS ? [UIColor colorWithRed:0.10 green:0.12 blue:0.12 alpha:0.98] : [UIColor colorWithRed:0.94 green:0.88 blue:0.70 alpha:0.98]).CGColor;
                _key[b].lineWidth = 2.0 * u;
            } else {
                CGRect rc = [self pillRect:b];
                setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
                _key[b].fillColor = k_idle.CGColor; _key[b].strokeColor = k_line.CGColor; _key[b].lineWidth = 1.5;
            }
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    CGPoint sh = _shieldTouch ? _shieldOrigin : self.shieldHome; CGFloat sr = [self stickR:0];
    setPath(_shieldRing, circlePath(sh, sr));
    CGPoint sk = sh;
    if (_shieldTouch) {
        CGFloat dx = _shieldNow.x-_shieldOrigin.x, dy = _shieldNow.y-_shieldOrigin.y, d = hypot(dx,dy);
        if (d > sr) { dx *= sr/d; dy *= sr/d; }
        sk = CGPointMake(_shieldOrigin.x+dx, _shieldOrigin.y+dy);
    }
    CGFloat sks = K_KNOB_R*u;
    _shieldKnob.bounds = CGRectMake(0,0,2*sks,2*sks);
    setPath(_shieldKnob, circlePath(CGPointMake(sks,sks),sks));
    _shieldKnob.position = sk;
    placeLabel(_shieldLabel, sh, 15*u);
    int triggerHeld = -1;
    CGMutablePathRef cancelPath = CGPathCreateMutable();
    for (UITouch *t in _owner) {
        uint64_t v=[_owner objectForKey:t].unsignedLongLongValue;
        if ((v&0xff)==C_BTN && ((v>>8)==B_R || (v>>8)==B_ZR)) {
            int b=(int)(v>>8); if (triggerHeld < 0) triggerHeld=b;
            CGPoint c=[self dropCenter:b]; CGFloat r=DM_TP_CANCEL_RADIUS*u;
            CGPathAddEllipseInRect(cancelPath, NULL, CGRectMake(c.x-r,c.y-r,2*r,2*r));
        }
    }
    _cancelRing.hidden = !(triggerHeld >= 0 && [self botwTouchControlsActive] && dm_botw_touch_actions_available());
    _cancelCue.hidden = _cancelRing.hidden;
    if (triggerHeld >= 0) {
        _cancelRing.path = cancelPath; _cancelRing.shadowPath = cancelPath;
        CGPoint c=[self dropCenter:triggerHeld]; CGFloat r=DM_TP_CANCEL_RADIUS*u, fs=10*u;
        _cancelCue.fontSize=fs; _cancelCue.frame=CGRectMake(c.x-3.2*fs,c.y-r-1.35*fs,6.4*fs,1.5*fs);
    }
    CGPathRelease(cancelPath);
    BOOL hideDpadArt = [self botwTouchControlsActive] || _padOff;
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
- (BOOL)dm_testZLArtworkHidden { return _key[B_ZL].hidden; }
- (BOOL)dm_testL3ArtworkHidden { return _key[B_LS].hidden; }
- (BOOL)dm_testR3ArtworkHidden { return _key[B_RS].hidden; }
- (BOOL)dm_testMinusArtworkHidden { return _key[B_MINUS].hidden; }
- (BOOL)dm_testL3GestureEnabled { return _leftStickDoubleTap.enabled; }
- (BOOL)dm_testLeftStickOwnsPoint:(CGPoint)p { return [self leftStickOwnsPoint:p]; }
- (BOOL)dm_testSetBotwMapRectValid:(BOOL)valid x:(CGFloat)x y:(CGFloat)y width:(CGFloat)width height:(CGFloat)height {
    [self setBotwMapRectValid:valid x:x y:y width:width height:height]; return _botwMapValid;
}
- (int)dm_testBtnAt:(CGPoint)p { return [self btnAt:p]; }
- (BOOL)dm_testBotwMapOwnsPoint:(CGPoint)p { return [self botwMapOwnsPoint:p]; }
- (CGPoint)dm_testShieldHome { return self.shieldHome; }
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
- (BOOL)dm_testSwapHidden { return _swap.hidden; }
- (BOOL)dm_testInSwap:(CGPoint)p { return [self inSwap:p]; }
- (void)dm_testNextLayout { [self nextLayout]; }
#endif
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        BOOL zeldaBadge = [self botwTouchControlsActive] && (b == B_L || b == B_PLUS);
        if (zeldaBadge) {
            UIColor *cream = [UIColor colorWithRed:.94 green:.88 blue:.70 alpha:.98];
            UIColor *dark = [UIColor colorWithRed:.10 green:.12 blue:.12 alpha:on ? .98 : .82];
            BOOL plus = b == B_PLUS;
            _key[b].fillColor = (plus ? (on ? [UIColor colorWithWhite:.88 alpha:1] : UIColor.whiteColor) : (on ? cream : dark)).CGColor;
            _key[b].strokeColor = (plus ? dark : cream).CGColor;
            _key[b].lineWidth = 2.0 * self.u;
            _label[b].foregroundColor = plus ? dark.CGColor : (on ? dark.CGColor : cream.CGColor);
        } else {
            _key[b].fillColor = (on ? k_on : k_idle).CGColor;
            _key[b].strokeColor = k_line.CGColor;
            _key[b].lineWidth = 1.5;
            _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor;
        }
    }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0];
    if (!CGPointEqualToPoint(h, _ringAt)) { _ringAt = h; setPath(_ring, circlePath(h, [self stickR:0])); }
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    [CATransaction commit];
}

// ---- Physical controllers ----
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    dm_haptics_apple_controller(0, g.controller);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    if (m || fabsf(g.leftThumbstick.xAxis.value) > 0.15f || fabsf(g.leftThumbstick.yAxis.value) > 0.15f ||
        fabsf(g.rightThumbstick.xAxis.value) > 0.15f || fabsf(g.rightThumbstick.yAxis.value) > 0.15f) motion_first_input();
    pthread_mutex_lock(&g_mu);
    g_pad_btn = m; g_pad_lx = axis(g.leftThumbstick.xAxis.value); g_pad_ly = axis(g.leftThumbstick.yAxis.value);
    g_pad_rx = axis(g.rightThumbstick.xAxis.value); g_pad_ry = axis(g.rightThumbstick.yAxis.value);
    pthread_mutex_unlock(&g_mu);
    publish();
}
- (void)padsChanged {
    _botwLookTapPending = NO;
    BOOL anyExtended = NO;
    BOOL anyConnected = GCController.controllers.count != 0;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) {
        anyExtended = YES;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        read_pad(c.extendedGamepad);
    }
    atomic_store(&g_any_controller_connected, anyConnected);
    if (anyConnected && botwTouchHudSupported()) dm_input_cancel_virtual_latch(DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS);
    if (!anyExtended) { dm_haptics_apple_controller(0, nil); pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish(); }
    [self publishTouchHudForController:anyConnected];   // BOTW customizations stop for any connected pad; ordinary pad routing remains extended-only
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = anyExtended; self->_controls.hidden = anyExtended || self->_botwMenuMode; [self reset]; [self applyLayout]; [self refreshBotwTouchMenuMode]; [self setNeedsLayout]; });
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_geometry_changed(UIInterfaceOrientation orientation) {
    motion_update_flip_value(orientation);
    [g_view checkLookGeometry];
}
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_pad_btn = 0; g_shake_btn = 0; g_pad_lx = g_pad_ly = g_pad_rx = g_pad_ry = 0; pthread_mutex_unlock(&g_mu); publish();
}
