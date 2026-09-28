.text
.globl _ABISwiftAsyncCallbackAssembly
.private_extern _ABISwiftAsyncCallbackAssembly
.p2align 4
_ABISwiftAsyncCallbackAssembly:
.cfi_startproc
#if defined(__aarch64__)
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
    ldr x2, [x9, #16]
#if __has_feature(ptrauth_calls)
    braa x16, x17
#else
    br x16
#endif
#elif defined(__x86_64__)
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    subq $256, %rsp
    movq %rdi, 0(%rsp)
    movq %rsi, 8(%rsp)
    movq %rdx, 16(%rsp)
    movq %rcx, 24(%rsp)
    movq %r8, 32(%rsp)
    movq %r9, 40(%rsp)
    movq %xmm0, 64(%rsp)
    movq %xmm1, 72(%rsp)
    movq %xmm2, 80(%rsp)
    movq %xmm3, 88(%rsp)
    movq %xmm4, 96(%rsp)
    movq %xmm5, 104(%rsp)
    movq %xmm6, 112(%rsp)
    movq %xmm7, 120(%rsp)
    movq %r13, 200(%rsp)
    leaq 16(%rbp), %rax
    movq %rax, 208(%rsp)
    movq %r11, %rdi
    movq %rsp, %rsi
    movq %r14, %rdx
    callq _ABIPrepareSwiftAsyncCallback
    movq %rax, %r10
    leave
    movq (%rsp), %rax
    movq 216(%r10), %rcx
    andq $-16, %rcx
    addq %rcx, %rsp
    movq %rax, (%rsp)
    movq 232(%r10), %r11
    movq 240(%r10), %r14
    movq 200(%r10), %r13
    movq 0(%r10), %rdi
    movq 8(%r10), %rsi
    movq 16(%r10), %rdx
    jmpq *%r11
#else
#error Unsupported Swift async callback architecture
#endif
.cfi_endproc

.globl _ABISwiftAsyncCallbackBodyResume
.private_extern _ABISwiftAsyncCallbackBodyResume
.p2align 4
_ABISwiftAsyncCallbackBodyResume:
.cfi_startproc
#if defined(__aarch64__)
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
#elif defined(__x86_64__)
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    movq %r14, %rdi
    callq _ABICompleteSwiftAsyncCallback
    movq %rax, %r10
    movq 240(%r10), %r14
    movq 0(%r10), %rdi
    movq 8(%r10), %rsi
    movq 16(%r10), %rdx
    popq %rbp
    jmp _swift_task_switch
#endif
.cfi_endproc

.globl _ABISwiftAsyncCallbackFinish
.private_extern _ABISwiftAsyncCallbackFinish
.p2align 4
_ABISwiftAsyncCallbackFinish:
.cfi_startproc
#if defined(__aarch64__)
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
#elif defined(__x86_64__)
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    subq $256, %rsp
    movq %r14, %rdi
    movq %rsp, %rsi
    callq _ABIFinishSwiftAsyncCallback
    movq 232(%rsp), %r11
    movq 240(%rsp), %r14
    movq 224(%rsp), %r13
    movq 128(%rsp), %rdi
    movq 136(%rsp), %rsi
    movq 144(%rsp), %rdx
    movq 152(%rsp), %rcx
    movq 160(%rsp), %xmm0
    movq 168(%rsp), %xmm1
    movq 176(%rsp), %xmm2
    movq 184(%rsp), %xmm3
    leave
    jmpq *%r11
#endif
.cfi_endproc
