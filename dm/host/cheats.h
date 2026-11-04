// Public cheat controls shared by the Mac and iOS front ends.
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

// Cheats (hle_cheats.c): Atmosphère-format cheat code files applied to the running game (docs/development.md "Cheats")
void dm_cheats_prepare(const char *build_id); // Startup UI only: load choices from metadata without mapping or executing game code
void dm_cheats_init(void);            // Called once in host_preload after loading the modules (main.c): reads DM_CHEATS and friends, loads the build's file
void dm_cheats_present(void);         // Per presented frame (hle_nvn.c presents): applies the enabled cheats once
// Front-end rows (Mac and iOS). Readers of the list of cheats; the front end copies the strings out immediately
int dm_cheats_found(void);            // A cheat file is loaded (this build's, or another build's on DM_CHEATS_ANY_BUILD)
int dm_cheats_ncheats(void);          // The loaded file's cheats, in file order
const char *dm_cheats_build(void);    // This game's build ID, first 16 hex digits ("" when the main NSO has none)
const char *dm_cheats_dir_path(void); // The cheats folder ("", when neither DM_CHEATS nor DM_ROOT is set: the menu's folder action is off)
int dm_cheats_nothers(void);          // The .txt files of other builds in the folder (the menu's disabled "another version" rows)
const char *dm_cheats_other(int i);
const char *dm_cheat_name_at(int i);
const char *dm_cheat_why_at(int i);   // The disabled state's reason (" (unsupported opcode N)", " (off: ...)"); "" when plain
int dm_cheat_kind_at(int i);          // 0 a plain row (click toggles), 1 master (always on, no toggle), 2 disabled (broken or killed at run time), 3 a label (credits, a section marker)
int dm_cheat_on_at(int i);
void dm_cheat_toggle(int i);          // The click on a plain row: flips the cheat (an on / off pair as one switch) and rewrites <build ID>.enabled
void dm_cheats_reload(void);          // "Reload cheats": re-reads the file (the same path), so edits during play need no re-launch
// What the panel shows beyond the menu (hle_cheats.c header: labels and sections, the meta file of scripts/cheat_anchor.py)
enum { DM_CHEAT_LABEL = 1, DM_CHEAT_SECTION_START = 2, DM_CHEAT_SECTION_END = 4, DM_CHEAT_PAIR_ON = 8, DM_CHEAT_PAIR_OFF = 16,
       DM_CHEAT_ONCE = 32, DM_CHEAT_ASK = 64, DM_CHEAT_HOST = 128, DM_CHEAT_WEAK = 256 };   // ONCE: a "set" cheat; HOST: a never-decrease run by this host only
int dm_cheat_flags_at(int i);         // DM_CHEAT_* of entry i
const char *dm_cheat_section_at(int i);   // the section entry i lies in ("" none)
const char *dm_cheat_note_at(int i);  // the meta file's note: how the cheat was compiled, and its own note
const char *dm_cheat_type_at(int i);  // the meta type (u16, s32, f32, …), "" unknown
int dm_cheat_pair_at(int i);          // the other half of an on / off pair, -1 none
int dm_cheat_preview(int i, char *out, size_t cap);   // a dry run: one line per write it would make now ("main+0x… (2 bytes): 37 -> 999"), nothing written; returns the writes
int dm_cheat_value_get(int i, char *out, size_t cap); // an "ask" cheat's value as text: 1, or 0 when it takes none
int dm_cheat_value_set(int i, const char *text);      // set it (its type, its bounds) and keep it in <build ID>.values: 0 done, -1 refused
const char *dm_cheat_value_bounds(int i);             // "min..max" (a side empty when open), "" when it takes none
int dm_cheats_master(void);           // the master switch (off: no cheat runs; kept in the folder's .cheats-off)
void dm_cheats_master_set(int on);
int dm_cheats_safe(void);             // safe mode: the last run ended without a clean exit while cheats were on, so all start off
void dm_cheats_safe_restore(void);    // leave safe mode: the masters and the saved toggles come back
const char *dm_cheats_report(void);   // the load report: counts, duplicate names, ignored lines, carried-over toggles, Atmosphère's limits
const char *dm_cheats_version(void);  // this build's display version ("" unknown)
const char *dm_cheats_other_version(int i);   // the display version of another build's file (its meta file), "" unknown
int dm_cheats_nskipped(void);         // cheats the compiler left out of this build's file (its meta file), with their reasons
const char *dm_cheats_skipped_name(int i);
const char *dm_cheats_skipped_why(int i);
int dm_cheats_nsources(void);         // anchored sources (*.cheats.toml) in the cheats folder
const char *dm_cheats_source(int i);
void dm_cheats_exit(void);            // a clean exit (hle_lifecycle.c, atexit): removes the safe-mode flag

#ifdef __cplusplus
}
#endif
