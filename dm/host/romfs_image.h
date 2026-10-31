// DMROMFS1's index loader, shared by the host mount and iOS startup. Startup must validate the same index before replacing a working folder.
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { uint64_t a, b; uint32_t name; uint16_t nlen; uint8_t type, pad; } __attribute__((packed)) img_ent;   // directory: a = first child, b = children; file: a = offset, b = size
_Static_assert(sizeof(img_ent) == 24, "RomFS image entry layout");
typedef struct { int fd; uint64_t n, root, index_size, device, inode; img_ent *e; const char *names; char *path; int shared_index; } romfs_img;

static void romfs_image_close(romfs_img *m) {
    if (m) { close(m->fd); if (!m->shared_index) free(m->e); free(m->path); free(m); }
}
static int romfs_image_read(int fd, void *buf, size_t size, off_t off) {
    size_t got = 0;
    while (got < size) {
        ssize_t n = pread(fd, (char *)buf + got, size - got, off + (off_t)got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (!n) errno = EINVAL; return 0; }
        got += (size_t)n;
    }
    return 1;
}
// NULL for an incomplete or invalid image (errno EINVAL), an I/O error, or allocation failure. The caller owns the descriptor and index on success.
static romfs_img *romfs_image_open_file(const char *path) {
    int fd = open(path, O_RDONLY); struct stat st; uint8_t h[32]; romfs_img *m = NULL; uint64_t ioff, isz, n;
    if (fd < 0) return NULL;
    if (fstat(fd, &st) || !romfs_image_read(fd, h, sizeof h, 0)) goto bad;
    errno = EINVAL;
    if (memcmp(h, "DMROMFS1", 8) || st.st_size < (off_t)sizeof h) goto bad;
    memcpy(&ioff, h + 8, 8); memcpy(&isz, h + 16, 8); memcpy(&n, h + 24, 8);
    if (!n || n > UINT32_MAX || ioff < sizeof h || ioff > (uint64_t)st.st_size || isz != (uint64_t)st.st_size - ioff || isz > SIZE_MAX || n > isz / sizeof(img_ent)) goto bad;
    if (!(m = calloc(1, sizeof *m))) goto bad;
    m->fd = fd;
    m->device = (uint64_t)st.st_dev; m->inode = (uint64_t)st.st_ino;
    if (!(m->path = strdup(path))) goto bad;
    if (!(m->e = malloc((size_t)isz)) || !romfs_image_read(fd, m->e, (size_t)isz, (off_t)ioff)) goto bad;
    m->n = n; m->index_size = isz; m->names = (const char *)m->e + n * sizeof(img_ent);
    uint64_t pool = isz - n * sizeof(img_ent), next_child = 1;
    errno = EINVAL;
    if (m->e[0].type || m->e[0].nlen) goto bad;
    for (uint64_t k = 0; k < n; k++) {
        const img_ent *x = &m->e[k];
        if ((uint64_t)x->name + x->nlen > pool || x->type > 1 || x->pad) goto bad;
        const char *name = m->names + x->name;
        if (k && (!x->nlen || x->nlen > 0x300 || memchr(name, 0, x->nlen) || memchr(name, '/', x->nlen) || (x->nlen == 1 && name[0] == '.') || (x->nlen == 2 && !memcmp(name, "..", 2)))) goto bad;
        if (x->type) { if (x->a < sizeof h || x->a > ioff || x->b > ioff - x->a) goto bad; }
        else {
            // Breadth-first child runs partition entries 1..n-1; reject cycles, aliases and unreachable entries.
            if (x->a != next_child || x->a <= k || x->a > n || x->b > n - x->a) goto bad;
            next_child += x->b;
        }
    }
    if (next_child != n) goto bad;
    for (uint64_t k = 0; k < n; k++) {
        const img_ent *d = &m->e[k]; if (d->type) continue;
        for (uint64_t j = 1; j < d->b; j++) {
            const img_ent *a = &m->e[d->a + j - 1], *b = a + 1;
            size_t len = a->nlen < b->nlen ? a->nlen : b->nlen;
            int c = memcmp(m->names + a->name, m->names + b->name, len);
            if (c > 0 || (!c && a->nlen >= b->nlen)) goto bad;
        }
    }
    return m;
bad: {
    int e = errno ? errno : EINVAL;
    if (m) romfs_image_close(m); else close(fd);
    errno = e; return NULL;
    }
}

// Normalize relative to the selected image directory, never above it. This is lexical, as Horizon normalizes a/../b before looking up either name.
static inline int romfs_image_normalize(const char *path, char *out, size_t size) {
    size_t len = 0;
    if (!path || !size) { errno = EINVAL; return 0; }
    out[0] = 0;
    while (*path) {
        while (*path == '/' || *path == '\\') path++;
        if (!*path) break;
        const char *end = path; while (*end && *end != '/' && *end != '\\') end++;
        size_t n = (size_t)(end - path);
        if (n == 2 && path[0] == '.' && path[1] == '.') {
            if (!len) { errno = ENOENT; return 0; }
            while (len && out[len - 1] != '/') len--;
            if (len) len--;
            out[len] = 0;
        } else if (!(n == 1 && path[0] == '.')) {
            if (n > 0x300 || len + n + 2 > size) { errno = ENAMETOOLONG; return 0; }
            out[len++] = '/'; memcpy(out + len, path, n); len += n; out[len] = 0;
        }
        path = end;
    }
    return 1;
}

// A binary search of each directory's sorted child run. root belongs to this mount: a DLC cannot name its siblings or the base game's files.
static inline int64_t romfs_image_find(const romfs_img *m, const char *path) {
    char normalized[PATH_MAX];
    if (!m || !romfs_image_normalize(path, normalized, sizeof normalized)) return -1;
    const char *rest = normalized; uint64_t k = m->root;
    while (*rest) {
        rest++;
        const char *end = strchr(rest, '/'); if (!end) end = rest + strlen(rest);
        size_t len = (size_t)(end - rest);
        if (m->e[k].type) { errno = ENOTDIR; return -1; }
        uint64_t lo = m->e[k].a, hi = lo + m->e[k].b; int found = 0;
        while (lo < hi) {
            uint64_t mid = lo + (hi - lo) / 2; const img_ent *x = &m->e[mid];
            int c = memcmp(m->names + x->name, rest, x->nlen < len ? x->nlen : len);
            if (!c) c = (x->nlen > len) - (x->nlen < len);
            if (!c) { k = mid; found = 1; break; }
            if (c < 0) lo = mid + 1; else hi = mid;
        }
        if (!found) { errno = ENOENT; return -1; }
        rest = end;
    }
    return (int64_t)k;
}

// Accept a physical image or a directory view such as game.img/romfs and game.img/aoc/2. Real directories (including ones named *.img) keep their usual meaning.
static inline romfs_img *romfs_image_open(const char *path) {
    if (!path || strlen(path) >= PATH_MAX) { errno = path ? ENAMETOOLONG : EINVAL; return NULL; }
    char physical[PATH_MAX]; strcpy(physical, path);
    struct stat st; const char *sub = path + strlen(path); int ancestor = 0;
    for (;;) {
        if (!stat(physical, &st)) {
            if (!S_ISREG(st.st_mode)) { errno = S_ISDIR(st.st_mode) ? (ancestor ? ENOENT : EISDIR) : EINVAL; return NULL; }
            break;
        }
        if (errno != ENOTDIR && errno != ENOENT) return NULL;
        char *slash = strrchr(physical, '/');
        if (!slash) return NULL;
        sub = path + (slash - physical) + 1;
        if (slash == physical) return NULL;
        *slash = 0; ancestor = 1;
    }
    romfs_img *m = romfs_image_open_file(physical);
    if (!m) return NULL;
    if (*sub) {
        int64_t root = romfs_image_find(m, sub);
        if (root < 0 || m->e[root].type) {
            int e = root < 0 ? errno : ENOTDIR; romfs_image_close(m); errno = e; return NULL;
        }
        m->root = (uint64_t)root;
    }
    return m;
}

// Detect the combined layout from the physical container, independent of the selected view.
static inline int romfs_image_combined(const romfs_img *m, uint64_t *romfs, uint64_t *aoc) {
    romfs_img container = *m; container.root = 0;
    int64_t r = romfs_image_find(&container, "romfs"), a = romfs_image_find(&container, "aoc");
    if (r < 0 || a < 0 || m->e[r].type || m->e[a].type) return 0;
    if (romfs) *romfs = (uint64_t)r;
    if (aoc) *aoc = (uint64_t)a;
    return 1;
}

// All frontends can omit DM_AOC_DIR when DM_ROMFS names a whole combined image or its base view. Explicit DM_AOC_DIR is handled by the caller and takes precedence.
static inline int romfs_image_aoc_path(const char *romfs, char *out, size_t size) {
    if (!romfs) return 0;
    romfs_img *m = romfs_image_open(romfs); if (!m) return 0;
    uint64_t base; int ok = romfs_image_combined(m, &base, NULL) && (!m->root || m->root == base);
    size_t len = strlen(m->path);
    if (ok && len + sizeof "/aoc" <= size) { memcpy(out, m->path, len); memcpy(out + len, "/aoc", sizeof "/aoc"); }
    else ok = 0;
    romfs_image_close(m); return ok;
}

static inline size_t romfs_image_buckets(size_t n) {
    if (n < 3) return 3;
    if (n < 19) return n | 1;
    while (!(n % 2 && n % 3 && n % 5 && n % 7 && n % 11 && n % 13 && n % 17)) n++;
    return n;
}

// Horizon's file-table work buffer counts only the mounted subtree; its root has an empty name even when the physical image calls it romfs or 2.
static inline size_t romfs_image_work_size(const romfs_img *m) {
    size_t ndir = 1, dbytes = 0x18, nfile = 0, fbytes = 0;
    const img_ent *root = &m->e[m->root];
    uint64_t first = root->a, end = first + root->b;
    while (first < end) {
        uint64_t next_first = m->n, next_end = m->n;
        for (uint64_t k = first; k < end; k++) {
            const img_ent *e = &m->e[k]; size_t name = (e->nlen + 3) & ~(size_t)3;
            if (e->type) { nfile++; fbytes += 0x20 + name; }
            else {
                ndir++; dbytes += 0x18 + name;
                if (next_first == m->n) next_first = e->a;
                next_end = e->a + e->b;
            }
        }
        first = next_first; end = next_end;
    }
    return 4 * romfs_image_buckets(ndir) + dbytes + 4 * romfs_image_buckets(nfile) + fbytes;
}
