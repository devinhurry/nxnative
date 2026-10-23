#include "../hle_look.c"
#include <assert.h>
#include <math.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
static int test_gate_present, test_gate_registered, test_missing_gate;
static uint64_t test_frame;

static int known_gate(int id) { return id == OBS_BOTW_LOOK_VECTOR; }
int gate_obs_present(int id) { return known_gate(id) && test_gate_present && id != test_missing_gate; }
void gate_obs_set(int id, void (*fn)(const uint64_t *regs)) {
    assert(id == OBS_BOTW_LOOK_VECTOR && fn);
    test_gate_registered++;
}
uint64_t dm_guest_frame(void) { return test_frame; }

static int cases, fails;
static void check(const char *name, int ok) {
    cases++;
    if (!ok) { fprintf(stderr, "FAIL %s\n", name); fails++; }
}
static int near(float a, float b) { return fabsf(a - b) <= 1e-6f; }
static void reset(float gain) {
    dm_look_test_vector_config(NULL, gain);
    test_frame = 0;
}
static void apply(uint64_t frame, float nx, float ny, float ratio, float *x, float *y) {
    dm_look_test_vector(frame, nx, ny, ratio, x, y);
}

static void test_native_passthrough(void) {
    reset(60);
    float x, y;
    apply(1, 0.375f, -0.625f, 1, &x, &y);
    check("without a drag the processed native vector is preserved exactly", x == 0.375f && y == -0.625f);
    apply(2, 0, 0, 1, &x, &y);
    check("without native or relative input the output remains zero", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 3);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, -0.02f, 3);
    apply(3, 0.25f, -0.5f, 1, &x, &y);
    check("physical stick input takes priority and remains unchanged", x == 0.25f && y == -0.5f);
    apply(3, 0, 0, 1, &x, &y);
    check("a same-frame zero read cannot reveal the suppressed touch impulse", x == 0 && y == 0);
    apply(4, 0, 0, 1, &x, &y);
    check("suppressed physical-frame movement does not leak into the next frame", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 3);
    apply(3, 0.25f, -0.5f, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, -0.02f, 3);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 3);
    apply(4, 0, 0, 1, &x, &y);
    check("movement arriving later in a physically-owned frame is not deferred", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 3);
    apply(3, 0.25f, -0.5f, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, -0.02f, 3);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 3);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 4);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, 0.0025f, 4);
    apply(4, 0, 0, 1, &x, &y);
    check("fresh next-frame movement applies without suppressed touch from the physical frame", near(x, 0.3f) && near(y, -0.15f));
}

static void test_shared_vector_and_repeat(void) {
    reset(60);
    float x, y, again_x, again_y;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 10);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0.02f, 10);
    // The output units are native stick-input units; gain is the user-configured impulse at base 30 Hz.
    apply(10, 0, 0, 1, &x, &y);
    apply(10, 0, 0, 1, &again_x, &again_y);
    check("the shared vector receives signed horizontal and inverted vertical deltas", near(x, 0.6f) && near(y, -1.2f));
    check("repeated getter reads in one frame see the same cached impulse", x == again_x && y == again_y);

    dm_look_test_input_at(DM_LOOK_END, 0, 0, 10);
    apply(11, 0, 0, 1, &x, &y);
    check("END retains no already-consumed movement into the next frame", x == 0 && y == 0);
}

static void test_end_and_cancel(void) {
    reset(60);
    float x, y;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 20);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.01f, 20);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 20);
    apply(20, 0, 0, 1, &x, &y);
    check("END preserves the final unconsumed delta for the getter", near(x, 0.3f) && near(y, 0.6f));
    apply(21, 0, 0, 1, &x, &y);
    check("the END delta is consumed once", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 22);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.004f, -0.003f, 22);
    apply(22, 0, 0, 1, &x, &y);
    apply(23, 0, 0, 1, &x, &y);
    check("a held finger with no MOVE has no repeated impulse on the next frame", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 30);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.02f, 0.03f, 30);
    apply(30, 0, 0, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_CANCEL, 0, 0, 30);
    apply(30, 0, 0, 1, &x, &y);
    check("CANCEL clears a cached same-frame impulse", x == 0 && y == 0);
    apply(31, 0, 0, 1, &x, &y);
    check("CANCEL leaves no queued or cached movement for the following frame", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 40);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0.02f, 40);
    apply(40, 0, 0, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_CANCEL, 0, 0, 41);
    apply(40, 0, 0, 1, &x, &y);
    check("a CANCEL stamped after the cached frame still clears its pending sample", x == 0 && y == 0);
    apply(41, 0, 0, 1, &x, &y);
    check("a delayed getter cannot replay movement cleared by a later CANCEL", x == 0 && y == 0);
}

static void test_frame_ratio(void) {
    const float ratios[] = {0.5f, 1.0f, 1.5f};
    const char *names[] = {"60 Hz VFR ratio", "30 Hz VFR ratio", "20 Hz VFR ratio"};
    for (unsigned i = 0; i < 3; i++) {
        reset(60);
        float x, y;
        dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 40);
        dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, 0.0025f, 40);
        apply(40, 0, 0, ratios[i], &x, &y);
        check(names[i], near(x, 0.3f / ratios[i]) && near(y, -0.15f / ratios[i]));
    }

    reset(60);
    float x, y, second_x, second_y;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 50);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.0025f, 50);
    apply(50, 0, 0, 0.5f, &x, &y);
    apply(50, 0, 0, 1.5f, &second_x, &second_y);
    check("the VFR ratio is snapshotted with the frame sample", x == second_x && y == second_y);
}

static void test_late_and_stale_input(void) {
    reset(60);
    float x, y;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 60);
    apply(60, 0, 0, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.004f, 0.003f, 60);
    apply(60, 0, 0, 1, &x, &y);
    check("movement arriving after a frame snapshot waits instead of changing that snapshot", x == 0 && y == 0);
    apply(61, 0, 0, 1, &x, &y);
    check("late fresh movement is applied on the next frame", near(x, 0.24f) && near(y, -0.18f));

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 70);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.02f, 0.01f, 70);
    apply(70, 0, 0, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.003f, -0.004f, 74);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.002f, 0.001f, 74);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 74);
    apply(74, 0, 0, 1, &x, &y);
    check("fresh movement after a long gap survives subsequent MOVE and END events", near(x, 0.3f) && near(y, 0.18f));
    apply(75, 0, 0, 1, &x, &y);
    check("stale pre-gap movement does not replay after the fresh sample", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 76);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.02f, 0.01f, 76);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.003f, -0.004f, 80);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.002f, 0.001f, 80);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 80);
    apply(80, 0, 0, 1, &x, &y);
    check("fresh movement after a gap does not combine with stale queued movement", near(x, 0.3f) && near(y, 0.18f));

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 80);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.02f, 0.01f, 80);
    apply(83, 0, 0, 1, &x, &y);
    check("a queued movement with no fresh input expires across a long frame gap", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 90);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0.01f, 90);
    apply(91, 0, 0, 1, &x, &y);
    apply(90, 0.25f, -0.5f, 1, &x, &y);
    check("a delayed older getter call bypasses look without rewinding the frame cache", x == 0.25f && y == -0.5f);
    apply(92, 0, 0, 1, &x, &y);
    check("an older getter call does not replay an already sampled drag", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 100);
    apply(101, 0, 0, 1, &x, &y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.004f, -0.002f, 100);
    apply(102, 0, 0, 1, &x, &y);
    check("a producer event stamped one frame behind the cached snapshot remains fresh next frame", near(x, 0.24f) && near(y, 0.12f));
}

static void test_actual_observer_ratio_read(void) {
    static uint8_t image[0x200];
    static uint8_t vfr[0x40];
    module_t main = {0};
    main.base = image; main.size = sizeof image;
    dm_look_test_vector_config(&main, 60);
    uint64_t vfr_ptr = 0;
    memcpy(image + 0x100, &vfr_ptr, sizeof vfr_ptr);
    float ratio = 1.5f;
    memcpy(vfr + 0x20, &ratio, sizeof ratio);
    float pair[2] = {0, 0};
    uint64_t regs[31] = {0}; regs[19] = (uintptr_t)pair;
    test_frame = 80;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 80);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.0025f, 80);
    camera_look_vector(regs);
    check("a missing VFR singleton leaves the native zero vector unchanged and drops unready touch input", pair[0] == 0 && pair[1] == 0);

    pair[0] = 0.125f; pair[1] = -0.25f;
    camera_look_vector(regs);
    check("OBS32 preserves a native vector without requiring the VFR singleton", pair[0] == 0.125f && pair[1] == -0.25f);

    vfr_ptr = (uintptr_t)vfr;
    memcpy(image + 0x100, &vfr_ptr, sizeof vfr_ptr);
    test_frame = 81;
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.0025f, 81);
    pair[0] = pair[1] = 0;
    camera_look_vector(regs);
    check("OBS32 reads the VFR ratio and applies both signed axes in place", near(pair[0], 0.2f) && near(pair[1], 0.1f));

    ratio = 0.5f; memcpy(vfr + 0x20, &ratio, sizeof ratio);
    pair[0] = pair[1] = 0;
    camera_look_vector(regs);
    check("OBS32 keeps the first ratio and sample stable for repeated getter reads", near(pair[0], 0.2f) && near(pair[1], 0.1f));
}

static void install_wrong_build(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "00000000000000000000000000000000");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = sizeof image;
    test_gate_present = 1; dm_look_install();
}
static void install_missing_gate(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = sizeof image;
    test_gate_present = 0; dm_look_install();
}
typedef void (*bad_call)(void);
static void expect_abort(const char *name, bad_call fn) {
    pid_t p = fork();
    if (!p) { freopen("/dev/null", "w", stderr); fn(); _exit(0); }
    int status = 0;
    if (p < 0 || waitpid(p, &status, 0) != p) { check(name, 0); return; }
    check(name, WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}

static void test_profile_guard(void) {
    expect_abort("the look observer rejects a different main build ID", install_wrong_build);
    expect_abort("the look observer refuses a stale rewrite without OBS32", install_missing_gate);

    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof g_mod); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = sizeof image;
    test_gate_present = 1; test_missing_gate = 0; test_gate_registered = 0;
    unsetenv("DM_LOOK"); dm_look_install();
    check("the matching BOTW build installs only the shared vector observer", dm_look_enabled() && test_gate_registered == 1);
}

int main(void) {
    check("relative look starts disabled until a build-checked installer enables it", !dm_look_enabled());
    test_native_passthrough();
    test_shared_vector_and_repeat();
    test_end_and_cancel();
    test_frame_ratio();
    test_late_and_stale_input();
    test_actual_observer_ratio_read();
    test_profile_guard();
    printf("== %d checks, %d failed ==\n", cases, fails);
    return fails != 0;
}
