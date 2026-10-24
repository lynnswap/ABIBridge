# Calling Objective-C from Objective-C++

Capture a concrete selector implementation with a typed signature, then supply or retain its receiver.

## Import the public interface

Link the `ABIBridge` product and include `<ABIBridge/ObjectiveCInvocation.hpp>` in an Objective-C++ source file. Use C++20 and either ARC or manual reference counting. The lower-level Objective-C binding functions and error domain are declared in `<ABIBridge/ObjectiveCInvocation.h>`.

```objc
#include <ABIBridge/ObjectiveCInvocation.hpp>

auto setEnabled = abi_bridge::bound_objc_implementation<void(BOOL)>(renderer, "setEnabled:");
setEnabled.unsafe_invoke(YES);

auto nativeObject = abi_bridge::bound_objc_implementation<void *()>(renderer, "nativeObject");
void *address = nativeObject.unsafe_invoke();
```

The example requires an existing receiver implementing those selectors. Signatures exclude `self` and `_cmd`. Passing a class object binds a class method. A selector can be supplied as `SEL` or a UTF-8 name; embedded NULs are rejected.

Capture checks argument counts and encodings, runs dynamic method resolution, and selects a concrete IMP. Concrete NSProxy methods work without NSObject reflection. Forwarding-only methods cannot be captured.

## Reuse the captured implementation

Extract a value from an existing bound handle, or use an existing object as a prototype for discovery:

```objc
auto bound = abi_bridge::bound_objc_implementation<void(BOOL)>(firstRenderer, "setEnabled:");
auto setEnabled = bound.implementation();
setEnabled.unsafe_invoke(secondRenderer, YES);
auto secondBound = setEnabled.bind(secondRenderer);
secondBound.unsafe_invoke(NO);

abi_bridge::objc_implementation<void(BOOL)> prepared(firstRenderer, "setEnabled:");
```

`objc_implementation<Signature>` retains the lookup class and discoverable implementation images without retaining a receiver instance. Releasing the original binding can release that receiver while the extracted implementation stays alive. Calls accept instances of the lookup class or its subclasses, or compatible class objects for a class-method capture. Incompatible receiver kinds or classes fail before invoking the IMP.

Extraction and `bind` preserve the IMP, selector, and ownership without repeating lookup. Calls bypass subclass overrides and later replacements; capture again to select a new implementation. Keep generated classes and IMPs valid through their final use.

## Own the receiver and result

Copies of a bound implementation share a retained receiver and any discoverable implementation image. The last handle releases the receiver before its implementation image. This does not keep an arbitrary raw-pointer result, argument, generated class, or dynamically generated IMP alive; those lifetimes and thread requirements remain the caller's responsibility.

Object and block results follow ordinary +0 return semantics. ARC callers receive managed values. MRC callers must retain a result or copy a block to keep it beyond its autorelease pool. The binding infers Objective-C method-family conventions; explicit ownership attributes absent from runtime encodings require overrides:

```objc
auto create = abi_bridge::bound_objc_implementation<id()>(
    renderer, "retainedObject", {.returns_retained = true}
);
id result = create.unsafe_invoke();
```

`objc_method_options` also supports `consumes_receiver`. Consumption transfers an additional receiver reference for the call, preserving the binding's retained receiver. Use `consumed_parameters` for zero-based explicit arguments annotated `ns_consumed`:

```objc
auto consume = abi_bridge::bound_objc_implementation<void(NSObject *)>(
    renderer, "consumeObject:", {.consumed_parameters = {0}}
);
consume.unsafe_invoke(value);
```

The wrapper supplies a separate owned reference for each selected object or block input, preserving the caller's ARC or MRC ownership. Bound and receiver-independent calls share this contract. Runtime encodings cannot prove these ownership annotations, so invocation is explicitly unsafe.

For Objective-C callers, `ABIObjCSignature` groups the result and explicit parameter encodings. `ABIObjCMethodOptions` holds result and receiver ownership plus the consumed-parameter indexes, which capture copies. Zero-initialized options infer selector-family ownership; `ABIObjCOwnershipBorrowed` and `ABIObjCOwnershipTransferred` explicitly override it. Hooks use the same ownership values. `ABIBoundObjCImplementationGetConsumesParameter` and `ABIObjCImplementationGetConsumesParameter` expose the prepared contract. Calling the raw IMP still requires the caller to provide the declared ownership.

## Handle binding failures

The C++ interface throws `abi_bridge::resolution_error`, with an owned message and an `ABIFailure` category. Missing concrete declarations report `ABIFailureDeclarationNotFound`; a forwarded-only signature or forwarding IMP reports `ABIFailureUnsupportedDeclaration`; incompatible signatures report `ABIFailureSignatureMismatch`. A fast-forwarded selector without a method signature is treated as an absent concrete declaration. Objective-C exceptions raised by application code during lookup or invocation are not converted into C++ exceptions.

The Foundation-aware interface returns an owned captured implementation or receiver binding, or an NSError in `ABIObjCInvocationErrorDomain`. Release the binding with `ABIReleaseBoundObjCImplementation`. Selector, IMP, and `ABIBoundObjCImplementationGetReceiverAddress` results borrow from it; bridge the receiver address to `id` only while the binding lives. Raw IMP calls require the typed interface's signature and ownership contract.

## Capture and bind from Objective-C

`ObjectiveCInvocation.h` also works in ordinary `.m` files under ARC or manual reference counting:

```objective-c
const ABIObjCSignature signature = {@encode(NSInteger), NULL, 0};
NSError *error = nil;
ABIObjCImplementation *implementation = ABICopyObjCImplementation(
    renderer, @selector(itemCount), &signature, (ABIObjCMethodOptions){0}, &error);
if (!implementation) {
    NSLog(@"%@", error);
    return;
}
ABIBoundObjCImplementation *binding = ABICopyBoundObjCImplementation(
    implementation, renderer, &error);
ABIReleaseObjCImplementation(implementation);
if (!binding) {
    NSLog(@"%@", error);
    return;
}
typedef NSInteger (*ItemCount)(id, SEL);
NSInteger count = ((ItemCount)ABIBoundObjCImplementationGetIMP(binding))(
    (__bridge id)ABIBoundObjCImplementationGetReceiverAddress(binding),
    ABIBoundObjCImplementationGetSelector(binding));
ABIReleaseBoundObjCImplementation(binding);
```

Capture validates the supplied encoding, retains the class and discoverable images, and leaves the prototype receiver unretained. A binding validates and retains a compatible receiver while keeping the same IMP. Calls through the raw IMP require the caller's actual signature and native ownership; ordinary C-style opaque handles are released explicitly under both ARC and MRC.

`ABIBoundObjCImplementationCopyImplementation` returns an owned `ABIObjCImplementation *` independently of an existing `ABIBoundObjCImplementation` binding. `ABIRetainObjCImplementation` adds a reference and returns the same handle and `ABIReleaseObjCImplementation` releases it. Selector/IMP/ownership getters borrow their values from that live handle; keep it alive through invocation. The IMP getter preserves its signed function-pointer representation.

`ABIObjCImplementationValidateReceiver` checks class and method kind. `ABICopyBoundObjCImplementation` creates an owned binding and reports incompatible receivers through NSError. The binding releases its receiver before the plan's images. The caller still supplies the actual invocation signature and ownership annotations.

## Invoke a variadic implementation

Use an ellipsis in the C++ signature for a variadic native method. The fixed prefix is validated against its runtime encoding, and each call's tail uses the compiler's C argument promotions:

```objective-c++
auto format = abi_bridge::objc_implementation<NSString *(NSString *, ...)>(
    NSString.class, @selector(stringWithFormat:));
NSString *text = format.unsafe_invoke(NSString.class, @"%.1f/%d", 1.5f, -3);
auto bound = format.bind(NSString.class);
NSString *literal = bound.unsafe_invoke(@"literal");
```

Receiver binding, captured IMP identity, ARC/MRC ownership, and code owners follow the fixed-signature contract. The caller supplies the method's required sentinel and a C-compatible anonymous tail; Objective-C metadata does not encode those arguments.
