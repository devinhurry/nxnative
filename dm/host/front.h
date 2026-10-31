// Host front end (Mac: front_mac.m; iOS: dm/ios separately implements the same-named interface).
#pragma once
#include <stdlib.h>
#include <stddef.h>
// Metal reads HUD switches when the first device is made. Called before host preload and again after the launcher applies its settings; explicit environment values win.
static inline void front_hud_env(void) {
    const char *e = getenv("DM_METAL_HUD");
    if (!e || !atoi(e)) return;
    setenv("MTL_HUD_ENABLED", "1", 0);
    // Spatial scaling has no temporal exposure: showing that HUD metric makes the MetalFX rows flicker.
    setenv("MTL_HUD_HIDE_METALFX_METRICS", "1", 0);
}
// Run the guest: with a window the guest runs on its own thread and the main thread belongs to the system UI; without a window it runs directly on the current thread.
void front_run(void (*guest)(void));
// The CAMetalLayer the graphics backend presents frames to (NULL when there is no window)
void *front_metal_layer(void);
// The highest refresh rate of the window's screen in Hz, 0 = not known (Mac front_mac.m; none on iOS, whose screens run at multiples of 60 Hz). Any thread
int front_screen_max_fps(void);
// The frame rate the display link paces the game at (60, 30, 120; nvn_mtl.m link_sync): in fullscreen, a screen whose refresh rate is not a multiple of it is switched, while the game runs,
// to a mode of the same size whose rate is, and back when the window leaves fullscreen or that screen (front_mac.m; none on iOS). Called from the present thread
void front_screen_match(int fps);
// Progress screen of the first-start prepare step (nvn_mtl.m warm_prepare: "Preparing shaders" while the pipelines of the prewarm lists are built before the game's first frame):
// title and done of total shown over the game's view (a dark screen, the title, a bar and a count), updated on each call; title NULL hides it. Any thread; the front end switches to its main
// thread and does not block. Nothing is shown without a window
void front_progress(const char *title, long done, long total);
#include <stdint.h>
// Text input box (for the software keyboard swkbd): the main thread shows a native input box and the calling thread blocks until the user confirms / cancels.
// All text is UTF-8; max_chars is the maximum character count (0 = unlimited, only a hint for the front end; truncation is done uniformly by the caller hle_swkbd.c in UTF-16 units).
// Confirm returns 1 and writes the result into out (including the terminating 0); cancel returns 0;
// with no window (front_metal_layer() == NULL) nothing is shown and -1 is returned.
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap);
// BOTW touch-mode software keyboard bounds are counted in UTF-16 units, as in swkbd_show.
static inline int front_text_input_length_valid(int botw_touch_mode, int min_chars, int max_chars, size_t length) {
    return !botw_touch_mode || ((min_chars <= 0 || length >= (size_t)min_chars) &&
                                (max_chars <= 0 || length <= (size_t)max_chars));
}

// Early start of host loading (main.c): reading the NSO / relocation / forced takeover / prefetch start are moved to a background thread, in parallel with the front end (UIKit launch chain, Metal view);
// the dm_main / main called afterwards waits for it to finish. For call timing and preconditions see the comments in main.c (set DM_ROMFS and the other environment variables and the cwd first; arguments identical item by item to those of the later main).
void dm_host_preload_start(int argc, char **argv);

// Native display (hle_aspect.c): the game view fills the screen instead of a centred 16:9 picture; the host stretches the 16:9 canvas and squeezes UI draws.
int dm_aspect_native(void);
void dm_aspect_set_seated(float picture_end, float controls_begin);
int dm_aspect_region(int controls, float rect[4]);
void dm_aspect_set_display(float ratio);
void dm_aspect_touch_rect(float w, float h, float rect[4]);
void dm_aspect_hud_rect(float w, float h, float rect[4]);
void dm_aspect_set_safe_area(float w, float h, float left, float top, float right);
float dm_aspect_hud_y_scale(void);
float dm_aspect_hud_gain(void);
float dm_aspect_hud_top(void);

// Publish the virtual 3D-pad target used by BOTW's gameplay HUD. The centre is
// normalized to the centered 16:9 touch rectangle (top-left origin). Other
// profiles ignore this state. May be called from the UI thread.
void dm_botw_touch_hud_publish(int active, float center_x, float center_y, float dpad_scale);
void dm_botw_touch_hud_map_tapped(void);   // consume the published host hit region until native panes are calculated again
int dm_botw_touch_hud_available(void);
// Minimap bounds use the safe-area-aware HUD rectangle, unlike the centered D-pad.
void front_botw_touch_hud_map_region(int valid, float x, float y, float width, float height);
void front_botw_touch_hud_mode_changed(void);
// The native BOTW inventory touch-menu state changed; front ends marshal to
// their UI thread and update touch ownership / visible game controls.
void front_botw_touch_menu_changed(void);
// The guest renderer published or invalidated the copied current-rune image.
// Front ends snapshot it on their UI thread and discard stale generations.
void front_botw_rune_icon_changed(void);
// Native BOTW touch-action acknowledgements may arrive on the guest thread.
// Front ends marshal this to their UI thread and release acknowledged inputs.
void front_botw_touch_action_changed(void);

// Touchscreen (implemented by the host's hle_touch.c; called by the iOS / Mac front end): whenever the set of touch points changes (down / move / up / cancel) the whole set is pushed once; n = 0 = all lifted.
// id = finger slot number 0–15 (the lowest free slot on down, unchanged until up; used directly as finger_id); x / y = normalized coordinates [0,1) on the output frame, origin at top left.
// The host converts to the panel coordinates the game reads, 1280x720 (x·1280, y·720), and latches short taps (a down and up between two reads is reported at least once). May be called from any thread.
typedef struct { uint32_t id; float x, y; } dm_touch;
void dm_touch_set(const dm_touch *t, int n);
void dm_touch_script(const dm_touch *t, int n);   // scripted touches (DM_KEYS, DM_CTL; hle_hid.c): as dm_touch_set, but never recorded by DM_REC

// Relative pointer look (implemented by the host's hle_look.c; Mac and iOS front ends):
// deltas are normalized by the smaller logical view dimension, with right and down positive.
// BEGIN starts a session, MOVE adds displacement, END preserves the last unconsumed displacement,
// and CANCEL clears held and pending input. May be called from any thread.
enum { DM_LOOK_BEGIN, DM_LOOK_MOVE, DM_LOOK_END, DM_LOOK_CANCEL };
int dm_look_enabled(void);
// Freeze relative-gesture ownership with the Npad sample, including its release/cancel frame.
int dm_look_owns_stick(uint64_t frame);
void dm_look_input(int phase, float dx, float dy);
// Republish already-connected input sources when a build-checked look mode becomes available.
void front_look_mode_changed(void);

// Device motion (implemented by the host's hle_hid.c; called by the iOS front end): one sample per CoreMotion update.
// acc = acceleration in G in the device frame (gravity included); gyro = angular velocity in revolutions/s in the device frame;
// quat = device -> reference attitude as (w, x, y, z). The first sample (or one with DM_MOTION_RESET) defines the neutral pose:
// the screen's right, into-screen and up axes become the controller's X, Y and Z axes, so the phone held as it is then reads as a
// controller at rest, and games see forward/back and left/right motion about the axes they expect.
// May be called from any thread; NULL disables device motion (the synthetic at-rest / shake sensor is used again).
enum { DM_MOTION_RESET = 1u };
typedef struct { float acc[3], gyro[3], quat[4]; uint32_t flags; } dm_motion;
void dm_device_motion_set(const dm_motion *m);

// Save not written (called by the host's hle_fs.c; the iOS front end provides a strong implementation of the same name that shows the native prompt "Not enough storage. Progress was not saved"; the default weak implementation only logs).
// Timing: when a save write fails (disk full etc.) within one of the game's save transactions (between two Commits), so that this Commit is refused and the previously committed save is unchanged, it is called once per refused transaction;
// the next transaction that succeeds commits as usual, and the front end need not do any recovery. err = the first failing errno (ENOSPC = 28 means out of space). Called on the game thread; the front end switches to the main thread itself and must not block
void front_save_failed(int err);
