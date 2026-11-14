// Map the guest's reserved ranges in 256 MiB
// chunks, up to four donor processes, leaving 256 MiB of each donor's reported
// allowance unused. Donors are ended once the shared mappings are installed.
#include "ram_donor.h"
#include <errno.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

extern kern_return_t mach_vm_region_recurse(vm_map_t, mach_vm_address_t *, mach_vm_size_t *, natural_t *, vm_region_recurse_info_t, mach_msg_type_number_t *);
enum { DONOR_RUNS = 1024, DONOR_MAX = 4 };
static const size_t chunk_bytes = 256ull << 20;
typedef struct { uintptr_t lo, hi; int donor; uint32_t object; } donor_run;
static donor_run g_runs[DONOR_RUNS];
static _Atomic int g_runs_n;

int dm_donor_enabled(void) { const char *e = getenv("DM_RAM_DONOR"); return !(e && !strcmp(e, "0")); }

static void restore(uintptr_t a, size_t n) {
    if (mmap((void *)a, n, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == MAP_FAILED) {
        fprintf(stderr, "[dm] FATAL RAM donor: cannot put the guest reservation back at %#lx+%#zx (errno %d)\n", (unsigned long)a, n, errno);
        abort();
    }
}
static uint32_t object_at(uintptr_t a) {
    mach_vm_address_t address = a; mach_vm_size_t size = 0; natural_t depth = 0;
    for (int i = 0; i < 64; i++) {
        vm_region_submap_info_data_64_t info = {0}; mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t k = mach_vm_region_recurse(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count);
        if (k != KERN_SUCCESS || address > a) return 0;
        if (!info.is_submap) return info.object_id;
        depth++;
    }
    return 0;
}

size_t dm_donor_back(const dm_donor_range *ranges, int n, const dm_donor_ops *ops, int maximum) {
    if (n <= 0) return 0;
    size_t total = 0, mapped = 0; for (int i = 0; i < n; i++) total += ranges[i].size;
    if (!total) return 0;
    if (!dm_donor_enabled()) {
        fprintf(stderr, "[dm] [mem] RAM donor: off (DM_RAM_DONOR=0), the guest's %.2f GB are the app's own memory\n", total / 1073741824.0);
        return 0;
    }
    struct { int id, used; uint64_t left; } donors[DONOR_MAX] = {0};
    int nd = 0, next = 0, stop = 0; char why[256] = "";
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (maximum > DONOR_MAX) maximum = DONOR_MAX;
    for (int r = 0; r < n && !stop; r++) for (size_t off = 0; off < ranges[r].size;) {
        size_t size = ranges[r].size - off; if (size > chunk_bytes) size = chunk_bytes;
        int slot = -1;
        for (int i = 0; i < nd; i++) { int d = next++ % nd; if (donors[d].left >= size) { slot = d; break; } }
        if (slot < 0) {
            if (nd >= maximum) { snprintf(why, sizeof why, "the %d donor processes had no room for more (each keeps 256 MB of what it reports available)", nd); stop = 1; break; }
            int id = ops->start(ops->context, why, sizeof why); if (id < 0) { stop = 1; break; }
            uint64_t available = ops->available(ops->context, id);
            slot = nd++; donors[slot].id = id; donors[slot].left = available > chunk_bytes ? available - chunk_bytes : 0;
            fprintf(stderr, "[dm] [mem] RAM donor process %d: %.0f MB available, up to %.0f MB of it used\n", id, available / 1048576.0, donors[slot].left / 1048576.0);
            if (donors[slot].left < size) { snprintf(why, sizeof why, "donor process %d reports %.0f MB available, too little for a %.0f MB chunk with its 256 MB headroom", id, available / 1048576.0, size / 1048576.0); stop = 1; break; }
        }
        int count = atomic_load_explicit(&g_runs_n, memory_order_relaxed);
        if (count >= DONOR_RUNS) { snprintf(why, sizeof why, "more than %d chunks", DONOR_RUNS); stop = 1; break; }
        uintptr_t address = ranges[r].address + off;
        if (ops->map(ops->context, donors[slot].id, address, size, why, sizeof why)) { restore(address, size); stop = 1; break; }
        if (mprotect((void *)address, size, PROT_NONE)) { snprintf(why, sizeof why, "a donated chunk could not be made inaccessible (errno %d)", errno); restore(address, size); stop = 1; break; }
        g_runs[count] = (donor_run){address, address + size, donors[slot].id, object_at(address)};
        atomic_store_explicit(&g_runs_n, count + 1, memory_order_release);
        donors[slot].left -= size; donors[slot].used = 1; off += size; mapped += size;
    }
    int used = 0; for (int i = 0; i < nd; i++) used += donors[i].used;
    if (mapped == total) fprintf(stderr, "[dm] [mem] RAM donor: the guest's %.2f GB on memory of %d donor processes (%d chunks, %.0f ms): their pages are not the app's footprint, the donors are ended\n", total / 1073741824.0, used, atomic_load(&g_runs_n), (clock_gettime_nsec_np(CLOCK_MONOTONIC) - t0) / 1e6);
    else if (mapped) fprintf(stderr, "[dm] [mem] RAM donor: %.2f GB of the guest's %.2f GB on memory of %d donor processes, the other %.2f GB are the app's own memory: %s\n", mapped / 1073741824.0, total / 1073741824.0, used, (total - mapped) / 1073741824.0, why);
    else fprintf(stderr, "[dm] [mem] RAM donor: none, the guest's %.2f GB are the app's own memory: %s\n", total / 1073741824.0, why);
    return mapped;
}

uintptr_t dm_donor_run(uintptr_t lo, uintptr_t hi, int *donated) {
    *donated = 0;
    int count = atomic_load_explicit(&g_runs_n, memory_order_acquire);
    for (int i = 0; i < count; i++) {
        donor_run r = g_runs[i];
        if (lo >= r.lo && lo < r.hi) { *donated = 1; return r.hi < hi ? r.hi : hi; }
        if (lo < r.lo && r.lo < hi) hi = r.lo;
    }
    return hi;
}
void dm_donor_zero(uintptr_t lo, uintptr_t hi) {
    if (lo >= hi || !madvise((void *)lo, hi - lo, MADV_ZERO)) return;
    static _Atomic int said;
    if (!atomic_fetch_add(&said, 1)) fprintf(stderr, "[dm] [RED] RAM donor: MADV_ZERO refused on %#lx+%#lx (errno %d): the pages in memory are cleared by hand\n", (unsigned long)lo, (unsigned long)(hi - lo), errno);
    size_t page = (size_t)getpagesize(); unsigned char resident[512];
    while (lo < hi) {
        size_t n = hi - lo; if (n > sizeof resident * page) n = sizeof resident * page;
        if (mincore((void *)lo, n, (char *)resident)) memset((void *)lo, 0, n);
        else for (size_t p = 0, count = (n + page - 1) / page; p < count; p++) if (resident[p] & 0x21) {   // resident or paged out
            size_t bytes = n - p * page; if (bytes > page) bytes = page; memset((void *)(lo + p * page), 0, bytes);
        }
        lo += n;
    }
}
int dm_ram_donor_objects(uint32_t *objects, int capacity) {
    int n = 0, count = atomic_load_explicit(&g_runs_n, memory_order_acquire);
    for (int i = 0; i < count && n < capacity; i++) if (g_runs[i].object) objects[n++] = g_runs[i].object;
    return n;
}
