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
    let target: CXXCallTarget
    let adapter: ResolvedSymbol?

    init(receiver: NativeValue, target: CXXCallTarget, adapter: ResolvedSymbol?) throws {
        if let adapter, adapter.declaration.kind != .function {
            throw ABIResolutionError.unsupportedDeclaration("A method adapter must be an executable function.")
        }
        self.receiver = receiver
        self.target = target
        self.adapter = adapter
    }

    deinit {
        // A receiver's final release may execute native destruction code.
        withExtendedLifetime((target, adapter)) { receiver = nil }
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

    fileprivate init(runtime: ABIRuntime, storage: NativeValue, typeName: String, scope: CXXImageScope) {
        self.runtime = runtime
        self.storage = storage
        self.typeName = typeName
        self.scope = scope
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
    ) async throws -> NativeCXXMethod<Result, repeat each Argument> {
        let declaration = NativeDeclaration(name: typeName + "::" + name, language: .cxx)
        let symbol: ResolvedSymbol
        switch scope {
        case .selector(let selector): symbol = try await runtime.resolve(declaration, in: selector)
        case .image(let image): symbol = try await runtime.resolve(declaration, in: image)
        }
        return try NativeCXXMethod(
            binding: CXXMethodBinding(receiver: storage, target: .symbol(symbol), adapter: adapter)
        )
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
    /// - Returns: A method retaining the selected entry's image, table owner, and receiver.
    /// - Throws: A slot-bounds, null-entry, image-lifetime, or signature error.
    @unsafe public func virtualMethod<Result, each Argument>(
        at index: Int, in table: NativeVTable,
        authentication: NativePointerAuthentication,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) throws -> NativeCXXMethod<Result, repeat each Argument> {
        try NativeCXXMethod(binding: CXXMethodBinding(
            receiver: storage, target: .virtual(table.target(at: index, authentication: authentication)),
            adapter: adapter
        ))
    }
}

/// A direct or vtable-selected C++ method bound to retained receiver storage.
///
/// Each call supplies this automatically. Custom ABIBridgeValue results keep
/// the binding alive when their wrapper retains the returned NativeValue.
/// Raw pointer results remain borrowed; keep the method or another owner alive.
/// See <doc:CXXObjectInvocation>.
public struct NativeCXXMethod<Result, each Argument> {
    private let binding: CXXMethodBinding
    private let call: CFunctionCall<Result, repeat each Argument>

    fileprivate init(binding: CXXMethodBinding) throws {
        self.binding = binding
        call = try CFunctionCall(hiddenPointerCount: binding.adapter == nil ? 1 : 2)
    }

    /// Invokes the captured implementation with the bound receiver.
    ///
    /// Honor the native object's thread requirements, signature, and lifetime.
    /// Direct calls need C-compatible values. Use a compiled native adapter for
    /// nontrivial copy/destruction, consumed arguments, and special result ABIs.
    /// Foreign exceptions must be handled inside the adapter.
    ///
    /// - Parameter values: Explicit arguments in declaration order.
    /// - Returns: The converted result.
    /// - Throws: A conversion or call-interface error.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        let receiver = binding.receiver!
        return try unsafe receiver.withUnsafeMutableBytes { bytes in
            let receiverAddress = UnsafeRawPointer(bytes.baseAddress!)
            return try unsafe binding.target.withFunction { target in
                if let adapter = binding.adapter {
                    guard let targetBits = ABIFunctionPointerBits(target) else {
                        throw ABIResolutionError.invalidAddress
                    }
                    return try unsafe adapter.withUnsafeAddress {
                        try unsafe call.unsafeInvoke(
                            ABIUnsafeFunctionAtAddress($0),
                            hiddenPointers: [targetBits, receiverAddress],
                            retainingResultOwner: binding, repeat each values
                        )
                    }
                }
                return try unsafe call.unsafeInvoke(
                    target, hiddenPointers: [receiverAddress],
                    retainingResultOwner: binding, repeat each values
                )
            }
        }
    }
}

extension ABIRuntime {
    /// Creates a retained C++ receiver scope for source-level member lookup.
    ///
    /// - Parameters:
    ///   - storage: A live object or caller-adjusted subobject view.
    ///   - typeName: The qualified C++ class name.
    ///   - scope: Loaded images to search; defaults to all loaded images.
    /// - Returns: A receiver scope using this runtime's shared indexes.
    public nonisolated func cxxObject(
        _ storage: NativeValue, typeNamed typeName: String, in scope: ImageSelector = .automatic
    ) -> NativeCXXObject {
        .init(runtime: self, storage: storage, typeName: typeName, scope: .selector(scope))
    }

    /// Creates a C++ receiver scope within an already retained image.
    ///
    /// - Parameters:
    ///   - storage: A live object or caller-adjusted subobject view.
    ///   - typeName: The qualified C++ class name.
    ///   - image: The image whose symbol index can be reused.
    /// - Returns: A receiver scope retaining its storage and image.
    public nonisolated func cxxObject(
        _ storage: NativeValue, typeNamed typeName: String, in image: NativeImage
    ) -> NativeCXXObject {
        .init(runtime: self, storage: storage, typeName: typeName, scope: .image(image))
    }
}
