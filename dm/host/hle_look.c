// Relative look input: sum pointer displacement at the front end and inject one frame's sample
// into BOTW's shared, post-filter right-stick vector so every native consumer sees the same input.
#include "hle.h"
#include "front.h"
#include "dm_input.h"
#include <math.h>

static pthread_mutex_t g_look_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_available, g_held, g_have_pending, g_have_snapshot, g_suppress_snapshot;
static uint64_t g_snapshot_frame, g_pending_frame;
static uint64_t g_owned_frame = UINT64_MAX;
static float g_dx, g_dy, g_sample_x, g_sample_y, g_sample_dx, g_sample_dy, g_gain;
static int g_trace;
static uint64_t g_injections;
// OBS33 and OBS32 bracket one native getter call. This must be thread-local: camera/action
// consumers may call the getter concurrently, and their raw inputs must never be cross-paired.
static _Thread_local struct {
    uint64_t frame;
    float raw_x, raw_y;
    int valid;
    dm_hid_look_sample hid;
    uint64_t action;
    int aim_camera;
} g_raw_call;

typedef struct {
    module_t *main;
    uint64_t hook, source_pair, vfr_singleton, vfr_ratio;
} camera_look_t;
static camera_look_t g_camera;
typedef struct {
    uint64_t caller, vtable, pitch_base, pitch_min, pitch_max, yaw_base, yaw_stack;
} aim_compose_t;
static aim_compose_t g_aim[2];
static int g_compose;
static float g_aim_gain;
// Keep the tracker continuous: aiming sees zero stick input, then the later
// pitch/yaw gates add relative displacement to that frame's native gyro result.
static _Thread_local struct {
    uint64_t frame, action;
    int camera, consumed;
} g_aim_call;

int dm_look_enabled(void) {
    pthread_mutex_lock(&g_look_mu);
    int enabled = g_available;
    pthread_mutex_unlock(&g_look_mu);
    return enabled;
}

int dm_look_owns_stick(uint64_t frame) {
    pthread_mutex_lock(&g_look_mu);
    int owned = g_available && (g_held || g_have_pending || frame == g_owned_frame);
    pthread_mutex_unlock(&g_look_mu);
    return owned;
}

static void dm_look_set_available(int available) {
    if (available != 0 && available != 1) die("[RED] look: available must be 0 or 1");
    pthread_mutex_lock(&g_look_mu);
    if (g_available != available) {
        g_available = available;
        g_held = g_have_pending = g_have_snapshot = g_suppress_snapshot = 0;
        g_dx = g_dy = g_sample_x = g_sample_y = g_sample_dx = g_sample_dy = 0;
        g_snapshot_frame = g_pending_frame = 0;
        g_owned_frame = UINT64_MAX;
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
    g_owned_frame = event_frame;
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
            g_sample_x = g_sample_y = g_sample_dx = g_sample_dy = 0;
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
        g_sample_dx = replace && ratio > 0 ? queued_x : 0;
        g_sample_dy = replace && ratio > 0 ? queued_y : 0;
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
    g_raw_call.aim_camera = -1;
    if (!regs[0]) return; // the native null-source branch skips the raw pair load
    g_raw_call.frame = dm_guest_frame();
    if (!dm_hid_look_sample_at(g_raw_call.frame, &g_raw_call.hid)) return;
    const uint8_t *child = (const uint8_t *)(uintptr_t)regs[0];
    memcpy(&g_raw_call.raw_x, child + g_camera.source_pair, sizeof(float));
    memcpy(&g_raw_call.raw_y, child + g_camera.source_pair + sizeof(float), sizeof(float));
    g_raw_call.valid = isfinite(g_raw_call.raw_x) && isfinite(g_raw_call.raw_y);
    if (g_compose && regs[29] && regs[29] <= UINTPTR_MAX - 24) {
        // The validated getter saves LR at FP+8 and the caller's x19 at FP+16.
        // Match both the exact call site and the owning camera before diverting input.
        uint64_t caller, action, vtable;
        memcpy(&caller, (const void *)(uintptr_t)(regs[29] + 8), sizeof caller);
        for (int i = 0; i < 2; i++) if (caller == (uint64_t)(uintptr_t)g_camera.main->base + g_aim[i].caller) {
            memcpy(&action, (const void *)(uintptr_t)(regs[29] + 16), sizeof action);
            if (!action) break;
            memcpy(&vtable, (const void *)(uintptr_t)action, sizeof vtable);
            if (vtable == (uint64_t)(uintptr_t)g_camera.main->base + g_aim[i].vtable) {
                g_raw_call.aim_camera = i; g_raw_call.action = action;
            }
            break;
        }
    }
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

static int raw_matches_relative(void) {
    // A manual virtual stick and keyboard/script axes keep their native curve.
    // Only a sample owned by a relative gesture can be replaced or cancelled.
    if (!g_raw_call.valid || g_raw_call.hid.source != DM_HID_LOOK_RELATIVE) return 0;
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
    int raw_match = sample_valid && raw_matches_relative();
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
    if (g_compose && g_raw_call.aim_camera >= 0) {
        if (sample_valid && raw_match && !physical) {
            if (g_aim_call.frame != frame || g_aim_call.action != g_raw_call.action ||
                g_aim_call.camera != g_raw_call.aim_camera) g_aim_call.consumed = 0;
            g_aim_call.frame = frame; g_aim_call.action = g_raw_call.action;
            g_aim_call.camera = g_raw_call.aim_camera;
            // Let native gyro selection and tracking run, even while the finger moves.
            out_x = out_y = 0;
        } else g_aim_call.action = 0;
    }
    if (out_x != x || out_y != y) {
        memcpy(native, &out_x, sizeof out_x); memcpy(native + 1, &out_y, sizeof out_y);
    }
    uint32_t raw_bits[2];
    memcpy(raw_bits, &g_raw_call.raw_x, sizeof raw_bits);
    if (sample_valid && g_trace && (drag_active || physical || raw_match))
        LOG("look: source frame=%llu raw=(%a,%a) bits=(%08x,%08x) selected=(%d,%d) virtual=(%d,%d) physical=(%d,%d) source=%d match=%d native=(%.5f,%.5f) out=(%.5f,%.5f) aim=%d",
            (unsigned long long)frame, g_raw_call.raw_x, g_raw_call.raw_y,
            raw_bits[0], raw_bits[1],
            g_raw_call.hid.selected_rx, g_raw_call.hid.selected_ry,
            g_raw_call.hid.virtual_rx, g_raw_call.hid.virtual_ry,
            g_raw_call.hid.physical_rx, g_raw_call.hid.physical_ry,
            g_raw_call.hid.source, raw_match, x, y, out_x, out_y, g_raw_call.aim_camera);
    memset(&g_raw_call, 0, sizeof g_raw_call);
}

static float aim_delta(uint64_t action, int camera, int axis) {
    if (!g_compose || camera < 0 || camera >= 2 || !action || g_aim_call.action != action ||
        g_aim_call.camera != camera || g_aim_call.frame != dm_guest_frame() ||
        (g_aim_call.consumed & axis)) return 0;
    pthread_mutex_lock(&g_look_mu);
    float delta = 0;
    if (g_available && g_have_snapshot && !g_suppress_snapshot && g_snapshot_frame == g_aim_call.frame) {
        delta = (axis == 1 ? -g_sample_dx : g_sample_dy) * g_aim_gain;
        g_aim_call.consumed |= axis;
    }
    pthread_mutex_unlock(&g_look_mu);
    if (!isfinite(delta)) die("[RED] look: aim displacement overflow");
    return delta;
}

static float wrap_degrees(float value) {
    value = fmodf(value + 180, 360);
    if (value < 0) value += 360;
    return value - 180;
}

static void camera_aim_pitch(uint64_t *regs, int camera) {
    if (camera < 0 || camera >= 2) return;
    float delta = aim_delta(regs[19], camera, 2);
    if (!delta && !g_trace) return;
    uint8_t *action = (uint8_t *)(uintptr_t)regs[19];
    const aim_compose_t *aim = &g_aim[camera];
    float target, base, lo, hi;
    // entry.S saves q0 at byte 256. Change only its low float, the native pitch target.
    memcpy(&target, (uint8_t *)regs + 256, sizeof target);
    memcpy(&base, action + aim->pitch_base, sizeof base);
    memcpy(&lo, action + aim->pitch_min, sizeof lo);
    memcpy(&hi, action + aim->pitch_max, sizeof hi);
    if (g_trace) {
        uint64_t frame = dm_guest_frame();
        LOG("look: aim camera=%d frame=%llu pitch=%.6f base=%.6f bounds=(%.3f,%.3f) touch=%.6f owned=%d",
            camera,(unsigned long long)frame,target,base,lo,hi,delta,
            g_aim_call.action == regs[19] && g_aim_call.frame == frame);
    }
    if (!delta) return;
    if (!isfinite(target) || !isfinite(base) || !isfinite(lo) || !isfinite(hi) || lo > hi)
        die("[RED] look: invalid native aim pitch or bounds");
    float next = fminf(hi, fmaxf(lo, target + delta));
    base = fminf(hi, fmaxf(lo, base + next - target));
    memcpy((uint8_t *)regs + 256, &next, sizeof next);
    memcpy(action + aim->pitch_base, &base, sizeof base);
    if (g_trace) LOG("look: compose camera=%d frame=%llu pitch=%.3f touch=%.3f",
        camera, (unsigned long long)g_aim_call.frame, next, delta);
}

static void camera_aim_yaw(uint64_t *regs, int camera) {
    if (camera < 0 || camera >= 2) return;
    float delta = aim_delta(regs[19], camera, 1);
    if (!delta) return;
    uint8_t *action = (uint8_t *)(uintptr_t)regs[19];
    const aim_compose_t *aim = &g_aim[camera];
    if (regs[29] < aim->yaw_stack) die("[RED] look: invalid native aim frame");
    void *output = (void *)(uintptr_t)(regs[29] - aim->yaw_stack);
    float target, current;
    memcpy(&target, action + aim->yaw_base, sizeof target);
    memcpy(&current, output, sizeof current);
    if (!isfinite(target) || !isfinite(current)) die("[RED] look: invalid native aim yaw");
    target = wrap_degrees(target + delta); current = wrap_degrees(current + delta);
    memcpy(action + aim->yaw_base, &target, sizeof target);
    memcpy(output, &current, sizeof current);
    if (g_trace) LOG("look: compose camera=%d frame=%llu yaw=%.3f touch=%.3f",
        camera, (unsigned long long)g_aim_call.frame, current, delta);
}

static void aim_compose_install(const char *look_build) {
    g_compose = 0;
    if (!*DM_GAME_CAMERA_LOOK_COMPOSE) return;
    char build[33] = {0}; unsigned long long v[14]; float gain; int used = 0;
    int n = sscanf(DM_GAME_CAMERA_LOOK_COMPOSE,
        "%32[0-9a-f]:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%f%n",
        build, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6],
        &v[7], &v[8], &v[9], &v[10], &v[11], &v[12], &v[13], &gain, &used);
    if (n != 16 || DM_GAME_CAMERA_LOOK_COMPOSE[used] || strcmp(build, look_build) ||
        !isfinite(gain) || gain <= 0 || gain > 3600)
        die("[RED] look: malformed or mismatched camera_look_compose profile");
    for (int i = 0; i < 2; i++) {
        unsigned long long *a = v + 7 * i;
        if (!a[0] || a[0] >= g_camera.main->text_end || !a[1] || a[1] > g_camera.main->size - sizeof(uint64_t) ||
            a[2] > 0x10000 - sizeof(float) || a[3] > 0x10000 - sizeof(float) ||
            a[4] > 0x10000 - sizeof(float) || a[5] > 0x10000 - sizeof(float) || !a[6] || a[6] > 0x1000)
            die("[RED] look: camera_look_compose offsets are out of range");
        g_aim[i] = (aim_compose_t){a[0], a[1], a[2], a[3], a[4], a[5], a[6]};
    }
    const char *e = getenv("DM_LOOK_GYRO_COMPOSE");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK_GYRO_COMPOSE must be 0 or 1");
    if (e && !strcmp(e, "0")) return;
    if (!gate_obs_present(OBS_BOTW_LOOK_PITCH) || !gate_obs_present(OBS_BOTW_LOOK_YAW))
        die("[RED] look: composition gates missing; rewrite main with the experimental patch_nso.py");
    g_aim_gain = gain; g_compose = 1;
    gate_obs_set(OBS_BOTW_LOOK_PITCH, camera_aim_pitch);
    gate_obs_set(OBS_BOTW_LOOK_YAW, camera_aim_yaw);
    LOG("look: experimental touch/gyro aiming composition (%.1f degrees per normalized short edge)", gain);
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
    gate_obs_read_set(OBS_BOTW_LOOK_SOURCE, camera_look_source);
    gate_obs_read_set(OBS_BOTW_LOOK_VECTOR, camera_look_vector);
    aim_compose_install(build);
    dm_look_set_available(1);
    front_look_mode_changed();
    LOG("look: BOTW shared stick vector main+%#llx installed for build %s (%.1f normalized-input impulse per short edge)",
        (unsigned long long)g_camera.hook, build, gain);
}

#ifdef DM_TEST_HOOKS
void dm_look_test_input_at(int phase, float dx, float dy, uint64_t frame) { look_input_at(phase, dx, dy, frame); }
void dm_look_test_vector_config(module_t *main, float gain) {
    g_compose = 0; memset(&g_aim_call, 0, sizeof g_aim_call);
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
