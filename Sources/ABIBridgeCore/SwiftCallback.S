// Incoming register storage matches CallFrame in SwiftInvocation.cpp. The
// trampoline only consumes caller-scratch registers, preserving Swift self,
// indirect results, argument registers and the incoming stack.
#include <mach/machine/vm_param.h>
.text
.p2align PAGE_MAX_SHIFT
.globl _ABISwiftCallbackCodePage
.private_extern _ABISwiftCallbackCodePage
_ABISwiftCallbackCodePage:
.rept PAGE_MAX_SIZE / 32
#if defined(__aarch64__)
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
#elif defined(__x86_64__)
    leaq -PAGE_MAX_SIZE-7(%rip), %r11
    movq 8(%r11), %r10
    movq (%r11), %r11
    jmpq *%r10
    .fill 15, 1, 0x90
#else
#error Unsupported Swift callback architecture
#endif
.endr

.globl _ABISwiftCallbackAssembly
.private_extern _ABISwiftCallbackAssembly
.p2align 4
_ABISwiftCallbackAssembly:
.cfi_startproc
#if defined(__aarch64__)
    bti c
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    sub sp, sp, #256
    stp x29, x30, [sp, #224]
    add x29, sp, #224
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
    add x9, sp, #256
    str x9, [sp, #208]
    str xzr, [sp, #216]
    mov x0, x17
    mov x1, sp
    bl _ABIDispatchSwiftCallback
    ldp x0, x1, [sp, #128]
    ldp x2, x3, [sp, #144]
    ldp d0, d1, [sp, #160]
    ldp d2, d3, [sp, #176]
    ldp x29, x30, [sp, #224]
    add sp, sp, #256
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
    subq $224, %rsp
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
    movq %rax, 192(%rsp)
    movq %r13, 200(%rsp)
    leaq 16(%rbp), %r10
    movq %r10, 208(%rsp)
    movq $0, 216(%rsp)
    movq %r11, %rdi
    movq %rsp, %rsi
    callq _ABIDispatchSwiftCallback
    movq 128(%rsp), %rax
    movq 136(%rsp), %rdx
    movq 144(%rsp), %rcx
    movq 152(%rsp), %r8
    movq 160(%rsp), %xmm0
    movq 168(%rsp), %xmm1
    movq 176(%rsp), %xmm2
    movq 184(%rsp), %xmm3
    leave
    retq
#endif
.cfi_endproc
