// Deterministic device-motion samples through the HID six-axis APIs, with the relative-look queue active.
#include "../hle_hid.c"
#include "../hle_look.c"
#include <assert.h>
#include <math.h>

static uint64_t test_now;
uint64_t guest_ns(void) { return test_now; }
uint64_t now_ns(void) { return test_now; }
uint64_t dm_guest_frame(void) { return 9; }
int dm_detclock_enabled(void) { return 0; }
void dm_guest_clock_advanced(void) {}
void guest_clock_freeze(int on) { (void)on; }
void guest_clock_freeze_for(int reason, int on) { (void)reason; (void)on; }
void guest_clock_read_wait(void) {}
int dm_opmode(void) { return 0; }
void dm_touch_set(const dm_touch *touches, int n) { (void)touches; (void)n; }
void *objmap_get(const void *p) { (void)p; return NULL; }
void objmap_put(const void *p, void *host) { (void)p; (void)host; }
void *objmap_del(const void *p) { (void)p; return NULL; }
void hle_bind_system_event(void *guest, int autoclear) { (void)guest; (void)autoclear; }
void hle_signal_system_event(void *guest) { (void)guest; }
int touch_fill_n(void *out, int max, uint64_t now) { (void)out; (void)max; (void)now; return 0; }
void dm_gfx_shot_at(long count, const char *path) { (void)count; (void)path; }
void dm_gfx_texlist(int target) { (void)target; }
void dm_gfx_texraw(uint64_t serial, const char *path) { (void)serial; (void)path; }
void dm_ctl_peek(uint64_t address, int count) { (void)address; (void)count; }
void dm_ctl_memdump(uint64_t address, uint64_t size, const char *path) { (void)address; (void)size; (void)path; }
void dm_ctl_cvar_i32(uint64_t offset, int32_t value) { (void)offset; (void)value; }
void dm_ctl_cvar_f32(uint64_t offset, float value) { (void)offset; (void)value; }
void dm_gfx_texdump_next(const char *path) { (void)path; }
void dm_gfx_passdump_next(long frames) { (void)frames; }

static int near(float a, float b) { return fabsf(a - b) < 1e-5f; }
static void qmul_test(const float a[4], const float b[4], float q[4]) {
    q[0] = a[0]*b[0] - a[1]*b[1] - a[2]*b[2] - a[3]*b[3];
    q[1] = a[0]*b[1] + a[1]*b[0] + a[2]*b[3] - a[3]*b[2];
    q[2] = a[0]*b[2] - a[1]*b[3] + a[2]*b[0] + a[3]*b[1];
    q[3] = a[0]*b[3] + a[1]*b[2] - a[2]*b[1] + a[3]*b[0];
}

int main(void) {
    const float root_half = (float)sqrt(0.5);
    const float neutral_q[4] = {root_half, root_half, 0, 0}; // phone held upright; exercises the projected screen-frame path
    dm_motion neutral = {{0, -1, 0}, {0, 0, 0},
                         {neutral_q[0], neutral_q[1], neutral_q[2], neutral_q[3]}, DM_MOTION_RESET};
    test_now = 1000000000ull;
    dm_motion_set(&neutral);

    dm_look_set_available(1);
    dm_look_input(DM_LOOK_BEGIN, 0, 0);
    dm_look_input(DM_LOOK_MOVE, 0.2f, -0.1f);

    const float half_yaw = (float)(M_PI / 8.0); // 45 degrees, quaternion half-angle
    const float yaw_q[4] = {cosf(half_yaw), 0, 0, sinf(half_yaw)};
    float turned_q[4]; qmul_test(yaw_q, neutral_q, turned_q);
    dm_motion turned = {{0, -1, 0}, {0.1f, 0.3f, -0.2f},
                        {turned_q[0], turned_q[1], turned_q[2], turned_q[3]}, 0};
    test_now += SIX_PERIOD_NS;
    dm_motion_set(&turned);

    SixAxisState six[2];
    uint32_t handheld_handle = 1u | (0x20u << 8); // handheld style, left sensor
    assert(six_states(six, 2, handheld_handle) == 2);
    assert(near(six[0].acc[0], 0) && near(six[0].acc[1], 0) && near(six[0].acc[2], -1));
    assert(near(six[0].gyro[0], 0.1f) && near(six[0].gyro[1], 0.2f) && near(six[0].gyro[2], 0.3f));
    assert(near(six[0].angle[0], 0) && near(six[0].angle[1], 0) && near(six[0].angle[2], 0.125f));
    assert(near(six[0].dir[0], cosf(2 * half_yaw)) && near(six[0].dir[1], sinf(2 * half_yaw)) &&
           near(six[0].dir[3], -sinf(2 * half_yaw)) && near(six[0].dir[4], cosf(2 * half_yaw)));

    SevenState seven[2];
    assert(seven_states(seven, 2) == 2);
    assert(near(seven[0].gyro[2], 0.3f));
    assert(near(seven[0].quat[0], 0) && near(seven[0].quat[1], 0));
    assert(near(seven[0].quat[2], sinf(half_yaw)) && near(seven[0].quat[3], cosf(half_yaw)));

    // Recenter at the same tilted pose, then move in screen pitch. The baseline must stay neutral and map gravity to controller axes.
    test_now += SIX_PERIOD_NS;
    dm_motion_set(&neutral);
    const float half_pitch = (float)(M_PI / 18.0); // 20 degrees
    const float pitch_q[4] = {cosf(half_pitch), sinf(half_pitch), 0, 0};
    qmul_test(pitch_q, neutral_q, turned_q);
    turned = (dm_motion){{0, -cosf(2 * half_pitch), -sinf(2 * half_pitch)}, {0.1f, 0.3f, -0.2f},
                         {turned_q[0], turned_q[1], turned_q[2], turned_q[3]}, 0};
    test_now += SIX_PERIOD_NS;
    dm_motion_set(&turned);
    assert(six_states(six, 1, handheld_handle) == 1);
    assert(near(six[0].acc[0], 0) && near(six[0].acc[1], sinf(2 * half_pitch)) &&
           near(six[0].acc[2], -cosf(2 * half_pitch)));
    assert(near(six[0].gyro[0], 0.1f) && near(six[0].gyro[1], 0.2f) && near(six[0].gyro[2], 0.3f));
    assert(near(six[0].angle[0], 1.0f / 18.0f) && near(six[0].angle[1], 0) && near(six[0].angle[2], 0));
    assert(near(six[0].dir[4], cosf(2 * half_pitch)) && near(six[0].dir[5], sinf(2 * half_pitch)) &&
           near(six[0].dir[7], -sinf(2 * half_pitch)));
    assert(seven_states(seven, 1) == 1);
    assert(near(seven[0].quat[0], sinf(half_pitch)) && near(seven[0].quat[1], 0) &&
           near(seven[0].quat[2], 0) && near(seven[0].quat[3], cosf(half_pitch)));

    // The look queue and HID sensor feed are independent: sampling while look is held still returns the same sensor state.
    SixAxisState again;
    assert(six_states(&again, 1, handheld_handle) == 1);
    assert(near(again.gyro[0], six[0].gyro[0]) && near(again.gyro[1], six[0].gyro[1]) && near(again.gyro[2], six[0].gyro[2]));
    dm_look_input(DM_LOOK_CANCEL, 0, 0);

    // SevenSixAxis uses guest time directly; the six-axis history rounds it down to its 5 ms sample tick.
    test_now += MOTION_STALE_NS + 1;
    assert(seven_states(seven, 1) == 0);
    assert(six_states(&again, 1, handheld_handle) == 1 && near(again.gyro[2], 0.3f));
    test_now += SIX_PERIOD_NS;
    assert(six_states(&again, 1, handheld_handle) == 1 && near(again.acc[2], -1) && near(again.gyro[2], 0));

    // A landscape-neutral pose has world up along device X and screen-right along -device Y.
    // After a 180-degree turn the same screen-right tilt is +device Y. A fresh UI frame
    // remaps it back to the original X pitch; stale orientation leaks it into yaw and reverses gyro.
    const float flip_z[4] = {0, 0, 0, 1};
    const float half_tilt = (float)(M_PI / 18.0);
    const float landscape_q[4] = {0.5f, 0.5f, -0.5f, 0.5f};
    const float screen_right_tilt[4] = {cosf(half_tilt), 0, sinf(half_tilt), 0};
    float turned_neutral[4];
    float raw_after_flip[4], mapped_after_flip[4];
    qmul_test(landscape_q, flip_z, turned_neutral);
    qmul_test(turned_neutral, screen_right_tilt, raw_after_flip);
    qmul_test(raw_after_flip, flip_z, mapped_after_flip);

    dm_motion_set(NULL);
    test_now = (test_now / SIX_PERIOD_NS + 1) * SIX_PERIOD_NS;
    dm_motion upright = {{-1, 0, 0}, {0, 0, 0},
                         {landscape_q[0], landscape_q[1], landscape_q[2], landscape_q[3]}, DM_MOTION_RESET};
    dm_motion_set(&upright);
    dm_motion corrected = {{-cosf(2 * half_tilt), 0, 0}, {0, -sinf(half_tilt) / (float)(2 * M_PI), 0},
                           {mapped_after_flip[0], mapped_after_flip[1], mapped_after_flip[2], mapped_after_flip[3]}, 0};
    test_now += SIX_PERIOD_NS;
    dm_motion_set(&corrected);
    assert(seven_states(seven, 1) == 1);
    assert(near(fabsf(seven[0].quat[0]), sinf(half_tilt)) && near(seven[0].quat[1], 0) &&
           near(seven[0].quat[2], 0) && near(fabsf(seven[0].quat[3]), cosf(half_tilt)) &&
           near(seven[0].gyro[0], sinf(half_tilt) / (float)(2 * M_PI)));
    assert(six_states(six, 1, handheld_handle) == 1 &&
           near(six[0].gyro[0], sinf(half_tilt) / (float)(2 * M_PI)) &&
           near(six[0].angle[0], 1.0f / 18.0f));

    dm_motion_set(NULL);
    test_now += SIX_PERIOD_NS;
    dm_motion_set(&upright);
    dm_motion stale = {{-cosf(2 * half_tilt), 0, 0}, {0, sinf(half_tilt) / (float)(2 * M_PI), 0},
                       {raw_after_flip[0], raw_after_flip[1], raw_after_flip[2], raw_after_flip[3]}, 0};
    test_now += SIX_PERIOD_NS;
    dm_motion_set(&stale);
    assert(seven_states(seven, 1) == 1);
    assert(!near(seven[0].quat[0], sinf(half_tilt)) || !near(seven[0].quat[2], 0) ||
           !near(seven[0].gyro[0], sinf(half_tilt) / (float)(2 * M_PI)));
    assert(six_states(six, 1, handheld_handle) == 1 &&
           !near(six[0].gyro[0], sinf(half_tilt) / (float)(2 * M_PI)));

    dm_motion_set(NULL);
    assert(seven_states(seven, 1) == 0);
    assert(six_states(&again, 1, handheld_handle) == 1 && near(again.acc[2], -1) && near(again.gyro[2], 0));
    puts("Device-motion/HID regression: 0 failures; six-axis and SevenSixAxis preserve samples with look queued.");
    return 0;
}
