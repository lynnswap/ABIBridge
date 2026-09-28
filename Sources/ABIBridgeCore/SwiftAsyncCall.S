// The Swift declaration supplies a compiler-managed caller-isolated async frame.
// Its descriptor reserves the header, operation, callee, and saved executor.
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
#if defined(__aarch64__)
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
Lasync_probe_arm:
    cmp x11, #4096
    b.lo Lasync_stack_arm
    sub sp, sp, #4096
    str xzr, [sp]
    sub x11, x11, #4096
    b Lasync_probe_arm
Lasync_stack_arm:
    sub sp, sp, x11
    ldr x11, [x9, #208]
    mov x12, sp
    cbz x10, Lasync_args_arm
Lasync_copy_arm:
    ldr x13, [x11], #8
    str x13, [x12], #8
    subs x10, x10, #8
    b.ne Lasync_copy_arm
Lasync_args_arm:
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
#elif defined(__x86_64__)
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    movq %rsi, %rcx
    movq %rdi, %r8
    movq %rdx, %rdi
    movq %r14, %rsi
    movq %r8, %rdx
    callq _ABIPrepareSwiftAsyncEntry
    movq %rax, %r10
    popq %rbp
    movq (%rsp), %rax
    movq 216(%r10), %rcx
    movq %rcx, %r11
Lasync_probe_x86:
    cmpq $4096, %r11
    jb Lasync_stack_x86
    subq $4096, %rsp
    movb $0, (%rsp)
    subq $4096, %r11
    jmp Lasync_probe_x86
Lasync_stack_x86:
    subq %r11, %rsp
    movq %rax, (%rsp)
    leaq 8(%rsp), %rdi
    movq 208(%r10), %rsi
    rep movsb
    movq 64(%r10), %xmm0
    movq 72(%r10), %xmm1
    movq 80(%r10), %xmm2
    movq 88(%r10), %xmm3
    movq 96(%r10), %xmm4
    movq 104(%r10), %xmm5
    movq 112(%r10), %xmm6
    movq 120(%r10), %xmm7
    movq 240(%r10), %r14
    movq 200(%r10), %r13
    movq 232(%r10), %r11
    movq 0(%r10), %rdi
    movq 8(%r10), %rsi
    movq 16(%r10), %rdx
    movq 24(%r10), %rcx
    movq 32(%r10), %r8
    movq 40(%r10), %r9
    jmpq *%r11
#else
#error Unsupported Swift async architecture
#endif
.cfi_endproc

.globl _ABISwiftAsyncResume
.private_extern _ABISwiftAsyncResume
.p2align 2
_ABISwiftAsyncResume:
.cfi_startproc
#if defined(__aarch64__)
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
#elif defined(__x86_64__)
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    subq $240, %rsp
    movq %rdi, 128(%rsp)
    movq %rsi, 136(%rsp)
    movq %rdx, 144(%rsp)
    movq %rcx, 152(%rsp)
    movq %xmm0, 160(%rsp)
    movq %xmm1, 168(%rsp)
    movq %xmm2, 176(%rsp)
    movq %xmm3, 184(%rsp)
    movq %r13, 224(%rsp)
    movq %r14, %rdi
    movq %rsp, %rsi
    callq _ABICompleteSwiftAsync
    movq %rax, %r10
    movq 240(%r10), %r14
    movq 0(%r10), %rdi
    movq 8(%r10), %rsi
    movq 16(%r10), %rdx
    leave
    jmp _swift_task_switch
#endif
.cfi_endproc
