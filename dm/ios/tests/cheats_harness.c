// Loader and memory fixture for the real cheat engine in the launcher-only simulator app.
#include "dm.h"
#include "dm_input.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static module_t fixture_module;
module_t *g_mod = &fixture_module;
int g_nmod;
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }
uint64_t dm_cheats_keys(void) { return 0; }
const char *dm_module_dir(void) { return ""; }
void dm_guest_write_prepare(void *address, size_t size) { (void)address; (void)size; }
void dm_guest_heap_range(uint64_t *base, size_t *size) { *base = 0; *size = 0; }
int dm_guest_heap_read(uint64_t address, void *out, size_t size) { (void)address; (void)out; (void)size; return 1; }
int dm_guest_heap_write(uint64_t address, const void *in, size_t size) { (void)address; (void)in; (void)size; return 1; }
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void svc_guest_range(uint8_t **base, size_t *size) { *base = NULL; *size = 0; }
void svc_alias_range(uint8_t **base, size_t *size) { *base = NULL; *size = 0; }

static void write_fixture(const char *folder, const char *name, const char *text) {
    char path[1400]; snprintf(path, sizeof path, "%s/%s", folder, name);
    if (access(path, F_OK) == 0) return; // Keep choices across intentional fixture relaunches.
    FILE *file = fopen(path, "w");
    if (!file) { perror(path); abort(); }
    fputs(text, file); fclose(file);
}
void dm_test_cheats_prepare(const char *documents) {
    char folder[1200]; snprintf(folder, sizeof folder, "%s/cheats", documents);
    mkdir(folder, 0755);
    setenv("DM_CHEATS", folder, 1);
    write_fixture(folder, "1111111111111111.txt",
        "[Coins]\n04000000 00004000 000003E7\n"
        "[Health]\n04000000 00004004 00000064\n"
        "[Set items]\n04000000 00004008 0000000A\n"
        "[Unsupported logger]\nFFF00000 00000000\n");
    write_fixture(folder, "1111111111111111.meta.tsv",
        "# build 1111111111111111 1.0.0 (fixture)\n"
        "name\tkind\tsection\ttype\taction\tvalue\task\tvalue_words\tonce\tnote\taddress\n"
        "Coins\tdata\tInventory\tu32\tfreeze\t999\t0..9999\t2\t\tSynthetic coins\t0:0x4000\n"
        "Health\tdata\tPlayer\tu32\tfreeze\t100\t\t\t\tSynthetic health\t0:0x4004\n"
        "Set items\tdata\tInventory\tu32\tset\t10\t0..99\t2\t1\tOne-time fixture\t0:0x4008\n");
    dm_cheats_prepare("1111111111111111aaaaaaaaaaaaaaaa");
}
void dm_test_cheats_start(void) {
    if (!fixture_module.base) {
        fixture_module.base = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (fixture_module.base == MAP_FAILED) abort();
        snprintf(fixture_module.name, sizeof fixture_module.name, "main");
        snprintf(fixture_module.build_id, sizeof fixture_module.build_id, "1111111111111111aaaaaaaaaaaaaaaa");
        fixture_module.size = 0x10000; fixture_module.text_end = 0x4000;
        fixture_module.key_page_off = 0xc000; fixture_module.key_page_size = 0x4000; fixture_module.patch_off = -1;
        g_nmod = 1;
        dm_cheats_init();
    }
}
