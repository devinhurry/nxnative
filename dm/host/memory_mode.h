#ifndef DM_MEMORY_MODE_H
#define DM_MEMORY_MODE_H

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// Apply once after launcher choices and host preload, before any guest code or
// NVN pool runs. This preset owns its component switches while enabled; turning
// it off on the next launch leaves the ordinary settings and archives in use.
// Return 1 when enabled, 0 when disabled, or -1 with errno on setup failure.
static int dm_low_memory_apply(void) {
    const char *mode = getenv("DM_LOW_MEMORY");
    if (!mode || !*mode || !strcmp(mode, "0")) return 0;
    if (strcmp(mode, "1")) { errno = EINVAL; return -1; }

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
