// Display-referred SDR picture filters shared by the launcher and presenter.
#pragma once
#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { DM_FILTER_OFF, DM_FILTER_VIVID, DM_FILTER_CINEMATIC, DM_FILTER_WARM, DM_FILTER_COOL, DM_FILTER_CUSTOM };

static inline int dm_present_filter_mode(const char *value) {
    static const char *const names[] = {"off", "vivid", "cinematic", "warm", "cool", "custom"};
    if (value) for (int i = DM_FILTER_OFF; i <= DM_FILTER_CUSTOM; i++) if (!strcmp(value, names[i])) return i;
    return -1;
}

static inline int dm_present_filter_strength(const char *value, float *out) {
    if (!value || !*value) return 0;
    char *end = NULL;
    float strength = strtof(value, &end);
    if (end == value || *end || !isfinite(strength) || strength < 0 || strength > 1) return 0;
    *out = strength;
    return 1;
}

// Publish environment choices to the presentation threads after a live edit.
void dm_present_filter_settings_changed(void);
