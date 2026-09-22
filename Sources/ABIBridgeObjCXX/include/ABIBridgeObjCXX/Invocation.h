#pragma once

#import <ABIBridgeObjCXX/ABIBridgeObjCXX.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ABIObjCInvocation ABIObjCInvocation;

/// Internal selector invocation support for the Swift frontend. Ownership
/// overrides use -1 for selector-family inference, 0 for borrowed, and 1 for
/// retained results or consumed self. The plan retains its receiver/signature.
FOUNDATION_EXPORT ABIObjCInvocation * _Nullable ABICopyObjCInvocation(
    id receiver, SEL selector, int32_t returnsRetained, int32_t consumesReceiver,
    NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void ABIReleaseObjCInvocation(ABIObjCInvocation *invocation);
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

/// Encodings for the standard imported value types supported by the frontend.
FOUNDATION_EXPORT const char *ABIObjCEncodingPoint(void);
FOUNDATION_EXPORT const char *ABIObjCEncodingSize(void);
FOUNDATION_EXPORT const char *ABIObjCEncodingRect(void);
FOUNDATION_EXPORT const char *ABIObjCEncodingRange(void);

NS_ASSUME_NONNULL_END
