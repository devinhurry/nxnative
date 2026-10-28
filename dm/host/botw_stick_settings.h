// The launcher applies these values before the gamepad is constructed.
#pragma once
#include "touchpad_geometry.h"
#include <stdlib.h>

// Returns the invalid variable's name, or NULL. The disjoint deadzone/full
// ranges ensure every offered combination has a positive movement interval.
static inline const char *dm_botw_stick_settings_read(dm_touchpad_stick_response *out) {
    *out = dm_touchpad_botw_move_defaults();
    const char *keys[] = {"DM_BOTW_MOVE_DEADZONE", "DM_BOTW_MOVE_CURVE", "DM_BOTW_MOVE_FULL", "DM_BOTW_MOVE_SIZE"};
    const float low[] = {0, .3f, .35f, .6f}, high[] = {.3f, 2, 1, 1.5f};
    float *values[] = {&out->deadzone, &out->curve, &out->full, &out->size};
    for (int i = 0; i < 4; i++) {
        const char *text = getenv(keys[i]);
        if (!text) continue;
        char *end = NULL;
        float value = strtof(text, &end);
        if (end == text || *end || !isfinite(value) || value < low[i] || value > high[i]) return keys[i];
        *values[i] = value;
    }
    return NULL;
}
