#ifndef ABIBRIDGE_POINTER_AUTHENTICATION_H
#define ABIBRIDGE_POINTER_AUTHENTICATION_H

/// Pointer authentication schema keys, including explicitly unsigned storage.
enum {
    ABIAuthenticationUnsigned = -1,
    ABIAuthenticationInstructionA = 0,
    ABIAuthenticationInstructionB = 1,
    ABIAuthenticationDataA = 2,
    ABIAuthenticationDataB = 3
};

#endif
