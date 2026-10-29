// What the tests that link hle_nvn.c and hle_bigstack.c without the host need of it: weak definitions, so a test that defines its own keeps it
#include <stdint.h>
__attribute__((weak)) uint64_t g_t0_ns;   // process start time (host main.c), read by hle_nvn's per-frame timing
__attribute__((weak)) _Atomic uint64_t dm_present_ns;   // when the last present was made, for DM_HITCH_DUMP (hle_thread.c)
__attribute__((weak)) int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }   // no guest address space (hle_bigstack.c)
// BOTW touch-HUD hooks are inert in graphics unit tests unless a test supplies
// its own definitions; linking nvn_mtl.m still compiles these gated paths.
__attribute__((weak)) int dm_botw_rune_icon_drawing(void) { return 0; }
__attribute__((weak)) void dm_botw_rune_icon_draw_begin(uint8_t *pane) { (void)pane; }
__attribute__((weak)) void dm_botw_rune_icon_draw_end(void) {}
__attribute__((weak)) int dm_botw_touch_hud_active(void) { return 0; }
__attribute__((weak)) int dm_aspect_ui_hud_drawing(void) { return 0; }
__attribute__((weak)) int dm_aspect_ui_background_drawing(void) { return 0; }
__attribute__((weak)) int dm_botw_rune_icon_capture_token(uint64_t *token) { (void)token; return 0; }
__attribute__((weak)) void dm_botw_rune_icon_publish(uint64_t token, const uint8_t *rgba,
                                                      uint32_t width, uint32_t height, uint32_t stride) {
    (void)token; (void)rgba; (void)width; (void)height; (void)stride;
}
__attribute__((weak)) void dm_botw_rune_icon_premultiply_rgba(uint8_t *rgba, uint32_t width,
                                                               uint32_t height, uint32_t stride) {
    (void)rgba; (void)width; (void)height; (void)stride;
}

__attribute__((weak)) void dm_vi_layer_crop(int c[4]) { c[0] = c[1] = c[2] = c[3] = 0; }   // no vi layer crop (hle_vi.c), read by hle_nvn's present
