# Calling Objective-C selectors

Bind a typed selector to an existing receiver from Objective-C++.

## Bind and call

Link the `ABIBridgeObjCXX` product and include `<ABIBridge/ABIBridgeObjCXX.hpp>`:

```objc++
#include <ABIBridge/ABIBridgeObjCXX.hpp>

auto refresh = abi_bridge::objc_method<BOOL(BOOL)>(
    renderer, "refreshAnimated:"
);
BOOL didRefresh = refresh.unsafe_invoke(YES);
```

The example assumes that `renderer` implements `refreshAnimated:` with a Boolean parameter and result. The bridge creates the selector and supplies `self` and `_cmd`. A `SEL`, such as `@selector(refreshAnimated:)`, can also be passed directly. Use the actual native C/Objective-C types, including `BOOL`, `NSInteger`, and the concrete struct types declared by the target.

There is no package-imposed limit on the number of fixed parameters. Ordinary scalar, object, block, and concrete value arguments/results are lowered by the consumer's compiler. Variadic methods require a separate adapter.

Pass a class object as the receiver to bind a class method. Binding performs normal class initialization and dynamic method resolution. A selector that has no concrete IMP, including a forwarded-only selector, produces a resolution error.

## Signature validation

Binding checks the runtime parameter count and type encodings against the supplied signature. Type qualifiers and optional quoted object-class annotations do not change the object-pointer representation. Blocks retain their distinct encoding.

These checks do not establish object-subclass compatibility, a block's full signature, ownership annotations, or the meaning of a native value's fields. The caller must satisfy those contracts and the target's thread requirements. `unsafe_invoke` is explicit because an incorrect native contract may corrupt memory or crash.

An incompatible signature throws `abi_bridge::resolution_error` with `ABIFailureSignatureMismatch`. Error messages distinguish count, argument, and result mismatches.

## Receiver and implementation lifetime

A handle retains its receiver. Copies share the same binding, and the receiver is released when the last handle releases it. A discoverable implementation image is also retained, with the receiver released first.

A binding invokes the IMP chosen at binding time. Rebind after method replacement to call the new implementation. For generated IMPs outside a loaded image, the caller must keep the implementation valid and must not remove its block trampoline while a handle uses it.

## Ownership

Object-returning `alloc`, `new`, `copy`, `mutableCopy`, and instance `init` families use their normal ownership conventions. Initializers also consume an ownership reference to the receiver. The handle keeps its own receiver reference, so a replacement object or a nil initializer result does not invalidate the binding.

Runtime type encodings do not record attributes such as `ns_returns_retained`, `ns_returns_not_retained`, or a method-family override. Supply options when the declaration differs from its selector's default convention:

```objc++
auto createObject = abi_bridge::objc_method<NSObject*()>(
    provider, @selector(createObject),
    {.returns_retained = true}
);
NSObject* result = createObject.unsafe_invoke();
```

Use `consumes_receiver` to override self-consumption for an explicitly annotated declaration. Consumed arguments other than self and Core Foundation ownership require a target-specific adapter.

Block return types do not acquire Objective-C method-family ownership merely because their selector begins with `copy` or `new`. Explicit retained-return annotations still require the corresponding option.

The wrapper normalizes Objective-C object and block results to ordinary +0 return semantics. ARC callers receive managed values. Under manual reference counting, retain a result if it must survive the current autorelease pool. The native consumers test both modes.

## C and C++ calls

The same product also provides `abi_bridge::Runtime` for <doc:NativeFunctions> and <doc:NativeMethods>. These use native C/C++ declarations rather than selector lookup.
