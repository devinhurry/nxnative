// Optional embedding interfaces. Native builds need no external application.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
/* Optional read-only logical filesystem. NULL keeps every native path.
   The provider owns source selection and verification; errno reports failures. */
typedef int (*nx_ro_visit)(void *, const char *, int, uint64_t);
typedef struct nx_readonly_provider {
    int (*volume)(const char *); /* 1 present, 0 missing, -1 error */
    void *(*open)(const char *);
    ssize_t (*read)(void *, void *, size_t, uint64_t);
    uint64_t (*size)(const void *);
    void (*close)(void *);
    int (*stat)(const char *, int *, uint64_t *);
    int (*list)(const char *, nx_ro_visit, void *);
    size_t (*work_size)(const char *);
} nx_readonly_provider;
#ifdef NX_HOST_EXTENSION
#include NX_HOST_EXTENSION
#endif
#ifndef NX_READONLY_PROVIDER
#define NX_READONLY_PROVIDER() ((const nx_readonly_provider *)0)
#endif
/* -1 = native enumeration; -2 = provider error; otherwise number of indices. */
#ifndef NX_ADDON_CONTENT_LIST
#define NX_ADDON_CONTENT_LIST(indices, capacity) (-1)
#endif
#ifndef NX_IOS_RESOURCE_ENABLED
#define NX_IOS_RESOURCE_ENABLED() 0
#endif
#ifndef NX_IOS_RESOURCE_LOCATE
#define NX_IOS_RESOURCE_LOCATE(program) nil
#endif
#ifndef NX_MODULES_READY
#define NX_MODULES_READY() ((void)0)
#endif
#ifndef NX_FRAME_TICK
#define NX_FRAME_TICK(frame) ((void)0)
#endif
#ifndef NX_FRONT_ATTACH
#define NX_FRONT_ATTACH(view) ((void)0)
#endif
#ifndef NX_SAVE_MOUNT
#define NX_SAVE_MOUNT(save, title) save_sync_mount(save, title)
#endif
#ifndef NX_SAVE_COMMITTED
#define NX_SAVE_COMMITTED() save_sync_committed()
#endif

#ifndef NX_HOST_STARTUP
#define NX_HOST_STARTUP() 1
#endif

#ifndef NX_FRONT_PREPARE
#define NX_FRONT_PREPARE(controller) ((void)0)
#endif
#ifndef NX_FRONT_LAYOUT
#define NX_FRONT_LAYOUT(root, game, pad, fps) 0
#endif
#ifndef NX_FRONT_ORIENTATIONS
#define NX_FRONT_ORIENTATIONS(scene) UIInterfaceOrientationMaskAll
#endif

#ifndef NX_FRONT_BOOT_READY
#define NX_FRONT_BOOT_READY(native_ready) (native_ready)
#endif
#ifndef NX_FRONT_START_READY
#define NX_FRONT_START_READY() 1
#endif
