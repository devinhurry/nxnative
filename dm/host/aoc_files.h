// Shared DLC discovery for startup status and the Horizon add-on-content service.
#pragma once
#include <dirent.h>
#include <stdio.h>
#include "romfs_image.h"

static inline int aoc_int_cmp(const void *a, const void *b) { return *(const int *)a - *(const int *)b; }
static inline int aoc_index(const char *name, size_t len, int allow_image) {
    if (!len || name[0] < '1' || name[0] > '9') return 0;
    size_t j = 0; int index = 0;
    for (; j < len && name[j] >= '0' && name[j] <= '9'; j++) {
        index = index * 10 + name[j] - '0';
        if (index > 2000) return 0;
    }
    return j == len || (allow_image && len - j == 4 && !memcmp(name + j, ".img", 4)) ? index : 0;
}

static inline int dm_aoc_collect(const char *dir, int *out, int capacity) {
    int count = 0;
    if (!dir || !*dir || capacity <= 0) return 0;
    DIR *d = opendir(dir); struct dirent *ent;
    while (d && (ent = readdir(d)) && count < capacity) {
        int i = aoc_index(ent->d_name, strlen(ent->d_name), 1); char path[PATH_MAX]; struct stat st;
        if (i && snprintf(path, sizeof path, "%s/%s", dir, ent->d_name) < (int)sizeof path && !stat(path, &st) &&
            (strchr(ent->d_name, '.') ? S_ISREG(st.st_mode) : S_ISDIR(st.st_mode))) out[count++] = i;
    }
    if (d) closedir(d);
    else {
        romfs_img *m = romfs_image_open(dir);
        if (m) {
            const img_ent *root = &m->e[m->root];
            for (uint64_t j = 0; j < root->b && count < capacity; j++) {
                const img_ent *x = &m->e[root->a + j];
                int i = !x->type ? aoc_index(m->names + x->name, x->nlen, 0) : 0;
                if (i) out[count++] = i;
            }
            romfs_image_close(m);
        }
    }
    qsort(out, count, sizeof *out, aoc_int_cmp);
    int unique = 0; for (int i = 0; i < count; i++) if (!i || out[i] != out[i - 1]) out[unique++] = out[i];
    count = unique;   // a legacy directory and its replacement image report the same DLC once
    return count;
}
static inline int dm_aoc_count_paths(const char *dir, const char *romfs) {
    const char *owned = getenv("DM_AOC_OWNED");
    if (owned && !strcmp(owned, "0")) return 0;
    char derived[PATH_MAX];
    if (!dir && romfs_image_aoc_path(romfs, derived, sizeof derived)) dir = derived;
    int indices[2000];
    return dm_aoc_collect(dir, indices, 2000);
}

// -1 distinguishes an absent combined-image DLC view from an authoritative empty view.
static inline int dm_aoc_combined_count(const char *romfs) {
    char derived[PATH_MAX];
    if (!romfs_image_aoc_path(romfs, derived, sizeof derived)) return -1;
    return dm_aoc_count_paths(derived, NULL);
}
