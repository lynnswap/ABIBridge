#pragma once
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <ABIBridge/Inspection.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ABIObjCMethod ABIObjCMethod;
typedef struct ABIObjCImplementation ABIObjCImplementation;

/// Errors use the ABIFailure categories declared by ABIBridgeCore.
FOUNDATION_EXPORT NSErrorDomain const ABIObjCInvocationErrorDomain;

/// Binds a selector to a retained receiver and validates concrete type encodings.
/// Parameter encodings exclude self and _cmd. Ownership overrides use -1 to
/// infer the method-family convention, 0 for borrowed, and 1 for retained or
/// consumed respectively. Runtime encodings cannot reveal ownership attributes.
/// A successful handle owns its receiver and any discoverable code image.
/// Forwarded-only selectors cannot be bound to a concrete IMP.
/// Missing declarations report ABIFailureDeclarationNotFound; forwarded-only
/// signatures/implementations report ABIFailureUnsupportedDeclaration, and
/// incompatible encodings report ABIFailureSignatureMismatch.
FOUNDATION_EXPORT ABIObjCMethod * _Nullable ABICopyObjCMethod(
    id receiver, SEL selector, const char *resultType,
    const char * _Nonnull const * _Nullable parameterTypes, size_t parameterCount,
    int32_t returnsRetained, int32_t consumesReceiver, NSError * _Nullable * _Nullable error);

/// Releases the receiver before releasing its implementation image.
FOUNDATION_EXPORT void ABIReleaseObjCMethod(ABIObjCMethod *method);
/// Returns the receiver's borrowed object address without Objective-C return ownership.
/// Keep the binding alive through use; bridge to id for a typed native call.
FOUNDATION_EXPORT const void *ABIObjCMethodReceiverAddress(const ABIObjCMethod *method);
/// Returns the selector captured at binding time.
FOUNDATION_EXPORT SEL ABIObjCMethodSelector(const ABIObjCMethod *method);
/// Returns the resolved IMP. Capture again to select a subsequent replacement.
FOUNDATION_EXPORT IMP ABIObjCMethodImplementation(const ABIObjCMethod *method);
/// Whether the target returns an Objective-C object at +1.
FOUNDATION_EXPORT BOOL ABIObjCMethodReturnsRetained(const ABIObjCMethod *method);
/// Whether the target consumes an ownership reference to self.
FOUNDATION_EXPORT BOOL ABIObjCMethodConsumesReceiver(const ABIObjCMethod *method);

/// Copies ownership of the captured implementation without retaining the bound receiver.
/// The handle retains its class and discoverable implementation images.
FOUNDATION_EXPORT ABIObjCImplementation *ABICopyObjCMethodImplementation(const ABIObjCMethod *method);
/// Adds an ownership reference to a live captured implementation.
FOUNDATION_EXPORT void ABIRetainObjCImplementation(ABIObjCImplementation *implementation);
/// Releases an ownership reference; null is permitted.
FOUNDATION_EXPORT void ABIReleaseObjCImplementation(ABIObjCImplementation * _Nullable implementation);
/// Checks class/instance receiver compatibility without looking up another IMP.
FOUNDATION_EXPORT BOOL ABIValidateObjCImplementationReceiver(
    const ABIObjCImplementation *implementation, id receiver, NSError * _Nullable * _Nullable error);
/// Retains a compatible receiver while preserving the captured IMP and ownership.
/// Failure returns null and an NSError in ABIObjCInvocationErrorDomain.
FOUNDATION_EXPORT ABIObjCMethod * _Nullable ABICopyBoundObjCMethod(
    ABIObjCImplementation *implementation, id receiver, NSError * _Nullable * _Nullable error);
/// Borrowed selector and signed IMP for the captured handle's lifetime.
FOUNDATION_EXPORT SEL ABIObjCImplementationSelector(const ABIObjCImplementation *implementation);
FOUNDATION_EXPORT IMP ABIObjCImplementationIMP(const ABIObjCImplementation *implementation);
FOUNDATION_EXPORT BOOL ABIObjCImplementationReturnsRetained(const ABIObjCImplementation *implementation);
FOUNDATION_EXPORT BOOL ABIObjCImplementationConsumesReceiver(const ABIObjCImplementation *implementation);

NS_ASSUME_NONNULL_END
