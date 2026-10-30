// Use the production entry, including its nested-stack guard.
#include "../entry.S"
.subsections_via_symbols

.macro test_gate name
    .globl _test_gate_\name
    .p2align 2
_test_gate_\name:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    mov x0, x1
    // This is the rewriter's gate block, with canaries in returned frames below it.
    stp x29, x30, [sp, #-16]!
    mov x9, #0x5a5a
    stp x9, x9, [sp, #-16]
    stp x9, x9, [sp, #-32]
    stp x9, x9, [sp, #-48]
    stp x9, x9, [sp, #-64]
    blr x19
    .globl _test_gate_\name\()_ret
_test_gate_\name\()_ret:
    mov x9, #0x5a5a
    ldp x10, x11, [sp, #-64]
    cmp x10, x9
    b.ne 9f
    cmp x11, x9
    b.ne 9f
    ldp x10, x11, [sp, #-48]
    cmp x10, x9
    b.ne 9f
    cmp x11, x9
    b.ne 9f
    ldp x10, x11, [sp, #-32]
    cmp x10, x9
    b.ne 9f
    cmp x11, x9
    b.ne 9f
    ldp x10, x11, [sp, #-16]
    cmp x10, x9
    b.ne 9f
    cmp x11, x9
    b.eq 8f
9:  mov x0, #-1
8:  ldp x29, x30, [sp], #16
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
.endm

test_gate observe
test_gate svc
