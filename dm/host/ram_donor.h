// RAM donor backing for the guest heap, stack and alias ranges.
// XPC/extension implementation derives from the MIT nxnative-mkw donor (see ../ios/Donor/README.md).
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct { uintptr_t address; size_t size; const char *name; } dm_donor_range;
typedef struct {
    int (*start)(void *, char *, size_t);
    uint64_t (*available)(void *, int);
    int (*map)(void *, int, uintptr_t, size_t, char *, size_t);
    void (*end)(void *);
    void *context;
} dm_donor_ops;
typedef struct {
    void (*back)(const dm_donor_range *, int);
    uintptr_t (*run)(uintptr_t, uintptr_t, int *);
    void (*zero)(uintptr_t, uintptr_t);
} dm_donor_hooks;

int dm_donor_enabled(void);
size_t dm_donor_back(const dm_donor_range *, int, const dm_donor_ops *, int);
uintptr_t dm_donor_run(uintptr_t, uintptr_t, int *);
void dm_donor_zero(uintptr_t, uintptr_t);
int dm_ram_donor_objects(uint32_t *, int);
void svc_donor_attach(const dm_donor_hooks *);
void dm_ram_donor_prestart(void);
