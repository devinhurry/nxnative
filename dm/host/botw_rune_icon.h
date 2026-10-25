// Live BOTW rune icon cropped from the game's own transparent UI canvas.
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

// Used by the renderer to obtain the current icon's logical 1280x720 top-left
// crop and invalidation token. No pane pointer escapes its native callback.
// The renderer also receives the live rectangle of the adjacent native
// cross-key guide; pixels inside it are excluded from the copied rune image.
int dm_botw_rune_icon_crop(float rect[4], float exclusion[4], uint64_t *token);

// Renderer completion publication. The token rejects callbacks that completed
// after the pane was hidden, the mode changed, or the pane was rebuilt.
void dm_botw_rune_icon_publish(uint64_t token, const uint8_t *rgba,
                               uint32_t width, uint32_t height, uint32_t stride);
// Convert straight RGBA8 readback pixels to premultiplied RGBA8 in place.
void dm_botw_rune_icon_premultiply_rgba(uint8_t *rgba, uint32_t width,
                                        uint32_t height, uint32_t stride);
// Clear only output samples whose logical canvas centers overlap the live
// authored D-pad guide rectangle. Letterboxed pixels outside image_rect stay
// transparent; crop/exclusion are top-left logical 1280x720 rectangles.
void dm_botw_rune_icon_mask_guide(uint8_t *rgba, uint32_t width,
                                  uint32_t height, uint32_t stride,
                                  const float crop[4], const float exclusion[4],
                                  uint32_t image_x, uint32_t image_y,
                                  uint32_t image_width, uint32_t image_height);
void dm_botw_rune_icon_clear(void);
