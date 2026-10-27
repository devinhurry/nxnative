// Mac front end: with DM_WINDOW=1 open a window (CAMetalLayer, for the graphics backend to present frames) + keyboard and controllers → dm_input; the guest runs on a large-stack thread instead and the main thread belongs to AppKit.
// Without DM_WINDOW: the guest runs directly on the current thread, behaving the same as with no front end (windowless tests use this).
// The window is fullscreen-capable (the green button and ⌃⌘F); DM_FULLSCREEN starts it that way. ⌘Q quits; the left mouse button is the touchscreen, except BOTW uses it for look while enabled.
// Key map (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F=press left stick G=press right stick, Return=+ Tab=−, Space=shake the controller.
// Controllers: buttons by position as on the iPhone (right A, bottom B, top X, left Y), shoulders L R, triggers ZL ZR, Menu + Options −, both sticks and their presses.
// Each controller is a player of its own (local co-op): the first one connected is player 1, together with the keyboard, the next player 2, and so on up to 8 (pad_slots.h);
// DM_PAD_MERGE=1 merges every controller into player 1 instead, DM_KBD_PLAYER=own makes the keyboard player 1 on its own, with the controllers from player 2 on.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "hle.h"
#include "pad_slots.h"
#include "haptics_apple.h"
#include "botw_touch_actions.h"
#include "botw_touch_menu.h"
#include "botw_touch_style.h"
#include "botw_rune_icon.h"
#include "touchpad_geometry.h"
#include <signal.h>
#include <math.h>

static CAMetalLayer *g_layer;
static uint64_t g_btn;
static int g_w, g_a, g_s, g_d;
static int g_input_on = 1;
static int g_mouse_down;

void *front_metal_layer(void) { return (__bridge void *)g_layer; }
static _Atomic int g_screen_fps;   // the window's screen's maximumFramesPerSecond, kept up to date when the window moves to another screen
int front_screen_max_fps(void) { return g_screen_fps; }
static int32_t g_mouse_rx, g_mouse_ry;
static int32_t g_preview_lx, g_preview_ly;
static uint64_t g_preview_buttons;
static BOOL g_touch_preview_requested, g_touch_preview_active;
static void push(void);
static void preview_refresh(void);
static void preview_set_map_region(int valid, float x, float y, float width, float height);
static void preview_action_changed(void);
static void preview_rune_icon_changed(void);
static void preview_menu_changed(void);
static void input_release(void);
static void input_resume(void);
void front_look_mode_changed(void) {} // Mac input sources are separate before and after look mode installs.
void front_botw_touch_hud_mode_changed(void) { dispatch_async(dispatch_get_main_queue(), ^{ preview_refresh(); }); }
void front_botw_touch_hud_map_region(int valid, float x, float y, float width, float height) {
    dispatch_async(dispatch_get_main_queue(), ^{ preview_set_map_region(valid, x, y, width, height); });
}
void front_botw_touch_action_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ preview_action_changed(); });
}
void front_botw_rune_icon_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ preview_rune_icon_changed(); });
}
void front_botw_touch_menu_changed(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ preview_menu_changed(); });
}
// The screen's refresh rate matched to the game's frame rate in fullscreen (front_screen_match, from PR #79; DM_SCREEN_MATCH=0 turns it off). 60 fps on a 144 Hz screen cannot be paced
// evenly: the display link counts a tick on the refresh nearest each 1/60 s slot (nvn_mtl.m link_range), so frames stay up 2 and 3 refreshes in turn (13.9 / 20.8 ms) and Apple's HUD shows
// the frame interval jumping between them. In fullscreen, a screen whose rate is not a multiple of the game's switches to the mode of the same size with the highest rate that is (144 → 120 Hz
// for 60 and 30 fps), for this app only: macOS switches it back when the host quits, crashes included, and leaving fullscreen or that screen switches it back at once. A window keeps the
// screen's rate, because the switch changes the whole screen for every app and most external screens go black for a second or more. A screen with no such mode keeps the virtual ticks
static NSWindow *g_win; static _Atomic int g_match_want;   // the game's window; the frame rate to match (0 = not known yet), written by the present thread only
static CGDirectDisplayID g_match_id; static CGDisplayModeRef g_match_orig;   // main thread: the screen this host switched and its own mode (NULL = none switched)
static double mode_hz(CGDisplayModeRef m) { double hz = CGDisplayModeGetRefreshRate(m); return hz > 0 ? hz : 0; }   // 0 = not known (older built-in screens report none)
static int hz_multiple(double hz, int fps) { double k = round(hz / fps); return k >= 1 && fabs(hz / fps - k) < 0.01; }   // 59.94 Hz counts as 60
static CGError screen_set_mode(CGDirectDisplayID id, CGDisplayModeRef m) {   // for this app only (kCGConfigureForAppOnly)
    CGDisplayConfigRef cfg; CGError r = CGBeginDisplayConfiguration(&cfg);
    if (r != kCGErrorSuccess) return r;
    r = CGConfigureDisplayWithDisplayMode(cfg, id, m, NULL);
    if (r != kCGErrorSuccess) { CGCancelDisplayConfiguration(cfg); return r; }
    return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}
static void screen_match_restore(int on_it) {   // main thread: the screen this host switched gets its own mode again; on_it: the window is on that screen
    double hz = mode_hz(g_match_orig); CGError r = screen_set_mode(g_match_id, g_match_orig);
    LOG("front end: screen %s %.0f Hz", r == kCGErrorSuccess ? "back at" : "could not be switched back to", hz);
    if (r == kCGErrorSuccess && on_it && hz > 0) g_screen_fps = (int)round(hz);
    CGDisplayModeRelease(g_match_orig); g_match_orig = NULL;
}
static void screen_match_apply(void) {   // main thread: on a new frame rate, on entering and leaving fullscreen and on a move to another screen
    static int off = -1; if (off < 0) { const char *e = getenv("DM_SCREEN_MATCH"); off = e && !strcmp(e, "0"); if (off) LOG("front end: the screen keeps its refresh rate in fullscreen too (DM_SCREEN_MATCH=0)"); }
    NSScreen *scr = g_win.screen; int want = g_match_want, full = (g_win.styleMask & NSWindowStyleMaskFullScreen) != 0;
    CGDirectDisplayID id = scr ? [scr.deviceDescription[@"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
    if (g_match_orig && (!full || id != g_match_id)) screen_match_restore(id == g_match_id);
    if (off || !full || want <= 0 || !scr) return;
    CGDisplayModeRef cur = CGDisplayCopyDisplayMode(id);
    if (!cur) return;
    double hz = mode_hz(cur);
    if (hz <= 0 || hz_multiple(hz, want)) {   // already a multiple, or not known
        if (g_match_orig && hz > 0) g_screen_fps = (int)round(hz);   // the screen this host switched: its rate from the mode, which maximumFramesPerSecond (the screen observer) may not show yet
        CGDisplayModeRelease(cur); return;
    }
    size_t w = CGDisplayModeGetWidth(cur), h = CGDisplayModeGetHeight(cur), pw = CGDisplayModeGetPixelWidth(cur), ph = CGDisplayModeGetPixelHeight(cur);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES});
    CGDisplayModeRef pick = NULL; double pick_hz = 0;
    for (CFIndex i = 0; modes && i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i); double r = mode_hz(m);
        if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetHeight(m) != h || CGDisplayModeGetPixelWidth(m) != pw || CGDisplayModeGetPixelHeight(m) != ph || !CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        if (hz_multiple(r, want) && r > pick_hz) { pick = m; pick_hz = r; }
    }
    if (!pick) LOG("front end: screen at %.0f Hz has no mode of this size at a multiple of %d Hz: frames are paced on the nearest refreshes", hz, want);
    else {
        CGError r = screen_set_mode(id, pick);
        LOG("front end: screen at %.0f Hz %s %.0f Hz for %d fps in fullscreen (DM_SCREEN_MATCH=0 keeps it)", hz, r == kCGErrorSuccess ? "switched to" : "could not be switched to", pick_hz, want);
        if (r == kCGErrorSuccess) { if (!g_match_orig) { g_match_orig = CGDisplayModeRetain(cur); g_match_id = id; } g_screen_fps = (int)round(pick_hz); }
    }
    if (modes) CFRelease(modes);
    CGDisplayModeRelease(cur);
}
void front_screen_match(int fps) {
    if (!g_layer || g_match_want == fps) return;   // no window (a windowless run's main thread runs the guest), or the rate as before
    g_match_want = fps; dispatch_async(dispatch_get_main_queue(), ^{ screen_match_apply(); });
}
static void push(void) {
    int32_t lx = (g_d - g_a) * 32767, ly = (g_w - g_s) * 32767;
    if (g_touch_preview_active && (abs(g_preview_lx) + abs(g_preview_ly) > abs(lx) + abs(ly))) {
        lx = g_preview_lx; ly = g_preview_ly;
    }
    dm_input_set(g_btn | (g_touch_preview_active ? g_preview_buttons : 0), lx, ly, g_mouse_rx, g_mouse_ry);
}
static int key_bit(unsigned short code) {
    switch (code) {
        case 38: return 0;  case 40: return 1;  case 32: return 2;  case 34: return 3;    // J K U I → A B X Y
        case 3: return 4;   case 5: return 5;                                            // F G → press stick
        case 12: return 6;  case 14: return 7;  case 6: return 8;   case 8: return 9;    // Q E Z C → L R ZL ZR
        case 36: return 10; case 48: return 11;                                          // Return Tab → + −
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15; // ← ↑ → ↓
    }
    return -1;
}
static void on_key(NSEvent *e, int down) {
    if (!g_input_on) return;
    unsigned short c = e.keyCode;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    int b = key_bit(c);
    uint64_t m = b >= 0 ? 1ull << b : c == 49 ? DM_BTN_SHAKE : 0;   // Space: shaken while held
    g_btn = down ? (g_btn | m) : (g_btn & ~m);
    push();
}

// Physical controllers (GameController) go to dm_pad_set_player, mapped as the iPhone's (DmGamepad.m read_pad, same layout); player 1's is ORed with the keyboard, a stick takes
// whichever is deflected more (hle_hid.c). DM_KEYS uses player 1's path, so player 1's controller touched during a script takes it over.
// Players: every controller with an extended gamepad profile holds a slot (pad_slots.h: player 1 first, a reconnected controller gets its player back), and hle_hid.c reports
// player n on its own npad while the slot is held (dm_pad_players). A one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c).
// With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins; when the last one goes away its buttons and sticks are released)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_kbd_own;
static int32_t pad_axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * DM_STICK_MAX); }
static void pad_read(GCExtendedGamepad *g) {
    if (!g_input_on) return;
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= bit
    K(g.buttonB, DM_BTN_A); K(g.buttonA, DM_BTN_B); K(g.buttonY, DM_BTN_X); K(g.buttonX, DM_BTN_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, DM_BTN_L); K(g.rightShoulder, DM_BTN_R); K(g.leftTrigger, DM_BTN_ZL); K(g.rightTrigger, DM_BTN_ZR);
    K(g.buttonMenu, DM_BTN_PLUS); K(g.buttonOptions, DM_BTN_MINUS); K(g.leftThumbstickButton, DM_BTN_LS); K(g.rightThumbstickButton, DM_BTN_RS);   // nil on pads without them: not pressed
    K(g.dpad.left, DM_BTN_LEFT); K(g.dpad.up, DM_BTN_UP); K(g.dpad.right, DM_BTN_RIGHT); K(g.dpad.down, DM_BTN_DOWN);
    #undef K
    dm_pad_set_player(p, m, pad_axis(g.leftThumbstick.xAxis.value), pad_axis(g.leftThumbstick.yAxis.value), pad_axis(g.rightThumbstick.xAxis.value), pad_axis(g.rightThumbstick.yAxis.value));
}
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil on a connect)
static void pads_changed(GCController *gone) {
    if (g_merge) {
        int any = 0;
        for (GCController *c in GCController.controllers) if (c.extendedGamepad && c != gone) {
            any = 1; c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
            pad_read(c.extendedGamepad);
        }
        if (!any) { dm_pad_set(0, 0, 0, 0, 0); dm_haptics_apple_controller(0, nil); }
        return;
    }
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c;
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; pad_read(g); };
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)", pad_name(c), p + 1, nb);
        pad_read(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
}
// AppKit may not deliver releases after the window loses key status; release only host-owned input and resample controllers on return.
static void input_release(void) {
    g_input_on = 0;
    g_btn = 0; g_w = g_a = g_s = g_d = 0;
    g_mouse_rx = g_mouse_ry = g_preview_lx = g_preview_ly = 0; g_preview_buttons = 0; push();
    if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); }
    if (g_merge) {
        for (GCController *c in GCController.controllers) if (c.extendedGamepad) { dm_pad_set(0, 0, 0, 0, 0); break; }
    } else {
        for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
    }
}
static void input_resume(void) {
    g_input_on = 1;
    if (g_merge) { for (GCController *c in GCController.controllers) if (c.extendedGamepad) pad_read(c.extendedGamepad); }
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p].extendedGamepad) pad_read(g_held[p].extendedGamepad);
}
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_KBD_PLAYER"); g_kbd_own = !g_merge && e && !strcmp(e, "own");
    static const char kbd = 0;
    if (g_kbd_own) pad_slot_take(&g_slots, &kbd, "keyboard");   // holds player 1 for good
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : g_kbd_own ? "the keyboard is player 1, each controller a player of its own from player 2 on (DM_KBD_PLAYER=own)"
                                                                           : "each controller is a player of its own, the keyboard plays with player 1");
    pads_changed(nil);
}

enum { PREVIEW_NONE, PREVIEW_STICK, PREVIEW_DPAD, PREVIEW_FACE, PREVIEW_BUTTON, PREVIEW_LOOK, PREVIEW_GAME, PREVIEW_SHIELD, PREVIEW_MENU };
@interface DmTouchPreviewView : NSView
- (void)setPreviewActive:(BOOL)active;
- (void)setMapRegionValid:(BOOL)valid x:(float)x y:(float)y width:(float)width height:(float)height;
- (void)cancelInput;
- (dm_touchpad_point)dpadCenter;
- (void)botwTouchActionChanged;
- (void)botwRuneIconChanged;
- (void)refreshBotwRuneIcon;
- (void)setBotwMenuActive:(BOOL)active;
- (void)sendBotwMenuPointer:(int)phase point:(dm_touchpad_point)p;
@end
static DmTouchPreviewView *g_preview_view;

static float preview_distance(NSPoint a, NSPoint b) { return hypotf((float)(a.x - b.x), (float)(a.y - b.y)); }
static NSPoint preview_from_top(float x, float y, float height) { return NSMakePoint(x, height - y); }
static dm_touchpad_point preview_pad_point(float x, float y) { return (dm_touchpad_point){x, y}; }
static void preview_fill_outlined_circle(NSRect background, CGFloat lineWidth) {
    [[NSBezierPath bezierPathWithOvalInRect:background] fill];
    NSBezierPath *border = [NSBezierPath bezierPathWithOvalInRect:
        NSInsetRect(background, -lineWidth*.5, -lineWidth*.5)];
    border.lineWidth = lineWidth; [border stroke];
}
static void preview_draw_botw_glyph(CGPathRef path, CGFloat height, NSColor *color) {
    if (!path) return;
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, 0, height); CGContextScaleCTM(context, 1, -1);
    CGContextSetFillColorWithColor(context, color.CGColor);
    CGContextAddPath(context, path); CGContextFillPath(context);
    CGContextRestoreGState(context); CGPathRelease(path);
}
static NSImage *preview_botw_rune_image(const dm_botw_rune_icon_state *snapshot) {
    if (!snapshot || !snapshot->valid || snapshot->width != DM_BOTW_RUNE_ICON_SIDE ||
        snapshot->height != DM_BOTW_RUNE_ICON_SIDE || snapshot->stride != DM_BOTW_RUNE_ICON_STRIDE) return nil;
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, snapshot->rgba, sizeof snapshot->rgba);
    CGDataProviderRef provider = data ? CGDataProviderCreateWithCFData(data) : NULL;
    CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    // The provider publishes RGBA with premultiplied alpha.
    CGImageRef cg = provider && color ? CGImageCreate(snapshot->width, snapshot->height, 8, 32,
        snapshot->stride, color, kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast, provider, NULL, false,
        kCGRenderingIntentDefault) : NULL;
    NSImage *image = cg ? [[NSImage alloc] initWithCGImage:cg size:NSMakeSize(snapshot->width, snapshot->height)] : nil;
    if (cg) CGImageRelease(cg);
    if (color) CGColorSpaceRelease(color);
    if (provider) CGDataProviderRelease(provider);
    if (data) CFRelease(data);
    return image;
}

@implementation DmTouchPreviewView {
    BOOL _active, _menuMode, _menuPointerActive, _mapValid, _mapTapConsumed, _mapInvalidAfterTap, _lookDragged, _lookTapPending;
    dm_touchpad_rect _mapRect;
    int _owner, _button;
    uint64_t _held, _cancelPending, _cancelLatched;
    NSPoint _down, _last, _stickCenter, _shieldOrigin;
    NSTimeInterval _lookDownTime, _lookTapTime;
    NSPoint _lookTapPoint;
    float _menuLastX, _menuLastY;
    BOOL _hasTouch;
    NSImage *_runeIcon, *_yIcon;
    uint64_t _runeIconGeneration;
    BOOL _runeIconValid;
}
- (BOOL)isFlipped { return NO; }
- (void)setFrameSize:(NSSize)s {
    BOOL resized = !NSEqualSizes(self.frame.size, s);
    [super setFrameSize:s];
    if (resized && _menuPointerActive) [self cancelInput];
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (NSView *)hitTest:(NSPoint)p { return _active && !self.hidden && NSPointInRect(p, self.bounds) ? self : nil; }
- (void)setPreviewActive:(BOOL)active {
    if (_active != active) _lookTapPending = NO;
    if (_active != active && !active) { [self cancelInput]; _mapValid = NO; _mapTapConsumed = NO; _mapInvalidAfterTap = NO; }
    _active = active; self.hidden = !active;
    if (!active) { _runeIcon = nil; _runeIconValid = NO; _runeIconGeneration = 0; }
    else [self refreshBotwRuneIcon];
    [self setNeedsDisplay:YES];
}
- (void)sendBotwMenuPointer:(int)phase point:(dm_touchpad_point)p {
    if (phase == DM_BOTW_MENU_CANCEL) {
        dm_botw_touch_menu_pointer(phase, _menuLastX, _menuLastY);
        return;
    }
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    if (rect[2] <= 0 || rect[3] <= 0) return;
    _menuLastX = (p.x-rect[0])/rect[2]; _menuLastY = (p.y-rect[1])/rect[3];
    dm_botw_touch_menu_pointer(phase, _menuLastX, _menuLastY);
}
- (void)setBotwMenuActive:(BOOL)active {
    if (_menuMode == active) return;
    [self cancelInput];
    if (dm_botw_touch_hud_available()) dm_input_cancel_virtual_latch(0xffffull);
    _menuMode = active;
    [self setNeedsDisplay:YES];
}
- (void)setMapRegionValid:(BOOL)valid x:(float)x y:(float)y width:(float)width height:(float)height {
    if (!_active) { _mapTapConsumed = NO; _mapInvalidAfterTap = NO; }
    _mapValid = valid && isfinite(x) && isfinite(y) && isfinite(width) && isfinite(height) && width > 0 && height > 0;
    if (!_mapValid) {
        _mapRect = (dm_touchpad_rect){0};
        if (_active && _mapTapConsumed) _mapInvalidAfterTap = YES;
    } else if (_mapTapConsumed && !_mapInvalidAfterTap) {
        _mapValid = NO; _mapRect = (dm_touchpad_rect){0};
    } else {
        _mapTapConsumed = NO; _mapInvalidAfterTap = NO;
        _mapRect = (dm_touchpad_rect){x, y, width, height};
    }
    [self setNeedsDisplay:YES];
}
- (void)refreshBotwRuneIcon {
    if (!_active) { _runeIcon=nil; _runeIconValid=NO; _runeIconGeneration=0; return; }
    dm_botw_rune_icon_state snapshot={0};
    if (!dm_botw_rune_icon_snapshot(&snapshot) || snapshot.generation < _runeIconGeneration) return;
    if (snapshot.generation == _runeIconGeneration) return;
    _runeIconGeneration=snapshot.generation;
    _runeIcon=nil; _runeIconValid=NO;
    if (snapshot.valid) {
        _runeIcon=preview_botw_rune_image(&snapshot);
        _runeIconValid=_runeIcon != nil;
    }
}
- (void)botwRuneIconChanged { [self refreshBotwRuneIcon]; [self setNeedsDisplay:YES]; }
- (dm_touchpad_point)stickHome { return _active ? dm_touchpad_botw_stick_home(self.bounds.size.width,self.bounds.size.height,0,0,0,0) : dm_touchpad_stick_home(self.bounds.size.width,self.bounds.size.height,0,0,0,0); }
- (dm_touchpad_point)shieldHome { return dm_touchpad_shield_stick_home(self.bounds.size.width, self.bounds.size.height, 0, 0, 0, 0); }
- (dm_touchpad_point)runeButton { return dm_touchpad_rune_button(self.bounds.size.width, self.bounds.size.height, 0, 0, 0, 0); }
- (dm_touchpad_point)mapBadgeCenter {
    if (!_active || !_mapValid) {
        float u=self.u;
        return (dm_touchpad_point){self.bounds.size.width*.5f+DM_TP_PILL_DX*u,
                                  DM_TP_PILL_Y*u};
    }
    float rect[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, rect);
    dm_touchpad_point p = dm_touchpad_map_badge(rect[0], rect[1], rect[2], rect[3], _mapRect,
                                                DM_TP_MAP_BADGE_WIDTH * self.u, DM_TP_MAP_BADGE_HEIGHT * self.u);
    return p;
}
- (dm_touchpad_point)faceCenter { return dm_touchpad_face_center(self.bounds.size.width, self.bounds.size.height, 0, 0, 0, 0); }
- (dm_touchpad_point)dpadCenter { return dm_touchpad_dpad_center(self.bounds.size.width, self.bounds.size.height, 0, 0, 0, 0); }
- (float)u { return dm_touchpad_u((float)self.bounds.size.height); }
- (BOOL)mapOwnsTop:(dm_touchpad_point)p {
    if (!_mapValid) return NO;
    float content[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, content);
    if (content[2] <= 0 || content[3] <= 0) return NO;
    float x = (p.x - content[0]) / content[2], y = (p.y - content[1]) / content[3];
    return x >= _mapRect.x && x < _mapRect.x + _mapRect.width && y >= _mapRect.y && y < _mapRect.y + _mapRect.height;
}
- (int)buttonAtTop:(dm_touchpad_point)p {
    float u = self.u, w = self.bounds.size.width;
    if (_active) {
        dm_touchpad_point badge = [self mapBadgeCenter];
        dm_touchpad_rect r = dm_touchpad_map_badge_rect(badge.x, badge.y, u);
        if (dm_touchpad_rounded_rect_contains(r, DM_TP_MAP_BADGE_RADIUS*u, p.x, p.y)) return 10;
    }
    // Shoulder buttons share the iOS edge positions; the preview uses simple round hit shapes.
    struct { int bit; float x, y, r; BOOL right; } keys[] = {
        {8, DM_TP_ZL_X, DM_TP_ZL_Y, DM_TP_ZL_R, NO}, {6, DM_TP_L_X, DM_TP_L_Y, DM_TP_L_R, NO},
        {9, DM_TP_ZL_X, DM_TP_ZL_Y, DM_TP_ZL_R, YES}, {7, DM_TP_L_X, DM_TP_L_Y, DM_TP_L_R, YES}
    };
    for (unsigned i = 0; i < sizeof keys / sizeof keys[0]; i++) {
        if (_active && keys[i].bit == 8) continue; // replaced by the shield stick
        if (_active && keys[i].bit == 6) {
            dm_touchpad_point c = [self runeButton];
            if (hypotf(p.x-c.x,p.y-c.y) <= DM_TP_L_R*u*1.45f) return 6;
            continue;
        }
        if (_active && (keys[i].bit == 7 || keys[i].bit == 9) && (_cancelLatched & (1ull << keys[i].bit))) continue;
        dm_touchpad_point c = {keys[i].right ? w - keys[i].x * u : keys[i].x * u, keys[i].y * u};
        if (_active && (keys[i].bit == 9 || keys[i].bit == 7))
            c = dm_touchpad_right_shoulder(w, (float)self.bounds.size.height, 0, 0, 0, 0, keys[i].bit == 9);
        float hit_scale = _active && (keys[i].bit == 9 || keys[i].bit == 7) ? DM_TP_SHOULDER_HIT_SCALE : 1.35f;
        if (preview_distance(NSMakePoint(p.x, p.y), NSMakePoint(c.x, c.y)) < keys[i].r * u * hit_scale) return keys[i].bit;
    }
    float pillY = DM_TP_PILL_Y * u;
    float minusX = w * .5f - DM_TP_PILL_DX * u, plusX = w * .5f + DM_TP_PILL_DX * u;
    if (_active && _mapValid) {
        dm_touchpad_point badge = [self mapBadgeCenter];
        dm_touchpad_rect r = dm_touchpad_map_badge_rect(badge.x,badge.y,u);
        if (dm_touchpad_rounded_rect_contains(r,DM_TP_MAP_BADGE_RADIUS*u,p.x,p.y)) return 10;
        return -1; // the old + hit region is replaced while the live-map badge exists
    }
    if (!(_mapValid || _mapTapConsumed) && (_active ? hypotf(p.x-minusX,p.y-pillY) <= DM_TP_MAP_BADGE_RADIUS*u : fabsf(p.x-minusX) <= DM_TP_PILL_W*u*.5f+8*u && fabsf(p.y-pillY) <= DM_TP_PILL_H*u*.5f+8*u)) return 11;
    if (_active) return -1; // only the old + region is replaced; Pro HUD still needs the visible − button
    if (fabsf(p.x - plusX) <= (DM_TP_PILL_W * u * .5f + 8 * u) && fabsf(p.y - pillY) <= (DM_TP_PILL_H * u * .5f + 8 * u)) return 10;
    return -1;
}
- (BOOL)leftStickOwnsTop:(dm_touchpad_point)p {
    if ([self buttonAtTop:p] >= 0) return NO;
    dm_touchpad_point face = [self faceCenter], dpad = [self dpadCenter], stick = [self stickHome];
    float f = preview_distance(NSMakePoint(p.x, p.y), NSMakePoint(face.x, face.y)) /
              (DM_TP_FACE_GAP * self.u + DM_TP_FACE_R * self.u * 1.6f);
    float d = preview_distance(NSMakePoint(p.x, p.y), NSMakePoint(dpad.x, dpad.y)) /
              (DM_TP_DPAD_R * self.u * DM_TP_DPAD_GRAB);
    float s = preview_distance(NSMakePoint(p.x, p.y), NSMakePoint(stick.x, stick.y)) /
              (DM_TP_STICK_R * self.u * DM_TP_STICK_GRAB);
    return s <= 1.0f && s < f && s < d;
}
- (uint64_t)faceAtTop:(dm_touchpad_point)p {
    dm_touchpad_point c = [self faceCenter]; float u = self.u;
    return dm_touchpad_face_buttons(p.x, p.y, c.x, c.y, DM_TP_FACE_GAP * u, DM_TP_FACE_R * u * 1.25f);
}
- (uint64_t)dpadAtTop:(dm_touchpad_point)p {
    dm_touchpad_point c = [self dpadCenter];
    return dm_touchpad_dpad_buttons(p.x, p.y, c.x, c.y, DM_TP_DPAD_R * self.u);
}
- (void)publishButtons {
    g_preview_buttons = _held | _cancelPending;
    push(); [self setNeedsDisplay:YES];
}
- (void)updateStick:(dm_touchpad_point)p {
    float dx = p.x - _stickCenter.x, dy = p.y - _stickCenter.y, radius = DM_TP_STICK_R * self.u;
    float d = hypotf(dx, dy);
    if (_active) dm_botw_touch_sprint_request(dm_touchpad_sprint_requested(d, radius));
    if (d > radius) { dx *= radius / d; dy *= radius / d; }
    dm_touchpad_stick_axis(dx, dy, radius, 0, &g_preview_lx, &g_preview_ly);
    push(); [self setNeedsDisplay:YES];
}
- (void)updateShield:(dm_touchpad_point)p {
    dm_touchpad_stick_axis(p.x-_shieldOrigin.x,p.y-_shieldOrigin.y,DM_TP_STICK_R*self.u,0,&g_preview_lx,&g_preview_ly);
    _held |= DM_BTN_ZL; [self publishButtons];
}
- (dm_touchpad_point)topPoint:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    return preview_pad_point((float)p.x, (float)(self.bounds.size.height - p.y));
}
- (void)sendGameTouch:(dm_touchpad_point)p {
    float r[4]; dm_aspect_touch_rect((float)self.bounds.size.width, (float)self.bounds.size.height, r);
    if (r[2] <= 0 || r[3] <= 0) return;
    dm_touch t = {0, fminf(fmaxf((p.x-r[0])/r[2], 0), .999f), fminf(fmaxf((p.y-r[1])/r[3], 0), .999f)};
    dm_touch_set(&t, 1);
}
- (void)mouseDown:(NSEvent *)e {
    dm_touchpad_point p = [self topPoint:e];
    _down = _last = NSMakePoint(p.x, p.y); _hasTouch = YES; _held = _cancelPending; _owner = PREVIEW_NONE;
    [self setBotwMenuActive:_active && !dm_botw_touch_controls_visible()];
    if (_menuMode) {
        _owner = PREVIEW_MENU; _menuPointerActive = YES;
        [self sendBotwMenuPointer:DM_BOTW_MENU_BEGIN point:p];
        return;
    }
    if (e.clickCount >= 2 && [self leftStickOwnsTop:p]) {
        _lookTapPending = NO;
        g_preview_buttons |= DM_BTN_LS; push(); g_preview_buttons &= ~DM_BTN_LS; push(); _hasTouch = NO; return;
    }
    int b = [self buttonAtTop:p];
    // The L hit circle slightly overlaps the shield stick's grab radius; keep
    // the explicit L button's touch-down ownership ahead of shield capture.
    if (_active && b == 6) { _lookTapPending = NO; _owner = PREVIEW_BUTTON; _button = b; _held |= 1ull << b; [self publishButtons]; return; }
    if (_active) {
        dm_touchpad_point sh = [self shieldHome];
        if (hypotf(p.x-sh.x,p.y-sh.y) <= DM_TP_STICK_R*self.u*DM_TP_STICK_GRAB) {
            _lookTapPending = NO; _owner = PREVIEW_SHIELD; _shieldOrigin = NSMakePoint(p.x,p.y); _held |= DM_BTN_ZL; [self updateShield:p]; return;
        }
    }
    if (b >= 0) { _lookTapPending = NO; _owner = PREVIEW_BUTTON; _button = b; _held |= 1ull << b; [self publishButtons]; return; }
    // Match iOS touch-down ownership: nearby face/D-pad/stick controls get first refusal,
    // the floating left stick owns its home region, then the relocated map takes the tap.
    if ([self leftStickOwnsTop:p]) { _lookTapPending = NO; _owner = PREVIEW_STICK; _stickCenter = NSMakePoint(p.x,p.y); [self updateStick:p]; return; }
    dm_touchpad_point fc = [self faceCenter], dc = [self dpadCenter]; float u = self.u;
    float fd = preview_distance(NSMakePoint(p.x,p.y), NSMakePoint(fc.x,fc.y));
    float dd = preview_distance(NSMakePoint(p.x,p.y), NSMakePoint(dc.x,dc.y));
    if (fd <= DM_TP_FACE_GAP*u + DM_TP_FACE_R*u*1.6f && fd <= dd) { _lookTapPending = NO; _owner = PREVIEW_FACE; _held = [self faceAtTop:p]; [self publishButtons]; return; }
    if (dd <= DM_TP_DPAD_R*u*DM_TP_DPAD_GRAB && dd < fd) { _lookTapPending = NO; _owner = PREVIEW_DPAD; _held = [self dpadAtTop:p]; [self publishButtons]; return; }
    if ([self mapOwnsTop:p]) {
        _lookTapPending = NO;
        _owner = PREVIEW_NONE; _hasTouch = NO;
        _mapTapConsumed = YES; _mapInvalidAfterTap = NO; _mapValid = NO; _mapRect = (dm_touchpad_rect){0};
        // The host publishes the invalid map region as part of this call. Do not
        // synthesize a local invalidation here: a queued pre-tap valid callback
        // must not be mistaken for the fresh collapsed-map publication.
        dm_botw_touch_hud_map_tapped();
        g_preview_buttons |= DM_BTN_MINUS; push(); g_preview_buttons &= ~DM_BTN_MINUS; push();
        return;
    }
    if (dm_look_enabled() && p.x >= self.bounds.size.width * (1.0f-DM_TP_RSWIPE)) {
        _owner = PREVIEW_LOOK; _lookDownTime = e.timestamp; _lookDragged = NO; dm_look_input(DM_LOOK_BEGIN,0,0); return;
    }
    _lookTapPending = NO;
    _owner = PREVIEW_GAME; [self sendGameTouch:p];
}
- (void)mouseDragged:(NSEvent *)e {
    if (!_hasTouch) return;
    dm_touchpad_point p = [self topPoint:e];
    if (_owner == PREVIEW_MENU && _menuPointerActive) [self sendBotwMenuPointer:DM_BOTW_MENU_MOVE point:p];
    else if (_owner == PREVIEW_STICK) [self updateStick:p];
    else if (_owner == PREVIEW_SHIELD) [self updateShield:p];
    else if (_owner == PREVIEW_FACE) { _held = [self faceAtTop:p]; [self publishButtons]; }
    else if (_owner == PREVIEW_DPAD) { _held = [self dpadAtTop:p]; [self publishButtons]; }
    else if (_owner == PREVIEW_GAME) [self sendGameTouch:p];
    else if (_owner == PREVIEW_LOOK) {
        float scale = fminf((float)self.bounds.size.width, (float)self.bounds.size.height);
        _lookDragged |= dm_touchpad_look_dragged((float)_down.x, (float)_down.y, p.x, p.y,
                                                  DM_TP_LOOK_TAP_SLOP * self.u);
        if (_lookDragged) _lookTapPending = NO;
        if (scale > 0) dm_look_input(DM_LOOK_MOVE, (p.x-_last.x)/scale, (p.y-_last.y)/scale);
    }
    _last = NSMakePoint(p.x,p.y);
}
- (void)mouseUp:(NSEvent *)e {
    if (!_hasTouch) return;
    dm_touchpad_point release = [self topPoint:e];
    if (_owner == PREVIEW_MENU && _menuPointerActive) {
        [self sendBotwMenuPointer:DM_BOTW_MENU_END point:release];
        _menuPointerActive=NO; _owner=PREVIEW_NONE; _hasTouch=NO; _held=_cancelPending;
        return;
    }
    if (_owner == PREVIEW_BUTTON && (_button == 7 || _button == 9) && _active &&
        dm_botw_touch_actions_available()) {
        uint64_t bit = 1ull << _button;
        dm_touchpad_point c = dm_touchpad_right_shoulder(self.bounds.size.width,self.bounds.size.height,0,0,0,0,_button==9);
        if (!(_cancelLatched & bit) && dm_touchpad_cancel_outside(release.x,release.y,c.x,c.y,DM_TP_CANCEL_RADIUS*self.u)) {
            _cancelLatched |= bit; _cancelPending |= bit; dm_botw_touch_cancel_trigger(bit);
        }
    }
    if (_owner == PREVIEW_GAME) dm_touch_set(NULL,0);
    if (_owner == PREVIEW_LOOK) {
        dm_touchpad_point p = [self topPoint:e];
        _lookDragged |= dm_touchpad_look_dragged((float)_down.x, (float)_down.y, p.x, p.y,
                                                  DM_TP_LOOK_TAP_SLOP * self.u);
        if (_lookDragged) _lookTapPending = NO;
        dm_look_input(DM_LOOK_END,0,0);
        if (dm_touchpad_look_tap((float)(e.timestamp - _lookDownTime), _lookDragged)) {
            float u = self.u;
            if (_lookTapPending && dm_touchpad_look_double_tap((double)_lookTapTime, (double)e.timestamp,
                    (float)_lookTapPoint.x, (float)_lookTapPoint.y, (float)_down.x, (float)_down.y, u)) {
                _lookTapPending = NO;
                g_preview_buttons |= DM_BTN_RS; push(); g_preview_buttons &= ~DM_BTN_RS; push();
            } else { _lookTapPending = YES; _lookTapTime = e.timestamp; _lookTapPoint = _down; }
        } else {
            _lookTapPending = NO;
        }
    }
    if (_active) dm_botw_touch_sprint_request(0);
    if (_owner == PREVIEW_BUTTON && (_button == 7 || _button == 9)) {
        uint64_t bit = 1ull << _button;
        if (!(_cancelPending & bit)) _cancelLatched &= ~bit;
    }
    _owner = PREVIEW_NONE; _hasTouch = NO; _held = 0;
    g_preview_lx = g_preview_ly = 0; g_preview_buttons = _cancelPending; push(); [self setNeedsDisplay:YES];
}
- (void)cancelInput {
    dm_touchpad_point noPoint = {0};
    if (_menuPointerActive) [self sendBotwMenuPointer:DM_BOTW_MENU_CANCEL point:noPoint];
    _menuPointerActive = NO;
    if (_owner == PREVIEW_GAME) dm_touch_set(NULL,0);
    if (_owner == PREVIEW_LOOK) dm_look_input(DM_LOOK_CANCEL,0,0);
    if (dm_botw_touch_hud_available()) dm_botw_touch_actions_reset();
    dm_botw_touch_sprint_request(0);
    _lookTapPending = NO; _owner = PREVIEW_NONE; _hasTouch = NO; _held = 0; _cancelPending = _cancelLatched = 0;
    g_preview_lx = g_preview_ly = 0; g_preview_buttons = 0;
    dm_input_cancel_virtual_latch(DM_BTN_LS | DM_BTN_RS | DM_BTN_MINUS); push();
}
- (void)botwTouchActionChanged {
    if (!_active) return;
    if ((_cancelPending & DM_BTN_R) && dm_botw_touch_cancel_complete(DM_BTN_R)) _cancelPending &= ~DM_BTN_R;
    if ((_cancelPending & DM_BTN_ZR) && dm_botw_touch_cancel_complete(DM_BTN_ZR)) _cancelPending &= ~DM_BTN_ZR;
    if (!_hasTouch || _owner != PREVIEW_BUTTON) _cancelLatched &= ~(_cancelPending ? 0 : (DM_BTN_R|DM_BTN_ZR));
    [self publishButtons];
}
- (void)drawCircle:(NSPoint)c radius:(float)r fill:(float)alpha label:(NSString *)label {
    NSRect rect = NSMakeRect(c.x-r, c.y-r, 2*r, 2*r);
    [[NSColor colorWithWhite:alpha >= .45 ? .35 : DM_BOTW_BUTTON_GRAY alpha:DM_BOTW_BUTTON_ALPHA] setFill];
    [[NSColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA] setStroke];
    preview_fill_outlined_circle(rect, 1.5*DM_BOTW_STROKE_WIDTH_SCALE);
    if (label.length) {
        NSDictionary *a = @{NSFontAttributeName:[NSFont systemFontOfSize:11 weight:NSFontWeightMedium], NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:.75]};
        NSSize s = [label sizeWithAttributes:a]; [label drawAtPoint:NSMakePoint(c.x-s.width/2,c.y-s.height/2) withAttributes:a];
    }
}
- (void)drawPlainKey:(NSString *)text center:(NSPoint)c {
    NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:18*self.u weight:NSFontWeightMedium],
        NSForegroundColorAttributeName:NSColor.whiteColor};
    NSSize size=[text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(c.x-size.width*.5,c.y-size.height*.5) withAttributes:attrs];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; if (!_active || _menuMode) return;
    float h = self.bounds.size.height, w = self.bounds.size.width, u = self.u;
    dm_touchpad_point sh = _owner == PREVIEW_STICK ? preview_pad_point((float)_stickCenter.x,(float)_stickCenter.y) : [self stickHome]; NSPoint ring = preview_from_top(sh.x,sh.y,h);
    NSColor *glyphColor=[NSColor colorWithRed:226/255.0 green:222/255.0 blue:211/255.0 alpha:.8];
    if (_owner==PREVIEW_STICK) {
        CGFloat r=DM_TP_STICK_R*u;
        [[NSColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA] setStroke];
        NSBezierPath *outer=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(ring.x-r,ring.y-r,2*r,2*r)];
        outer.lineWidth=DM_BOTW_STICK_RING_WIDTH; [outer stroke];
        int sprint=dm_touchpad_sprint_requested(hypotf(_last.x-sh.x,_last.y-sh.y),r);
        preview_draw_botw_glyph(dm_botw_stick_direction_path(CGPointMake(sh.x,sh.y),CGPointMake(_last.x,_last.y),r,u,sprint),h,glyphColor);
    }
    NSColor *faint=[NSColor colorWithWhite:1 alpha:DM_BOTW_STICK_GRAPH_ALPHA]; [faint setStroke];
    CGFloat kr=DM_TP_KNOB_R*u;
    NSBezierPath *center=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(ring.x-kr,ring.y-kr,2*kr,2*kr)];
    center.lineWidth=1.5; [center stroke];
    preview_draw_botw_glyph(dm_botw_four_arrows_path(CGPointMake(sh.x,sh.y),17*u,12*u),h,faint);
    dm_touchpad_point fc = [self faceCenter];
    for (int b=0;b<4;b++) {
        dm_touchpad_point q = dm_touchpad_face_button(w,h,0,0,0,0,b);
        static NSString *names[] = {@"A",@"B",@"X",@"Y"};
        NSPoint center=preview_from_top(q.x,q.y,h); float radius=DM_TP_FACE_R*u;
        [self drawCircle:center radius:radius fill:(_held & (1ull<<b))?.48:.15 label:b==3 ? @"" : names[b]];
        if (b==3) {
            if (!_yIcon) _yIcon=[[NSImage alloc] initWithContentsOfFile:dm_botw_touch_y_icon_path()];
            [_yIcon drawInRect:NSMakeRect(center.x-radius*.5,center.y-radius*.5,radius,radius)
                     fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
            NSPoint badge=NSMakePoint(center.x+radius*M_SQRT1_2,center.y+radius*M_SQRT1_2); float br=radius*.30;
            [[NSColor colorWithWhite:.20 alpha:1] setFill];
            [[NSColor colorWithRed:.94 green:.88 blue:.70 alpha:1] setStroke];
            preview_fill_outlined_circle(NSMakeRect(badge.x-br,badge.y-br,2*br,2*br),1.15*u*DM_BOTW_STROKE_WIDTH_SCALE);
            NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:9*u weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName:[NSColor colorWithRed:.94 green:.88 blue:.70 alpha:1]};
            NSSize size=[@"Y" sizeWithAttributes:attrs];
            [@"Y" drawAtPoint:NSMakePoint(badge.x-size.width*.5,badge.y-size.height*.5) withAttributes:attrs];
        }
    }
    struct { int bit; float x,y,r; BOOL right; NSString *name; } keys[] = {
        {8,DM_TP_ZL_X,DM_TP_ZL_Y,DM_TP_ZL_R,NO,@"ZL"},{6,DM_TP_L_X,DM_TP_L_Y,DM_TP_L_R,NO,@"L"},
        {9,DM_TP_ZL_X,DM_TP_ZL_Y,DM_TP_ZL_R,YES,@"ZR"},{7,DM_TP_L_X,DM_TP_L_Y,DM_TP_L_R,YES,@"R"}
    };
    for (unsigned i=0;i<sizeof keys/sizeof keys[0];i++) {
        if (_active && keys[i].bit == 8) continue;
        dm_touchpad_point c = {keys[i].right ? w-keys[i].x*u : keys[i].x*u, keys[i].y*u};
        if (_active && keys[i].bit == 6) c = [self runeButton];
        if (_active && (keys[i].bit == 9 || keys[i].bit == 7))
            c = dm_touchpad_right_shoulder(w, h, 0, 0, 0, 0, keys[i].bit == 9);
        if (_active && keys[i].bit == 6) {
            NSPoint center=preview_from_top(c.x,c.y,h); float radius=keys[i].r*u;
            NSRect button=NSMakeRect(center.x-radius,center.y-radius,2*radius,2*radius);
            [[NSColor colorWithWhite:DM_BOTW_BUTTON_GRAY alpha:DM_BOTW_BUTTON_ALPHA] setFill];
            [[NSColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA] setStroke];
            preview_fill_outlined_circle(button,2*u*DM_BOTW_STROKE_WIDTH_SCALE);
            if (_runeIconValid) {
                NSRect imageRect=NSMakeRect(center.x-.68*radius,center.y-.68*radius,1.36*radius,1.36*radius);
                [_runeIcon drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
                float br=.30f*radius; NSPoint badge=NSMakePoint(center.x+M_SQRT1_2*radius,center.y+M_SQRT1_2*radius);
                NSRect badgeRect=NSMakeRect(badge.x-br,badge.y-br,2*br,2*br);
                [[NSColor colorWithWhite:.20 alpha:1] setFill];
                [[NSColor colorWithRed:.94 green:.88 blue:.70 alpha:1] setStroke];
                preview_fill_outlined_circle(badgeRect,1.15*u*DM_BOTW_STROKE_WIDTH_SCALE);
                NSDictionary *badgeAttrs=@{NSFontAttributeName:[NSFont systemFontOfSize:9*u weight:NSFontWeightSemibold],NSForegroundColorAttributeName:[NSColor colorWithRed:.94 green:.88 blue:.70 alpha:1]};
                NSSize badgeLabel=[keys[i].name sizeWithAttributes:badgeAttrs];
                [keys[i].name drawAtPoint:NSMakePoint(badge.x-badgeLabel.width/2,badge.y-badgeLabel.height/2) withAttributes:badgeAttrs];
            } else {
                NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:11*u weight:NSFontWeightMedium],NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:.75]};
                NSSize s=[keys[i].name sizeWithAttributes:a]; [keys[i].name drawAtPoint:NSMakePoint(center.x-s.width/2,center.y-s.height/2) withAttributes:a];
            }
        } else [self drawCircle:preview_from_top(c.x,c.y,h) radius:keys[i].r*u fill:(_held & (1ull<<keys[i].bit))?.48:.15 label:keys[i].name];
        if (_active && dm_botw_touch_actions_available() && (keys[i].bit == 9 || keys[i].bit == 7) && _owner == PREVIEW_BUTTON && _button == keys[i].bit) {
            NSPoint boundary=preview_from_top(c.x,c.y,h);
            [[NSColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA] setStroke];
            NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(boundary.x-DM_TP_CANCEL_RADIUS*u,boundary.y-DM_TP_CANCEL_RADIUS*u,2*DM_TP_CANCEL_RADIUS*u,2*DM_TP_CANCEL_RADIUS*u)];
            ring.lineWidth=1.5*u; [ring stroke];
            NSDictionary *cueAttrs=@{NSFontAttributeName:[NSFont systemFontOfSize:9*u weight:NSFontWeightMedium],NSForegroundColorAttributeName:[NSColor colorWithRed:.94 green:.88 blue:.70 alpha:.9]};
            NSSize cueSize=[@"Cancel" sizeWithAttributes:cueAttrs];
            [@"Cancel" drawAtPoint:NSMakePoint(boundary.x-cueSize.width/2,boundary.y+DM_TP_CANCEL_RADIUS*u+2*u) withAttributes:cueAttrs];
        }
    }
    if (_active) {
        dm_touchpad_point home=[self shieldHome];
        if (_owner==PREVIEW_SHIELD) home=preview_pad_point((float)_shieldOrigin.x,(float)_shieldOrigin.y);
        NSPoint c=preview_from_top(home.x,home.y,h);
        if (_owner==PREVIEW_SHIELD) {
            CGFloat r=DM_TP_STICK_R*u;
            [[NSColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA] setStroke];
            NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x-r,c.y-r,2*r,2*r)];
            ring.lineWidth=DM_BOTW_STICK_RING_WIDTH; [ring stroke];
        }
        CGPoint origin=CGPointMake(home.x,home.y);
        preview_draw_botw_glyph(dm_botw_shield_graph_path(origin,u),h,glyphColor);
        if (_owner==PREVIEW_SHIELD)
            preview_draw_botw_glyph(dm_botw_stick_direction_path(origin,CGPointMake(_last.x,_last.y),DM_TP_STICK_R*u,u,0),h,glyphColor);
    }
    float py=DM_TP_PILL_Y*u;
    for (int b=10;b<=11;b++) {
        if (b==11 && (_mapValid || _mapTapConsumed)) continue;
        if (b==10 && _active) {
            dm_touchpad_point badge=[self mapBadgeCenter]; NSPoint c=preview_from_top(badge.x,badge.y,h);
            [self drawPlainKey:@"+" center:c]; continue;
        }
        float x=w*.5f+(b==10?1:-1)*DM_TP_PILL_DX*u;
        if (_active) { [self drawPlainKey:b==10?@"+":@"−" center:preview_from_top(x,py,h)]; continue; }
        NSRect r=NSMakeRect(x-DM_TP_PILL_W*u*.5f,h-py-DM_TP_PILL_H*u*.5f,DM_TP_PILL_W*u,DM_TP_PILL_H*u);
        [[NSColor colorWithWhite:(_held&(1ull<<b))?.35:DM_BOTW_BUTTON_GRAY alpha:DM_BOTW_BUTTON_ALPHA] setFill]; [[NSColor colorWithWhite:DM_BOTW_STROKE_GRAY alpha:DM_BOTW_STROKE_ALPHA] setStroke];
        NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:r xRadius:7 yRadius:7]; [p fill]; [p stroke];
        NSString *name=b==10?@"+":@"−"; NSDictionary *a=@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:.75]};
        NSSize s=[name sizeWithAttributes:a]; [name drawAtPoint:NSMakePoint(x-s.width/2,h-py-s.height/2) withAttributes:a];
    }
    (void)fc;
}
@end

static void preview_set_map_region(int valid, float x, float y, float width, float height) {
    [g_preview_view setMapRegionValid:valid x:x y:y width:width height:height];
}
static void preview_action_changed(void) { [g_preview_view botwTouchActionChanged]; }
static void preview_rune_icon_changed(void) { [g_preview_view botwRuneIconChanged]; }
static void preview_menu_changed(void) { preview_refresh(); }
static void preview_refresh(void) {
    if (!g_preview_view) return;
    BOOL connected = GCController.controllers.count != 0;
    BOOL active = g_touch_preview_requested && !connected && dm_botw_touch_hud_available();
    if (g_touch_preview_active != active) {
        if (!active) [g_preview_view cancelInput];
        g_touch_preview_active = active;
        if (active) LOG("front end: BOTW Mac touch preview active (mouse single-pointer controls)");
        else if (g_touch_preview_requested) LOG("front end: BOTW Mac touch preview paused while a physical controller is connected or HUD build is unavailable");
    }
    [g_preview_view setPreviewActive:active];
    [g_preview_view setBotwMenuActive:active && !dm_botw_touch_controls_visible()];
    float rect[4]; dm_aspect_touch_rect((float)g_preview_view.bounds.size.width, (float)g_preview_view.bounds.size.height, rect);
    dm_touchpad_point d = [g_preview_view dpadCenter];
    if (active && rect[2] > 0 && rect[3] > 0)
        dm_botw_touch_hud_publish(1, (d.x-rect[0])/rect[2], (d.y-rect[1])/rect[3]);
    else dm_botw_touch_hud_publish(0,0,0);
}

// Mouse input stays on the content view, so titlebar, window-button and resize-edge clicks remain native AppKit events.
// With look disabled, the left button is touchscreen finger 0; BOTW uses its held drag for relative camera look instead.
@interface DmGameView : NSView {
    NSSize _lookSize;
    NSPoint _lookLastPoint, _lookCenter;
    BOOL _hasLookSize, _lookHeld, _lookCanceled;
}
- (void)cancelLook;
- (void)fitDrawable;
@end
@implementation DmGameView
- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    if (s.width <= 0 || s.height <= 0) return;
    if (_hasLookSize && !NSEqualSizes(_lookSize, s)) {
        [self cancelLook];
        if (g_preview_view) [g_preview_view cancelInput];
    }
    _lookSize = s; _hasLookSize = YES;
    dm_aspect_set_display((float)(s.width / s.height));
    [self fitDrawable];
    preview_refresh();
}
- (void)cancelLook {
    if (_lookHeld || (dm_look_enabled() && !_lookCanceled)) dm_look_input(DM_LOOK_CANCEL, 0, 0);
    if (_lookHeld) _lookCanceled = YES;
    _lookHeld = NO;
    if (g_mouse_rx || g_mouse_ry) { g_mouse_rx = g_mouse_ry = 0; push(); }
}
- (NSPoint)lookPoint:(NSEvent *)e {
    return [self convertPoint:e.locationInWindow fromView:nil];
}
- (void)moveLookToPoint:(NSPoint)p {
    NSSize b = self.bounds.size;
    double scale = fmin(b.width, b.height);
    if (scale <= 0) return;
    // AppKit's view coordinates grow upward; look deltas grow downward.
    float dx = (float)((p.x - _lookLastPoint.x) / scale);
    float dy = (float)((_lookLastPoint.y - p.y) / scale);
    _lookLastPoint = p;
    // Keep the original virtual-stick response available to native UI, while the shared scene
    // getter replaces this synthetic vector with the direct relative displacement above.
    CGFloat sx = p.x - _lookCenter.x, sy = p.y - _lookCenter.y; // AppKit native stick Y grows upward.
    CGFloat d = hypot(sx, sy), radius = 60.0 * fmin(b.height / 430.0, 1.3);
    if (radius > 0 && d > radius) {
        _lookCenter = NSMakePoint(p.x - sx * radius / d, p.y - sy * radius / d);
        sx = p.x - _lookCenter.x; sy = p.y - _lookCenter.y; d = hypot(sx, sy);
    }
    CGFloat dead = radius * 0.1, full = radius * 0.8;
    if (d > dead && radius > 0) {
        CGFloat magnitude = fmin((d - dead) / (full - dead), 1);
        g_mouse_rx = (int32_t)lrint(sx / d * magnitude * DM_STICK_MAX);
        g_mouse_ry = (int32_t)lrint(sy / d * magnitude * DM_STICK_MAX);
    } else g_mouse_rx = g_mouse_ry = 0;
    push();
    if (dx != 0 || dy != 0) dm_look_input(DM_LOOK_MOVE, dx, dy);
}
- (void)mouseDown:(NSEvent *)e {
    if (_lookHeld) [self cancelLook];
    _lookCanceled = NO;
    if (dm_look_enabled()) {
        _lookLastPoint = _lookCenter = [self lookPoint:e];
        g_mouse_rx = g_mouse_ry = 0; push();
        _lookHeld = YES;
        dm_look_input(DM_LOOK_BEGIN, 0, 0);
        return;
    }
    [self mouseDragged:e];
}
- (void)mouseDragged:(NSEvent *)e {
    if (!g_input_on) return;
    if (_lookCanceled) return;
    if (_lookHeld) {
        if (!dm_look_enabled()) { [self cancelLook]; return; }
        [self moveLookToPoint:[self lookPoint:e]];
        return;
    }
    if (dm_look_enabled()) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil]; NSSize b = self.bounds.size;
    double w = b.width, h = b.height;
    if (w <= 0 || h <= 0) return;
    float rect[4]; dm_aspect_touch_rect(w, h, rect);
    double x0 = rect[0], y0 = rect[1]; w = rect[2]; h = rect[3];
    dm_touch t = {0, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax(1 - (p.y - y0) / h, 0), 0.999)};   // The AppKit view origin is at bottom left, the touchscreen origin is at top left
    dm_touch_set(&t, 1); g_mouse_down = 1;
}
- (void)mouseUp:(NSEvent *)e {
    if (_lookCanceled) { _lookCanceled = NO; return; }
    if (!_lookHeld) { (void)e; if (g_mouse_down) { g_mouse_down = 0; dm_touch_set(NULL, 0); } return; }
    if (dm_look_enabled()) {
        [self moveLookToPoint:[self lookPoint:e]];
        dm_look_input(DM_LOOK_END, 0, 0);
        _lookHeld = NO;
        g_mouse_rx = g_mouse_ry = 0; push();
    } else [self cancelLook];
}
// The drawable follows the view in pixels: a layer assigned to a layer-backed view kept the drawable at the first window's 1280x720 in fullscreen too, so the game picture was
// scaled down to it and up again by the compositor
- (void)fitDrawable {
    CAMetalLayer *l = (CAMetalLayer *)self.layer; if (![l isKindOfClass:CAMetalLayer.class] || !self.window) return;
    l.contentsScale = self.window.backingScaleFactor;
    NSSize px = [self convertSizeToBacking:self.bounds.size]; if (px.width < 1 || px.height < 1 || CGSizeEqualToSize(l.drawableSize, px)) return;
    l.drawableSize = px; LOG("front end: drawable %.0fx%.0f", px.width, px.height);
}
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self fitDrawable]; }
@end

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];                       // The signal alternate stack is per thread; crash printing must also work on the guest thread
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread finished"); exit(0);
}

// Metal reads MTL_HUD_ENABLED when the process makes its first device, which can be before the window: set from DM_METAL_HUD before main (set in front_run, the HUD did not show)
__attribute__((constructor)) static void hud_env(void) { front_hud_env(); }
void front_run(void (*guest)(void)) {
    // A game: tell macOS its work is latency-critical, so the system does not trade its frame time for power while the frame rate is capped
    static id activity; activity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated | NSActivityLatencyCritical reason:@"game"];
    const char *touch_preview = getenv("DM_TOUCH_PREVIEW");
    g_touch_preview_requested = touch_preview && !strcmp(touch_preview, "1");
    if (touch_preview && *touch_preview && strcmp(touch_preview, "0") && strcmp(touch_preview, "1"))
        die("[RED] DM_TOUCH_PREVIEW must be 0 or 1");
    if (!getenv("DM_WINDOW")) {
        if (g_touch_preview_requested) die("[RED] DM_TOUCH_PREVIEW requires the Mac window front end (DM_WINDOW=1)");
        guest(); return;
    }
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        int ww = 1280, wh = 720;
        const char *ws = getenv("DM_WINDOW_SIZE");
        if (ws) { int w, h; if (sscanf(ws, "%dx%d", &w, &h) == 2 && w >= 320 && h >= 240) { ww = w; wh = h; } }
        dm_aspect_set_display((float)ww / wh);
        NSRect r = NSMakeRect(0, 0, ww, wh);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @DM_GAME_NAME;   // the game profile's name (game name label)
        // Fullscreen: without FullScreenPrimary the green button only zooms the window. The present path already scales
        // the game picture to fit the drawable with black bars around it, so fullscreen keeps the game's aspect ratio.
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        DmGameView *gameView = [[DmGameView alloc] initWithFrame:r];
        NSView *v = win.contentView = gameView;
        v.wantsLayer = YES;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
        v.layer = g_layer;
        if (g_touch_preview_requested) {
            g_preview_view = [[DmTouchPreviewView alloc] initWithFrame:v.bounds];
            g_preview_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            g_preview_view.wantsLayer = YES;
            [gameView addSubview:g_preview_view];
        }
        [(DmGameView *)v fitDrawable];
        [win center];
        [win makeKeyAndOrderFront:nil];
        g_screen_fps = (int)(win.screen ?: NSScreen.mainScreen).maximumFramesPerSecond;
        g_win = win;
        [NSApp activateIgnoringOtherApps:YES];
        // Main menu: AppKit runs ⌘ shortcuts only through menu items, so ⌘Q quits and ⌃⌘F toggles fullscreen from here (AppKit shows the item as Globe-F and keeps ⌃⌘F as a hidden twin)
        NSMenu *bar = [NSMenu new], *app = [NSMenu new], *wm = [[NSMenu alloc] initWithTitle:@"Window"];
        [[bar addItemWithTitle:@"" action:nil keyEquivalent:@""] setSubmenu:app];
        [app addItemWithTitle:@"Quit " DM_GAME_NAME action:@selector(terminate:) keyEquivalent:@"q"];
        [[bar addItemWithTitle:@"Window" action:nil keyEquivalent:@""] setSubmenu:wm];
        [wm addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"].keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
        NSApp.mainMenu = bar;
        const char *fs = getenv("DM_FULLSCREEN");
        if (fs && *fs && strcmp(fs, "0")) dispatch_async(dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; });   // start in fullscreen (DM_FULLSCREEN=0 keeps the window)
        for (NSNotificationName nm in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
                GCController *c = n.object; int conn = n.name == GCControllerDidConnectNotification;
                if (!c.extendedGamepad || g_merge) LOG("controller %s: %s%s", conn ? "connected" : "disconnected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
                pads_changed(conn ? nil : c); preview_refresh(); }];
        dm_haptics_apple_init();
        pads_start();
        preview_refresh();
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;   // Only swallow keys for the game window; other windows such as the software keyboard input box receive typing as usual
            if (e.type == NSEventTypeKeyDown && (e.modifierFlags & NSEventModifierFlagCommand)) return e;   // ⌘ shortcuts go to the menu; a key released while ⌘ is held still reaches the game, or it would stay pressed
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;   // Swallow it to avoid the system beep
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:win queue:nil
                                                      usingBlock:^(NSNotification *n) { (void)n; exit(0); }];
        // Lifecycle (hle.h / dm.h): focus lost → 2, focus regained → 1; minimized → 3 + audio paused + GPU suspended, restored → resume (followed by focus regained → 1)
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidChangeScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (win.screen) { g_screen_fps = (int)win.screen.maximumFramesPerSecond; g_layer.contentsScale = win.backingScaleFactor; } screen_match_apply(); }];
        // Entering and leaving fullscreen: the layer is layer-backed, so its frame (and with it the drawable) follows the
        // content view by itself; only the scale factor has to be carried over to the screen the window ended up on. The screen's rate is matched in fullscreen only (screen_match_apply)
        [nc addObserverForName:NSWindowDidEnterFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidExitFullScreenNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; g_layer.contentsScale = win.backingScaleFactor; screen_match_apply(); }];
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); [(DmGameView *)v cancelLook]; [g_preview_view cancelInput]; if (!win.miniaturized) dm_focus_set(2); }];
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_resume(); dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; input_release(); [(DmGameView *)v cancelLook]; [g_preview_view cancelInput]; dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(2); }];
        // Guest thread: 64 MiB stack (the Switch main thread stack is specified by npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Progress screen of the prepare step: AppKit draws it while the game's thread builds first-use pipelines.
static NSView *g_prog; static NSTextField *g_prog_title, *g_prog_count; static NSProgressIndicator *g_prog_bar;
static NSTextField *prog_label(NSRect r, CGFloat size, NSFontWeight w, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:@""]; t.frame = r; t.alignment = NSTextAlignmentCenter; t.textColor = c;
    t.font = [NSFont monospacedDigitSystemFontOfSize:size weight:w]; return t;
}
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            NSView *cv = g_win.contentView;
            g_prog = [[NSView alloc] initWithFrame:cv.bounds]; g_prog.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            g_prog.wantsLayer = YES; g_prog.layer.backgroundColor = [NSColor colorWithWhite:0.06 alpha:0.94].CGColor;
            NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(floor((cv.bounds.size.width - 400) / 2), floor((cv.bounds.size.height - 96) / 2), 400, 96)];
            box.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
            g_prog_title = prog_label(NSMakeRect(0, 62, 400, 30), 20, NSFontWeightSemibold, NSColor.whiteColor);
            g_prog_bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 36, 360, 20)];
            g_prog_bar.style = NSProgressIndicatorStyleBar; g_prog_bar.indeterminate = NO; g_prog_bar.minValue = 0;
            g_prog_count = prog_label(NSMakeRect(0, 4, 400, 22), 13, NSFontWeightRegular, [NSColor colorWithWhite:0.72 alpha:1]);
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box]; [cv addSubview:g_prog];
        }
        g_prog_title.stringValue = tt; g_prog_bar.maxValue = total > 0 ? (double)total : 1; g_prog_bar.doubleValue = (double)done;
        g_prog_count.stringValue = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                                    [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}

// Software keyboard input box (front.h): the main thread shows an NSAlert + text field and the guest thread waits synchronously for the result. Not shown in windowless mode (returns -1, the caller treats it as cancel)
extern int g_swkbd_min_chars;
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        g_btn = 0; g_w = g_a = g_s = g_d = 0; push(); dm_touch_set(NULL, 0);
        int min_chars = g_swkbd_min_chars > 0 ? g_swkbd_min_chars : 0;
        NSString *info = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
        for (;;) {
            NSAlert *a = [NSAlert new];
            a.messageText = title && *title ? @(title) : @"Input"; a.informativeText = info;
            [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
            NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
            f.stringValue = text ?: (initial ? @(initial) : @"");
            if (guide && *guide) f.placeholderString = @(guide);
            a.accessoryView = f; a.window.initialFirstResponder = f;
            r = [a runModal] == NSAlertFirstButtonReturn; text = f.stringValue;
            if (!r || (int)text.length >= min_chars) break;
            info = [info stringByAppendingFormat:@"\nAt least %d characters are needed here.", min_chars];
        }
    });
    if (!r) return 0;
    (void)max_chars;                              // Truncation is done uniformly in hle_swkbd.c in UTF-16 units
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
