#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
// All paths are relative to one game's data root. A successful prepare returns
// a lock descriptor held until the game and its final cloud send have exited.
// An explicit DM_SAVE remains the caller's responsibility and bypasses prepare.
int dm_saves_prepare(const char *root, const char *title, char *save, size_t size,
                     int *lock_fd, char *error, size_t error_size);
// Shared backend for native front ends and scripts/saves.py. Returns malloc'd
// JSON (free it), or NULL with a readable error. Mutations require the game closed.
// Commands: list, inspect (read-only, allowed during play), create(name),
// copy(id,name), select(id), rename(id,name),
// import(path,name), import-raw(path,name), export(id,path), delete(id), restore(id),
// refresh (discover cloud slots), sync(id).
char *dm_saves_command(const char *root, const char *title, const char *command,
                       const char *arg1, const char *arg2, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
