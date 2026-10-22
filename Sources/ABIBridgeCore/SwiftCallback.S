// Incoming register storage matches CallFrame in SwiftInvocation.cpp. The
// trampoline only consumes caller-scratch registers, preserving Swift self,
// indirect results, argument registers and the incoming stack.
#include "SupportedArchitectures.h"
#include <mach/machine/vm_param.h>
.text
.p2align PAGE_MAX_SHIFT
.globl _ABISwiftCallbackCodePage
.private_extern _ABISwiftCallbackCodePage
_ABISwiftCallbackCodePage:
.rept PAGE_MAX_SIZE / 32
    bti c
    // Native slot loads need not be acquire loads. Order configuration reads
    // after the caller's load of the published function pointer.
    dmb ishld
    adr x16, -PAGE_MAX_SIZE-8
    ldr x17, [x16]
    ldp x16, x9, [x16, #8]
#if __has_feature(ptrauth_calls)
    braa x16, x9
#else
    br x16
#endif
    nop
    nop
.endr

.globl _ABISwiftCallbackAssembly
.private_extern _ABISwiftCallbackAssembly
.p2align 4
_ABISwiftCallbackAssembly:
.cfi_startproc
    bti c
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    sub sp, sp, #272
    stp x29, x30, [sp, #240]
    add x29, sp, #240
    .cfi_def_cfa w29, 32
    .cfi_offset w29, -32
    .cfi_offset w30, -24
    stp x0, x1, [sp]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp d0, d1, [sp, #64]
    stp d2, d3, [sp, #80]
    stp d4, d5, [sp, #96]
    stp d6, d7, [sp, #112]
    str x8, [sp, #192]
    str x20, [sp, #200]
    add x9, sp, #272
    str x9, [sp, #208]
    str xzr, [sp, #216]
    str x21, [sp, #224]
    mov x0, x17
    mov x1, sp
    bl _ABIDispatchSwiftCallback
    ldp x0, x1, [sp, #128]
    ldp x2, x3, [sp, #144]
    ldp d0, d1, [sp, #160]
    ldp d2, d3, [sp, #176]
    ldr x21, [sp, #224]
    ldp x29, x30, [sp, #240]
    add sp, sp, #272
#if __has_feature(ptrauth_calls)
    retab
#else
    ret
#endif
.cfi_endproc
