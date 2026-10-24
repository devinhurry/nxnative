// Relative look input: sum pointer displacement at the front end and inject one frame's sample
// into BOTW's shared, post-filter right-stick vector so every native consumer sees the same input.
#include "hle.h"
#include "front.h"
#include "dm_input.h"
#include <math.h>

static pthread_mutex_t g_look_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_available, g_held, g_have_pending, g_have_snapshot, g_suppress_snapshot;
static uint64_t g_snapshot_frame, g_pending_frame;
static float g_dx, g_dy, g_sample_x, g_sample_y, g_gain;
static int g_trace;
static uint64_t g_injections;
// OBS33 and OBS32 bracket one native getter call. This must be thread-local: camera/action
// consumers may call the getter concurrently, and their raw inputs must never be cross-paired.
static _Thread_local struct {
    uint64_t frame;
    float raw_x, raw_y;
    int valid;
    dm_hid_look_sample hid;
} g_raw_call;

typedef struct {
    module_t *main;
    uint64_t hook, source_pair, vfr_singleton, vfr_ratio;
} camera_look_t;
static camera_look_t g_camera;

int dm_look_enabled(void) {
    pthread_mutex_lock(&g_look_mu);
    int enabled = g_available;
    pthread_mutex_unlock(&g_look_mu);
    return enabled;
}

static void dm_look_set_available(int available) {
    if (available != 0 && available != 1) die("[RED] look: available must be 0 or 1");
    pthread_mutex_lock(&g_look_mu);
    if (g_available != available) {
        g_available = available;
        g_held = g_have_pending = g_have_snapshot = g_suppress_snapshot = 0;
        g_dx = g_dy = g_sample_x = g_sample_y = 0;
        g_snapshot_frame = g_pending_frame = 0;
    }
    pthread_mutex_unlock(&g_look_mu);
}

static void look_input_at(int phase, float dx, float dy, uint64_t frame) {
    if (phase < DM_LOOK_BEGIN || phase > DM_LOOK_CANCEL) die("[RED] look: invalid input phase %d", phase);
    if (!isfinite(dx) || !isfinite(dy)) die("[RED] look: non-finite pointer delta");
    pthread_mutex_lock(&g_look_mu);
    if (!g_available) { pthread_mutex_unlock(&g_look_mu); return; }
    // The front end reads the guest frame before taking this mutex. If a getter publishes the
    // next snapshot while the producer waits here, this event is fresh even when its timestamp
    // is one frame behind. Retimestamp it at the snapshot boundary so the next getter can consume it.
    uint64_t event_frame = g_have_snapshot && frame < g_snapshot_frame ? g_snapshot_frame : frame;
    switch (phase) {
    case DM_LOOK_BEGIN:
        if (g_held) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: nested BEGIN"); }
        if (g_have_pending && event_frame > g_pending_frame + 1) { g_dx = g_dy = 0; g_have_pending = 0; }
        g_held = 1; g_have_pending = 1; g_pending_frame = event_frame;
        break;
    case DM_LOOK_MOVE:
        if (!g_held) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: MOVE outside a drag"); }
        // Physical stick input wins the entire sampled frame; never defer its suppressed touch
        // movement into the following frame, even if the producer's frame read raced the snapshot.
        if (g_have_snapshot && event_frame <= g_snapshot_frame && g_suppress_snapshot) break;
        if (g_have_pending && event_frame > g_pending_frame + 1) { g_dx = g_dy = 0; g_have_pending = 0; }
        g_dx += dx; g_dy += dy; g_have_pending = 1; g_pending_frame = event_frame;
        if (!isfinite(g_dx) || !isfinite(g_dy)) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: accumulated pointer delta overflow"); }
        break;
    case DM_LOOK_END:
        if (!g_held) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: END outside a drag"); }
        g_held = 0; // Keep the final queued displacement for the next getter sample.
        break;
    case DM_LOOK_CANCEL:
        g_held = g_have_pending = 0; g_dx = g_dy = 0; g_pending_frame = frame;
        // A cancel can arrive after the getter cached this frame's impulse, or even one frame
        // later while an older getter is still in flight. Clear any accepted cached sample that
        // this cancel supersedes. A matched virtual source is replaced with zero independently
        // of gesture state, so no stale synthetic stick can survive this cancellation.
        if (g_have_snapshot && event_frame >= g_snapshot_frame)
            g_sample_x = g_sample_y = 0;
        break;
    }
    pthread_mutex_unlock(&g_look_mu);
}

void dm_look_input(int phase, float dx, float dy) { look_input_at(phase, dx, dy, dm_guest_frame()); }

static void look_apply_vector(uint64_t frame, float native_x, float native_y, float ratio,
                              int sample_valid, int raw_match, int physical,
                              float *out_x, float *out_y) {
    if (!out_x || !out_y || !isfinite(native_x) || !isfinite(native_y)) die("[RED] look: invalid native stick vector");
    pthread_mutex_lock(&g_look_mu);
    if (!g_available) { *out_x = native_x; *out_y = native_y; pthread_mutex_unlock(&g_look_mu); return; }
    if (!sample_valid) {
        if (g_have_pending && frame >= g_pending_frame) { g_dx = g_dy = 0; g_have_pending = 0; }
        *out_x = native_x; *out_y = native_y; pthread_mutex_unlock(&g_look_mu); return;
    }
    if (g_have_snapshot && frame < g_snapshot_frame) {
        // A delayed getter can carry a still-frozen synthetic pair from the previous frame.
        // Suppress that velocity, but do not rewind or consume the newer frame's cache.
        int stale_virtual = raw_match && !physical;
        *out_x = stale_virtual ? 0 : native_x;
        *out_y = stale_virtual ? 0 : native_y;
        pthread_mutex_unlock(&g_look_mu); return;
    }
    if (!g_have_snapshot || frame != g_snapshot_frame) {
        if (g_have_pending && frame > g_pending_frame + 1) { g_dx = g_dy = 0; g_have_pending = 0; }
        float queued_x = g_dx, queued_y = g_dy;
        int replace = !physical && raw_match;
        if ((queued_x != 0 || queued_y != 0) && (!isfinite(ratio) || ratio < 0)) {
            pthread_mutex_unlock(&g_look_mu); die("[RED] look: invalid current frame ratio");
        }
        // A null VFR during loading has no ratio yet. Drop only this frame's sample; fresh later
        // movement can still apply once the game publishes its update interval.
        g_sample_x = replace && queued_x != 0 && ratio > 0 ? queued_x * g_gain / ratio : 0;
        g_sample_y = replace && queued_y != 0 && ratio > 0 ? -queued_y * g_gain / ratio : 0;
        if (!isfinite(g_sample_x) || !isfinite(g_sample_y)) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: normalized relative impulse overflow"); }
        g_dx = g_dy = 0; g_have_pending = 0;
        g_snapshot_frame = frame;
        g_have_snapshot = 1;
        g_suppress_snapshot = !replace;
    }
    // The shared getter can be called with different selected native candidates in one frame.
    // A prior matching virtual call must not make us overwrite a later physical or unknown one.
    int replace_this_call = sample_valid && raw_match && !physical;
    int apply_sample = replace_this_call && !g_suppress_snapshot;
    float dx = apply_sample ? g_sample_x : 0;
    float dy = apply_sample ? g_sample_y : 0;
    // Replace the synthetic virtual-stick result with relative displacement. A held, stationary
    // pointer therefore produces zero rather than a repeated turn; physical/native input is kept.
    *out_x = replace_this_call ? dx : native_x;
    *out_y = replace_this_call ? dy : native_y;
    if (!isfinite(*out_x) || !isfinite(*out_y)) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: output vector overflow"); }
    if (dx != 0 || dy != 0) {
        g_injections++;
        if (g_trace) LOG("look: #%llu frame=%llu sample=(%.5f,%.5f)",
                         (unsigned long long)g_injections, (unsigned long long)frame, dx, dy);
    }
    pthread_mutex_unlock(&g_look_mu);
}

static void camera_look_source(const uint64_t *regs) {
    memset(&g_raw_call, 0, sizeof g_raw_call);
    if (!regs[0]) return; // the native null-source branch skips the raw pair load
    g_raw_call.frame = dm_guest_frame();
    if (!dm_hid_look_sample_at(g_raw_call.frame, &g_raw_call.hid)) return;
    const uint8_t *child = (const uint8_t *)(uintptr_t)regs[0];
    memcpy(&g_raw_call.raw_x, child + g_camera.source_pair, sizeof(float));
    memcpy(&g_raw_call.raw_y, child + g_camera.source_pair + sizeof(float), sizeof(float));
    g_raw_call.valid = isfinite(g_raw_call.raw_x) && isfinite(g_raw_call.raw_y);
}

static void native_stick_pair(int32_t rx, int32_t ry, float *out_x, float *out_y) {
    // BOTW 1.9's cached Npad provider converts signed axes with SCVTF/FDiv, then evaluates
    // y*y + x*x with FMADD and normalizes only when the radius is strictly greater than one.
    // Keep the same binary32 operation order so this is an exact provenance check, not a fuzzy
    // comparison or a component-wise approximation.
    float x = (float)rx / (float)DM_STICK_MAX;
    float y = (float)ry / (float)DM_STICK_MAX;
    float radius = sqrtf(fmaf(x, x, y * y));
    if (radius > 1.0f) {
        float scale = 1.0f / radius;
        x *= scale;
        y *= scale;
    }
    *out_x = x;
    *out_y = y;
}

static int raw_matches_virtual(void) {
    if (!g_raw_call.valid || g_raw_call.hid.source != DM_HID_LOOK_VIRTUAL) return 0;
    // Match the exact BOTW native stick normalization; unmatched provider candidates remain native.
    float expected_x, expected_y;
    native_stick_pair(g_raw_call.hid.selected_rx, g_raw_call.hid.selected_ry, &expected_x, &expected_y);
    return g_raw_call.raw_x == expected_x && g_raw_call.raw_y == expected_y;
}

static void camera_look_vector(const uint64_t *regs) {
    float *native = (float *)(uintptr_t)regs[19];
    if (!native) die("[RED] look: shared stick getter supplied a null output pair");
    float x, y;
    memcpy(&x, native, sizeof x); memcpy(&y, native + 1, sizeof y);
    float ratio = 1.0f;
    uint64_t frame = g_raw_call.valid ? g_raw_call.frame : dm_guest_frame();
    int sample_valid = g_raw_call.valid;
    int physical = sample_valid && g_raw_call.hid.source == DM_HID_LOOK_PHYSICAL;
    int raw_match = sample_valid && raw_matches_virtual();
    int drag_active;
    pthread_mutex_lock(&g_look_mu); drag_active = g_held || g_have_pending; pthread_mutex_unlock(&g_look_mu);
    int needs_ratio = drag_active && sample_valid && raw_match && !physical;
    if (needs_ratio) {
        uint64_t vfr = 0;
        memcpy(&vfr, g_camera.main->base + g_camera.vfr_singleton, sizeof vfr);
        if (vfr && vfr <= UINTPTR_MAX - g_camera.vfr_ratio)
            memcpy(&ratio, (const void *)(uintptr_t)(vfr + g_camera.vfr_ratio), sizeof ratio);
        else ratio = 0;
    }
    float out_x, out_y;
    look_apply_vector(frame, x, y, ratio, sample_valid, raw_match, physical, &out_x, &out_y);
    if (out_x != x || out_y != y) {
        memcpy(native, &out_x, sizeof out_x); memcpy(native + 1, &out_y, sizeof out_y);
    }
    uint32_t raw_bits[2];
    memcpy(raw_bits, &g_raw_call.raw_x, sizeof raw_bits);
    if (sample_valid && g_trace && (drag_active || physical || raw_match))
        LOG("look: source frame=%llu raw=(%a,%a) bits=(%08x,%08x) selected=(%d,%d) virtual=(%d,%d) physical=(%d,%d) source=%d match=%d out=(%.5f,%.5f)",
            (unsigned long long)frame, g_raw_call.raw_x, g_raw_call.raw_y,
            raw_bits[0], raw_bits[1],
            g_raw_call.hid.selected_rx, g_raw_call.hid.selected_ry,
            g_raw_call.hid.virtual_rx, g_raw_call.hid.virtual_ry,
            g_raw_call.hid.physical_rx, g_raw_call.hid.physical_ry,
            g_raw_call.hid.source, raw_match, out_x, out_y);
    memset(&g_raw_call, 0, sizeof g_raw_call);
}

void dm_look_install(void) {
    if (!*DM_GAME_CAMERA_LOOK) return;
    char build[33] = {0}; unsigned long long hook, source_pair, singleton, ratio_off; float gain; int used = 0;
    int n = sscanf(DM_GAME_CAMERA_LOOK, "%32[0-9a-f]:%llx:%llx:%llx:%llx:%f%n", build, &hook, &source_pair, &singleton, &ratio_off, &gain, &used);
    if (n != 6 || DM_GAME_CAMERA_LOOK[used]) die("[RED] look: malformed camera_look profile");
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_camera.main = &g_mod[i];
    if (!g_camera.main || strcmp(build, g_camera.main->build_id))
        die("[RED] look: camera_look requires main build %s (loaded %s)", build, dm_main_build());
    if (!isfinite(gain) || gain <= 0 || gain > 10000 || source_pair > 0x10000 - 2 * sizeof(float) || hook >= g_camera.main->text_end ||
        g_camera.main->size < sizeof(uint64_t) || singleton > g_camera.main->size - sizeof(uint64_t) || ratio_off > 0x10000)
        die("[RED] look: camera_look offsets or gain are out of range");
    if (!gate_obs_present(OBS_BOTW_LOOK_VECTOR) || !gate_obs_present(OBS_BOTW_LOOK_SOURCE))
        die("[RED] look: raw-source/vector gates missing; rewrite main with the current patch_nso.py");
    const char *e = getenv("DM_LOOK");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK must be 0 or 1");
    if (e && !strcmp(e, "0")) { LOG("look: disabled by DM_LOOK=0"); return; }
    g_camera.hook = hook; g_camera.source_pair = source_pair; g_camera.vfr_singleton = singleton; g_camera.vfr_ratio = ratio_off; g_gain = gain;
    e = getenv("DM_LOOK_TRACE");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK_TRACE must be 0 or 1");
    g_trace = e && !strcmp(e, "1");
    gate_obs_set(OBS_BOTW_LOOK_SOURCE, camera_look_source);
    gate_obs_set(OBS_BOTW_LOOK_VECTOR, camera_look_vector);
    dm_look_set_available(1);
    front_look_mode_changed();
    LOG("look: BOTW shared stick vector main+%#llx installed for build %s (%.1f normalized-input impulse per short edge)",
        (unsigned long long)g_camera.hook, build, gain);
}

#ifdef DM_TEST_HOOKS
void dm_look_test_input_at(int phase, float dx, float dy, uint64_t frame) { look_input_at(phase, dx, dy, frame); }
void dm_look_test_vector_config(module_t *main, float gain) {
    g_camera.main = main; g_camera.source_pair = 0x128; g_camera.vfr_singleton = 0x100; g_camera.vfr_ratio = 0x20;
    if (!isfinite(gain) || gain <= 0) die("[RED] look: invalid test gain");
    g_gain = gain; dm_look_set_available(0); dm_look_set_available(1);
}
void dm_look_test_vector(uint64_t frame, float native_x, float native_y, float ratio, float *out_x, float *out_y) {
    int physical = native_x != 0 || native_y != 0;
    look_apply_vector(frame, native_x, native_y, ratio, 1, !physical, physical, out_x, out_y);
}
void dm_look_test_vector_source(uint64_t frame, float native_x, float native_y, float ratio,
                                int sample_valid, int raw_match, int physical, float *out_x, float *out_y) {
    look_apply_vector(frame, native_x, native_y, ratio, sample_valid, raw_match, physical, out_x, out_y);
}
#endif
