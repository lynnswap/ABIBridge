// A nonthrowing Swift entry must preserve a live caller error register.
#if defined(__aarch64__)
.text
.globl _ABIProbeSwiftErrorRegister
.p2align 2
_ABIProbeSwiftErrorRegister:
#if __has_feature(ptrauth_calls)
    pacibsp
#endif
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    str x21, [sp, #32]
    mov x19, x0
    mov x20, x1
    mov x21, #0x1234
    mov x0, #35
#if __has_feature(ptrauth_calls)
    blraaz x19
#else
    blr x19
#endif
    cmp x0, #42
    cset w0, eq
    mov x9, #0x1234
    cmp x21, x9
    cset w9, eq
    and w0, w0, w9
    ldr x21, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
#if __has_feature(ptrauth_calls)
    retab
#else
    ret
#endif
#endif
