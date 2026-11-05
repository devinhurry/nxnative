#pragma once
#include "picture_lut.h"

// Returns 1 for settings that can be changed in the running game, 0 for
// settings that take effect after relaunch, and -1 for unknown keys.
int dm_launcher_setting_is_live(const char *key);

// Applies a validated setting to host state. Returns 1 when applied, 0 when
// the setting is restart-only, and -1 for an unknown key or invalid value.
int dm_launcher_setting_apply(const char *key, const char *value);

// Validate and publish a private copy of a 3D CUBE before live application.
// Returns a DM_CUBE_* result; "none" removes the custom table.
int dm_launcher_lut_apply(const char *path);

// The lifetime of a successfully presented in-game settings page, on the UI thread.
// Separate owners keep backgrounding and audio interruptions paused on dismissal.
void dm_launcher_settings_pause(int on);
