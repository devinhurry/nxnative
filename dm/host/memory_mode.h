#ifndef DM_MEMORY_MODE_H
#define DM_MEMORY_MODE_H

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#else
#include <mach/mach.h>
#endif
#endif

// Use the selected 4.5 GiB available-memory cutoff.
// This is a launch-setting heuristic, not a guarantee against memory pressure.
static inline uint64_t dm_low_memory_threshold(void) { return UINT64_C(9) << 29; }
static inline int dm_low_memory_default(uint64_t available) {
    return available && available < dm_low_memory_threshold();
}
static inline uint64_t dm_low_memory_available(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return os_proc_available_memory(); // current app headroom, not installed RAM
#elif defined(__APPLE__)
    // macOS has no iOS app budget. Estimate reclaimable RAM from free/inactive
    // pages, without counting inactive pages twice as purgeable memory.
    mach_port_t host = mach_host_self();
    vm_statistics64_data_t vm; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    int ok = host_page_size(host, &page) == KERN_SUCCESS &&
        host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS;
    mach_port_deallocate(mach_task_self(), host);
    return ok ? ((uint64_t)vm.free_count + vm.inactive_count) * page : 0;
#else
    return 0; // unavailable: preserve the ordinary default
#endif
}

// Component options alone must never bypass the master switch.
static inline int dm_low_memory_enabled(void) {
    const char *mode = getenv("DM_LOW_MEMORY");
    return mode && !strcmp(mode, "1");
}
// Apply once after launcher choices and host preload, before any guest code or
// NVN pool runs. This preset owns its component switches while enabled; turning
// it off on the next launch leaves the ordinary settings and archives in use.
// Return 1 when enabled, 0 when disabled, or -1 with errno on setup failure.
static inline int dm_low_memory_apply(void) {
    if (!dm_low_memory_enabled()) return 0;

    const char *temp = getenv("DM_TEMP");
    if (!temp || temp[0] != '/') { errno = EINVAL; return -1; }
    struct stat st;
    if (stat(temp, &st)) return -1;
    if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
    char archive[PATH_MAX];
    int n = snprintf(archive, sizeof archive, "%s/pso-low-memory", temp);
    if (n < 0 || (size_t)n >= sizeof archive) { errno = ENAMETOOLONG; return -1; }
    if (mkdir(archive, 0700) && errno != EEXIST) return -1;
    if (stat(archive, &st)) return -1;
    if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }

    if (setenv("DM_FILE_HEAP", temp, 1) ||
        setenv("DM_NVN_TRANSIENT_UPLOADS", "1", 1) ||
        setenv("DM_PSO_PREBUILD", "0", 1) ||
        setenv("DM_PSO_BUNDLE", "off", 1) ||
        setenv("DM_PSO_ARCHIVE", archive, 1)) return -1;
    return 1;
}

#endif
