// Live BOTW rune icon copied from the native rune Picture's own texture.
#pragma once
#include <stdint.h>

enum { DM_BOTW_RUNE_ICON_SIDE = 64, DM_BOTW_RUNE_ICON_STRIDE = 64 * 4 };

// Copy snapshot API: pixels are caller-owned after return, byte order is RGBA8,
// and the renderer publishes premultiplied alpha for interpolation-safe display.
typedef struct {
    uint64_t generation;
    int valid;
    uint32_t width, height, stride;
    uint8_t rgba[DM_BOTW_RUNE_ICON_SIDE * DM_BOTW_RUNE_ICON_SIDE * 4];
} dm_botw_rune_icon_state;

// Safe from UI threads; copies a small fixed-size snapshot under a short lock.
int dm_botw_rune_icon_snapshot(dm_botw_rune_icon_state *out);
// DrawSelf scope, recorded with the NVN draw so replay can copy the isolated
// rune source before it is composed with location names or other HUD layers.
void dm_botw_rune_icon_draw_begin(uint8_t *pane);
void dm_botw_rune_icon_draw_end(void);
int dm_botw_rune_icon_drawing(void);

// Current native pane lifetime/visibility token. No guest pointer escapes its
// callback; the renderer gets the rune source from the tagged NVN draw.
int dm_botw_rune_icon_capture_token(uint64_t *token);

// Renderer completion publication. The token rejects callbacks that completed
// after the pane was hidden, the mode changed, or the pane was rebuilt.
void dm_botw_rune_icon_publish(uint64_t token, const uint8_t *rgba,
                               uint32_t width, uint32_t height, uint32_t stride);
// Convert straight RGBA8 readback pixels to premultiplied RGBA8 in place.
void dm_botw_rune_icon_premultiply_rgba(uint8_t *rgba, uint32_t width,
                                        uint32_t height, uint32_t stride);
void dm_botw_rune_icon_clear(void);
