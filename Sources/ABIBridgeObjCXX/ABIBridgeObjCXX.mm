#import <ABIBridge/ObjectiveCInvocation.h>
#import <ABIBridgeObjCXX/Invocation.h>
#import <CoreGraphics/CGGeometry.h>
#include <optional>
#import <objc/message.h>
#include <ABIBridgeCore.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

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
bool isForwardingImplementation(IMP implementation) {
    if (implementation == reinterpret_cast<IMP>(_objc_msgForward)) return true;
#if defined(__x86_64__)
    if (implementation == reinterpret_cast<IMP>(_objc_msgForward_stret)) return true;
#endif
    return false;
}

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

struct Ownership { bool retained; bool consumed; };

std::optional<Ownership> ownershipFor(
    const char *resultType, Class cls, SEL selector,
    int32_t returnsRetained, int32_t consumesReceiver, NSError **error)
{
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
        return std::nullopt;
    }

    return Ownership{
        returnsRetained == -1 ? retainedFamily : returnsRetained == 1,
        consumesReceiver == -1 ? initializer : consumesReceiver == 1
    };
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
    if (!method) {
        // A custom method signature can describe a forwarded-only selector.
        // NSProxy's abstract implementation must not be invoked for an unknown
        // selector; concrete methods above require no NSObject reflection.
        SEL signatureSelector = @selector(methodSignatureForSelector:);
        Method signatureMethod = class_getInstanceMethod(cls, signatureSelector);
        Method proxyDefault = class_getInstanceMethod(objc_getClass("NSProxy"), signatureSelector);
        NSMethodSignature *signature = nil;
        if (signatureMethod && (!proxyDefault || method_getImplementation(signatureMethod) != method_getImplementation(proxyDefault))) {
            using SignatureGetter = NSMethodSignature *(*)(id, SEL, SEL);
            signature = reinterpret_cast<SignatureGetter>(method_getImplementation(signatureMethod))(
                receiver, signatureSelector, selector);
        }
        fail(error, signature ? ABIFailureUnsupportedDeclaration : ABIFailureDeclarationNotFound,
             [NSString stringWithFormat:@"No concrete implementation for %@ on %@.",
              NSStringFromSelector(selector), NSStringFromClass(cls)]);
        return nullptr;
    }
    if (!implementation || isForwardingImplementation(implementation)) {
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

    const auto ownership = ownershipFor(resultType, cls, selector, returnsRetained, consumesReceiver, error);
    if (!ownership) return nullptr;
    auto binding = std::make_unique<ABIObjCMethod>(
        receiver, selector, implementation,
        ownership->retained, ownership->consumed);

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

struct ABIObjCInvocation {
    CFTypeRef receiver;
    CFTypeRef signature;
    SEL selector;
    Ownership ownership;
    Class receiverType = Nil;
    bool classMethod = false;
    IMP implementation = nullptr;
    using ImageLease = std::unique_ptr<ABIImageLease, decltype(&ABIReleaseImage)>;
    std::vector<ImageLease> images;

    ABIObjCInvocation(id receiver, NSMethodSignature *signature, SEL selector, Ownership ownership)
        : receiver(CFBridgingRetain(receiver)), signature(CFBridgingRetain(signature)),
          selector(selector), ownership(ownership) {}
    ~ABIObjCInvocation() { if (receiver) CFRelease(receiver); CFRelease(signature); }
    NSMethodSignature *methodSignature() const { return (__bridge NSMethodSignature *)signature; }
};

ABIObjCInvocation *ABICopyObjCInvocation(
    id receiver, SEL selector, int32_t returnsRetained, int32_t consumesReceiver, NSError **error)
{
    if (error) *error = nil;
    if (!receiver || !selector || returnsRetained < -1 || returnsRetained > 1
        || consumesReceiver < -1 || consumesReceiver > 1) {
        fail(error, ABIFailureInvalidRequest, @"A receiver, selector, and valid ownership options are required.");
        return nullptr;
    }
    Class cls = object_getClass(receiver);
    class_getMethodImplementation(cls, selector);
    Method method = class_getInstanceMethod(cls, selector);
    NSMethodSignature *signature = nil;
    @try {
        if (method) {
            signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
        } else if ([receiver respondsToSelector:@selector(methodSignatureForSelector:)]) {
            signature = [receiver methodSignatureForSelector:selector];
        }
    } @catch (NSException *exception) {
        // Foundation rejects some valid runtime encodings, including unions.
        // Only signature acquisition is translated; invocation exceptions retain
        // their native behavior.
        if (![exception.name isEqualToString:NSInvalidArgumentException]) @throw;
        fail(error, ABIFailureUnsupportedDeclaration,
             [NSString stringWithFormat:@"Unsupported signature for %@: %@",
              NSStringFromSelector(selector), exception.reason]);
        return nullptr;
    }
    if (!signature || signature.numberOfArguments < 2) {
        fail(error, ABIFailureDeclarationNotFound,
             [NSString stringWithFormat:@"No method signature for %@ on %@.",
              NSStringFromSelector(selector), NSStringFromClass(cls)]);
        return nullptr;
    }
    const auto ownership = ownershipFor(signature.methodReturnType, cls, selector,
                                        returnsRetained, consumesReceiver, error);
    if (!ownership) return nullptr;
    return new ABIObjCInvocation(receiver, signature, selector, *ownership);
}

namespace {
bool retainImplementationImage(
    ABIObjCInvocation& plan, const void* address, const char* path, NSError** error) {
    Dl_info info{};
    const bool hasAddress = address && dladdr(address, &info) && info.dli_fbase;
    if (!hasAddress && !path) return true;
    std::unique_ptr<ABIImageList, decltype(&ABIFreeImageList)> images(ABICopyLoadedImages(), ABIFreeImageList);
    if (!images) { fail(error, ABIFailureImageUnavailable, @"The loaded image catalog is unavailable."); return false; }
    for (size_t index = 0; index < ABIImageListCount(images.get()); ++index) {
        const auto image = ABIImageListGet(images.get(), index);
        const bool matches = hasAddress ? image.header == reinterpret_cast<uintptr_t>(info.dli_fbase)
                                        : std::strcmp(image.path, path) == 0;
        if (!matches) continue;
        if (auto* lease = ABIRetainLoadedImage(image.generation)) {
            plan.images.emplace_back(lease, ABIReleaseImage);
            return true;
        }
        break;
    }
    fail(error, ABIFailureImageChanged, @"The implementation or class image could not be retained.");
    return false;
}
}

ABIObjCInvocation *ABICopyObjCImplementation(
    Class type, SEL selector, BOOL classMethod, int32_t returnsRetained,
    int32_t consumesReceiver, NSError **error) {
    if (error) *error = nil;
    if (!type || class_isMetaClass(type) || !selector ||
        returnsRetained < -1 || returnsRetained > 1 || consumesReceiver < -1 || consumesReceiver > 1) {
        fail(error, ABIFailureInvalidRequest, @"A class, selector, and valid ownership options are required.");
        return nullptr;
    }
    Class lookup = classMethod ? object_getClass(type) : type;
    class_getMethodImplementation(lookup, selector);
    Method method = class_getInstanceMethod(lookup, selector);
    IMP implementation = method ? method_getImplementation(method) : nullptr;
    if (!method || !implementation || isForwardingImplementation(implementation)) {
        fail(error, ABIFailureDeclarationNotFound, @"A captured call requires a concrete method implementation.");
        return nullptr;
    }
    NSMethodSignature *signature = nil;
    @try {
        signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    } @catch (NSException *exception) {
        if (![exception.name isEqualToString:NSInvalidArgumentException]) @throw;
        fail(error, ABIFailureUnsupportedDeclaration, exception.reason);
        return nullptr;
    }
    if (!signature || signature.numberOfArguments < 2) {
        fail(error, ABIFailureSignatureMismatch, @"The method has no usable signature.");
        return nullptr;
    }
    const auto ownership = ownershipFor(signature.methodReturnType, lookup, selector,
                                        returnsRetained, consumesReceiver, error);
    if (!ownership) return nullptr;
    auto plan = std::make_unique<ABIObjCInvocation>(nil, signature, selector, *ownership);
    plan->receiverType = type;
    plan->classMethod = classMethod;
    plan->implementation = implementation;
    const void* address = reinterpret_cast<const void*>(implementation);
#if __has_feature(ptrauth_calls)
    address = ptrauth_strip(address, ptrauth_key_function_pointer);
#endif
    if (!retainImplementationImage(*plan, address, nullptr, error) ||
        !retainImplementationImage(*plan, nullptr, class_getImageName(type), error)) return nullptr;
    return plan.release();
}

void ABIReleaseObjCInvocation(ABIObjCInvocation *invocation) { delete invocation; }
size_t ABIObjCInvocationParameterCount(const ABIObjCInvocation *invocation) {
    return invocation->methodSignature().numberOfArguments - 2;
}
const char *ABIObjCInvocationParameterType(const ABIObjCInvocation *invocation, size_t index) {
    return [invocation->methodSignature() getArgumentTypeAtIndex:index + 2];
}
const char *ABIObjCInvocationResultType(const ABIObjCInvocation *invocation) {
    return invocation->methodSignature().methodReturnType;
}
size_t ABIObjCInvocationParameterSize(const ABIObjCInvocation *invocation, size_t index) {
    NSUInteger size = 0;
    NSGetSizeAndAlignment(ABIObjCInvocationParameterType(invocation, index), &size, nullptr);
    return size;
}
size_t ABIObjCInvocationResultSize(const ABIObjCInvocation *invocation) {
    return invocation->methodSignature().methodReturnLength;
}
BOOL ABIInvokeObjCInvocation(
    ABIObjCInvocation *plan, void *result, const void *const *arguments, NSError **error)
{
    if (error) *error = nil;
    const size_t count = ABIObjCInvocationParameterCount(plan);
    const size_t resultSize = ABIObjCInvocationResultSize(plan);
    if ((resultSize && !result) || (count && !arguments)) {
        fail(error, ABIFailureInvalidRequest, @"Argument and result storage are required.");
        return NO;
    }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:plan->methodSignature()];
    invocation.selector = plan->selector;
    for (size_t index = 0; index < count; ++index) {
        if (!arguments[index]) {
            fail(error, ABIFailureInvalidRequest, @"Each argument requires value storage.");
            return NO;
        }
        [invocation setArgument:const_cast<void *>(arguments[index]) atIndex:index + 2];
    }
    if (plan->ownership.consumed) CFRetain(plan->receiver);
    [invocation invokeWithTarget:(__bridge id)plan->receiver];
    if (resultSize) {
        const char *type = unqualified(plan->methodSignature().methodReturnType);
        if (*type == '@' || *type == '#') {
            __unsafe_unretained id object = nil;
            [invocation getReturnValue:&object];
            CFTypeRef owned = object
                ? (plan->ownership.retained ? (__bridge CFTypeRef)object : CFRetain((__bridge CFTypeRef)object))
                : nullptr;
            std::memcpy(result, &owned, sizeof(owned));
        } else {
            [invocation getReturnValue:result];
        }
    }
    return YES;
}
BOOL ABIInvokeObjCImplementation(
    ABIObjCInvocation *plan, ABICallInterface *interface, id receiver,
    void *result, const void *const *arguments, NSError **error) {
    if (error) *error = nil;
    if (!plan->implementation || !receiver || !interface) {
        fail(error, ABIFailureInvalidRequest, @"A captured implementation and live receiver are required.");
        return NO;
    }
    Class actual = object_getClass(receiver);
    const bool receiverIsClass = class_isMetaClass(actual);
    if (plan->classMethod == receiverIsClass) {
        if (receiverIsClass) actual = (Class)receiver;
        for (; actual && actual != plan->receiverType; actual = class_getSuperclass(actual)) {}
    } else {
        actual = Nil;
    }
    if (!actual) {
        fail(error, ABIFailureSignatureMismatch, @"The receiver is incompatible with the captured class.");
        return NO;
    }
    const size_t count = ABIObjCInvocationParameterCount(plan);
    if ((ABIObjCInvocationResultSize(plan) && !result) || (count && !arguments)) {
        fail(error, ABIFailureInvalidRequest, @"Argument and result storage are required.");
        return NO;
    }
    id target = receiver;
    SEL selector = plan->selector;
    std::vector<void*> values{&target, &selector};
    for (size_t index = 0; index < count; ++index) {
        if (!arguments[index]) {
            fail(error, ABIFailureInvalidRequest, @"Each argument requires storage.");
            return NO;
        }
        values.push_back(const_cast<void*>(arguments[index]));
    }
    if (plan->ownership.consumed) CFRetain((__bridge CFTypeRef)receiver);
    ABIResolutionFailure *failure = nullptr;
    // Keep the IMP as a function pointer; the compiler preserves/resigns its
    // authentication when converting it to the generic C function-pointer ABI.
    const auto function = reinterpret_cast<ABIUnmanagedFunction>(plan->implementation);
    const bool success = ABIUnsafeInvokeCCallInterface(interface, function, result, values.data(), &failure);
    if (!success) {
        if (plan->ownership.consumed) CFRelease((__bridge CFTypeRef)receiver);
        fail(error, failure ? ABIResolutionFailureCode(failure) : ABIFailureInvalidRequest,
             failure ? @(ABIResolutionFailureMessage(failure)) : @"Captured invocation failed.");
        if (failure) ABIReleaseResolutionFailure(failure);
        return NO;
    }
    const char *encoding = unqualified(plan->methodSignature().methodReturnType);
    if (*encoding == '@' || *encoding == '#') {
        CFTypeRef object = nullptr;
        std::memcpy(&object, result, sizeof(object));
        if (object && !plan->ownership.retained) CFRetain(object);
    }
    return YES;
}

void *ABICopyObjCBlock(const void *pointer) {
    id object = (__bridge id)pointer;
    Class blockClass = objc_lookUpClass("NSBlock");
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        if (cls == blockClass) return (void *)CFBridgingRetain([object copy]);
    }
    return nullptr;
}

const char *ABIObjCEncodingPoint() { return @encode(CGPoint); }
const char *ABIObjCEncodingSize() { return @encode(CGSize); }
const char *ABIObjCEncodingRect() { return @encode(CGRect); }
const char *ABIObjCEncodingRange() { return @encode(NSRange); }
