// Synthetic combined image: base romfs/data/{a="base",empty/,other="z"}, DLC 2 data/a="two", DLC 7 item="seven".
#pragma once
#include <stdio.h>
#include "../romfs_image.h"

static int game_image_fixture(const char *path) {
    const char *names[] = {"", "aoc", "romfs", "2", "7", "data", "data", "item", "a", "empty", "other", "a"};
    img_ent entries[] = {
        {1, 2, 0, 0, 0, 0}, {3, 2, 0, 0, 0, 0}, {5, 1, 0, 0, 0, 0}, {6, 1, 0, 0, 0, 0}, {7, 1, 0, 0, 0, 0},
        {8, 3, 0, 0, 0, 0}, {11, 1, 0, 0, 0, 0}, {32, 5, 0, 0, 1, 0}, {37, 4, 0, 0, 1, 0},
        {12, 0, 0, 0, 0, 0}, {41, 1, 0, 0, 1, 0}, {42, 3, 0, 0, 1, 0},
    };
    char pool[64]; size_t used = 0;
    for (size_t i = 0; i < sizeof entries / sizeof *entries; i++) {
        entries[i].name = (uint32_t)used; entries[i].nlen = (uint16_t)strlen(names[i]);
        memcpy(pool + used, names[i], entries[i].nlen); used += entries[i].nlen;
    }
    uint64_t header[] = {45, sizeof entries + used, sizeof entries / sizeof *entries};
    FILE *f = fopen(path, "wb"); if (!f) return 0;
    int ok = fwrite("DMROMFS1", 1, 8, f) == 8 && fwrite(header, 1, sizeof header, f) == sizeof header &&
        fwrite("sevenbaseztwo", 1, 13, f) == 13 && fwrite(entries, 1, sizeof entries, f) == sizeof entries && fwrite(pool, 1, used, f) == used;
    return !fclose(f) && ok;
}
