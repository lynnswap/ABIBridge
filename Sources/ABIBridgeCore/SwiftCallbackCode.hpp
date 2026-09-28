#ifndef ABIBRIDGE_SWIFT_CALLBACK_CODE_HPP
#define ABIBRIDGE_SWIFT_CALLBACK_CODE_HPP

#include <ABIBridge/Invocation.h>
#include <memory>

namespace abibridge {
/// A borrowed entry in remapped, precompiled executable code. Unpublished
/// entries can be reclaimed once no caller can use their address. Published
/// dispatchers must keep this owner alive as long as saved native pointers.
class SwiftCallbackCode {
    struct Storage;
    std::unique_ptr<Storage> storage;
public:
    SwiftCallbackCode(void *context, ABIResolutionFailure **error, bool closure = false, uint32_t asyncContextSize = 0);
    static void *closureContext(ABIUnmanagedFunction function, bool asynchronous = false);
    const void *asyncDescriptor() const;
    ~SwiftCallbackCode();
    ABIUnmanagedFunction function() const;
};
}
#endif
