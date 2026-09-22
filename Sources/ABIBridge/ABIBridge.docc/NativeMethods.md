# Calling C++ instance methods

Invoke a direct member entry point on an existing object, with borrowed or shared receiver ownership.

## Resolve a concrete method

Resolve the complete demangled declaration, including `const` where applicable. The signature describes explicit arguments and the result; ABIBridge supplies `this`.

```cpp
auto runtime = abi_bridge::Runtime::current();
auto add = runtime.cxx_method<int(int)>(
    abi_bridge::declaration("Example::Counter::add(int)")
);
auto current = runtime.cxx_method<int() const>(
    abi_bridge::declaration("Example::Counter::current() const")
);

// counter is an existing Example::Counter instance.
int result = add.unsafe_invoke(&counter, 2);
int value = current.unsafe_invoke(&counter);
```

`unsafe_invoke` borrows the receiver for that call. The receiver must point to a live object of the correct class, at the exact subobject address the entry point expects. It is the caller's responsibility to provide the actual native signature and satisfy the target's thread and lifetime requirements.

The compiler lowers all fixed parameters, references, and concrete result types. There is no package-imposed parameter-count limit. This does not enable variadic declarations using C's `...`.

## Bind an existing shared owner

Bind a `std::shared_ptr` to reuse the receiver across calls:

```cpp
auto increment = add.bind(counterOwner);
counterOwner.reset();
int result = increment.unsafe_invoke(2);
```

The bound handle retains the shared owner and the method's image. Copies share that ownership; the receiver is released when the last owner is released. Binding an empty pointer throws `resolution_error` with `ABIFailureInvalidRequest`.

A const-qualified method accepts a shared pointer to a const receiver. A non-const method requires a mutable receiver. This static distinction does not verify the target class or reconstruct its layout.

For multiple inheritance or an object stored inside another allocation, use an aliasing shared pointer whose address already refers to the correct subobject:

```cpp
auto receiver = std::shared_ptr<Example::Counter>(
    combinedOwner, static_cast<Example::Counter*>(combinedOwner.get())
);
auto increment = add.bind(receiver);
```

The standard shared pointer retains `combinedOwner` while presenting the adjusted receiver address to the method. ABIBridge does not infer this adjustment from a name or a vtable.

## Direct dispatch

A resolved method calls the named implementation directly. It does not perform virtual dispatch, select a derived override, or turn an arbitrary address into a C++ pointer-to-member. Constructors and destructors require separate contracts; these handles operate on instances whose construction and destruction are managed by the caller or its shared owner.

See <doc:NativeFunctions> for image scopes, resolution failures, and the native signature contract.
