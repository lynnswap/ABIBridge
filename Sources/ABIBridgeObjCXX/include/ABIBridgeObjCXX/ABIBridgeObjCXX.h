#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <ABIBridgeCore.h>
#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct ABIObjCMethod ABIObjCMethod;

/// Errors use the ABIFailure categories declared by ABIBridgeCore.
FOUNDATION_EXPORT NSErrorDomain const ABIObjCInvocationErrorDomain;

/// Binds a selector to a retained receiver and validates concrete type encodings.
/// Parameter encodings exclude self and _cmd. Ownership overrides use -1 to
/// infer the method-family convention, 0 for borrowed, and 1 for retained or
/// consumed respectively. Runtime encodings cannot reveal ownership attributes.
/// A successful handle owns its receiver and any discoverable code image.
/// Forwarded-only selectors cannot be bound to a concrete IMP.
FOUNDATION_EXPORT ABIObjCMethod * _Nullable ABICopyObjCMethod(
    id receiver, SEL selector, const char *resultType,
    const char * _Nonnull const * _Nullable parameterTypes, size_t parameterCount,
    int32_t returnsRetained, int32_t consumesReceiver, NSError * _Nullable * _Nullable error);

/// Releases the receiver before releasing its implementation image.
FOUNDATION_EXPORT void ABIReleaseObjCMethod(ABIObjCMethod *method);
/// Returns a borrowed receiver; keep the method handle alive during use.
FOUNDATION_EXPORT id ABIObjCMethodReceiver(const ABIObjCMethod *method);
/// Returns the selector captured at binding time.
FOUNDATION_EXPORT SEL ABIObjCMethodSelector(const ABIObjCMethod *method);
/// Returns the resolved IMP. Subsequent method replacement requires rebinding.
FOUNDATION_EXPORT IMP ABIObjCMethodImplementation(const ABIObjCMethod *method);
/// Whether the target returns an Objective-C object at +1.
FOUNDATION_EXPORT BOOL ABIObjCMethodReturnsRetained(const ABIObjCMethod *method);
/// Whether the target consumes an ownership reference to self.
FOUNDATION_EXPORT BOOL ABIObjCMethodConsumesReceiver(const ABIObjCMethod *method);

NS_ASSUME_NONNULL_END
