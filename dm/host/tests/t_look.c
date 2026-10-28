#include "../hle_look.c"
#include <assert.h>
#include <math.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

static module_t test_modules[8];
module_t *g_mod = test_modules;
int g_nmod;
static int test_gate_present, test_gate_registered, test_missing_gate;
static uint64_t test_frame;
static int test_hid_valid;
static dm_hid_look_sample test_hid_sample;
int dm_hid_look_sample_at(uint64_t frame, dm_hid_look_sample *out) {
    if (!test_hid_valid || test_hid_sample.frame > frame || !out) return 0;
    *out = test_hid_sample; return 1;
}

static int known_gate(int id) { return id == OBS_BOTW_LOOK_VECTOR || id == OBS_BOTW_LOOK_SOURCE; }
int gate_obs_present(int id) { return known_gate(id) && test_gate_present && id != test_missing_gate; }
void gate_obs_read_set(int id, void (*fn)(const uint64_t *regs)) {
    assert(known_gate(id) && fn);
    test_gate_registered++;
}
uint64_t dm_guest_frame(void) { return test_frame; }
void front_look_mode_changed(void) {}

static int cases, fails;
static void check(const char *name, int ok) {
    cases++;
    if (!ok) { fprintf(stderr, "FAIL %s\n", name); fails++; }
}
static int near(float a, float b) { return fabsf(a - b) <= 1e-6f; }
static float from_bits(uint32_t bits) { float value; memcpy(&value, &bits, sizeof value); return value; }
static void reset(float gain) {
    dm_look_test_vector_config(NULL, gain);
    test_frame = 0;
    test_hid_valid = 0; memset(&test_hid_sample, 0, sizeof test_hid_sample);
}
static void apply(uint64_t frame, float nx, float ny, float ratio, float *x, float *y) {
    dm_look_test_vector(frame, nx, ny, ratio, x, y);
}

static void apply_source(uint64_t frame, float nx, float ny, float ratio,
                         int sample_valid, int raw_match, int physical, float *x, float *y) {
    dm_look_test_vector_source(frame, nx, ny, ratio, sample_valid, raw_match, physical, x, y);
}

static void test_source_attribution(void) {
    reset(60);
    float x, y;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 120);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0.02f, 120);
    apply_source(120, 0.75f, -0.25f, 1, 1, 0, 0, &x, &y);
    check("an unmatched raw native source is preserved", x == 0.75f && y == -0.25f);
    apply_source(120, 0.75f, -0.25f, 1, 1, 1, 0, &x, &y);
    check("an unknown first getter suppresses a later same-frame synthetic velocity", x == 0 && y == 0);
    apply_source(121, 0, 0, 1, 1, 1, 0, &x, &y);
    check("movement rejected for an unmatched source is not replayed", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 122);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0.02f, 122);
    apply_source(122, 0.9f, -0.8f, 1, 1, 1, 0, &x, &y);
    check("a proven synthetic source is replaced by signed relative movement", near(x, 0.6f) && near(y, -1.2f));
    apply_source(122, 0.7f, -0.6f, 1, 1, 0, 0, &x, &y);
    check("a later same-frame unknown candidate is preserved per invocation", x == 0.7f && y == -0.6f);
    apply_source(122, 0.9f, -0.8f, 1, 1, 1, 0, &x, &y);
    check("a later matching virtual candidate still sees the frame sample", near(x, 0.6f) && near(y, -1.2f));
    apply_source(122, 0.3f, -0.4f, 1, 1, 1, 1, &x, &y);
    check("a physical candidate on a later getter call keeps native output", x == 0.3f && y == -0.4f);
    apply_source(123, 0.9f, -0.8f, 1, 1, 1, 0, &x, &y);
    check("a held stationary synthetic stick is replaced with zero on the next frame", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 124);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.01f, 124);
    apply_source(124, 0.5f, -0.5f, 1, 1, 1, 0, &x, &y);
    check("relative movement replaces the post-filter virtual response", near(x, 0.3f) && near(y, 0.6f));
    dm_look_test_input_at(DM_LOOK_CANCEL, 0, 0, 124);
    apply_source(124, 0.5f, -0.5f, 1, 1, 1, 0, &x, &y);
    check("CANCEL after a frozen HID sample clears that frame's synthetic output", x == 0 && y == 0);
    apply_source(125, 0, 0, 1, 1, 1, 0, &x, &y);
    check("CANCEL leaves no later impulse", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 125);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0, 125);
    apply_source(125, 0.2f, 0.1f, 1, 1, 1, 0, &x, &y);
    dm_look_test_input_at(DM_LOOK_CANCEL, 0, 0, 126);
    apply_source(125, 0.2f, 0.1f, 1, 1, 1, 0, &x, &y);
    check("a newer CANCEL clears an already-cached sample for a delayed getter", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 126);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, 0, 126);
    apply_source(126, 0.2f, -0.4f, 1, 1, 0, 1, &x, &y);
    check("sampled physical right stick keeps its native curve and suppresses drag", x == 0.2f && y == -0.4f);
    apply_source(127, 0, 0, 1, 1, 1, 0, &x, &y);
    check("physical-priority movement cannot leak after release", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 128);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0, 128);
    apply_source(128, 0.1f, 0.2f, 1, 0, 0, 0, &x, &y);
    check("a getter without a matching HID snapshot fails open", x == 0.1f && y == 0.2f);
    apply_source(129, 0, 0, 1, 1, 1, 0, &x, &y);
    check("an unobserved frame's drag is not replayed later", x == 0 && y == 0);
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

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 42);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0, 42);
    dm_look_test_input_at(DM_LOOK_CANCEL, 0, 0, 42);
    apply_source(42, 0.8f, 0.2f, 1, 1, 1, 0, &x, &y);
    check("CANCEL before the first getter replaces a frozen virtual stick with zero", x == 0 && y == 0);

    reset(60);
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 43);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0, 43);
    apply_source(43, 0.8f, 0.2f, 1, 1, 1, 0, &x, &y);
    dm_look_test_input_at(DM_LOOK_END, 0, 0, 44);
    apply_source(44, 0.8f, 0.2f, 1, 1, 1, 0, &x, &y);
    check("END without a final MOVE suppresses the frozen virtual stick next frame", x == 0 && y == 0);
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
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 93);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.01f, 0.005f, 93);
    apply_source(93, 0, 0, 1, 1, 1, 0, &x, &y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.004f, 0, 94);
    apply_source(94, 0, 0, 1, 1, 1, 0, &x, &y);
    check("a newer frame samples its own movement before delayed older work", near(x, 0.24f) && y == 0);
    apply_source(93, 0.7f, -0.6f, 1, 1, 1, 0, &x, &y);
    check("a delayed older synthetic getter is zero rather than stale stick velocity", x == 0 && y == 0);
    apply_source(94, 0, 0, 1, 1, 1, 0, &x, &y);
    check("the delayed getter does not rewind the newer sample", near(x, 0.24f) && y == 0);

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
    static uint8_t child[0x140];
    module_t main = {0};
    main.base = image; main.size = sizeof image;
    dm_look_test_vector_config(&main, 60);
    uint64_t vfr_ptr = 0;
    memcpy(image + 0x100, &vfr_ptr, sizeof vfr_ptr);
    float ratio = 1.5f;
    memcpy(vfr + 0x20, &ratio, sizeof ratio);
    float pair[2] = {0, 0};
    uint64_t regs[31] = {0}; regs[0] = (uintptr_t)child; regs[19] = (uintptr_t)pair;
    test_frame = 80;
    dm_look_test_input_at(DM_LOOK_BEGIN, 0, 0, 80);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.0025f, 80);
    test_hid_valid = 1; test_hid_sample = (dm_hid_look_sample){.frame=80, .source=DM_HID_LOOK_VIRTUAL};
    camera_look_source(regs);
    camera_look_vector(regs);
    check("a valid paired source with no VFR leaves native output unchanged and drops unready touch input", pair[0] == 0 && pair[1] == 0);
    check("OBS32 consumes and clears its paired OBS33 packet", !g_raw_call.valid);

    pair[0] = 0.125f; pair[1] = -0.25f;
    regs[0] = 0; camera_look_source(regs); // native null-source branch skips the raw pair load
    camera_look_vector(regs);
    check("a null source cannot reuse the previous OBS33 packet", pair[0] == 0.125f && pair[1] == -0.25f && !g_raw_call.valid);

    vfr_ptr = (uintptr_t)vfr;
    memcpy(image + 0x100, &vfr_ptr, sizeof vfr_ptr);
    test_frame = 81;
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, -0.0025f, 81);
    pair[0] = pair[1] = 0;
    regs[0] = (uintptr_t)child;
    test_hid_sample = (dm_hid_look_sample){.frame=81, .source=DM_HID_LOOK_VIRTUAL};
    camera_look_source(regs);
    camera_look_vector(regs);
    check("the real OBS33→OBS32 path reads the VFR ratio and applies both signed axes", near(pair[0], 0.2f) && near(pair[1], 0.1f));

    ratio = 0.5f; memcpy(vfr + 0x20, &ratio, sizeof ratio);
    pair[0] = pair[1] = 0;
    camera_look_source(regs);
    camera_look_vector(regs);
    check("OBS32 keeps the first ratio and sample stable for repeated getter reads", near(pair[0], 0.2f) && near(pair[1], 0.1f));

    test_frame = 82; pair[0] = 0.25f; pair[1] = 0.5f;
    dm_look_test_input_at(DM_LOOK_MOVE, 0.002f, -0.003f, 82);
    // The native pair is intentionally not the frame-frozen virtual candidate. This exercises
    // the real pre-filter capture -> post-filter source match, rather than the helper's boolean
    // mismatch seam. Such a mismatch can represent another native producer that won selection.
    float native_candidate[2] = {0.25f, -0.125f};
    memcpy(child + 0x128, native_candidate, sizeof native_candidate);
    test_hid_sample = (dm_hid_look_sample){.frame=82, .source=DM_HID_LOOK_VIRTUAL,
        .selected_rx=23170, .selected_ry=23170, .virtual_rx=23170, .virtual_ry=23170};
    camera_look_source(regs);
    camera_look_vector(regs);
    check("an unmatched virtual-source candidate preserves native filtered output", pair[0] == 0.25f && pair[1] == 0.5f);
    apply_source(83, pair[0], pair[1], 1, 1, 1, 0, &pair[0], &pair[1]);
    check("movement rejected by a raw-source mismatch is not replayed", pair[0] == 0 && pair[1] == 0);

    test_frame = 84;
    dm_look_test_input_at(DM_LOOK_MOVE, 0.005f, 0.002f, 84);
    float virtual_axis = 16384.0f / 32767.0f;
    memcpy(child + 0x128, &virtual_axis, sizeof virtual_axis);
    float virtual_y = 0;
    memcpy(child + 0x12c, &virtual_y, sizeof virtual_y);
    test_hid_sample = (dm_hid_look_sample){.frame=84, .source=DM_HID_LOOK_VIRTUAL,
        .selected_rx=16384, .virtual_rx=16384};
    pair[0] = pair[1] = 0;
    camera_look_source(regs);
    check("OBS33 captures the actual same-frame virtual HID sample and native raw pair", g_raw_call.valid && g_raw_call.raw_x == virtual_axis && g_raw_call.hid.selected_rx == 16384);
    camera_look_vector(regs);
    check("the paired OBS33 to OBS32 path consumes that source exactly once", near(pair[0], 0.6f) && near(pair[1], -0.24f) && !g_raw_call.valid);

    test_frame = 85; pair[0] = pair[1] = 0;
    // Fixture from the exact native 1.9 cached-stick instruction sequence for signed rounded-circle axes.
    // The component divide alone is not the final native pair: radius > 1 rescales both axes.
    float diagonal_axis = from_bits(0x3f3504f3);
    memcpy(child + 0x128, &diagonal_axis, sizeof diagonal_axis);
    memcpy(child + 0x12c, &diagonal_axis, sizeof diagonal_axis);
    test_hid_sample = (dm_hid_look_sample){.frame=85, .source=DM_HID_LOOK_VIRTUAL,
        .selected_rx=23170, .selected_ry=23170, .virtual_rx=23170, .virtual_ry=23170};
    dm_look_test_input_at(DM_LOOK_MOVE, 0.003f, -0.004f, 85);
    camera_look_source(regs);
    camera_look_vector(regs);
    check("OBS33→OBS32 accepts the native-normalized rounded diagonal pair", near(pair[0], 0.36f) && near(pair[1], 0.48f));

    // The game can call its shared stick getter after this present's Npad poll has not run yet.
    // Keep the last frozen source usable only while the raw candidate still exactly matches it.
    test_frame = 86; pair[0] = virtual_axis; pair[1] = 0;
    memcpy(child + 0x128, &virtual_axis, sizeof virtual_axis);
    memcpy(child + 0x12c, &virtual_y, sizeof virtual_y);
    test_hid_sample = (dm_hid_look_sample){.frame=85, .source=DM_HID_LOOK_VIRTUAL,
        .selected_rx=16384, .virtual_rx=16384};
    dm_look_test_input_at(DM_LOOK_MOVE, 0.001f, 0, 86);
    camera_look_source(regs); camera_look_vector(regs);
    check("getter one frame after an unchanged cached virtual sample applies the fresh relative impulse", near(pair[0], 0.12f) && pair[1] == 0);

    test_frame = 87; pair[0] = virtual_axis; pair[1] = 0;
    test_hid_sample = (dm_hid_look_sample){.frame=84, .source=DM_HID_LOOK_PHYSICAL,
        .selected_rx=16384, .physical_rx=16384};
    dm_look_test_input_at(DM_LOOK_MOVE, 0.001f, 0, 87);
    camera_look_source(regs); camera_look_vector(regs);
    check("cached physical-stick provenance preserves the native candidate", pair[0] == virtual_axis && pair[1] == 0);

    test_frame = 88; pair[0] = virtual_axis; pair[1] = 0;
    test_hid_sample = (dm_hid_look_sample){.frame=89, .source=DM_HID_LOOK_VIRTUAL,
        .selected_rx=16384, .virtual_rx=16384};
    camera_look_source(regs); camera_look_vector(regs);
    check("a future HID sample cannot be paired with an older in-flight getter", pair[0] == virtual_axis && pair[1] == 0);

    test_frame = 90; pair[0] = virtual_axis; pair[1] = 0;
    test_hid_sample = (dm_hid_look_sample){.frame=90, .source=DM_HID_LOOK_VIRTUAL,
        .selected_rx=10000, .virtual_rx=10000};
    float replacement_axis; native_stick_pair(10000, 0, &replacement_axis, &virtual_y);
    memcpy(child + 0x128, &replacement_axis, sizeof replacement_axis);
    memcpy(child + 0x12c, &virtual_y, sizeof virtual_y);
    dm_look_test_input_at(DM_LOOK_MOVE, 0.001f, 0, 90);
    camera_look_source(regs); camera_look_vector(regs);
    check("a newer HID sample replaces old provenance and matches its own native candidate", near(pair[0], 0.12f) && pair[1] == 0);

    test_frame = 93; pair[0] = replacement_axis; pair[1] = 0;
    dm_look_test_input_at(DM_LOOK_MOVE, 0.001f, 0, 93);
    camera_look_source(regs); camera_look_vector(regs);
    check("getter three frames after the last HID poll uses that cached source only while raw still matches", near(pair[0], 0.12f) && pair[1] == 0);
}

static void test_native_stick_float_mapping(void) {
    float x, y;
    native_stick_pair(16384, 0, &x, &y);
    check("native cardinal stick conversion matches its binary32 fixture", x == from_bits(0x3f000100) && y == 0.0f);
    native_stick_pair(23170, 23170, &x, &y);
    check("native rounded diagonal applies the radial clamp and exact float rounding", x == from_bits(0x3f3504f3) && y == from_bits(0x3f3504f3));
    native_stick_pair(20000, 24000, &x, &y);
    check("native in-range asymmetric conversion preserves component order", x == from_bits(0x3f1c4139) && y == from_bits(0x3f3b8177));
    native_stick_pair(-23170, 23170, &x, &y);
    check("native radial normalization preserves signed axis orientation", x == from_bits(0xbf3504f3) && y == from_bits(0x3f3504f3));
}

static void install_wrong_build(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof test_modules); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "00000000000000000000000000000000");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = sizeof image;
    test_gate_present = 1; dm_look_install();
}
static void install_missing_gate(void) {
    static uint8_t image[0x2000000];
    memset(g_mod, 0, sizeof test_modules); g_nmod = 1;
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
    memset(g_mod, 0, sizeof test_modules); g_nmod = 1;
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].base = image; g_mod[0].size = sizeof image; g_mod[0].text_end = sizeof image;
    test_gate_present = 1; test_missing_gate = 0; test_gate_registered = 0;
    unsetenv("DM_LOOK"); dm_look_install();
    check("the matching BOTW build installs the pre-filter source and shared vector observers", dm_look_enabled() && test_gate_registered == 2);
}

int main(void) {
    check("relative look starts disabled until a build-checked installer enables it", !dm_look_enabled());
    test_native_passthrough();
    test_source_attribution();
    test_shared_vector_and_repeat();
    test_end_and_cancel();
    test_frame_ratio();
    test_late_and_stale_input();
    test_native_stick_float_mapping();
    test_actual_observer_ratio_read();
    test_profile_guard();
    printf("== %d checks, %d failed ==\n", cases, fails);
    return fails != 0;
}
