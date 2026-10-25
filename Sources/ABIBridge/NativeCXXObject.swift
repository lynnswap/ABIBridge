import ABIBridgeCore
import ABIBridgeCore.Backend

/// A direct C++ member declaration and its C-compatible call adapter.
///
/// Wrap with `NativeRequest.cxx`, then resolve on a ``NativeCXXObject``.
/// Names are relative to that object's type, such as `add(int)` or
/// `current() const`. Construction performs no lookup or call preparation.
public struct NativeCXXMethodRequest<Result, each Argument>: Sendable {
    let name: String
    let adapter: ResolvedSymbol?

    /// Describes a direct member implementation.
    ///
    /// - Parameters:
    ///   - name: The declaration relative to the receiver's C++ type name.
    ///   - signature: Explicit Swift arguments and result, excluding `this`.
    ///   - adapter: An optional C-compatible bridge receiving a signed generic
    ///     function pointer, the receiver pointer, then explicit arguments.
    public static func method(
        _ name: String,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) -> Self {
        Self(name: name, adapter: adapter)
    }
}

/// A virtual C++ slot, signature, and owners, inspected when resolved.
///
/// Wrap with `NativeRequest.cxx`, then use unsafe resolution on a
/// ``NativeCXXObject``. Construction does not read or validate the slot.
/// Each resolution reads its current target. The table and its storage owner
/// remain retained while this request is saved, including a receiver retained
/// by a receiver-backed table. The request stays in the caller's isolation
/// domain and is not Sendable.
public struct NativeCXXVirtualMethodRequest<Result, each Argument> {
    let table: NativeVTable
    let index: Int
    let authentication: NativePointerAuthentication
    let adapter: ResolvedSymbol?
    let image: NativeImage?

    /// Describes a selected entry with its original image and authentication.
    ///
    /// - Parameters:
    ///   - entry: A named or explicitly described table entry for the live
    ///     receiver/subobject supplied when resolving this request.
    ///   - signature: Explicit Swift arguments and result, excluding `this`.
    ///   - adapter: An optional C-compatible bridge, as for a direct method.
    public static func virtualMethod(
        _ entry: NativeVTable.Entry,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) -> Self {
        Self(
            table: entry.table,
            index: entry.index,
            authentication: entry.authentication,
            adapter: adapter,
            image: entry.image
        )
    }

    /// Describes an absolute table slot without acquiring an image owner.
    ///
    /// The table's existing storage and code owners remain retained. Bounds
    /// and target validation occur during resolution.
    ///
    /// - Parameters:
    ///   - index: A zero-based function slot within the supplied table.
    ///   - table: A live, bounded absolute function-pointer table.
    ///   - authentication: The slot's target-specific authentication schema.
    ///   - signature: Explicit Swift arguments and result, excluding `this`.
    ///   - adapter: An optional C-compatible bridge, as for a direct method.
    public static func virtualMethod(
        at index: Int,
        in table: NativeVTable,
        authentication: NativePointerAuthentication,
        as signature: ((repeat each Argument) -> Result).Type,
        using adapter: ResolvedSymbol? = nil
    ) -> Self {
        Self(
            table: table,
            index: index,
            authentication: authentication,
            adapter: adapter,
            image: nil
        )
    }
}

extension NativeRequest {
    /// Describes a direct C++ member resolved on a ``NativeCXXObject``.
    public static func cxx<Result, each Argument>(
        _ declaration: NativeCXXMethodRequest<Result, repeat each Argument>
    ) -> Self where Declaration == NativeCXXMethodRequest<Result, repeat each Argument> {
        Self(declaration: declaration)
    }

    /// Describes a C++ virtual slot captured by unsafe resolution on a ``NativeCXXObject``.
    public static func cxx<Result, each Argument>(
        _ declaration: NativeCXXVirtualMethodRequest<Result, repeat each Argument>
    ) -> Self where Declaration == NativeCXXVirtualMethodRequest<Result, repeat each Argument> {
        Self(declaration: declaration)
    }
}

private enum CXXImageScope: Sendable {
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
/// The caller supplies a live object or correctly adjusted base-subobject view. This type does not infer object layout, inheritance, or construction state. It retains the storage owner and preserves the caller's isolation domain.
public final class NativeCXXObject {
    /// The source-level qualified class name used for direct member lookup.
    public let typeName: String
    /// The retained receiver or subobject view.
    public let storage: NativeValue

    private let runtime: ABIRuntime
    private let scope: CXXImageScope
    private let loading: ImageLoadingPolicy

    fileprivate init(
        runtime: ABIRuntime,
        storage: NativeValue,
        typeName: String,
        scope: CXXImageScope,
        loading: ImageLoadingPolicy
    ) {
        self.runtime = runtime
        self.storage = storage
        self.typeName = typeName
        self.scope = scope
        self.loading = loading
    }

    /// Resolves a direct member implementation and binds this receiver.
    ///
    /// The request names a member relative to the class, including parameter
    /// types and qualifiers. Search and call preparation run synchronously
    /// on the caller's thread and join required work already in progress.
    /// Use a virtual-method request to capture a vtable-selected target.
    ///
    /// - Parameter request: The direct declaration, signature, and optional
    ///   C-compatible adapter.
    /// - Returns: A method retaining its receiver and implementation images.
    /// - Throws: A resolution, adapter, or call-signature error.
    public nonisolated func resolveAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeCXXMethodRequest<Result, repeat each Argument>>
    ) throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        let member = request.declaration
        let declaration = NativeDeclaration(name: typeName + "::" + member.name, language: .cxx)
        let symbol: ResolvedSymbol
        switch scope {
        case .selector(let selector):
            symbol = try runtime.resolver.resolve(declaration, in: selector, loading: loading)
        case .image(let image):
            symbol = try runtime.resolver.resolve(declaration, in: image, loading: loading)
        }
        let method = try NativeCXXMethod<Result, repeat each Argument>(
            target: .symbol(symbol),
            adapter: member.adapter
        )
        return method.bind(to: storage)
    }

    /// Resolves a direct member without blocking the caller's executor.
    ///
    /// Search and call preparation run on a worker and join required work
    /// already in progress. The receiver and bound handle remain in the
    /// caller's isolation domain; resolution does not invoke the member.
    public nonisolated(nonsending) func resolve<Result, each Argument>(
        _ request: NativeRequest<NativeCXXMethodRequest<Result, repeat each Argument>>
    ) async throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        let member = request.declaration
        let declaration = NativeDeclaration(name: typeName + "::" + member.name, language: .cxx)
        let runtime = runtime
        let scope = scope
        let loading = loading
        let prepared = try await NativePreparation.run {
            let symbol: ResolvedSymbol
            switch scope {
            case .selector(let selector):
                symbol = try runtime.resolver.resolve(declaration, in: selector, loading: loading)
            case .image(let image):
                symbol = try runtime.resolver.resolve(declaration, in: image, loading: loading)
            }
            let call: CFunctionCall<Result, repeat each Argument> = try prepareCXXCall(
                adapter: member.adapter
            )
            return (symbol, call)
        }
        return NativeCXXMethod<Result, repeat each Argument>(
            target: .symbol(prepared.0),
            adapter: member.adapter,
            call: prepared.1
        ).bind(to: storage)
    }

    /// Captures a selected virtual slot and binds this receiver/subobject.
    ///
    /// The table, authentication, receiver adjustment, and signature must
    /// match the target ABI. Bounds, null-entry, image acquisition, and call
    /// preparation checks occur here. Authentication failure can fault.
    /// A named entry retains its original image and adjustment thunk.
    ///
    /// - Parameter request: A selected entry or explicit table slot, signature,
    ///   and optional C-compatible adapter.
    /// - Returns: A method retaining its selected target, code owners, and receiver.
    @unsafe public func resolveAndWait<Result, each Argument>(
        _ request: NativeRequest<NativeCXXVirtualMethodRequest<Result, repeat each Argument>>
    ) throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        let member = request.declaration
        return try NativeCXXMethod<Result, repeat each Argument>(
            target: .virtual(
                member.table.target(
                    at: member.index,
                    authentication: member.authentication,
                    retaining: member.image
                )
            ),
            adapter: member.adapter
        ).bind(to: storage)
    }

    /// Resolves a virtual slot without blocking the caller's executor.
    ///
    /// The current slot and original authentication address are captured on
    /// the caller. Image acquisition and call preparation run on a worker;
    /// the receiver, table, and code owners remain with the caller. The same
    /// unsafe table, subobject, and signature contract applies as for
    /// synchronous resolution.
    @unsafe public nonisolated(nonsending) func resolve<Result, each Argument>(
        _ request: NativeRequest<NativeCXXVirtualMethodRequest<Result, repeat each Argument>>
    ) async throws -> NativeBoundCXXMethod<Result, repeat each Argument> {
        let member = request.declaration
        let table = member.table
        let slot = try table.slot(at: member.index)
        let authentication = member.authentication
        let adapter = member.adapter
        let prepared = try await NativePreparation.run {
            let implementation = try NativeVTable.prepareTarget(
                slot,
                authentication: authentication
            )
            let call: CFunctionCall<Result, repeat each Argument> = try prepareCXXCall(
                adapter: adapter
            )
            return (implementation, call)
        }
        let target = table.target(capturing: prepared.0, retaining: member.image)
        return NativeCXXMethod<Result, repeat each Argument>(
            target: .virtual(target),
            adapter: adapter,
            call: prepared.1
        ).bind(to: storage)
    }
}

private func prepareCXXCall<Result, each Argument>(
    adapter: ResolvedSymbol?
) throws -> CFunctionCall<Result, repeat each Argument> {
    if let adapter, adapter.declaration.kind != .function {
        throw ABIResolutionError.unsupportedDeclaration(
            "A method adapter must be an executable function."
        )
    }
    return try CFunctionCall(hiddenPointerCount: adapter == nil ? 1 : 2)
}

/// A prepared direct or table-selected C++ implementation with an explicit receiver.
///
/// Copies retain the selected implementation and adapter images, but no receiver binding. A selected virtual target keeps its original adjustment thunk and authentication; calls do not redispatch through the supplied receiver's table.
public struct NativeCXXMethod<Result, each Argument> {
    private let target: CXXCallTarget
    private let adapter: ResolvedSymbol?
    private let call: CFunctionCall<Result, repeat each Argument>

    fileprivate init(target: CXXCallTarget, adapter: ResolvedSymbol?) throws {
        self.init(target: target, adapter: adapter, call: try prepareCXXCall(adapter: adapter))
    }

    fileprivate init(
        target: CXXCallTarget,
        adapter: ResolvedSymbol?,
        call: CFunctionCall<Result, repeat each Argument>
    ) {
        self.target = target
        self.adapter = adapter
        self.call = call
    }

    /// Retains receiver storage for repeated calls without preparing the method again.
    ///
    /// The storage must describe the live object or adjusted subobject expected by this captured entry point. Binding does not inspect C++ object layout.
    public func bind(to receiver: NativeValue) -> NativeBoundCXXMethod<Result, repeat each Argument>
    {
        NativeBoundCXXMethod(method: self, receiver: receiver)
    }

    /// Calls the captured implementation on a live receiver or adjusted subobject.
    ///
    /// Direct calls require C-compatible values. A compiled native adapter handles nontrivial ownership and special result ABIs. Foreign exceptions must not cross this boundary. Custom result wrappers retain the method and receiver; raw pointer results remain borrowed. Honor the object's thread requirements.
    @unsafe public func unsafeInvoke(
        on receiver: NativeValue,
        _ values: repeat each Argument
    ) throws -> Result {
        let binding = CXXMethodBinding(receiver: receiver, method: self)
        return try unsafe invoke(on: receiver, retaining: binding, repeat each values)
    }

    @unsafe fileprivate func invoke(
        on receiver: NativeValue,
        retaining owner: Any,
        _ values: repeat each Argument
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
                            retainingResultOwner: owner,
                            repeat each values
                        )
                    }
                }
                return try unsafe call.unsafeInvoke(
                    target,
                    hiddenPointers: [receiverAddress],
                    retainingResultOwner: owner,
                    repeat each values
                )
            }
        }
    }
}

/// A prepared C++ implementation bound to retained receiver storage.
///
/// Custom ABIBridgeValue results retain this binding when their wrapper keeps the returned NativeValue. Raw pointer results remain borrowed. See <doc:CXXObjectInvocation>.
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
    /// The signature, subobject, ownership, and thread requirements remain those of the prepared method. Retention does not make the object thread-safe.
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
    ///   - scope: Images searched during direct member resolution; automatic
    ///     scope stays loaded-only.
    ///   - loading: Whether direct member resolution may acquire and initialize
    ///     an explicit image.
    /// - Returns: A receiver scope using this runtime's shared indexes.
    public nonisolated func cxxObject(
        _ storage: NativeValue,
        typeNamed typeName: String,
        in scope: ImageSelector = .automatic,
        loading: ImageLoadingPolicy = .ifNeeded
    ) -> NativeCXXObject {
        .init(
            runtime: self,
            storage: storage,
            typeName: typeName,
            scope: .selector(scope),
            loading: loading
        )
    }

    /// Creates a C++ receiver scope within an already retained image.
    ///
    /// - Parameters:
    ///   - storage: A live object or caller-adjusted subobject view.
    ///   - typeName: The qualified C++ class name.
    ///   - image: The image whose symbol index can be reused.
    ///   - loading: Whether direct member resolution may ask dyld to acquire
    ///     and initialize the image.
    /// - Returns: A receiver scope retaining its storage and image.
    public nonisolated func cxxObject(
        _ storage: NativeValue,
        typeNamed typeName: String,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) -> NativeCXXObject {
        .init(
            runtime: self,
            storage: storage,
            typeName: typeName,
            scope: .image(image),
            loading: loading
        )
    }
}
