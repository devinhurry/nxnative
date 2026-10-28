// Current host implementation: display changes must affect the camera only at its guest projection gate.
#include "../hle.h"
// This fixture describes the camera under test, independent of the profile used to build the rest of the host tests.
#undef DM_GAME_ASPECT_NATIVE
#undef DM_GAME_CAMERA_ASPECT
#undef DM_GAME_CAMERA_UI_ASPECT
#define DM_GAME_ASPECT_NATIVE 1
#define DM_GAME_CAMERA_ASPECT "cd57b23fa4bbad65803d9788c01821ee:0x1e39d10:0x38:0x1d05380:0xb0:0x8"
#define DM_GAME_CAMERA_UI_ASPECT "19:0xa0:0xa8:0x74"
#define DM_GAME_CAMERA_WORLD_ASPECT "19:0x41c0"
#include "../hle_aspect.c"
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
static module_t test_modules[8];
module_t *g_mod = test_modules; int g_nmod = 1;
static void (*callback)(const uint64_t *);
static void (*ui_callback)(const uint64_t *);
static void (*screen_callback)(const uint64_t *);
static int have_gate = 1;
void gate_obs_read_set(int id, void (*fn)(const uint64_t *)) {
    if (id == OBS_ASPECT_PROJECTION) callback = fn;
    else if (id == OBS_ASPECT_UI_CAMERA) ui_callback = fn;
    else { assert(id == OBS_ASPECT_WORLD_PROJECTION); screen_callback = fn; }
}
int gate_obs_present(int id) { return (id == OBS_ASPECT_PROJECTION || id == OBS_ASPECT_UI_CAMERA || id == OBS_ASPECT_WORLD_PROJECTION) && have_gate && !(id == OBS_ASPECT_UI_CAMERA && have_gate == 2) && !(id == OBS_ASPECT_WORLD_PROJECTION && have_gate == 3); }
static void failure(const char *value, int bad_build, int stale) {
    pid_t pid = fork(); assert(pid >= 0);
    if (!pid) {
        freopen("/dev/null", "w", stderr);
        if (value) setenv("DM_ASPECT_RATIO", value, 1);
        if (bad_build) strcpy(g_mod[0].build_id, "00000000000000000000000000000000");
        if (stale) have_gate = stale == 1 ? 0 : stale == 2 ? 2 : 3;
        dm_aspect_install(); _exit(0);
    }
    int status; assert(waitpid(pid, &status, 0) == pid);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}
int main(void) {
    unsetenv("DM_ASPECT"); unsetenv("DM_ASPECT_RATIO");
    strcpy(g_mod[0].name, "main"); strcpy(g_mod[0].build_id, "cd57b23fa4bbad65803d9788c01821ee");
    g_mod[0].size = 0x2000000; g_mod[0].base = calloc(1, g_mod[0].size); assert(g_mod[0].base);
    failure("20:0", 0, 0); failure("nan", 0, 0); failure("20:9junk", 0, 0); failure("2.2x", 0, 0);
    failure("20:9", 1, 0); failure("20:9", 0, 1); failure("20:9", 0, 2); failure("20:9", 0, 3);
    dm_aspect_install(); assert(callback && screen_callback);
    uint8_t object[512] = {0}; uint8_t *proj = object + 0x38;
    *(void **)(g_mod[0].base + g_single_off) = object;
    *(uintptr_t *)proj = (uintptr_t)(g_mod[0].base + g_vt_off);
    float *aspect = (float *)(proj + g_field_off); *aspect = GAME_ASPECT;
    uint64_t regs[31] = {(uint64_t)proj};
    dm_aspect_set_display(20.f / 9); assert(*aspect == GAME_ASPECT); // no asynchronous guest writes
    callback(regs); assert(*aspect == 20.f / 9 && proj[g_dirty_off]);
    proj[g_dirty_off] = 0; *aspect = GAME_ASPECT; callback(regs); assert(*aspect == 20.f / 9 && proj[g_dirty_off]);
    dm_aspect_set_display(GAME_ASPECT); callback(regs); assert(*aspect == GAME_ASPECT);
    dm_aspect_set_display(4.f / 3); callback(regs); assert(*aspect == 4.f / 3);
    *aspect = 2.4f; dm_aspect_set_display(GAME_ASPECT); callback(regs); assert(*aspect == GAME_ASPECT);
    uint8_t other[512] = {0}; regs[0] = (uint64_t)other; callback(regs); assert(!other[g_dirty_off]);
    // The world-UI screen copies its 16:9 source into this clone each frame. Correct every reset
    // immediately after the copy, marking the matrix dirty only when the target aspect differs.
    uint8_t screen[0x41c0 + 512] = {0}, *clone = screen + 0x41c0;
    *(uintptr_t *)clone = (uintptr_t)(g_mod[0].base + g_vt_off);
    float *clone_aspect = (float *)(clone + g_field_off);
    regs[0] = (uint64_t)clone; regs[19] = (uint64_t)screen;
    const float world_ratios[] = {20.f/9, GAME_ASPECT, 4.f/3, 20.f/9};
    for (unsigned i = 0; i < sizeof(world_ratios)/sizeof(world_ratios[0]); i++) {
        dm_aspect_set_display(world_ratios[i]);
        for (int frame = 0; frame < 3; frame++) {
            *clone_aspect = GAME_ASPECT; clone[g_dirty_off] = 0; // game recopied the 16:9 lens
            screen_callback(regs);
            assert(*clone_aspect == world_ratios[i]);
            assert(clone[g_dirty_off] == (world_ratios[i] != GAME_ASPECT));
        }
    }
    regs[0] = (uint64_t)other; callback(regs); assert(!other[g_dirty_off]);
    float r[4]; dm_aspect_touch_rect(1600, 720, r); assert(r[0] == 160 && r[1] == 0 && r[2] == 1280 && r[3] == 720);
    // The UI camera's source lens is rebuilt by the game on every update. Apply the same mapping as a 16:9 UI rectangle:
    // wide screens shrink clip x; narrow screens shrink clip y, including the optical center, without accumulating scaling.
    uint8_t owner[256] = {0}, source[256] = {0};
    *(void **)(owner + 0xa0) = source; *(void **)(owner + 0xa8) = proj; regs[19] = (uint64_t)owner;
    const float ratios[] = {20.f/9, 4.f/3, 16.f/9};
    for (int i=0; i<3; i++) for (int repeat=0; repeat<2; repeat++) {
        float original[3] = {0.5235988f, -0.295f, -0.005f};
        memcpy(source + 0x74, original, sizeof original); *aspect = GAME_ASPECT;
        dm_aspect_set_display(ratios[i]); ui_callback(regs);
        float lens[3]; memcpy(lens, source + 0x74, sizeof lens);
        float sx=fminf(1, GAME_ASPECT/ratios[i]), sy=fminf(1, ratios[i]/GAME_ASPECT);
        assert(*aspect == ratios[i]);
        assert(fabsf(tanf(original[0]/2)*GAME_ASPECT/(tanf(lens[0]/2)*ratios[i]) - sx) < 1e-6f);
        assert(fabsf(tanf(original[0]/2)/tanf(lens[0]/2) - sy) < 1e-6f);
        assert(fabsf(lens[1] - original[1]*sx) < 1e-6f && fabsf(lens[2] - original[2]*sy) < 1e-6f);
    }
    free(g_mod[0].base); puts("aspect: parsing, build/gate validation, camera timing, UI lens proportions and touch checks passed");
}
