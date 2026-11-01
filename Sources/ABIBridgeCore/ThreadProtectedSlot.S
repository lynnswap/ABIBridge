// The kernel's TPRO controls affect the current thread. Keep the register
// transition, atomic exchange and restoration in one leaf function. The interval
// contains only register and memory operations and makes no calls.
#if defined(__arm64__) && defined(__LP64__)
.text
.p2align 2
.globl _ABIExchangeThreadProtectedSlot
.private_extern _ABIExchangeThreadProtectedSlot
_ABIExchangeThreadProtectedSlot:
    bti c
    // x0: storage, x1: expected, x2: replacement, x3: writable bits, x4: mask.
    ldr x11, [x1]
    mrs x9, S3_6_C15_C1_5
    bic x12, x9, x4
    and x13, x3, x4
    orr x12, x12, x13
    msr S3_6_C15_C1_5, x12
    isb
1:
    ldaxr x10, [x0]
    cmp x10, x11
    b.ne 2f
    stlxr w14, x2, [x0]
    cbnz w14, 1b
    mov w0, #1
    b 3f
2:
    clrex
    mov w0, #0
3:
    dmb ish
    msr S3_6_C15_C1_5, x9
    isb
    str x10, [x1]
    ret
#endif
