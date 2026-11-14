// The production donor policy and shared-VM lifecycle, without an iOS extension.
#include "../ram_donor.c"
#include "../ram_donor_proto.h"
#include <assert.h>
extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t, int, vm_map_t, mach_vm_address_t, boolean_t, vm_prot_t *, vm_prot_t *, vm_inherit_t);
static int starts, maps, failure = -1;
static uint64_t allowance;
static int start(void *c, char *why, size_t cap) { (void)c; (void)why; (void)cap; return starts++; }
static uint64_t available(void *c, int d) { (void)c; (void)d; return allowance; }
static int map(void *c, int d, uintptr_t address, size_t n, char *why, size_t cap) {
    (void)c; (void)d;
    if (maps++ == failure) { snprintf(why, cap, "injected map failure"); return -1; }
    assert(n && n <= DM_DONOR_CHUNK);
    mach_vm_address_t source = 0, target = address; vm_prot_t cur, max;
    assert(mach_vm_allocate(mach_task_self(), &source, n, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE) == KERN_SUCCESS);
    assert(mach_vm_remap(mach_task_self(), &target, n, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), source, false, &cur, &max, VM_INHERIT_SHARE) == KERN_SUCCESS);
    assert(target == address && (cur & 3) == 3);
    assert(mach_vm_deallocate(mach_task_self(), source, n) == KERN_SUCCESS);
    return 0;
}
int main(void) {
    const size_t bytes = 4 * DM_DONOR_CHUNK, page = (size_t)getpagesize();
    uint8_t *base = mmap(NULL, bytes, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0); assert(base != MAP_FAILED);
    dm_donor_range ranges[] = {{(uintptr_t)base, 2 * DM_DONOR_CHUNK, "heap"}, {(uintptr_t)base + 2 * DM_DONOR_CHUNK, DM_DONOR_CHUNK, "stack"}, {(uintptr_t)base + 3 * DM_DONOR_CHUNK, DM_DONOR_CHUNK, "alias"}};
    dm_donor_ops ops = {start, available, map, NULL, NULL};
    unsetenv("DM_RAM_DONOR"); allowance = 2 * DM_DONOR_CHUNK;
    assert(dm_donor_back(ranges, 3, &ops, 4) == bytes && starts == 4 && maps == 4);
    int donated; assert(dm_donor_run((uintptr_t)base - page, (uintptr_t)base + bytes, &donated) == (uintptr_t)base && !donated);
    assert(dm_donor_run((uintptr_t)base, (uintptr_t)base + bytes, &donated) == (uintptr_t)base + DM_DONOR_CHUNK && donated);
    uint32_t objects[4]; assert(dm_ram_donor_objects(objects, 4) == 4);
    assert(mprotect(base, 2 * page, PROT_READ | PROT_WRITE) == 0); memset(base, 0x6a, 2 * page);
    uint32_t object = object_at((uintptr_t)base); dm_donor_zero((uintptr_t)base, (uintptr_t)base + 2 * page);
    assert(object_at((uintptr_t)base) == object); for (size_t i = 0; i < 2 * page; i++) assert(!base[i]);
    assert(mprotect(base, 2 * page, PROT_NONE) == 0); assert(mprotect(base, 2 * page, PROT_READ | PROT_WRITE) == 0);
    assert(object_at((uintptr_t)base) == object); for (size_t i = 0; i < 2 * page; i++) assert(!base[i]);
    atomic_store(&g_runs_n, 0); starts = maps = 0; failure = 1; allowance = 3 * DM_DONOR_CHUNK;
    assert(dm_donor_back(ranges, 3, &ops, 4) == DM_DONOR_CHUNK && starts == 1 && maps == 2 && atomic_load(&g_runs_n) == 1);
    atomic_store(&g_runs_n, 0); starts = maps = 0; failure = -1; allowance = DM_DONOR_CHUNK;
    assert(!dm_donor_back(ranges, 3, &ops, 4) && starts == 1 && !maps);
    setenv("DM_RAM_DONOR", "0", 1); starts = maps = 0; assert(!dm_donor_back(ranges, 3, &ops, 4) && !starts && !maps);
    unsetenv("DM_RAM_DONOR"); assert(munmap(base, bytes) == 0);
    puts("RAM donor: chunk/headroom policy, partial failure, opt-out, run boundaries and shared zero/reopen passed");
    return 0;
}
