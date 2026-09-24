# Calling retained native symbols from C++

Use the consumer's compiler to call a resolved C/C++ entry point while retaining its code image.

## Import the public interface

Link the `ABIBridge` product, use C++20, and include `<ABIBridge/NativeInvocation.hpp>` from C++ or Objective-C++:

```cpp
#include <ABIBridge/NativeInvocation.hpp>

abi_bridge::Runtime runtime;
auto symbol = runtime.resolve({"Example::Math::add(int, int)"});
abi_bridge::function<int(int, int)> add(std::move(symbol));
int result = add.unsafe_invoke(20, 22);
```

The example requires an already-loaded library defining that declaration. Construction accepts an owned `resolved_symbol` without running lookup again. Batch results and symbols transferred from Swift through `ResolvedSymbol.copyNativeHandle()` use the same constructor after wrapping their C handle with `resolved_symbol::adopt` or `resolved_symbol::retain` as appropriate. Both the transferred symbol and call handle retain the implementation image.

A constructor rejects empty handles, data/vtable symbols, and declarations marked with other source-language calling conventions. These checks use declaration metadata, not signature inference: C++ mangled names do not establish a complete calling contract. `ABIResolvedSymbolKind` and `ABIResolvedSymbolLanguage` expose this metadata through the C inspection interface.

## Supply the actual signature

`function<Result(Arguments...)>` preserves C++ reference categories and lets the compiler lower register arguments, stack arguments, and indirect or nontrivial results. Variadic signatures are not supported. The caller must use types with the same ABI, layout, standard-library ABI, and ownership as the target definition. Compiler support for a type does not make an unknown private type's layout inferable.

On an authenticated call ABI, the handle signs the resolved address for the supplied function-pointer type. This is not authentication of an original signed pointer. The resolver establishes executable storage and image lifetime; it cannot prove that the supplied signature, receiver, argument lifetime, or calling thread is correct.

Copies share the retained symbol. Handles remain valid after the original loader reference, resolver, or cache is released. A moved-from handle may be destroyed or assigned but must not be invoked or used to access its symbol.

## Call a direct member entry point

```cpp
auto symbol = runtime.resolve({"Example::Counter::add(int)"});
abi_bridge::method<int(int)> add(std::move(symbol));
int result = add.unsafe_invoke(counter, 2);
```

The receiver must point to the exact class subobject expected by that nonstatic member entry point. Use `Result(Arguments...) const` for a const method. The handle does not perform virtual dispatch or adjust base subobjects automatically.

To retain a receiver, use `method.bind(sharedPointer)`. An aliasing `std::shared_ptr` can keep an enclosing allocation alive while pointing to the required subobject. The resulting `bound_method` owns both receiver and implementation image, releasing the receiver first. Raw receiver calls borrow the receiver only for that call. Neither form retains other pointer or reference arguments or makes target state thread-safe.

Framework-specific layout shims, callback interfaces, and value ownership adapters remain in the consuming code. These headers do not publish the internal `InvocationRuntime` or every backend invocation facility.
