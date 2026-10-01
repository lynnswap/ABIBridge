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

Capturing checks argument counts and Objective-C type encodings, performs dynamic method resolution, and captures a concrete IMP. It works with concrete methods on NSProxy subclasses without asking the receiver to implement NSObject reflection. The captured method does not follow later method replacement; capture again to observe a new implementation. Forwarded-only methods cannot be captured by this interface.

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

Extraction and `bind` preserve the selected IMP, selector, and ownership overrides without repeating lookup or encoding validation. Compatible overrides and later method replacements are bypassed; capture again to select a different implementation. This remains distinct from ordinary Objective-C message dispatch. Generated classes and IMPs still require caller-managed validity.

## Own the receiver and result

Copies of a bound implementation share a retained receiver and any discoverable implementation image. The last handle releases the receiver before its implementation image. This does not keep an arbitrary raw-pointer result, argument, generated class, or dynamically generated IMP alive; those lifetimes and thread requirements remain the caller's responsibility.

Object and block results follow ordinary +0 return semantics. ARC callers receive managed values. MRC callers must retain a result or copy a block to keep it beyond its autorelease pool. The binding infers Objective-C method-family conventions; explicit ownership attributes absent from runtime encodings require overrides:

```objc
auto create = abi_bridge::bound_objc_implementation<id()>(
    renderer, "retainedObject", {.returns_retained = true}
);
id result = create.unsafe_invoke();
```

`objc_method_options` also supports `consumes_receiver`. Consumption transfers an additional receiver reference for the call, preserving the binding's retained receiver. Consumed arguments other than `self` require a caller-specific adapter. Runtime encodings cannot prove these ownership contracts, so invocation is explicitly unsafe.

## Handle binding failures

The C++ interface throws `abi_bridge::resolution_error`, with an owned message and an `ABIFailure` category. Missing concrete declarations report `ABIFailureDeclarationNotFound`; a forwarded-only signature or forwarding IMP reports `ABIFailureUnsupportedDeclaration`; incompatible signatures report `ABIFailureSignatureMismatch`. A fast-forwarded selector without a method signature is treated as an absent concrete declaration. Objective-C exceptions raised by application code during lookup or invocation are not converted into C++ exceptions.

The lower-level interface returns an owned `ABIObjCMethod *` or an NSError in `ABIObjCInvocationErrorDomain`. Release a successful binding with `ABIReleaseObjCMethod`. Its selector and IMP getters are borrowed for the binding's lifetime. `ABIObjCMethodReceiverAddress` returns the borrowed receiver address without Objective-C return ownership; bridge it to `id` while the binding is alive. This replaces the former `id`-returning `ABIObjCMethodReceiver` getter. Directly calling that IMP still requires the same signature and ownership contract as the typed interface.

## Use receiver-independent C ownership

`ABICopyObjCMethodImplementation` returns an owned `ABIObjCImplementation *` independently of an existing `ABIObjCMethod` binding. `ABIRetainObjCImplementation` adds a reference and `ABIReleaseObjCImplementation` releases it. Selector/IMP/ownership getters borrow their values from that live handle; keep it alive through invocation. The IMP getter preserves its signed function-pointer representation.

`ABIValidateObjCImplementationReceiver` checks a live receiver's class and method kind. `ABICopyBoundObjCMethod` creates an owned retained-receiver binding to the same captured implementation, reporting incompatible receivers through NSError. Releasing a binding destroys its receiver before releasing the implementation plan's images. These C functions do not establish a different invocation signature or infer ownership annotations.
