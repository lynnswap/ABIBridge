# Calling Objective-C from Objective-C++

Bind a concrete selector implementation with a typed signature and a retained receiver.

## Import the public interface

Link the `ABIBridge` product and include `<ABIBridge/ObjectiveCInvocation.hpp>` in an Objective-C++ source file. Use C++20 and either ARC or manual reference counting. The lower-level Objective-C binding functions and error domain are declared in `<ABIBridge/ObjectiveCInvocation.h>`.

```objc
#include <ABIBridge/ObjectiveCInvocation.hpp>

auto setEnabled = abi_bridge::objc_method<void(BOOL)>(renderer, "setEnabled:");
setEnabled.unsafe_invoke(YES);

auto nativeObject = abi_bridge::objc_method<void *()>(renderer, "nativeObject");
void *address = nativeObject.unsafe_invoke();
```

The example requires an existing receiver implementing those selectors. Signatures exclude `self` and `_cmd`. Passing a class object binds a class method. A selector can be supplied as `SEL` or a UTF-8 name; embedded NULs are rejected.

Binding checks argument counts and Objective-C type encodings, performs dynamic method resolution, and captures a concrete IMP. It works with concrete methods on NSProxy subclasses without asking the receiver to implement NSObject reflection. The captured method does not follow later method replacement; bind again to observe a new implementation. Forwarded-only methods cannot be captured by this interface.

## Own the receiver and result

Copies of a method handle share a retained receiver and any discoverable implementation image. The last handle releases the receiver before its implementation image. This does not keep an arbitrary raw-pointer result, argument, generated class, or dynamically generated IMP alive; those lifetimes and thread requirements remain the caller's responsibility.

Object and block results follow ordinary +0 return semantics. ARC callers receive managed values. MRC callers must retain a result or copy a block to keep it beyond its autorelease pool. The binding infers Objective-C method-family conventions; explicit ownership attributes absent from runtime encodings require overrides:

```objc
auto create = abi_bridge::objc_method<id()>(
    renderer, "retainedObject", {.returns_retained = true}
);
id result = create.unsafe_invoke();
```

`objc_method_options` also supports `consumes_receiver`. Consumption transfers an additional receiver reference for the call, preserving the binding's retained receiver. Consumed arguments other than `self` require a caller-specific adapter. Runtime encodings cannot prove these ownership contracts, so invocation is explicitly unsafe.

## Handle binding failures

The C++ interface throws `abi_bridge::resolution_error`, with an owned message and an `ABIFailure` category. Missing concrete declarations report `ABIFailureDeclarationNotFound`; a forwarded-only signature or forwarding IMP reports `ABIFailureUnsupportedDeclaration`; incompatible signatures report `ABIFailureSignatureMismatch`. A fast-forwarded selector without a method signature is treated as an absent concrete declaration. Objective-C exceptions raised by application code during lookup or invocation are not converted into C++ exceptions.

The lower-level interface returns an owned `ABIObjCMethod *` or an NSError in `ABIObjCInvocationErrorDomain`. Release a successful binding with `ABIReleaseObjCMethod`. Its receiver, selector, and IMP getters are borrowed for the binding's lifetime. Directly calling that IMP still requires the same signature and ownership contract as the typed interface.
