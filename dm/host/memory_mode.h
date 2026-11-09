#pragma once
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
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

// Current available memory, not installed RAM. Unknown memory keeps auto off.
static inline int dm_low_memory_default(uint64_t available) {
    return available && available < (UINT64_C(9) << 29);
}
static inline uint64_t dm_low_memory_available(void) {
#if defined(__APPLE__) && TARGET_OS_IPHONE
    return os_proc_available_memory();
#elif defined(__APPLE__)
    mach_port_t host = mach_host_self(); vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT; vm_size_t page = 0;
    int ok = host_page_size(host, &page) == KERN_SUCCESS &&
        host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) == KERN_SUCCESS;
    mach_port_deallocate(mach_task_self(), host);
    return ok ? ((uint64_t)vm.free_count + vm.inactive_count) * page : 0;
#else
    return 0;
#endif
}
static inline int dm_low_memory_wanted(const char *mode, int default_auto, uint64_t available) {
    if (!mode || !*mode) return default_auto && dm_low_memory_default(available);
    if (!strcmp(mode, "auto")) return dm_low_memory_default(available);
    return !strcmp(mode, "1");
}

// Called after launcher choices and preload, before guest memory or GPU pools.
// The preset owns its component switches while enabled. The host enforces
// disk-space limits for guest files and uses temporary texture upload sources.
static inline int dm_low_memory_apply(int default_auto) {
    if (!dm_low_memory_wanted(getenv("DM_LOW_MEMORY"), default_auto, dm_low_memory_available())) return 0;
    const char *temp = getenv("DM_TEMP"); char archive[PATH_MAX];
    const char *archive_path = "off";   // a command-line run may have no DM_TEMP
    if (temp && *temp) {
        struct stat st;
        if (temp[0] != '/') { errno = EINVAL; return -1; }
        if (stat(temp, &st)) return -1;
        if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
        int n = snprintf(archive, sizeof archive, "%s/pso-low-memory", temp);
        if (n < 0 || (size_t)n >= sizeof archive) { errno = ENAMETOOLONG; return -1; }
        if (mkdir(archive, 0700) && errno != EEXIST) return -1;
        if (stat(archive, &st)) return -1;
        if (!S_ISDIR(st.st_mode)) { errno = ENOTDIR; return -1; }
        archive_path = archive;
    }
    if (setenv("DM_GUEST_FILE", "1", 1) || setenv("DM_PSO_PREBUILD", "0", 1) ||
        setenv("DM_PSO_BUNDLE", "off", 1) || setenv("DM_PSO_ARCHIVE", archive_path, 1)) return -1;
    return 1;
}
