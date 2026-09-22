#import <ABIBridgeObjCXX/ABIBridgeObjCXX.h>
#import <objc/message.h>
#include <ABIBridgeCore.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <string>

NSErrorDomain const ABIObjCInvocationErrorDomain = @"ABIBridge.ObjCInvocation";

struct ABIObjCMethod {
    CFTypeRef receiver;
    SEL selector;
    IMP implementation;
    bool returnsRetained;
    bool consumesReceiver;
    std::unique_ptr<ABIImageLease, decltype(&ABIReleaseImage)> image{nullptr, ABIReleaseImage};

    ABIObjCMethod(id object, SEL selector, IMP implementation, bool retained, bool consumed)
        : receiver(CFBridgingRetain(object)), selector(selector), implementation(implementation),
          returnsRetained(retained), consumesReceiver(consumed) {}
    ~ABIObjCMethod() { CFRelease(receiver); }
};

namespace {
void fail(NSError **error, int code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:ABIObjCInvocationErrorDomain code:code
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
}

const char* unqualified(const char* type) {
    while (*type && std::strchr("rnNoORV", *type)) ++type;
    return type;
}

bool compatible(const char* expected, const char* actual) {
    expected = unqualified(expected);
    actual = unqualified(actual);
    // Runtime encodings may annotate an object with a quoted class/protocol.
    // Blocks keep their distinct @? encoding.
    if (*expected == '@' && *actual == '@') {
        return (expected[1] == '?') == (actual[1] == '?');
    }
    return std::strcmp(expected, actual) == 0;
}

bool inFamily(const char* selector, const char* family) {
    while (*selector == '_') ++selector;
    const size_t length = std::strlen(family);
    if (std::strncmp(selector, family, length) != 0) return false;
    const char next = selector[length];
    return next < 'a' || next > 'z';
}
}

ABIObjCMethod *ABICopyObjCMethod(
    id receiver, SEL selector, const char *resultType,
    const char *const *parameterTypes, size_t parameterCount,
    int32_t returnsRetained, int32_t consumesReceiver, NSError **error)
{
    if (error) *error = nil;
    if (!receiver || !selector || !resultType || (parameterCount && !parameterTypes)
        || returnsRetained < -1 || returnsRetained > 1
        || consumesReceiver < -1 || consumesReceiver > 1) {
        fail(error, ABIFailureInvalidRequest, @"A receiver, selector, and valid call contract are required.");
        return nullptr;
    }
    Class cls = object_getClass(receiver);
    // Unlike class_getInstanceMethod, this performs +initialize and dynamic
    // method resolution before returning the callable implementation.
    IMP implementation = class_getMethodImplementation(cls, selector);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || !implementation || implementation == reinterpret_cast<IMP>(_objc_msgForward)) {
        fail(error, ABIFailureUnsupportedDeclaration,
             [NSString stringWithFormat:@"No concrete implementation for %@ on %@.",
              NSStringFromSelector(selector), NSStringFromClass(cls)]);
        return nullptr;
    }
    if (method_getNumberOfArguments(method) != parameterCount + 2) {
        fail(error, ABIFailureSignatureMismatch, @"The selector's parameter count does not match the signature.");
        return nullptr;
    }
    std::unique_ptr<char, decltype(&std::free)> returnEncoding(method_copyReturnType(method), std::free);
    if (!returnEncoding || !compatible(resultType, returnEncoding.get())) {
        fail(error, ABIFailureSignatureMismatch, @"The selector's return encoding does not match the signature.");
        return nullptr;
    }
    for (size_t index = 0; index < parameterCount; ++index) {
        std::unique_ptr<char, decltype(&std::free)> actual(
            method_copyArgumentType(method, static_cast<unsigned int>(index + 2)), std::free);
        if (!parameterTypes[index] || !actual || !compatible(parameterTypes[index], actual.get())) {
            fail(error, ABIFailureSignatureMismatch,
                 [NSString stringWithFormat:@"Parameter %zu has an incompatible type encoding.", index]);
            return nullptr;
        }
    }

    const char* result = unqualified(resultType);
    const bool retainableResult = *result == '@' || *result == '#';
    // Blocks are retainable, but Clang does not apply Objective-C method-family
    // ownership to block return types. Explicit ownership overrides still apply.
    const bool objectResult = retainableResult && !(*result == '@' && result[1] == '?');
    const char* name = sel_getName(selector);
    const bool initializer = objectResult && !class_isMetaClass(cls) && inFamily(name, "init");
    const bool retainedFamily = objectResult && (initializer || inFamily(name, "alloc")
        || inFamily(name, "new") || inFamily(name, "copy") || inFamily(name, "mutableCopy"));
    if (returnsRetained == 1 && !retainableResult) {
        fail(error, ABIFailureInvalidRequest, @"Retained results require an Objective-C object type.");
        return nullptr;
    }
    auto binding = std::make_unique<ABIObjCMethod>(
        receiver, selector, implementation,
        returnsRetained == -1 ? retainedFamily : returnsRetained == 1,
        consumesReceiver == -1 ? initializer : consumesReceiver == 1);

    void* address = reinterpret_cast<void*>(implementation);
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    Dl_info info{};
    if (dladdr(address, &info) && info.dli_fbase) {
        std::unique_ptr<ABIImageList, decltype(&ABIFreeImageList)> images(ABICopyLoadedImages(), ABIFreeImageList);
        if (!images) {
            fail(error, ABIFailureImageUnavailable, @"The loaded image catalog is unavailable.");
            return nullptr;
        }
        for (size_t index = 0; index < ABIImageListCount(images.get()); ++index) {
            auto image = ABIImageListGet(images.get(), index);
            if (image.header != reinterpret_cast<uintptr_t>(info.dli_fbase)) continue;
            binding->image.reset(ABIRetainLoadedImage(image.generation));
            break;
        }
        if (!binding->image) {
            fail(error, ABIFailureImageChanged, @"The method's implementation image could not be retained.");
            return nullptr;
        }
    }
    return binding.release();
}

void ABIReleaseObjCMethod(ABIObjCMethod *method) { delete method; }
id ABIObjCMethodReceiver(const ABIObjCMethod *method) { return (__bridge id)method->receiver; }
SEL ABIObjCMethodSelector(const ABIObjCMethod *method) { return method->selector; }
IMP ABIObjCMethodImplementation(const ABIObjCMethod *method) { return method->implementation; }
BOOL ABIObjCMethodReturnsRetained(const ABIObjCMethod *method) { return method->returnsRetained; }
BOOL ABIObjCMethodConsumesReceiver(const ABIObjCMethod *method) { return method->consumesReceiver; }
