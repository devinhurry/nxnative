// Relative look input: sum pointer displacement at the front end and inject one frame's sample
// into BOTW's shared, post-filter right-stick vector so every native consumer sees the same input.
#include "hle.h"
#include "front.h"
#include <math.h>

static pthread_mutex_t g_look_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_available, g_held, g_have_pending, g_have_snapshot, g_suppress_snapshot;
static uint64_t g_snapshot_frame, g_pending_frame;
static float g_dx, g_dy, g_sample_x, g_sample_y, g_gain;
static int g_trace;
static uint64_t g_injections;

typedef struct {
    module_t *main;
    uint64_t hook, vfr_singleton, vfr_ratio;
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
        if (g_have_snapshot) {
            g_sample_x = g_sample_y = 0;
            g_suppress_snapshot = 1;
        }
        break;
    }
    pthread_mutex_unlock(&g_look_mu);
}

void dm_look_input(int phase, float dx, float dy) { look_input_at(phase, dx, dy, dm_guest_frame()); }

// The getter may be called more than once during a game frame. Cache the relative impulse and
// current frame ratio once so every native caller observes an identical touch sample.
static void look_apply_vector(uint64_t frame, float native_x, float native_y, float ratio, float *out_x, float *out_y) {
    if (!out_x || !out_y || !isfinite(native_x) || !isfinite(native_y)) die("[RED] look: invalid native stick vector");
    pthread_mutex_lock(&g_look_mu);
    if (!g_available) { *out_x = native_x; *out_y = native_y; pthread_mutex_unlock(&g_look_mu); return; }
    if (g_have_snapshot && frame < g_snapshot_frame) {
        *out_x = native_x; *out_y = native_y;
        pthread_mutex_unlock(&g_look_mu); return;
    }
    if (!g_have_snapshot || frame != g_snapshot_frame) {
        if (g_have_pending && frame > g_pending_frame + 1) { g_dx = g_dy = 0; g_have_pending = 0; }
        float queued_x = g_dx, queued_y = g_dy;
        if ((queued_x != 0 || queued_y != 0) && (!isfinite(ratio) || ratio < 0)) {
            pthread_mutex_unlock(&g_look_mu); die("[RED] look: invalid current frame ratio");
        }
        // A null VFR during loading has no ratio yet. Drop only this frame's sample; fresh later
        // movement can still apply once the game publishes its update interval.
        g_sample_x = queued_x != 0 && ratio > 0 ? queued_x * g_gain / ratio : 0;
        g_sample_y = queued_y != 0 && ratio > 0 ? -queued_y * g_gain / ratio : 0;
        if (!isfinite(g_sample_x) || !isfinite(g_sample_y)) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: normalized relative impulse overflow"); }
        g_dx = g_dy = 0; g_have_pending = 0;
        g_snapshot_frame = frame;
        g_have_snapshot = 1;
        g_suppress_snapshot = 0;
    }
    if (native_x != 0 || native_y != 0) {
        // Physical stick input has the native priority. Drop this frame's touch impulse and leave
        // the filtered physical vector untouched; do not defer the discarded movement.
        g_sample_x = g_sample_y = 0; g_dx = g_dy = 0; g_have_pending = 0;
        g_suppress_snapshot = 1;
    }
    float dx = g_suppress_snapshot ? 0 : g_sample_x;
    float dy = g_suppress_snapshot ? 0 : g_sample_y;
    *out_x = dx == 0 ? native_x : native_x + dx;
    *out_y = dy == 0 ? native_y : native_y + dy;
    if (!isfinite(*out_x) || !isfinite(*out_y)) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: output vector overflow"); }
    if (dx != 0 || dy != 0) {
        g_injections++;
        if (g_trace) LOG("look: #%llu frame=%llu sample=(%.5f,%.5f)",
                         (unsigned long long)g_injections, (unsigned long long)frame, dx, dy);
    }
    pthread_mutex_unlock(&g_look_mu);
}

static void camera_look_vector(const uint64_t *regs) {
    float *native = (float *)(uintptr_t)regs[19];
    if (!native) die("[RED] look: shared stick getter supplied a null output pair");
    float x, y;
    memcpy(&x, native, sizeof x); memcpy(&y, native + 1, sizeof y);
    float ratio = 1.0f;
    if (x == 0 && y == 0) {
        uint64_t vfr = 0;
        memcpy(&vfr, g_camera.main->base + g_camera.vfr_singleton, sizeof vfr);
        if (vfr && vfr <= UINTPTR_MAX - g_camera.vfr_ratio)
            memcpy(&ratio, (const void *)(uintptr_t)(vfr + g_camera.vfr_ratio), sizeof ratio);
        else ratio = 0;
    }
    float out_x, out_y;
    look_apply_vector(dm_guest_frame(), x, y, ratio, &out_x, &out_y);
    if (out_x != x || out_y != y) {
        memcpy(native, &out_x, sizeof out_x); memcpy(native + 1, &out_y, sizeof out_y);
    }
}

void dm_look_install(void) {
    if (!*DM_GAME_CAMERA_LOOK) return;
    char build[33] = {0}; unsigned long long hook, singleton, ratio_off; float gain; int used = 0;
    int n = sscanf(DM_GAME_CAMERA_LOOK, "%32[0-9a-f]:%llx:%llx:%llx:%f%n", build, &hook, &singleton, &ratio_off, &gain, &used);
    if (n != 5 || DM_GAME_CAMERA_LOOK[used]) die("[RED] look: malformed camera_look profile");
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_camera.main = &g_mod[i];
    if (!g_camera.main || strcmp(build, g_camera.main->build_id))
        die("[RED] look: camera_look requires main build %s (loaded %s)", build, dm_main_build());
    if (!isfinite(gain) || gain <= 0 || gain > 10000 || hook >= g_camera.main->text_end ||
        g_camera.main->size < sizeof(uint64_t) || singleton > g_camera.main->size - sizeof(uint64_t) || ratio_off > 0x10000)
        die("[RED] look: camera_look offsets or gain are out of range");
    if (!gate_obs_present(OBS_BOTW_LOOK_VECTOR))
        die("[RED] look: shared stick-vector gate missing; rewrite main with the current patch_nso.py");
    const char *e = getenv("DM_LOOK");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK must be 0 or 1");
    if (e && !strcmp(e, "0")) { LOG("look: disabled by DM_LOOK=0"); return; }
    g_camera.hook = hook; g_camera.vfr_singleton = singleton; g_camera.vfr_ratio = ratio_off; g_gain = gain;
    e = getenv("DM_LOOK_TRACE");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK_TRACE must be 0 or 1");
    g_trace = e && !strcmp(e, "1");
    gate_obs_set(OBS_BOTW_LOOK_VECTOR, camera_look_vector);
    dm_look_set_available(1);
    LOG("look: BOTW shared stick vector main+%#llx installed for build %s (%.1f normalized-input impulse per short edge)",
        (unsigned long long)g_camera.hook, build, gain);
}

#ifdef DM_TEST_HOOKS
void dm_look_test_input_at(int phase, float dx, float dy, uint64_t frame) { look_input_at(phase, dx, dy, frame); }
void dm_look_test_vector_config(module_t *main, float gain) {
    g_camera.main = main; g_camera.vfr_singleton = 0x100; g_camera.vfr_ratio = 0x20;
    if (!isfinite(gain) || gain <= 0) die("[RED] look: invalid test gain");
    g_gain = gain; dm_look_set_available(0); dm_look_set_available(1);
}
void dm_look_test_vector(uint64_t frame, float native_x, float native_y, float ratio, float *out_x, float *out_y) {
    look_apply_vector(frame, native_x, native_y, ratio, out_x, out_y);
}
#endif
