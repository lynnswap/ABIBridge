// Swift's context/error registers and four-register results differ from C.
// Offsets correspond to the statically checked CallFrame in SwiftInvocation.cpp.
#include "SupportedArchitectures.h"
.text
.globl _ABIInvokeSwiftAssembly
.private_extern _ABIInvokeSwiftAssembly
.p2align 2
_ABIInvokeSwiftAssembly:
.cfi_startproc
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    stp x29, x30, [sp, #-64]!
    mov x29, sp
    .cfi_def_cfa w29, 64
    .cfi_offset w30, -56
    .cfi_offset w29, -64
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    .cfi_offset w19, -48
    .cfi_offset w20, -40
    .cfi_offset w21, -32
    .cfi_offset w22, -24
    mov x19, x0
    mov x16, x1
    mov x17, x2
    ldr x9, [x19, #216]
    mov x10, x9
Lswift_probe:
    cmp x10, #4096
    b.lo Lswift_stack
    sub sp, sp, #4096
    str xzr, [sp]
    sub x10, x10, #4096
    b Lswift_probe
Lswift_stack:
    sub sp, sp, x10
    ldr x10, [x19, #208]
    mov x11, sp
    cbz x9, Lswift_args
Lswift_copy:
    ldr x12, [x10], #8
    str x12, [x11], #8
    subs x9, x9, #8
    b.ne Lswift_copy
Lswift_args:
    ldp d0, d1, [x19, #64]
    ldp d2, d3, [x19, #80]
    ldp d4, d5, [x19, #96]
    ldp d6, d7, [x19, #112]
    ldr x8, [x19, #192]
    ldr x20, [x19, #200]
    mov x21, #0
    ldp x0, x1, [x19]
    ldp x2, x3, [x19, #16]
    ldp x4, x5, [x19, #32]
    ldp x6, x7, [x19, #48]
#if __has_feature(ptrauth_calls)
    blraa x16, x17
#else
    blr x16
#endif
    str x21, [x19, #224]
    stp x0, x1, [x19, #128]
    stp x2, x3, [x19, #144]
    stp d0, d1, [x19, #160]
    stp d2, d3, [x19, #176]
    mov sp, x29
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x29, x30, [sp], #64
#if __has_feature(ptrauth_calls)
    retab
#else
    ret
#endif
.cfi_endproc
