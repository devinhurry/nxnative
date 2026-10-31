#ifndef DM_FILE_BACKED_HEAP_H
#define DM_FILE_BACKED_HEAP_H

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

// Experimental, opt-in backing for a reservation owned by the caller. Install
// before publishing any pointers or making a Metal buffer over this range.
// MAP_SHARED keeps writes in the file object rather than anonymous COW pages.
// The unlinked file lives as long as its mapping; crashes leave no heap files.
static int dm_file_heap_back(void *reserved, size_t size, const char *directory) {
    size_t page = (size_t)getpagesize();
    if (!reserved || reserved == MAP_FAILED || !size || size > INT64_MAX ||
        ((uintptr_t)reserved | size) % page || !directory || directory[0] != '/') {
        errno = EINVAL; return -1;
    }
    char path[PATH_MAX];
    if (snprintf(path, sizeof path, "%s/dm-heap-XXXXXX", directory) >= (int)sizeof path) {
        errno = ENAMETOOLONG; return -1;
    }
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    int rc = unlink(path);
    if (!rc) rc = fcntl(fd, F_SETFD, FD_CLOEXEC);
    if (!rc) rc = ftruncate(fd, (off_t)size);
    if (!rc && mmap(reserved, size, PROT_NONE, MAP_SHARED | MAP_FIXED, fd, 0) == MAP_FAILED) rc = -1;
    int saved = errno;
    close(fd);
    errno = saved;
    return rc;
}

#endif
