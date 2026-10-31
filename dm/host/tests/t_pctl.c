// pctl free communication offline policy (hle_misc.c, from PR #38): the hooks are looked up by their mangled names in the real swforce registrations, so a missing or misspelled
// takeover fails; no guest module, IPC session or system applet exists in this test
#include "../hle_misc.c"
#include "game_image_fixture.h"
void dm_applet_enter(const char *name) { (void)name; }   // hle_oe.c: the shop and error stand-ins hold the game out of focus
void dm_applet_leave(void) {}
#include <mach-o/getsect.h>

static int unexpected, checks, fails;
void *guest_sym(const char *name) { (void)name; unexpected++; return NULL; }
module_t *module_of(const void *p) { (void)p; unexpected++; return NULL; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; unexpected++; }
// The big-stack take-overs' stubs (HLE_FORCE_BIG) jump here with the implementation in x16; off a guest stack the real entry calls it straight
__asm__(".text\n.p2align 2\n.globl _dm_bigstack_enter\n_dm_bigstack_enter:\n    br x16\n");
extern const struct mach_header_64 _mh_execute_header;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static void *hook(const char *name) {
    unsigned long bytes = 0;
    const hle_force_ent *e = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &bytes);
    void *fn = NULL; unsigned count = 0;
    for (size_t i = 0; e && i < bytes / sizeof *e; i++) {
        if (strcmp(e[i].name, name)) continue;
        count++; fn = (void *)e[i].fn;
        CHECK(e[i].why && e[i].why[0], "takeover has a reason");
    }
    CHECK(count == 1 && fn, name);
    return count == 1 ? fn : NULL;
}
int main(void) {
    // bool arguments are widened as hle.h requires (only the low 8 bits count); the returns are bools in w0, not nn::Result
    unsigned (*check)(unsigned) = hook("_ZN2nn4pctl32CheckFreeCommunicationPermissionEb");
    unsigned (*begin)(unsigned) = hook("_ZN2nn4pctl25TryBeginFreeCommunicationEb");
    unsigned (*available)(void) = hook("_ZN2nn4pctl28IsFreeCommunicationAvailableEv");
    void (*end)(void) = hook("_ZN2nn4pctl20EndFreeCommunicationEv");
    unsigned (*stereo)(unsigned) = hook("_ZN2nn4pctl27CheckStereoVisionPermissionEb");
    const unsigned args[] = {0, 1, 0x100, 0x101, ~0u};
    if (available) CHECK(available() == 0, "communication unavailable before any permission query");
    for (size_t i = 0; i < sizeof args / sizeof *args; i++) {
        if (check) CHECK(check(args[i]) == 0, "permission query denies communication, with or without UI");
        if (begin) CHECK(begin(args[i]) == 0, "begin agrees with the permission query");
        if (stereo) CHECK(stereo(args[i]) == 0, "stereoscopic 3D not permitted: no VR display, as pl::BeginVrMode answers");
        if (end) end();
        if (check) CHECK(check(args[i]) == 0, "ending communication does not grant permission");
        if (available) CHECK(available() == 0, "permission queries do not make communication available");
    }
    CHECK(unexpected == 0, "no guest symbol lookup or event binding");
    char root[1024], image[1100], view[1200], path[1200];
    snprintf(root, sizeof root, "%s/t_aoc.XXXXXX", getenv("TMPDIR") ?: "/private/tmp");
    CHECK(mkdtemp(root), "create DLC fixture directory");
    snprintf(image, sizeof image, "%s/game.img", root); CHECK(game_image_fixture(image), "create combined game image");
    snprintf(view, sizeof view, "%s/aoc", image); setenv("DM_AOC_DIR", view, 1); unsetenv("DM_AOC_OWNED");
    int owned[4] = {0};
    CHECK(h_aoc_Count() == 2 && h_aoc_List(owned, 0, 4) == 2 && owned[0] == 2 && owned[1] == 7, "DLC ownership lists only immediate numeric directories in the combined aoc view");
    g_naoc = -1; unsetenv("DM_AOC_DIR"); setenv("DM_ROMFS", image, 1);
    CHECK(h_aoc_Count() == 2 && h_aoc_List(owned, 1, 4) == 1 && owned[0] == 7, "whole-image DM_ROMFS supplies the default owned DLC list");
    g_naoc = -1; snprintf(view, sizeof view, "%s/romfs", image); setenv("DM_ROMFS", view, 1);
    CHECK(h_aoc_Count() == 2, "a base-image view also supplies the default owned DLC list");
    g_naoc = -1; setenv("DM_AOC_DIR", "", 1);
    CHECK(h_aoc_Count() == 0, "explicit empty DM_AOC_DIR overrides the combined image");
    g_naoc = -1; setenv("DM_AOC_OWNED", "0", 1); unsetenv("DM_AOC_DIR");
    CHECK(h_aoc_Count() == 0, "DM_AOC_OWNED=0 disables image DLC");
    unsetenv("DM_AOC_OWNED"); setenv("DM_AOC_DIR", root, 1);
    const char *dirs[] = {"2", "8.img", "0", "2001"}, *files[] = {"2.img", "7.img", "4"};
    for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) { snprintf(path, sizeof path, "%s/%s", root, dirs[i]); mkdir(path, 0700); }
    for (size_t i = 0; i < sizeof files / sizeof *files; i++) { snprintf(path, sizeof path, "%s/%s", root, files[i]); FILE *f = fopen(path, "wb"); if (f) fclose(f); }
    g_naoc = -1;
    CHECK(h_aoc_Count() == 2 && h_aoc_List(owned, 0, 4) == 2 && owned[0] == 2 && owned[1] == 7, "legacy folders and image files remain supported, deduplicated, without unrelated ordinary files");
    for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) { snprintf(path, sizeof path, "%s/%s", root, dirs[i]); rmdir(path); }
    for (size_t i = 0; i < sizeof files / sizeof *files; i++) { snprintf(path, sizeof path, "%s/%s", root, files[i]); unlink(path); }
    setenv("DM_AOC_DIR", image, 1); int fd = open(image, O_WRONLY); if (fd >= 0) { ftruncate(fd, 9); close(fd); }
    g_naoc = -1; CHECK(h_aoc_Count() == 0, "an invalid image reports no owned DLC");
    unlink(image); rmdir(root);
    printf("pctl: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
