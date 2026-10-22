#if defined(__aarch64__)
.text
.globl _ABISwiftAsyncCallbackAssembly
.private_extern _ABISwiftAsyncCallbackAssembly
.p2align 4
_ABISwiftAsyncCallbackAssembly:
.cfi_startproc
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    sub sp, sp, #272
    stp x29, x30, [sp, #256]
    add x29, sp, #256
    .cfi_def_cfa w29, 16
    .cfi_offset w29, -16
    .cfi_offset w30, -8
    stp x0, x1, [sp]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp d0, d1, [sp, #64]
    stp d2, d3, [sp, #80]
    stp d4, d5, [sp, #96]
    stp d6, d7, [sp, #112]
    str x20, [sp, #200]
    add x9, sp, #272
    str x9, [sp, #208]
    mov x0, x17
    mov x1, sp
    mov x2, x22
    bl _ABIPrepareSwiftAsyncCallback
    mov x9, x0
    ldr x10, [x9, #216]
    ldp x29, x30, [sp, #256]
    add sp, sp, #272
#if __has_feature(ptrauth_calls)
    autibsp
#endif
    // Discard this entry's incoming swifttailcc stack arguments before
    // tail-calling the fixed compiler body (whose arguments fit registers).
    add sp, sp, x10
    ldr x16, [x9, #232]
    ldr x17, [x9, #248]
    ldr x22, [x9, #240]
    ldr x20, [x9, #200]
    ldp x0, x1, [x9]
    ldp x2, x3, [x9, #16]
    ldp x4, x5, [x9, #32]
    ldp x6, x7, [x9, #48]
    ldp d0, d1, [x9, #64]
    ldp d2, d3, [x9, #80]
    ldp d4, d5, [x9, #96]
    ldp d6, d7, [x9, #112]
#if __has_feature(ptrauth_calls)
    braa x16, x17
#else
    br x16
#endif
.cfi_endproc

.globl _ABISwiftAsyncCallbackBodyResume
.private_extern _ABISwiftAsyncCallbackBodyResume
.p2align 4
_ABISwiftAsyncCallbackBodyResume:
.cfi_startproc
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    .cfi_def_cfa w29, 16
    .cfi_offset w29, -16
    .cfi_offset w30, -8
    mov x0, x22
    bl _ABICompleteSwiftAsyncCallback
    mov x9, x0
    ldr x22, [x9, #240]
    ldp x0, x1, [x9]
    ldr x2, [x9, #16]
    ldp x29, x30, [sp], #16
#if __has_feature(ptrauth_calls)
    autibsp
#endif
    b _swift_task_switch
.cfi_endproc

.globl _ABISwiftAsyncCallbackFinish
.private_extern _ABISwiftAsyncCallbackFinish
.p2align 4
_ABISwiftAsyncCallbackFinish:
.cfi_startproc
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    sub sp, sp, #272
    stp x29, x30, [sp, #256]
    add x29, sp, #256
    .cfi_def_cfa w29, 16
    .cfi_offset w29, -16
    .cfi_offset w30, -8
    mov x0, x22
    mov x1, sp
    bl _ABIFinishSwiftAsyncCallback
    ldr x16, [sp, #232]
    ldr x17, [sp, #248]
    ldr x22, [sp, #240]
    ldr x20, [sp, #224]
    ldp x0, x1, [sp, #128]
    ldp x2, x3, [sp, #144]
    ldp d0, d1, [sp, #160]
    ldp d2, d3, [sp, #176]
    ldp x29, x30, [sp, #256]
    add sp, sp, #272
#if __has_feature(ptrauth_calls)
    autibsp
    braa x16, x17
#else
    br x16
#endif
.cfi_endproc
#endif
