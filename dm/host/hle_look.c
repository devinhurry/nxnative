// Relative look input: the front end sums pointer displacement here; a guest camera update consumes it once.
#include "hle.h"
#include "front.h"
#include <math.h>

static pthread_mutex_t g_look_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_available, g_held, g_have_frame;
static uint64_t g_last_frame, g_pending_frame;
static float g_dx, g_dy;
typedef struct {
    module_t *main;
    uint64_t hook, chase_vtable, state_init, camera_getter, camera_member;
    uint64_t control_ptr, state_mode;
    uint64_t pitch_base, pitch_velocity, yaw_base, yaw_velocity;
    uint64_t pitch_min, pitch_max, camera_manual, camera_status;
    float gain;
    int trace;
    uint64_t injections;
} camera_look_t;
static camera_look_t g_camera;
typedef struct {
    uint64_t hook, vtable, state_init, state_mode;
    uint64_t pitch_base, pitch_history_a, pitch_history_b;
    uint64_t yaw_base, yaw_history_a, yaw_history_b;
} camera_look_tail_t;
static camera_look_tail_t g_tail;
#ifdef DM_TEST_HOOKS
static void *(*g_test_camera_getter)(void *);
static void (*g_test_state_init)(void *);
static void (*g_test_tail_state_init)(void *);
#endif

int dm_look_enabled(void) {
    pthread_mutex_lock(&g_look_mu);
    int enabled = g_available;
    pthread_mutex_unlock(&g_look_mu);
    return enabled;
}

// The build-checked camera installer will enable input only after its guest gate is attached.
static void dm_look_set_available(int available) {
    if (available != 0 && available != 1) die("[RED] look: available must be 0 or 1");
    pthread_mutex_lock(&g_look_mu);
    if (g_available != available) {
        g_available = available;
        g_held = g_dx = g_dy = 0;
        g_have_frame = 0;
        g_last_frame = g_pending_frame = 0;
    }
    pthread_mutex_unlock(&g_look_mu);
}

static float wrap_degrees(float v) {
    v = fmodf(v + 180.0f, 360.0f);
    if (v < 0) v += 360.0f;
    return v - 180.0f;
}

static void look_apply_delta(float pitch, float yaw, float dx, float dy, float gain,
                             float pitch_min, float pitch_max, float *next_pitch, float *next_yaw) {
    if (!isfinite(pitch) || !isfinite(yaw) || !isfinite(dx) || !isfinite(dy) || !isfinite(gain) ||
        !isfinite(pitch_min) || !isfinite(pitch_max) || pitch_min >= pitch_max || gain <= 0 ||
        !next_pitch || !next_yaw) die("[RED] look: invalid polar delta inputs");
    float p = pitch + dy * gain;
    float y = yaw - dx * gain;
    if (!isfinite(p) || !isfinite(y)) die("[RED] look: polar delta overflow");
    *next_pitch = fminf(pitch_max, fmaxf(pitch_min, p));
    *next_yaw = wrap_degrees(y);
}

static void *look_camera_get(void *owner) {
#ifdef DM_TEST_HOOKS
    if (g_test_camera_getter) return g_test_camera_getter(owner);
#endif
    return ((void *(*)(void *))(g_camera.main->base + g_camera.camera_getter))(owner);
}

static void look_state_init(void *action) {
#ifdef DM_TEST_HOOKS
    if (g_test_state_init) { g_test_state_init(action); return; }
#endif
    ((void (*)(void *))(g_camera.main->base + g_camera.state_init))(action);
}

static void look_tail_state_init(void *action) {
#ifdef DM_TEST_HOOKS
    if (g_test_tail_state_init) { g_test_tail_state_init(action); return; }
#endif
    ((void (*)(void *))(g_camera.main->base + g_tail.state_init))(action);
}

static void look_input_at(int phase, float dx, float dy, uint64_t frame) {
    if (phase < DM_LOOK_BEGIN || phase > DM_LOOK_CANCEL) die("[RED] look: invalid input phase %d", phase);
    if (!isfinite(dx) || !isfinite(dy)) die("[RED] look: non-finite pointer delta");
    pthread_mutex_lock(&g_look_mu);
    if (!g_available) { pthread_mutex_unlock(&g_look_mu); return; }
    if (g_have_frame && frame > g_last_frame && frame - g_last_frame > 1) g_dx = g_dy = 0;
    switch (phase) {
    case DM_LOOK_BEGIN:
        if (g_held) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: nested BEGIN"); }
        g_held = 1; g_pending_frame = frame;
        break;
    case DM_LOOK_MOVE:
        if (!g_held) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: MOVE outside a drag"); }
        g_dx += dx; g_dy += dy; g_pending_frame = frame;
        if (!isfinite(g_dx) || !isfinite(g_dy)) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: accumulated pointer delta overflow"); }
        break;
    case DM_LOOK_END:
        if (!g_held) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: END outside a drag"); }
        g_held = 0;
        break;
    case DM_LOOK_CANCEL:
        g_held = 0; g_dx = g_dy = 0; g_pending_frame = frame;
        break;
    }
    pthread_mutex_unlock(&g_look_mu);
}

void dm_look_input(int phase, float dx, float dy) {
    look_input_at(phase, dx, dy, dm_guest_frame());
}

// Called by the build-specific guest camera callback. Inactive modes and gaps discard queued movement,
// but preserve a held drag so fresh movement can apply after returning to ordinary third-person camera.
static void dm_look_consume(uint64_t frame, int manual_camera, float *dx, float *dy) {
    if (!dx || !dy) die("[RED] look: null consume output");
    if (manual_camera != 0 && manual_camera != 1) die("[RED] look: manual-camera state must be 0 or 1");
    pthread_mutex_lock(&g_look_mu);
    if (g_have_frame && frame < g_last_frame) { pthread_mutex_unlock(&g_look_mu); die("[RED] look: guest frame moved backwards"); }
    int gap = g_have_frame && frame - g_last_frame > 1;
    if (!manual_camera || gap || (!g_have_frame && (g_dx != 0 || g_dy != 0) && frame > g_pending_frame + 1)) g_dx = g_dy = 0;
    *dx = g_dx; *dy = g_dy;
    g_dx = g_dy = 0;
    g_last_frame = frame; g_have_frame = 1;
    pthread_mutex_unlock(&g_look_mu);
}

static void camera_look_update(const uint64_t *regs) {
    uint8_t *action = (uint8_t *)(uintptr_t)regs[0];
    float *polar = (float *)(uintptr_t)regs[1];
    if (!action) die("[RED] look: camera update supplied a null action");
    if (*(uint64_t *)action != (uint64_t)(g_camera.main->base + g_camera.chase_vtable)) {
        float ignored_dx, ignored_dy;
        dm_look_consume(dm_guest_frame(), 0, &ignored_dx, &ignored_dy);
        return;
    }
    if (!polar) die("[RED] look: CameraChase supplied a null polar tuple");

    uint8_t *camera = look_camera_get(action + g_camera.camera_member);
    if (!camera) die("[RED] look: CameraChase has no camera state");
    uint64_t control_ptr;
    memcpy(&control_ptr, action + g_camera.control_ptr, sizeof control_ptr);
    if (!control_ptr) die("[RED] look: CameraChase control-mode parameter pointer is null");
    int32_t control_mode; uint8_t camera_status;
    memcpy(&control_mode, (void *)(uintptr_t)control_ptr, sizeof control_mode);
    memcpy(&camera_status, camera + g_camera.camera_status, sizeof camera_status);
    uint8_t current_mode;
    memcpy(&current_mode, action + g_camera.state_mode, sizeof current_mode);
    int manual = control_mode == 1 && (current_mode == 2 || current_mode == 3) && !(camera_status & 1);
    uint64_t frame = dm_guest_frame();
    float dx, dy;
    dm_look_consume(frame, manual, &dx, &dy);
    if (!manual || (dx == 0 && dy == 0)) return;

    uint8_t *mode = action + g_camera.state_mode;
    int entering_manual = *mode != 3;
    if (entering_manual) {
        *mode = 3;
        look_state_init(action);
        if (*mode != 3) die("[RED] look: native CameraChase state-3 initializer left another mode active");
        camera = look_camera_get(action + g_camera.camera_member);
        if (!camera) die("[RED] look: native CameraChase initialization left no camera state");
    }

    float radius, polar_pitch, polar_yaw, pitch, yaw, pitch_min, pitch_max;
    memcpy(&radius, polar, sizeof radius);
    memcpy(&polar_pitch, polar + 1, sizeof polar_pitch);
    memcpy(&polar_yaw, polar + 2, sizeof polar_yaw);
    memcpy(&pitch_min, action + g_camera.pitch_min, sizeof pitch_min);
    memcpy(&pitch_max, action + g_camera.pitch_max, sizeof pitch_max);
    if (!isfinite(radius) || radius <= 0 || !isfinite(polar_pitch) || !isfinite(polar_yaw) ||
        !isfinite(pitch_min) || !isfinite(pitch_max) || pitch_min >= pitch_max)
        die("[RED] look: invalid CameraChase polar tuple or pitch limits");
    if (entering_manual) {
        memcpy(&pitch, action + g_camera.pitch_base, sizeof pitch);
        memcpy(&yaw, action + g_camera.yaw_base, sizeof yaw);
    } else { pitch = polar_pitch; yaw = polar_yaw; }
    float next_pitch, next_yaw;
    look_apply_delta(pitch, yaw, dx, dy, g_camera.gain, pitch_min, pitch_max, &next_pitch, &next_yaw);

    // Keep the game's polar accumulator in sync and remove its stick-derived angular velocity.
    memcpy(action + g_camera.pitch_base, &next_pitch, sizeof next_pitch);
    memcpy(action + g_camera.pitch_velocity, &(float){0}, sizeof(float));
    memcpy(action + g_camera.yaw_base, &next_yaw, sizeof next_yaw);
    memcpy(action + g_camera.yaw_velocity, &(float){0}, sizeof(float));
    memcpy(polar + 1, &next_pitch, sizeof next_pitch);
    memcpy(polar + 2, &next_yaw, sizeof next_yaw);
    uint16_t flags;
    memcpy(&flags, camera + g_camera.camera_manual, sizeof flags);
    flags |= 1;
    memcpy(camera + g_camera.camera_manual, &flags, sizeof flags);
    g_camera.injections++;
    if (g_camera.trace) LOG("look: #%llu frame=%llu d=(%.5f,%.5f) angle=(%.3f,%.3f) mode=%u",
                            (unsigned long long)g_camera.injections, (unsigned long long)frame, dx, dy, next_pitch, next_yaw, *mode);
}

static void camera_look_tail_update(const uint64_t *regs) {
    uint8_t *action = (uint8_t *)(uintptr_t)regs[20];
    uint8_t *camera = (uint8_t *)(uintptr_t)regs[19];
    if (!action) die("[RED] look: CameraTail update supplied a null action");
    if (*(uint64_t *)action != (uint64_t)(g_camera.main->base + g_tail.vtable)) {
        float ignored_dx, ignored_dy;
        dm_look_consume(dm_guest_frame(), 0, &ignored_dx, &ignored_dy);
        return;
    }
    if (!camera) die("[RED] look: CameraTail update supplied a null camera state");

    uint8_t current_mode, camera_status;
    memcpy(&current_mode, action + g_tail.state_mode, sizeof current_mode);
    memcpy(&camera_status, camera + g_camera.camera_status, sizeof camera_status);
    int manual = current_mode <= 4 && !(camera_status & 1);
    uint64_t frame = dm_guest_frame();
    float dx, dy;
    dm_look_consume(frame, manual, &dx, &dy);
    if (!manual || (dx == 0 && dy == 0)) return;

    uint8_t *mode = action + g_tail.state_mode;
    int entering_manual = *mode != 4;
    if (entering_manual) {
        *mode = 4;
        look_tail_state_init(action);
        if (*mode != 4) die("[RED] look: native CameraTail mode-4 initializer left another mode active");
    }

    float pitch, yaw;
    memcpy(&pitch, action + g_tail.pitch_base, sizeof pitch);
    memcpy(&yaw, action + g_tail.yaw_base, sizeof yaw);
    if (!isfinite(pitch) || !isfinite(yaw) || !isfinite(g_camera.gain) || g_camera.gain <= 0)
        die("[RED] look: invalid CameraTail angles or gain");
    float next_pitch = pitch + dy * g_camera.gain;
    float next_yaw = wrap_degrees(yaw - dx * g_camera.gain);
    if (!isfinite(next_pitch) || !isfinite(next_yaw)) die("[RED] look: CameraTail angle overflow");

    memcpy(action + g_tail.pitch_base, &next_pitch, sizeof next_pitch);
    memcpy(action + g_tail.pitch_history_a, &(float){0}, sizeof(float));
    memcpy(action + g_tail.pitch_history_b, &(float){0}, sizeof(float));
    memcpy(action + g_tail.yaw_base, &next_yaw, sizeof next_yaw);
    memcpy(action + g_tail.yaw_history_a, &(float){0}, sizeof(float));
    memcpy(action + g_tail.yaw_history_b, &(float){0}, sizeof(float));
    g_camera.injections++;
    if (g_camera.trace) LOG("look: #%llu frame=%llu d=(%.5f,%.5f) tail-angle=(%.3f,%.3f) mode=%u",
                            (unsigned long long)g_camera.injections, (unsigned long long)frame, dx, dy, next_pitch, next_yaw, *mode);
}

void dm_look_install(void) {
    if (!*DM_GAME_CAMERA_LOOK && !*DM_GAME_CAMERA_LOOK_TAIL) return;
    if (!*DM_GAME_CAMERA_LOOK || !*DM_GAME_CAMERA_LOOK_TAIL)
        die("[RED] look: CameraChase and CameraTail profile settings must be configured together");
    char build[33] = {0}; unsigned long long v[15]; float gain; int used = 0;
    int n = sscanf(DM_GAME_CAMERA_LOOK,
        "%32[0-9a-f]:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%f%n",
        build, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8], &v[9], &v[10], &v[11], &v[12], &v[13], &v[14], &gain, &used);
    if (n != 17 || DM_GAME_CAMERA_LOOK[used]) die("[RED] look: malformed camera_look profile");
    char tail_build[33] = {0}; unsigned long long tv[10]; int tail_used = 0;
    n = sscanf(DM_GAME_CAMERA_LOOK_TAIL,
        "%32[0-9a-f]:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx:%llx%n",
        tail_build, &tv[0], &tv[1], &tv[2], &tv[3], &tv[4], &tv[5], &tv[6], &tv[7], &tv[8], &tv[9], &tail_used);
    if (n != 11 || DM_GAME_CAMERA_LOOK_TAIL[tail_used]) die("[RED] look: malformed camera_look_tail profile");
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) g_camera.main = &g_mod[i];
    if (!g_camera.main || strcmp(build, g_camera.main->build_id))
        die("[RED] look: camera_look requires main build %s (loaded %s)", build, dm_main_build());
    if (strcmp(tail_build, build)) die("[RED] look: CameraChase and CameraTail profile build IDs differ");
    if (!isfinite(gain) || gain <= 0 || gain > 3600 || v[0] >= g_camera.main->text_end ||
        v[2] >= g_camera.main->text_end || v[3] >= g_camera.main->text_end ||
        v[1] + sizeof(uint64_t) > g_camera.main->size || v[4] > 0x10000 || v[5] > 0x10000 ||
        v[6] > 0x10000 || v[7] > 0x10000 || v[8] > 0x10000 || v[9] > 0x10000 ||
        v[10] > 0x10000 || v[11] > 0x10000 || v[12] > 0x10000 || v[13] > 0x10000 ||
        v[14] > 0x10000)
        die("[RED] look: camera_look offsets or gain are out of range");
    if (tv[0] >= g_camera.main->text_end || tv[2] >= g_camera.main->text_end ||
        tv[1] > g_camera.main->size - sizeof(uint64_t) ||
        tv[3] > 0x10000 || tv[4] > 0x10000 || tv[5] > 0x10000 || tv[6] > 0x10000 ||
        tv[7] > 0x10000 || tv[8] > 0x10000 || tv[9] > 0x10000)
        die("[RED] look: CameraTail offsets are out of range");
    if (!gate_obs_present(OBS_BOTW_CAMERA_LOOK) || !gate_obs_present(OBS_BOTW_CAMERA_TAIL_LOOK))
        die("[RED] look: CameraChase or CameraTail gate missing; rewrite main with the current patch_nso.py");
    const char *e = getenv("DM_LOOK");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK must be 0 or 1");
    if (e && !strcmp(e, "0")) { LOG("look: disabled by DM_LOOK=0"); return; }
    g_camera.hook = v[0]; g_camera.chase_vtable = v[1]; g_camera.state_init = v[2]; g_camera.camera_getter = v[3];
    g_camera.camera_member = v[4]; g_camera.control_ptr = v[5]; g_camera.state_mode = v[6];
    g_camera.pitch_base = v[7]; g_camera.pitch_velocity = v[8]; g_camera.yaw_base = v[9]; g_camera.yaw_velocity = v[10];
    g_camera.pitch_min = v[11]; g_camera.pitch_max = v[12]; g_camera.camera_manual = v[13]; g_camera.camera_status = v[14];
    g_camera.gain = gain;
    g_tail.hook = tv[0]; g_tail.vtable = tv[1]; g_tail.state_init = tv[2]; g_tail.state_mode = tv[3];
    g_tail.pitch_base = tv[4]; g_tail.pitch_history_a = tv[5]; g_tail.pitch_history_b = tv[6];
    g_tail.yaw_base = tv[7]; g_tail.yaw_history_a = tv[8]; g_tail.yaw_history_b = tv[9];
    e = getenv("DM_LOOK_TRACE");
    if (e && strcmp(e, "0") && strcmp(e, "1")) die("[RED] DM_LOOK_TRACE must be 0 or 1");
    g_camera.trace = e && !strcmp(e, "1");
    gate_obs_set(OBS_BOTW_CAMERA_LOOK, camera_look_update);
    gate_obs_set(OBS_BOTW_CAMERA_TAIL_LOOK, camera_look_tail_update);
    dm_look_set_available(1);
    LOG("look: CameraChase main+%#llx and CameraTail main+%#llx installed for build %s (%.1f degrees per normalized short edge)",
        (unsigned long long)g_camera.hook, (unsigned long long)g_tail.hook, build, gain);
}

#ifdef DM_TEST_HOOKS
void dm_look_test_input_at(int phase, float dx, float dy, uint64_t frame) { look_input_at(phase, dx, dy, frame); }
void dm_look_test_camera_config(module_t *main, float gain) { g_camera.main = main; g_camera.gain = gain; }
void dm_look_test_camera_offsets(void) {
    g_camera.chase_vtable = 0x1000; g_camera.camera_getter = 0; g_camera.state_init = 0;
    g_camera.camera_member = 0x20; g_camera.control_ptr = 0x40; g_camera.state_mode = 0x50;
    g_camera.pitch_base = 0x60; g_camera.pitch_velocity = 0x64; g_camera.yaw_base = 0x68; g_camera.yaw_velocity = 0x6c;
    g_camera.pitch_min = 0x70; g_camera.pitch_max = 0x74; g_camera.camera_manual = 0x105c; g_camera.camera_status = 0x1073;
}
void dm_look_test_camera_functions(void *(*getter)(void *), void (*init)(void *)) { g_test_camera_getter = getter; g_test_state_init = init; }
void dm_look_test_tail_config(void) {
    g_tail.hook = 0x200; g_tail.vtable = 0x1100; g_tail.state_init = 0; g_tail.state_mode = 0x80;
    g_tail.pitch_base = 0x90; g_tail.pitch_history_a = 0x94; g_tail.pitch_history_b = 0x98;
    g_tail.yaw_base = 0x9c; g_tail.yaw_history_a = 0xa0; g_tail.yaw_history_b = 0xa4;
}
void dm_look_test_tail_state_init(void (*init)(void *)) { g_test_tail_state_init = init; }
#endif
