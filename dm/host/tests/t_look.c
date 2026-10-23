#include "../hle_look.c"
#include <assert.h>
#include <math.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
static int test_gate_present, test_gate_installed, test_gate_count, test_missing_gate;
int gate_obs_present(int id) { return (id == OBS_BOTW_CAMERA_LOOK || id == OBS_BOTW_CAMERA_TAIL_LOOK) && test_gate_present && id != test_missing_gate; }
void gate_obs_set(int id, void (*fn)(const uint64_t *regs)) {
    assert((id == OBS_BOTW_CAMERA_LOOK || id == OBS_BOTW_CAMERA_TAIL_LOOK) && fn);
    test_gate_installed = 1; test_gate_count++;
}
uint64_t dm_guest_frame(void) { return 0; }

static int cases, fails;
static void check(const char *name, int ok) {
    cases++;
    if (!ok) { fprintf(stderr, "FAIL %s\n", name); fails++; }
}
static int near(float a, float b) { return fabsf(a - b) <= 1e-6f; }
static void reset(void) { dm_look_set_available(0); dm_look_set_available(1); }
static void consume(uint64_t frame, int active, float *x, float *y) { dm_look_consume(frame, active, x, y); }

static void test_sum(int refresh_hz) {
    reset();
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 100);
    int events_per_frame = refresh_hz == 30 ? 4 : 2; // 12 samples of a 120 Hz gesture, batched by the game's update rate.
    int frames = 12 / events_per_frame;
    float total_x = 0, total_y = 0, x, y;
    for (int f = 0; f < frames; f++) {
        for (int e = 0; e < events_per_frame; e++)
            dm_look_test_input_at(DM_LOOK_MOVE, 1.0f / 12, -0.5f / 12, 100 + f);
        consume(100 + f, 1, &x, &y);
        total_x += x; total_y += y;
    }
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 100 + frames);
    consume(100 + frames, 1, &x, &y);
    total_x += x; total_y += y;
    check(refresh_hz == 30 || refresh_hz == 60 ? "same 120 Hz gesture sums equally at 30/60 Hz guest updates" : "unexpected test refresh rate",
          near(total_x, 1.0f) && near(total_y, -0.5f));
}

static void test_once_and_tail(void) {
    reset();
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 10);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.75f, -0.25f, 10);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 10);
    float x, y;
    consume(10, 1, &x, &y);
    check("END preserves the final unconsumed movement", near(x, 0.75f) && near(y, -0.25f));
    consume(10, 1, &x, &y);
    check("each movement is consumed exactly once", x == 0 && y == 0);

    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 11);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.25f, 0, 11);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 11);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 11);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.5f, 0, 11);
    consume(11, 1, &x, &y);
    check("a new drag before consumption preserves the previous END tail", near(x, 0.75f) && y == 0);
}

static void test_reverse(void) {
    reset();
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 30);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.375f, -0.125f, 30);
    dm_look_test_input_at(DM_LOOK_MOVE, -0.375f, 0.125f, 30);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 30);
    float x, y;
    consume(30, 1, &x, &y);
    check("reverse pointer travel cancels accumulated displacement", fabsf(x) < 1e-7f && fabsf(y) < 1e-7f);
}

static void test_angles(void) {
    float p, y;
    look_apply_delta(0, 0, 0.25f, 0.125f, 180, -85, 89, &p, &y);
    check("angular conversion is direct and independent of elapsed frames", near(p, 22.5f) && near(y, -45));
    look_apply_delta(88, -179, 0.25f, 0.25f, 180, -85, 89, &p, &y);
    check("pitch clamps and yaw wraps at the native polar limits", near(p, 89) && near(y, 136));
    look_apply_delta(0, 179, 0.25f, 0, 180, -85, 89, &p, &y);
    look_apply_delta(p, y, -0.25f, 0, 180, -85, 89, &p, &y);
    check("reverse travel cancels across the yaw wrap", near(y, 179));
    look_apply_delta(12, -40, 0.25f, 0.125f, 180, -85, 89, &p, &y);
    float p2, y2;
    look_apply_delta(p, y, -0.25f, -0.125f, 180, -85, 89, &p2, &y2);
    check("reverse deltas cancel angle to floating precision", fabsf(p2 - 12) < 1e-6f && fabsf(y2 + 40) < 1e-6f);
}

typedef struct { float pitch, yaw; } angle_result;
static angle_result angle_run(int refresh_hz) {
    float pitch = 0, yaw = 0, x, y;
    int events_per_frame = refresh_hz == 30 ? 4 : 2;
    for (int frame = 0; frame < 12 / events_per_frame; frame++) {
        x = y = 0;
        for (int event = 0; event < events_per_frame; event++) { x += 1.0f / 12; y += -0.5f / 12; }
        float p, a;
        look_apply_delta(pitch, yaw, x, y, 180, -85, 89, &p, &a);
        pitch = p; yaw = a;
    }
    return (angle_result){pitch, yaw};
}

static void test_angle_refresh_rates(void) {
    angle_result at30 = angle_run(30), at60 = angle_run(60);
    check("summed gesture produces the same final angles at 30 and 60 Hz",
          fabsf(at30.pitch - at60.pitch) < 1e-4f && fabsf(at30.yaw - at60.yaw) < 1e-4f);
}

static void test_cancel_and_inactive(void) {
    reset();
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 20);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.5f, 0.2f, 20);
    dm_look_test_input_at(DM_LOOK_CANCEL, 0, 0, 20);
    float x, y;
    consume(20, 1, &x, &y);
    check("CANCEL clears held and pending input", x == 0 && y == 0);

    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 21);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.4f, 0.1f, 21);
    consume(21, 0, &x, &y);
    check("inactive camera mode discards queued input", x == 0 && y == 0);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.1f, 0.2f, 22);
    consume(22, 1, &x, &y);
    check("held drag accepts fresh movement after mode resumes", near(x, 0.1f) && near(y, 0.2f));
}

static void test_frame_gap(void) {
    reset();
    float x, y;
    consume(100, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 101);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.6f, -0.3f, 101);
    consume(150, 1, &x, &y);
    check("frame gap discards movement accumulated while camera mode was inactive", x == 0 && y == 0);
    dm_look_test_input_at(DM_LOOK_MOVE, -0.2f, 0.1f, 150);
    consume(150, 1, &x, &y);
    check("fresh movement after a frame gap still applies", near(x, -0.2f) && near(y, 0.1f));

    reset();
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 10);
    dm_look_test_input_at(DM_LOOK_MOVE, 0, 0.4f, 10);
    consume(20, 1, &x, &y);
    check("vertical-only input is discarded on the first update after a frame gap", x == 0 && y == 0);
}

typedef void (*bad_call)(void);
static void invalid_phase(void) { dm_look_test_input_at(99, 0, 0, 0); }
static void nonfinite_delta(void) { dm_look_test_input_at(DM_LOOK_BEGIN, NAN, 0, 0); }
static void expect_abort(const char *name, bad_call fn) {
    pid_t p = fork();
    if (!p) { freopen("/dev/null", "w", stderr); fn(); _exit(0); }
    int status = 0;
    if (p < 0 || waitpid(p, &status, 0) != p) { check(name, 0); return; }
    check(name, WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}

static void wrong_build(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "00000000000000000000000000000000");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = 0x1000000;
    test_gate_present = 1; dm_look_install();
}
static void missing_gate(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = 0x1000000;
    test_gate_present = 0; dm_look_install();
}
static void missing_tail_gate(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = 0x1000000;
    test_gate_present = 1; test_missing_gate = OBS_BOTW_CAMERA_TAIL_LOOK; dm_look_install();
}
static void test_install_guard(void) {
    static uint8_t image[0x2000000];
    unsetenv("DM_LOOK"); unsetenv("DM_LOOK_TRACE");
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = 0x1000000;
    test_gate_present = 1; test_gate_installed = test_gate_count = test_missing_gate = 0;
    dm_look_install();
    check("matching build and both observation gates enable the backend", dm_look_enabled() && test_gate_installed && test_gate_count == 2);
    expect_abort("camera backend rejects a different main build", wrong_build);
    expect_abort("camera backend rejects a missing rewritten gate", missing_gate);
    expect_abort("camera backend rejects a missing CameraTail gate", missing_tail_gate);
    dm_look_set_available(0);
}

static uint8_t *fake_camera;
static int fake_init_count;
static uint8_t *fake_action;
static void *fake_camera_getter(void *owner) { assert(owner == fake_action + 0x20); return fake_camera; }
static void fake_state_init(void *obj) {
    uint8_t *a = obj; fake_init_count++;
    float pitch = 5, yaw = 10;
    memcpy(a + 0x60, &pitch, sizeof pitch); memcpy(a + 0x68, &yaw, sizeof yaw);
}
static void fake_tail_state_init(void *obj) {
    uint8_t *a = obj; assert(a == fake_action); fake_init_count++;
    float pitch = 5, yaw = 10, history = 3;
    memcpy(a + 0x90, &pitch, sizeof pitch); memcpy(a + 0x9c, &yaw, sizeof yaw);
    memcpy(a + 0x94, &history, sizeof history); memcpy(a + 0x98, &history, sizeof history);
    memcpy(a + 0xa0, &history, sizeof history); memcpy(a + 0xa4, &history, sizeof history);
}

static void send_camera_delta(uint64_t *regs, float dx, float dy) {
    dm_look_test_input_at(DM_LOOK_MOVE, dx, dy, 0);
    camera_look_update(regs);
}

static void send_tail_delta(uint64_t *regs, float dx, float dy) {
    dm_look_test_input_at(DM_LOOK_MOVE, dx, dy, 0);
    camera_look_tail_update(regs);
}

static void test_camera_callback(void) {
    static uint8_t image[0x2000], action[0x400], camera[0x1100];
    static int32_t control_mode;
    module_t main = {0}; strcpy(main.name, "main"); main.base = image; main.size = sizeof image;
    dm_look_test_camera_config(&main, 180); dm_look_test_camera_offsets();
    dm_look_test_camera_functions(fake_camera_getter, fake_state_init);
    fake_action = action; fake_camera = camera; fake_init_count = 0;
    memset(action, 0, sizeof action); memset(camera, 0, sizeof camera);
    *(uint64_t *)action = (uint64_t)(image + 0x1000);
    *(action + 0x50) = 2;
    *(uint64_t *)(action + 0x40) = (uint64_t)(uintptr_t)&control_mode; control_mode = 1;
    float min = -85, max = 89, radius = 6, pitch = 0, yaw = 30;
    memcpy(action + 0x70, &min, 4); memcpy(action + 0x74, &max, 4);
    memcpy(action + 0x60, &pitch, 4); memcpy(action + 0x68, &yaw, 4);
    float polar[3] = {radius, pitch, yaw};
    uint64_t regs[31] = {0}; regs[0] = (uint64_t)(uintptr_t)action; regs[1] = (uint64_t)(uintptr_t)polar;
    dm_look_set_available(1);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0);
    send_camera_delta(regs, 0.1f, 0.05f);
    check("state 2 enters native state 3 once and seeds from the live view", *(action + 0x50) == 3 && fake_init_count == 1);
    check("first relative delta uses native seeded angles without changing radius",
          near(polar[0], 6) && near(polar[1], 14) && near(polar[2], -8));
    uint16_t flags; memcpy(&flags, camera + 0x105c, sizeof flags);
    check("manual camera latch is set while dragging", (flags & 1) != 0);
    camera_look_update(regs);
    check("a stationary held drag preserves state 3 and its angle", *(action + 0x50) == 3 && fake_init_count == 1 && near(polar[1], 14) && near(polar[2], -8));
    send_camera_delta(regs, -0.1f, -0.05f);
    check("state 3 applies reverse motion directly without reinitializing", fake_init_count == 1 && near(polar[1], 5) && near(polar[2], 10));
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 0);

    dm_look_set_available(0); dm_look_set_available(1);
    *(uint64_t *)action = (uint64_t)(image + 0x1008);
    *(action + 0x50) = 2; polar[1] = 20; polar[2] = 30;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.1f, 0.1f, 0);
    camera_look_update(regs);
    check("a different camera action vtable discards input without reading Chase fields", *(action + 0x50) == 2 && fake_init_count == 1 && near(polar[1], 20) && near(polar[2], 30));
    *(uint64_t *)action = (uint64_t)(image + 0x1000);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 0);

    dm_look_set_available(0); dm_look_set_available(1);
    *(action + 0x50) = 4; polar[1] = 20; polar[2] = 30; memset(camera + 0x105c, 0, 2);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_camera_delta(regs, 0.1f, 0.1f);
    memcpy(&flags, camera + 0x105c, sizeof flags);
    check("state 4 rejects manual input without changing its mode, angles, or latch",
          *(action + 0x50) == 4 && fake_init_count == 1 && near(polar[1], 20) && near(polar[2], 30) && flags == 0);

    dm_look_set_available(0); dm_look_set_available(1);
    *(action + 0x50) = 2; control_mode = 0; polar[1] = 20; polar[2] = 30;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_camera_delta(regs, 0.1f, 0.1f);
    check("non-manual control mode rejects input", *(action + 0x50) == 2 && fake_init_count == 1 && near(polar[1], 20) && near(polar[2], 30));

    dm_look_set_available(0); dm_look_set_available(1);
    control_mode = 1; camera[0x1073] = 1; polar[1] = 20; polar[2] = 30;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_camera_delta(regs, 0.1f, 0.1f);
    check("native camera status rejects input during a camera transition", *(action + 0x50) == 2 && fake_init_count == 1 && near(polar[1], 20) && near(polar[2], 30));
    dm_look_set_available(0); dm_look_test_camera_functions(NULL, NULL);
}

static void test_tail_callback(void) {
    static uint8_t image[0x3000], action[0x400], camera[0x1100];
    module_t main = {0}; strcpy(main.name, "main"); main.base = image; main.size = sizeof image;
    dm_look_test_camera_config(&main, 180); dm_look_test_camera_offsets(); dm_look_test_tail_config();
    dm_look_test_camera_functions(fake_camera_getter, fake_state_init);
    dm_look_test_tail_state_init(fake_tail_state_init);
    fake_action = action; fake_camera = camera; fake_init_count = 0;
    memset(action, 0, sizeof action); memset(camera, 0, sizeof camera);
    *(uint64_t *)action = (uint64_t)(image + 0x1100);
    *(action + 0x80) = 2;
    uint64_t regs[31] = {0}; regs[20] = (uint64_t)(uintptr_t)action; regs[19] = (uint64_t)(uintptr_t)camera;
    dm_look_set_available(0); dm_look_set_available(1);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0);
    send_tail_delta(regs, 0.1f, 0.05f);
    float pitch, yaw, z;
    memcpy(&pitch, action + 0x90, sizeof pitch); memcpy(&yaw, action + 0x9c, sizeof yaw);
    check("CameraTail state 2 enters native state 4 once and applies relative angles", *(action + 0x80) == 4 && fake_init_count == 1 && near(pitch, 14) && near(yaw, -8));
    memcpy(&z, action + 0x94, sizeof z);
    check("CameraTail direct movement clears pitch history", z == 0);
    memcpy(&z, action + 0x98, sizeof z);
    check("CameraTail direct movement clears the second pitch history", z == 0);
    memcpy(&z, action + 0xa0, sizeof z);
    check("CameraTail direct movement clears yaw history", z == 0);
    memcpy(&z, action + 0xa4, sizeof z);
    check("CameraTail direct movement clears the second yaw history", z == 0);

    camera_look_tail_update(regs);
    memcpy(&pitch, action + 0x90, sizeof pitch); memcpy(&yaw, action + 0x9c, sizeof yaw);
    check("stationary held movement preserves CameraTail mode and angles", *(action + 0x80) == 4 && fake_init_count == 1 && near(pitch, 14) && near(yaw, -8));
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 0);
    camera_look_tail_update(regs);
    memcpy(&pitch, action + 0x90, sizeof pitch); memcpy(&yaw, action + 0x9c, sizeof yaw);
    check("release leaves native CameraTail angle state stable without reinitializing", *(action + 0x80) == 4 && fake_init_count == 1 && near(pitch, 14) && near(yaw, -8));

    dm_look_set_available(0); dm_look_set_available(1);
    *(action + 0x80) = 4; pitch = 12; yaw = 179;
    memcpy(action + 0x90, &pitch, sizeof pitch); memcpy(action + 0x9c, &yaw, sizeof yaw);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_tail_delta(regs, -0.25f, -0.5f);
    memcpy(&pitch, action + 0x90, sizeof pitch); memcpy(&yaw, action + 0x9c, sizeof yaw);
    check("CameraTail mode 4 applies signed deltas and wraps yaw without reinitializing", fake_init_count == 1 && near(pitch, -78) && near(yaw, -136));
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 0);

    dm_look_set_available(0); dm_look_set_available(1);
    *(action + 0x80) = 2; pitch = 0; yaw = 0;
    memcpy(action + 0x90, &pitch, sizeof pitch); memcpy(action + 0x9c, &yaw, sizeof yaw);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_tail_delta(regs, 0, 0.5f);
    memcpy(&pitch, action + 0x90, sizeof pitch);
    check("CameraTail leaves pitch clamping to the native update", near(pitch, 95));
    int init_count = fake_init_count;

    dm_look_set_available(0); dm_look_set_available(1);
    *(action + 0x80) = 5; pitch = 20; yaw = 30;
    memcpy(action + 0x90, &pitch, sizeof pitch); memcpy(action + 0x9c, &yaw, sizeof yaw);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_tail_delta(regs, 0.1f, 0.1f);
    memcpy(&pitch, action + 0x90, sizeof pitch); memcpy(&yaw, action + 0x9c, sizeof yaw);
    check("mode 5 rejects input without changing the camera state", *(action + 0x80) == 5 && fake_init_count == init_count && near(pitch, 20) && near(yaw, 30));

    dm_look_set_available(0); dm_look_set_available(1);
    *(action + 0x80) = 2; camera[0x1073] = 1;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_tail_delta(regs, 0.1f, 0.1f);
    check("camera status blocks CameraTail injection during native transitions", *(action + 0x80) == 2 && fake_init_count == init_count);
    camera[0x1073] = 0;

    dm_look_set_available(0); dm_look_set_available(1);
    *(uint64_t *)action = (uint64_t)(image + 0x1008); *(action + 0x80) = 2;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0); send_tail_delta(regs, 0.1f, 0.1f);
    check("non-CameraTail virtual actions discard movement without touching angle fields", *(action + 0x80) == 2 && fake_init_count == init_count);

    // A Chase update between Tail interactions owns and consumes the same queue during a camera handoff.
    dm_look_set_available(0); dm_look_set_available(1);
    *(uint64_t *)action = (uint64_t)(image + 0x1000); *(action + 0x50) = 2;
    float polar[3] = {5, 4, 6}; regs[0] = (uint64_t)(uintptr_t)action; regs[1] = (uint64_t)(uintptr_t)polar;
    int32_t control_mode = 1;
    *(uint64_t *)(action + 0x40) = (uint64_t)(uintptr_t)&control_mode;
    float min = -85, max = 89, chase_pitch = 0, chase_yaw = 0;
    memcpy(action + 0x70, &min, 4); memcpy(action + 0x74, &max, 4);
    memcpy(action + 0x60, &chase_pitch, 4); memcpy(action + 0x68, &chase_yaw, 4);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 0);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.2f, 0.1f, 0);
    camera_look_update(regs);
    check("Chase consumes handoff movement before CameraTail can reuse it", near(polar[1], 23) && near(polar[2], -26));
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 0);
    dm_look_set_available(0); dm_look_test_camera_functions(NULL, NULL); dm_look_test_tail_state_init(NULL);
}

int main(void) {
    check("relative look remains disabled before a build-checked installer enables it", !dm_look_enabled());
    test_angles();
    test_sum(30);
    test_sum(60);
    test_angle_refresh_rates();
    test_once_and_tail();
    test_reverse();
    test_cancel_and_inactive();
    test_frame_gap();
    test_install_guard();
    test_camera_callback();
    test_tail_callback();
    expect_abort("invalid phase fails fast", invalid_phase);
    expect_abort("non-finite movement fails fast", nonfinite_delta);
    printf("== %d checks, %d failed ==\n", cases, fails);
    return fails != 0;
}
