#include <assert.h>
#include <dirent.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../memory_mode.h"
#include "../file_backed_heap.h"

static void value(const char *key, const char *want) {
    const char *got = getenv(key);
    assert(got && !strcmp(got, want));
}

int main(void) {
    const uint64_t gib = UINT64_C(1) << 30;
    assert(!dm_low_memory_default(0)); // unavailable, not a measured low budget
    assert(dm_low_memory_default(4 * gib));
    assert(dm_low_memory_default(4 * gib + gib / 2 - 1));
    assert(!dm_low_memory_default(4 * gib + gib / 2));
    assert(!dm_low_memory_default(8 * gib));
    const char *scratch = getenv("TMPDIR"); assert(scratch && scratch[0] == '/');
    char root[PATH_MAX], cache[PATH_MAX], marker[PATH_MAX];
    assert(snprintf(root, sizeof root, "%s/memory-mode.XXXXXX", scratch) < (int)sizeof root);
    assert(mkdtemp(root));
    assert(snprintf(cache, sizeof cache, "%s/pso-low-memory", root) < (int)sizeof cache);
    assert(snprintf(marker, sizeof marker, "%s/keep", cache) < (int)sizeof marker);
    setenv("DM_SAVE", "/existing-save", 1);
    setenv("DM_FILE_HEAP", "/existing-heap", 1);
    setenv("DM_PSO_ARCHIVE", "/existing-archive", 1);
    setenv("DM_PSO_BUNDLE", "/existing-bundle", 1);
    setenv("DM_PSO_PREBUILD", "1", 1);
    setenv("DM_NVN_TRANSIENT_UPLOADS", "0", 1);
    unsetenv("DM_LOW_MEMORY"); unsetenv("DM_TEMP");
    assert(dm_low_memory_apply() == 0);
    setenv("DM_LOW_MEMORY", "0", 1);
    assert(dm_low_memory_apply() == 0);
    setenv("DM_LOW_MEMORY", "unexpected", 1);
    assert(dm_low_memory_apply() == 0);
    value("DM_FILE_HEAP", "/existing-heap"); value("DM_PSO_ARCHIVE", "/existing-archive");
    value("DM_PSO_BUNDLE", "/existing-bundle"); value("DM_PSO_PREBUILD", "1");
    value("DM_NVN_TRANSIENT_UPLOADS", "0");
    assert(access(cache, F_OK) == -1);

    setenv("DM_LOW_MEMORY", "1", 1);
    assert(dm_low_memory_apply() == -1 && errno == EINVAL);
    setenv("DM_TEMP", "relative", 1);
    assert(dm_low_memory_apply() == -1 && errno == EINVAL);
    setenv("DM_TEMP", root, 1);
    FILE *f = fopen(cache, "w"); assert(f); assert(!fclose(f));
    assert(dm_low_memory_apply() == -1 && errno == ENOTDIR);
    value("DM_FILE_HEAP", "/existing-heap"); value("DM_PSO_ARCHIVE", "/existing-archive");
    assert(!unlink(cache));

    assert(dm_low_memory_apply() == 1);
    value("DM_FILE_HEAP", root); value("DM_NVN_TRANSIENT_UPLOADS", "1");
    value("DM_PSO_PREBUILD", "0"); value("DM_PSO_BUNDLE", "off");
    value("DM_PSO_ARCHIVE", cache); value("DM_TEMP", root); value("DM_SAVE", "/existing-save");
    f = fopen(marker, "w"); assert(f); assert(fputs("cached", f) >= 0); assert(!fclose(f));
    assert(dm_low_memory_apply() == 1);
    f = fopen(marker, "r"); assert(f); assert(fgetc(f) == 'c'); assert(!fclose(f));

    // The resolved container path must work with the actual heap backing helper.
    size_t page = (size_t)getpagesize();
    void *heap = mmap(NULL, page, PROT_NONE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(heap != MAP_FAILED);
    assert(!dm_file_heap_back(heap, page, getenv("DM_FILE_HEAP")));
    assert(!mprotect(heap, page, PROT_READ | PROT_WRITE));
    memset(heap, 0x5d, page); assert(!msync(heap, page, MS_SYNC));
    for (size_t i = 0; i < page; i++) assert(((unsigned char *)heap)[i] == 0x5d);
    assert(!munmap(heap, page));
    DIR *dir = opendir(root); assert(dir);
    struct dirent *entry;
    while ((entry = readdir(dir))) assert(strncmp(entry->d_name, "dm-heap-", 8));
    assert(!closedir(dir));
    assert(!unlink(marker)); assert(!rmdir(cache)); assert(!rmdir(root));
    puts("memory mode: defaults, preset, private paths, preserved cache, and real file backing passed");
    return 0;
}
