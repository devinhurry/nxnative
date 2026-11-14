#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
// Shared numbered-progress recognition for import, preview and mount validation.
// Root: 1 = unique recognized root, 0 = unknown/empty, -1 = invalid/ambiguous.
int dm_saves_game_root(const char *path, char *root, size_t size);
int dm_saves_progress_slot(const char *path);
// All paths are relative to one game's data root. A successful prepare returns
// a lock descriptor held until the game and its final cloud send have exited.
// An explicit DM_SAVE remains the caller's responsibility and bypasses prepare.
int dm_saves_prepare(const char *root, const char *title, char *save, size_t size,
                     int *lock_fd, char *error, size_t error_size);
// Shared backend for native front ends and scripts/saves.py. Returns malloc'd
// JSON (free it), or NULL with a readable error. Mutations require the game closed.
// Commands: list, inspect (read-only, allowed during play), create(name),
// copy(id,name), select(id), rename(id,name),
// import(path,name), import-raw(path,name), import-root(path,name),
// import-inside(path,name), import-many(JSON paths,JSON layout choices),
// export(id,path), export-many(JSON IDs,path; [] means all), delete(id), restore(id),
// refresh (discover cloud slots), sync(id), validate(expected current ID).
// Export destinations ending in .zip use ordinary ZIP; other names retain the
// legacy .dmsync archive. The cloud always retains its existing .dmsync format.
// Import returns needs_layout instead of publishing when an outer directory is
// ambiguous. Retry with root/inside, or a source-path choice in import-many.
char *dm_saves_command(const char *root, const char *title, const char *command,
                       const char *arg1, const char *arg2, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
