# Calling native functions from C++

Resolve C and C++ functions by source-level name and invoke them through a concrete C++ signature.

## Add the native product

Link the `ABIBridgeCore` Swift package product and include `<ABIBridge/ABIBridge.hpp>`. The product includes the Swift implementation and MachOKit dependencies needed for symbol resolution. Consumers do not need a Swift source file, generated Swift header, or resolver-registration callback.

```cpp
#include <ABIBridge/ABIBridge.hpp>
#include <unistd.h>

auto runtime = abi_bridge::Runtime::current();
auto processID = runtime.c_function<pid_t()>("getpid");
pid_t result = processID.unsafe_invoke();
```

`Runtime::current()` and Swift's ``ABIRuntime/shared`` share their symbol indexes. Construct `abi_bridge::Runtime runtime;` for an independent cache. Native lookup is synchronous; it does not wait for a Swift concurrency task. Lookup and cache clearing may run concurrently.

## Describe the actual signature

Use the complete demangled declaration to locate a C++ function:

```cpp
auto add = runtime.cxx_function<int(int, int)>(
    abi_bridge::declaration("Example::Math::add(int, int)"),
    abi_bridge::image_selector::framework("Example")
);
int result = add.unsafe_invoke(20, 22);
```

The template signature determines how the consumer's compiler passes arguments and receives results. Concrete C++ types support their normal compiler-generated conventions, including references, non-trivial values, and indirect results.

The caller must supply the actual native types and calling convention. A symbol name cannot establish a C++ return type, object layout, ownership contract, or thread requirement. A successful lookup therefore does not make an incorrect signature safe. A mismatch can corrupt memory or crash; it is not a recoverable resolution error.

These handles support C and C++ free functions. Swift calling conventions, instance-method dispatch, Objective-C selectors, and variadic signatures require separate invocation APIs. Do not represent an instance method as a free function by guessing its hidden parameters.

## Select images and retain results

Omit the selector to search loaded images, or use `image_selector::framework("Example")` or `image_selector::path(executablePath)` to constrain the lookup. Paths select executable files. Selectors do not load missing libraries. Lookup precedence and ambiguity follow <doc:SymbolLookup>.

A `function<Signature>` retains its `resolved_symbol`, which keeps the image loaded. Copies share ownership. A function can outlive its `Runtime` and remain valid after `remove_cached_results()`. These handles retain code, not argument objects or memory passed by reference.

`function.symbol()` exposes the image identity and path for diagnostics. `resolved_symbol::unsafe_address()` borrows an unsigned address for use while the symbol handle remains alive. Normal invocation performs the function-pointer signing required by the compilation target.

## Handle lookup failures

Native resolution throws `abi_bridge::resolution_error`. Its `code()` returns an `ABIFailure...` category from `<ABIBridge/Runtime.h>`; `what()` contains the declaration-specific detail.

```cpp
try {
    auto function = runtime.c_function<int()>("ExampleVersion");
    int version = function.unsafe_invoke();
} catch (const abi_bridge::resolution_error& error) {
    if (error.code() == ABIFailureDeclarationNotFound) {
        // The optional function is absent from the loaded images.
    } else {
        throw;
    }
}
```

Missing images, missing declarations, ambiguous declarations, and invalid storage remain distinct failures. Invocation does not translate exceptions thrown by the target into resolution errors.
