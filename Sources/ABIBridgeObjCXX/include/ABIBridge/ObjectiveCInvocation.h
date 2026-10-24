#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <ABIBridge/Inspection.h>
#include <ABIBridge/ObjectiveCOwnership.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ABIBoundObjCImplementation ABIBoundObjCImplementation;
typedef struct ABIObjCImplementation ABIObjCImplementation;

/// Concrete result and explicit parameter encodings, excluding self and _cmd. The arrays and strings are borrowed only during capture; ownership annotations are supplied separately.
typedef struct {
    const char *resultType;
    const char * _Nonnull const * _Nullable parameterTypes;
    size_t parameterCount;
} ABIObjCSignature;

/// Zero-initialized options infer selector-family ownership. Consumed parameter indexes exclude self and _cmd and are copied during capture.
typedef struct {
    ABIObjCOwnership resultOwnership;
    ABIObjCOwnership receiverOwnership;
    const size_t * _Nullable consumedParameters;
    size_t consumedParameterCount;
} ABIObjCMethodOptions;

/// Errors use the ABIFailure categories declared by ABIBridgeCore.
FOUNDATION_EXPORT NSErrorDomain const ABIObjCInvocationErrorDomain;
/// An Objective-C exception raised by an invoked method. The error's user info
/// holds the exception's name, reason, and call stack under the keys below.
FOUNDATION_EXPORT NSErrorDomain const ABIObjCExceptionErrorDomain;
FOUNDATION_EXPORT NSErrorUserInfoKey const ABIObjCExceptionNameKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const ABIObjCExceptionReasonKey;
FOUNDATION_EXPORT NSErrorUserInfoKey const ABIObjCExceptionCallStackKey;

/// Captures a concrete IMP using an existing object or class as a prototype, without retaining that receiver. Validates concrete encodings and retains the class and discoverable implementation images. Capture runs dynamic method resolution; subsequent calls do not redispatch replacements or subclass overrides.
///
/// The signature does not establish native ownership. Options override method-family inference with borrowed or transferred results/receiver references and zero-based consumed parameters. Missing declarations report ABIFailureDeclarationNotFound; forwarded-only declarations report ABIFailureUnsupportedDeclaration; incompatible encodings report ABIFailureSignatureMismatch. Returns an owned implementation or null with an NSError in ABIObjCInvocationErrorDomain. Application Objective-C exceptions propagate normally.
FOUNDATION_EXPORT ABIObjCImplementation * _Nullable ABICopyObjCImplementation(
    id prototype, SEL selector,
    const ABIObjCSignature *signature, ABIObjCMethodOptions options,
    NSError * _Nullable * _Nullable error);

/// Adds an ownership reference to a live captured implementation and returns that same handle.
FOUNDATION_EXPORT ABIObjCImplementation *ABIRetainObjCImplementation(ABIObjCImplementation *implementation);
/// Releases an ownership reference; null is permitted.
FOUNDATION_EXPORT void ABIReleaseObjCImplementation(ABIObjCImplementation * _Nullable implementation);
/// Checks class/instance receiver compatibility without looking up another IMP.
FOUNDATION_EXPORT BOOL ABIObjCImplementationValidateReceiver(
    const ABIObjCImplementation *implementation, __unsafe_unretained id receiver,
    NSError * _Nullable * _Nullable error);
/// Retains a compatible receiver while preserving the captured IMP and ownership. Failure returns null and an NSError in ABIObjCInvocationErrorDomain. The binding releases its receiver before its implementation images.
FOUNDATION_EXPORT ABIBoundObjCImplementation * _Nullable ABICopyBoundObjCImplementation(
    ABIObjCImplementation *implementation, __unsafe_unretained id receiver,
    NSError * _Nullable * _Nullable error);
/// Copies ownership of the same captured implementation without retaining the binding's receiver or repeating lookup.
FOUNDATION_EXPORT ABIObjCImplementation *ABIBoundObjCImplementationCopyImplementation(
    const ABIBoundObjCImplementation *binding);
/// Releases the receiver before releasing its implementation image; null is permitted.
FOUNDATION_EXPORT void ABIReleaseBoundObjCImplementation(ABIBoundObjCImplementation * _Nullable binding);

/// Borrowed receiver address without Objective-C return ownership. Keep the binding alive through use; bridge to id for a typed native call.
FOUNDATION_EXPORT const void *ABIBoundObjCImplementationGetReceiverAddress(const ABIBoundObjCImplementation *binding);
/// Selector and signed IMP captured at preparation time, borrowed for the binding's lifetime.
FOUNDATION_EXPORT SEL ABIBoundObjCImplementationGetSelector(const ABIBoundObjCImplementation *binding);
FOUNDATION_EXPORT IMP ABIBoundObjCImplementationGetIMP(const ABIBoundObjCImplementation *binding);
FOUNDATION_EXPORT BOOL ABIBoundObjCImplementationGetReturnsRetained(const ABIBoundObjCImplementation *binding);
FOUNDATION_EXPORT BOOL ABIBoundObjCImplementationGetConsumesReceiver(const ABIBoundObjCImplementation *binding);
/// Whether an explicit parameter transfers an additional reference to the callee. Requires an index within the captured signature.
FOUNDATION_EXPORT BOOL ABIBoundObjCImplementationGetConsumesParameter(const ABIBoundObjCImplementation *binding, size_t index);

/// Borrowed selector and signed IMP for the captured implementation's lifetime.
FOUNDATION_EXPORT SEL ABIObjCImplementationGetSelector(const ABIObjCImplementation *implementation);
FOUNDATION_EXPORT IMP ABIObjCImplementationGetIMP(const ABIObjCImplementation *implementation);
FOUNDATION_EXPORT BOOL ABIObjCImplementationGetReturnsRetained(const ABIObjCImplementation *implementation);
FOUNDATION_EXPORT BOOL ABIObjCImplementationGetConsumesReceiver(const ABIObjCImplementation *implementation);
/// Whether an explicit parameter transfers an additional reference to the callee. Requires an index within the captured signature.
FOUNDATION_EXPORT BOOL ABIObjCImplementationGetConsumesParameter(const ABIObjCImplementation *implementation, size_t index);

NS_ASSUME_NONNULL_END
