import ABIBridgeCore

private enum CXXImageScope {
    case selector(ImageSelector)
    case image(NativeImage)
}

private enum CXXCallTarget {
    case symbol(ResolvedSymbol)
    case virtual(VirtualCallTarget)

    @unsafe func withFunction<Result>(
        _ body: (ABIUnmanagedFunction?) throws -> Result
    ) rethrows -> Result {
        switch self {
        case .symbol(let symbol):
            return try unsafe symbol.withUnsafeAddress { try body(ABIUnsafeFunctionAtAddress($0)) }
        case .virtual(let target):
            return try withExtendedLifetime(target) { try body(target.function) }
        }
    }
}

private final class CXXMethodBinding {
    var receiver: NativeValue?
    let method: Any

    init(receiver: NativeValue, method: Any) {
        self.receiver = receiver
        self.method = method
    }

    deinit {
        // A receiver's final release may execute native destruction code.
        withExtendedLifetime(method) { receiver = nil }
    }
}

/// A C++ receiver view and source-level type scope.
///
/// The caller supplies a live object or correctly adjusted base-subobject view.
/// This type does not infer object layout, inheritance, or construction state.
/// It retains the storage owner and preserves the caller's isolation domain.
public final class NativeCXXObject {
    /// The source-level qualified class name used for direct member lookup.
    public let typeName: String
    /// The retained receiver or subobject view.
    public let storage: NativeValue

    private let runtime: ABIRuntime
    private let scope: CXXImageScope
    private let loading: ImageLoadingPolicy

    fileprivate init(runtime: ABIRuntime, storage: NativeValue, typeName: String, scope: CXXImageScope, loading: ImageLoadingPolicy) {
        self.runtime = runtime
        self.storage = storage
        self.typeName = typeName
        self.scope = scope
        self.loading = loading
    }

    /// Resolves a direct member implementation and binds this receiver.
    ///
    /// Include parameter types and qualifiers in the relative declaration, such
    /// as add(int) or current() const. Lookup reuses the runtime's owner indexes.
    /// Use virtualMethod for a vtable-selected implementation.
    ///
    /// - Parameters:
    ///   - name: The member declaration relative to the class name.
    ///   - signature: Explicit Swift arguments and result, excluding this.
    ///   - adapter: An optional C-compatible native bridge. It receives a signed
    ///     generic C function pointer, the receiver pointer, then explicit arguments.
    /// - Returns: A method retaining its receiver and implementation images.
    /// - Throws: A resolution, adapter, or call-signature error.
    public nonisolated(nonsending) func method<Result, each Argument>(
        named name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) async throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        let declaration = NativeDeclaration(name: typeName + "::" + name, language: .cxx)
        let symbol: ResolvedSymbol
        switch scope {
        case .selector(let selector): symbol = try await runtime.resolve(declaration, in: selector, loading: loading)
        case .image(let image): symbol = try await runtime.resolve(declaration, in: image, loading: loading)
        }
        return try NativeCXXMethod<Result, repeat each Argument>(target: .symbol(symbol), adapter: adapter).bind(to: storage)
    }

    /// Captures a selected virtual entry and binds this receiver/subobject.
    /// The entry retains its original adjustment thunk and authentication schema;
    /// the caller must supply the corresponding live base-subobject view.
    @unsafe public func virtualMethod<Result, each Argument>(
        _ entry: NativeVTable.Entry,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        try NativeCXXMethod<Result, repeat each Argument>(
            target: .virtual(entry.table.target(at: entry.index, authentication: entry.authentication, retaining: entry.image)),
            adapter: adapter
        ).bind(to: storage)
    }

    /// Captures an absolute virtual-function entry and binds this receiver.
    ///
    /// The slot, authentication schema, receiver adjustment, and C-compatible
    /// signature must match the target ABI. Authentication failure can fault;
    /// it is not a recoverable Swift error.
    ///
    /// - Parameters:
    ///   - index: A function-slot index within the declared table.
    ///   - table: A bounded absolute function-pointer table.
    ///   - authentication: The slot's authentication schema.
    ///   - signature: Explicit arguments and result, excluding this.
    ///   - adapter: A C-compatible bridge receiving target, receiver, and arguments.
    /// - Returns: A method retaining the selected entry's image, code owner, and receiver.
    /// - Throws: A slot-bounds, null-entry, image-lifetime, or signature error.
    @unsafe public func virtualMethod<Result, each Argument>(
        at index: Int, in table: NativeVTable,
        authentication: NativePointerAuthentication,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        try NativeCXXMethod<Result, repeat each Argument>(
            target: .virtual(table.target(at: index, authentication: authentication)), adapter: adapter
        ).bind(to: storage)
    }
}

/// A prepared direct or table-selected C++ implementation with an explicit receiver.
///
/// Copies retain the selected implementation and adapter images, but no receiver
/// binding. A selected virtual target keeps its original adjustment thunk and
/// authentication; calls do not redispatch through the supplied receiver's table.
public struct NativeCXXMethod<Result, each Argument> {
    private let target: CXXCallTarget
    private let adapter: ResolvedSymbol?
    private let call: CFunctionCall<Result, repeat each Argument>

    fileprivate init(target: CXXCallTarget, adapter: ResolvedSymbol?) throws {
        if let adapter, adapter.declaration.kind != .function {
            throw ABIResolutionError.unsupportedDeclaration("A method adapter must be an executable function.")
        }
        self.target = target
        self.adapter = adapter
        call = try CFunctionCall(hiddenPointerCount: adapter == nil ? 1 : 2)
    }

    /// Retains receiver storage for repeated calls without preparing the method again.
    ///
    /// The storage must describe the live object or adjusted subobject expected
    /// by this captured entry point. Binding does not inspect C++ object layout.
    public func bind(to receiver: NativeValue) -> NativeBoundCXXMethod<Result, repeat each Argument> {
        NativeBoundCXXMethod(method: self, receiver: receiver)
    }

    /// Calls the captured implementation on a live receiver or adjusted subobject.
    ///
    /// Direct calls require C-compatible values. A compiled native adapter handles
    /// nontrivial ownership and special result ABIs. Foreign exceptions must not
    /// cross this boundary. Custom result wrappers retain the method and receiver;
    /// raw pointer results remain borrowed. Honor the object's thread requirements.
    @unsafe public func unsafeInvoke(on receiver: NativeValue, _ values: repeat each Argument) throws -> Result {
        let binding = CXXMethodBinding(receiver: receiver, method: self)
        return try unsafe invoke(on: receiver, retaining: binding, repeat each values)
    }

    @unsafe fileprivate func invoke(
        on receiver: NativeValue, retaining owner: Any, _ values: repeat each Argument
    ) throws -> Result {
        try unsafe receiver.withUnsafeMutableBytes { bytes in
            let receiverAddress = UnsafeRawPointer(bytes.baseAddress!)
            return try unsafe target.withFunction { target in
                if let adapter {
                    guard let targetBits = ABIFunctionPointerBits(target) else {
                        throw ABIResolutionError.invalidAddress
                    }
                    return try unsafe adapter.withUnsafeAddress {
                        try unsafe call.unsafeInvoke(
                            ABIUnsafeFunctionAtAddress($0),
                            hiddenPointers: [targetBits, receiverAddress],
                            retainingResultOwner: owner, repeat each values
                        )
                    }
                }
                return try unsafe call.unsafeInvoke(
                    target, hiddenPointers: [receiverAddress],
                    retainingResultOwner: owner, repeat each values
                )
            }
        }
    }
}

/// A prepared C++ implementation bound to retained receiver storage.
///
/// Custom ABIBridgeValue results retain this binding when their wrapper keeps the
/// returned NativeValue. Raw pointer results remain borrowed. See <doc:CXXObjectInvocation>.
public struct NativeBoundCXXMethod<Result, each Argument> {
    /// The prepared implementation, independent of this receiver binding.
    public let method: NativeCXXMethod<Result, repeat each Argument>
    private let binding: CXXMethodBinding

    fileprivate init(method: NativeCXXMethod<Result, repeat each Argument>, receiver: NativeValue) {
        self.method = method
        binding = CXXMethodBinding(receiver: receiver, method: method)
    }

    /// Calls the captured implementation using the retained receiver storage.
    ///
    /// The signature, subobject, ownership, and thread requirements remain those
    /// of the prepared method. Retention does not make the object thread-safe.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe method.invoke(on: binding.receiver!, retaining: binding, repeat each values)
    }
}

extension ABIRuntime {
    /// Creates a retained C++ receiver scope for source-level member lookup.
    ///
    /// - Parameters:
    ///   - storage: A live object or caller-adjusted subobject view.
    ///   - typeName: The qualified C++ class name.
    ///   - scope: Images to search; automatic scope stays loaded-only.
    ///   - loading: Whether an explicit target may be acquired and initialized.
    /// - Returns: A receiver scope using this runtime's shared indexes.
    public nonisolated func cxxObject(
        _ storage: NativeValue, typeNamed typeName: String, in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) -> NativeCXXObject {
        .init(runtime: self, storage: storage, typeName: typeName, scope: .selector(scope), loading: loading)
    }

    /// Creates a C++ receiver scope within an already retained image.
    ///
    /// - Parameters:
    ///   - storage: A live object or caller-adjusted subobject view.
    ///   - typeName: The qualified C++ class name.
    ///   - image: The image whose symbol index can be reused.
    ///   - loading: Whether to ask dyld to acquire and initialize the image.
    /// - Returns: A receiver scope retaining its storage and image.
    public nonisolated func cxxObject(
        _ storage: NativeValue, typeNamed typeName: String, in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) -> NativeCXXObject {
        .init(runtime: self, storage: storage, typeName: typeName, scope: .image(image), loading: loading)
    }
}
