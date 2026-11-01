#pragma once

// Returns 1 for settings that can be changed in the running game, 0 for
// settings that take effect after relaunch, and -1 for unknown keys.
int dm_launcher_setting_is_live(const char *key);

// Applies a validated setting to host state. Returns 1 when applied, 0 when
// the setting is restart-only, and -1 for an unknown key or invalid value.
int dm_launcher_setting_apply(const char *key, const char *value);
