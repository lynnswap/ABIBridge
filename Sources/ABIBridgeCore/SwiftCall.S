// Swift's context/error registers and four-register results differ from C.
// Offsets correspond to the statically checked CallFrame in SwiftInvocation.cpp.
.text
.globl _ABIInvokeSwiftAssembly
.private_extern _ABIInvokeSwiftAssembly
.p2align 2
_ABIInvokeSwiftAssembly:
.cfi_startproc
#if defined(__aarch64__)
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
Lswift_probe_arm:
    cmp x10, #4096
    b.lo Lswift_stack_arm
    sub sp, sp, #4096
    str xzr, [sp]
    sub x10, x10, #4096
    b Lswift_probe_arm
Lswift_stack_arm:
    sub sp, sp, x10
    ldr x10, [x19, #208]
    mov x11, sp
    cbz x9, Lswift_args_arm
Lswift_copy_arm:
    ldr x12, [x10], #8
    str x12, [x11], #8
    subs x9, x9, #8
    b.ne Lswift_copy_arm
Lswift_args_arm:
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
#elif defined(__x86_64__)
    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    .cfi_offset %rbx, -24
    .cfi_offset %r12, -32
    .cfi_offset %r13, -40
    .cfi_offset %r14, -48
    movq %rdi, %rbx
    movq %rsi, %r11
    movq 216(%rbx), %rcx
    movq %rcx, %rax
Lswift_probe_x86:
    cmpq $4096, %rax
    jb Lswift_stack_x86
    subq $4096, %rsp
    movb $0, (%rsp)
    subq $4096, %rax
    jmp Lswift_probe_x86
Lswift_stack_x86:
    subq %rax, %rsp
    movq 208(%rbx), %rsi
    movq %rsp, %rdi
    rep movsb
    movq 64(%rbx), %xmm0
    movq 72(%rbx), %xmm1
    movq 80(%rbx), %xmm2
    movq 88(%rbx), %xmm3
    movq 96(%rbx), %xmm4
    movq 104(%rbx), %xmm5
    movq 112(%rbx), %xmm6
    movq 120(%rbx), %xmm7
    movq 192(%rbx), %rax
    movq 200(%rbx), %r13
    xorq %r12, %r12
    movq 0(%rbx), %rdi
    movq 8(%rbx), %rsi
    movq 16(%rbx), %rdx
    movq 24(%rbx), %rcx
    movq 32(%rbx), %r8
    movq 40(%rbx), %r9
    callq *%r11
    movq %rax, 128(%rbx)
    movq %rdx, 136(%rbx)
    movq %rcx, 144(%rbx)
    movq %r8, 152(%rbx)
    movq %xmm0, 160(%rbx)
    movq %xmm1, 168(%rbx)
    movq %xmm2, 176(%rbx)
    movq %xmm3, 184(%rbx)
    leaq -32(%rbp), %rsp
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    retq
#else
#error Unsupported Swift call architecture
#endif
.cfi_endproc
