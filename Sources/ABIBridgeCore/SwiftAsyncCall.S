// The Swift declaration supplies a compiler-managed caller-isolated async frame.
// Its descriptor reserves the header, operation, callee, and saved executor.
#if defined(__aarch64__)
.section __TEXT,__const
.globl _ABIInvokeSwiftAsyncTu
.p2align 3
_ABIInvokeSwiftAsyncTu:
    .long _ABIInvokeSwiftAsync - _ABIInvokeSwiftAsyncTu
#if __SIZEOF_POINTER__ == 8
    .long 48
#else
    .long 32
#endif

.text
.globl _ABIInvokeSwiftAsync
.p2align 2
_ABIInvokeSwiftAsync:
.cfi_startproc
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    .cfi_def_cfa w29, 16
    .cfi_offset w29, -16
    .cfi_offset w30, -8
    mov x9, x2
    mov x3, x1
    mov x2, x0
    mov x1, x22
    mov x0, x9
    bl _ABIPrepareSwiftAsyncEntry
    mov x9, x0
    ldp x29, x30, [sp], #16
#if __has_feature(ptrauth_calls)
    autibsp
#endif
    // swifttailcc's target removes its incoming stack arguments.
    ldr x10, [x9, #216]
    mov x11, x10
Lasync_probe:
    cmp x11, #4096
    b.lo Lasync_stack
    sub sp, sp, #4096
    str xzr, [sp]
    sub x11, x11, #4096
    b Lasync_probe
Lasync_stack:
    sub sp, sp, x11
    ldr x11, [x9, #208]
    mov x12, sp
    cbz x10, Lasync_args
Lasync_copy:
    ldr x13, [x11], #8
    str x13, [x12], #8
    subs x10, x10, #8
    b.ne Lasync_copy
Lasync_args:
    ldr x16, [x9, #232]
    ldr x17, [x9, #248]
    ldr x22, [x9, #240]
    ldr x20, [x9, #200]
    ldp d0, d1, [x9, #64]
    ldp d2, d3, [x9, #80]
    ldp d4, d5, [x9, #96]
    ldp d6, d7, [x9, #112]
    ldp x0, x1, [x9]
    ldp x2, x3, [x9, #16]
    ldp x4, x5, [x9, #32]
    ldp x6, x7, [x9, #48]
#if __has_feature(ptrauth_calls)
    braa x16, x17
#else
    br x16
#endif
.cfi_endproc

.globl _ABISwiftAsyncResume
.private_extern _ABISwiftAsyncResume
.p2align 2
_ABISwiftAsyncResume:
.cfi_startproc
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    sub sp, sp, #256
    stp x29, x30, [sp, #240]
    add x29, sp, #240
    .cfi_def_cfa w29, 16
    .cfi_offset w29, -16
    .cfi_offset w30, -8
    stp x0, x1, [sp, #128]
    stp x2, x3, [sp, #144]
    stp d0, d1, [sp, #160]
    stp d2, d3, [sp, #176]
    str x20, [sp, #224]
    mov x0, x22
    mov x1, sp
    bl _ABICompleteSwiftAsync
    mov x9, x0
    ldr x22, [x9, #240]
    ldp x0, x1, [x9]
    ldr x2, [x9, #16]
    ldp x29, x30, [sp, #240]
    add sp, sp, #256
#if __has_feature(ptrauth_calls)
    autibsp
#endif
    b _swift_task_switch
.cfi_endproc
#endif
