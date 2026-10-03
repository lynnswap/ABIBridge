#pragma once

// Load Core as a module before referring to its declarations. Directly
// including Invocation.h can hide its constants from Swift batch imports.
#include <ABIBridgeCore.h>
#import <ABIBridge/ObjectiveCInvocation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ABIObjCInvocation ABIObjCInvocation;

/// Internal selector invocation support for the Swift frontend. Ownership
/// overrides use -1 for selector-family inference, 0 for borrowed, and 1 for
/// retained results or consumed self. The plan retains its receiver/signature.
FOUNDATION_EXPORT ABIObjCInvocation * _Nullable ABICopyObjCInvocation(
    id receiver, SEL selector, int32_t returnsRetained, int32_t consumesReceiver,
    const size_t * _Nullable consumedParameters, size_t consumedParameterCount,
    NSError * _Nullable * _Nullable error);
/// Captures a concrete IMP and signature without retaining an instance.
/// The class and selector must remain valid during lookup. Generated classes
/// must remain registered and generated IMPs must remain callable for its lifetime.
FOUNDATION_EXPORT ABIObjCInvocation * _Nullable ABICopyObjCImplementation(
    Class type, SEL selector, BOOL classMethod, int32_t returnsRetained,
    int32_t consumesReceiver, const size_t * _Nullable consumedParameters, size_t consumedParameterCount,
    NSError * _Nullable * _Nullable error);
/// Prepares a class-declared signature without retaining an instance or IMP.
/// Each invocation follows ordinary message dispatch on a compatible receiver.
FOUNDATION_EXPORT ABIObjCInvocation * _Nullable ABICopyObjCDispatch(
    Class type, SEL selector, BOOL classMethod, int32_t returnsRetained,
    int32_t consumesReceiver, const size_t * _Nullable consumedParameters, size_t consumedParameterCount,
    NSError * _Nullable * _Nullable error);
/// Retains a receiver after validating its signature against an unbound plan.
/// The result retains the prepared plan until after releasing its receiver.
FOUNDATION_EXPORT ABIObjCInvocation * _Nullable ABICopyBoundObjCInvocation(
    ABIObjCInvocation *plan, id receiver, NSError * _Nullable * _Nullable error);
/// Returns an owned reference to the prepared plan without retaining a binding.
/// Bound handles created by this backend always have a receiver-independent parent.
FOUNDATION_EXPORT ABIObjCInvocation *ABICopyObjCInvocationPlan(ABIObjCInvocation *invocation);
FOUNDATION_EXPORT void ABIReleaseObjCInvocation(ABIObjCInvocation *invocation);
FOUNDATION_EXPORT void ABIRetainObjCInvocation(ABIObjCInvocation *invocation);
FOUNDATION_EXPORT IMP _Nullable ABIObjCInvocationImplementation(const ABIObjCInvocation *invocation);
FOUNDATION_EXPORT BOOL ABIObjCInvocationReturnsRetained(const ABIObjCInvocation *invocation);
FOUNDATION_EXPORT BOOL ABIObjCInvocationConsumesReceiver(const ABIObjCInvocation *invocation);
FOUNDATION_EXPORT BOOL ABIObjCInvocationConsumesParameter(const ABIObjCInvocation *invocation, size_t index);
FOUNDATION_EXPORT size_t ABIObjCInvocationParameterCount(const ABIObjCInvocation *invocation);
/// Encodings are borrowed for the plan's lifetime. Index excludes self/_cmd.
FOUNDATION_EXPORT const char *ABIObjCInvocationParameterType(const ABIObjCInvocation *invocation, size_t index);
FOUNDATION_EXPORT const char *ABIObjCInvocationResultType(const ABIObjCInvocation *invocation);
FOUNDATION_EXPORT size_t ABIObjCInvocationParameterSize(const ABIObjCInvocation *invocation, size_t index);
FOUNDATION_EXPORT size_t ABIObjCInvocationResultSize(const ABIObjCInvocation *invocation);

/// Creates a separate NSInvocation frame and dispatches the selector normally.
/// The caller keeps argument storage and referenced values alive through this
/// synchronous call. Object/block results are transferred at +1 in result;
/// scalar/value results are copied without ownership conversion. Foreign
/// exceptions are not translated. Result may be null only for void.
FOUNDATION_EXPORT BOOL ABIInvokeObjCInvocation(
    ABIObjCInvocation *invocation, void * _Nullable result,
    const void * _Nonnull const * _Nullable arguments, NSError * _Nullable * _Nullable error);

/// Validates receiver compatibility and dispatches through a fresh NSInvocation.
FOUNDATION_EXPORT BOOL ABIInvokeObjCDispatch(
    ABIObjCInvocation *invocation, id receiver, void * _Nullable result,
    const void * _Nonnull const * _Nullable arguments, NSError * _Nullable * _Nullable error);

/// Calls a captured IMP with a prepared C interface whose first two parameters
/// are receiver/selector pointers. Validates receiver compatibility and transfers
/// retainable results at +1. This does not perform message forwarding.
FOUNDATION_EXPORT BOOL ABIInvokeObjCImplementation(
    ABIObjCInvocation *invocation, ABICallInterface *interface, id receiver,
    void * _Nullable result, const void * _Nonnull const * _Nullable arguments,
    NSError * _Nullable * _Nullable error);

/// Copies a live Objective-C block to owned heap/global storage. Returns null
/// for a non-block object. The input must be a valid live Objective-C object;
/// the returned reference is released with ordinary Objective-C ownership.
FOUNDATION_EXPORT void * _Nullable ABICopyObjCBlock(const void *block);

/// Encodings for the standard imported value types supported by the frontend.
FOUNDATION_EXPORT const char *ABIObjCEncodingPoint(void);
FOUNDATION_EXPORT const char *ABIObjCEncodingSize(void);
FOUNDATION_EXPORT const char *ABIObjCEncodingRect(void);
FOUNDATION_EXPORT const char *ABIObjCEncodingRange(void);

NS_ASSUME_NONNULL_END

/// Internal encoding-to-C-layout bridge, implemented by the existing Swift
/// Objective-C decoder. The returned type is owned; failure is owned.
FOUNDATION_EXPORT ABIValueType * _Nullable ABICopyObjCHookValueType(
    const char * _Nonnull encoding, ABIResolutionFailure * _Nullable * _Nullable error);

#ifdef __cplusplus
#include <vector>
NS_ASSUME_NONNULL_BEGIN

// The incoming hook owns native +1 arguments. Outgoing calls retain a separate
// reference, which transfers only at native entry and is reclaimed on rejection.
class ABIObjCArgumentOwnership {
public:
    explicit ABIObjCArgumentOwnership(const ABIObjCInvocation *plan) : plan_(plan) {}
    ~ABIObjCArgumentOwnership();
    ABIObjCArgumentOwnership(const ABIObjCArgumentOwnership&) = delete;
    ABIObjCArgumentOwnership& operator=(const ABIObjCArgumentOwnership&) = delete;
    bool retain(const void * _Nonnull const * _Nullable arguments, NSError * _Nullable * _Nullable error);
    void adopt(const void * _Nonnull const * _Nullable arguments);
    const void * _Nonnull const * _Nullable arguments() const { return replacements_.empty() ? incoming_ : replacements_.data(); }
    void transfer() { owned_ = false; }
    void reclaim() { owned_ = true; }
private:
    const ABIObjCInvocation *plan_;
    const void * _Nonnull const * _Nullable incoming_ = nullptr;
    std::vector<CFTypeRef> references_;
    std::vector<const void *> replacements_;
    bool owned_ = true;
};
NS_ASSUME_NONNULL_END
#endif
