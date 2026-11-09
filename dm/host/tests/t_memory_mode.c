#include <assert.h>
#include <unistd.h>
#include "../memory_mode.h"

static void value(const char *key, const char *want) {
    const char *got = getenv(key); assert(got && !strcmp(got, want));
}
int main(void) {
    const uint64_t gib = UINT64_C(1) << 30;
    assert(!dm_low_memory_default(0));
    assert(dm_low_memory_default(4 * gib));
    assert(dm_low_memory_default(4 * gib + gib / 2 - 1));
    assert(!dm_low_memory_default(4 * gib + gib / 2));
    assert(!dm_low_memory_wanted(NULL, 0, 4 * gib));
    assert(dm_low_memory_wanted(NULL, 1, 4 * gib));
    assert(dm_low_memory_wanted("auto", 1, 4 * gib));
    assert(!dm_low_memory_wanted("auto", 1, 8 * gib));
    assert(dm_low_memory_wanted("1", 0, 8 * gib));
    assert(!dm_low_memory_wanted("0", 1, 4 * gib));
    assert(!dm_low_memory_wanted("invalid", 1, 4 * gib));

    const char *tmp = getenv("TMPDIR"); assert(tmp && tmp[0] == '/');
    char root[PATH_MAX], archive[PATH_MAX], keep[PATH_MAX];
    assert(snprintf(root, sizeof root, "%s/memory-mode.XXXXXX", tmp) < (int)sizeof root);
    assert(mkdtemp(root));
    assert(snprintf(archive, sizeof archive, "%s/pso-low-memory", root) < (int)sizeof archive);
    assert(snprintf(keep, sizeof keep, "%s/keep", archive) < (int)sizeof keep);
    setenv("DM_SAVE", "/existing-save", 1); setenv("DM_GUEST_FILE", "0", 1);
    setenv("DM_PSO_PREBUILD", "1", 1); setenv("DM_PSO_BUNDLE", "/old-bundle", 1);
    setenv("DM_PSO_ARCHIVE", "/old-archive", 1); setenv("DM_TEMP", root, 1);
    setenv("DM_LOW_MEMORY", "0", 1); assert(dm_low_memory_apply(1) == 0);
    value("DM_GUEST_FILE", "0"); value("DM_PSO_PREBUILD", "1"); value("DM_PSO_BUNDLE", "/old-bundle");
    value("DM_PSO_ARCHIVE", "/old-archive"); assert(access(archive, F_OK));
    setenv("DM_LOW_MEMORY", "1", 1); setenv("DM_TEMP", "relative", 1);
    assert(dm_low_memory_apply(0) == -1 && errno == EINVAL); value("DM_GUEST_FILE", "0");
    setenv("DM_TEMP", root, 1); assert(dm_low_memory_apply(0) == 1);
    value("DM_GUEST_FILE", "1"); value("DM_PSO_PREBUILD", "0"); value("DM_PSO_BUNDLE", "off");
    value("DM_PSO_ARCHIVE", archive); value("DM_SAVE", "/existing-save");
    FILE *f = fopen(keep, "w"); assert(f); assert(fputs("cache", f) >= 0); assert(!fclose(f));
    assert(dm_low_memory_apply(0) == 1); assert(!access(keep, F_OK));
    assert(!unlink(keep)); assert(!rmdir(archive)); assert(!rmdir(root));
    unsetenv("DM_TEMP"); assert(dm_low_memory_apply(0) == 1); value("DM_PSO_ARCHIVE", "off");
    puts("memory mode: automatic threshold, overrides, isolated archive and preserved save passed");
    return 0;
}
