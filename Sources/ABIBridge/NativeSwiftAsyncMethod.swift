/// A concrete async Swift member with an explicit receiver.
///
/// The handle retains its type, async descriptor, and implementation images.
/// Invocation captures the implementation chosen during lookup and preserves
/// the caller's task. It does not perform virtual redispatch.
public struct NativeSwiftAsyncMethod<Result, each Argument>: Sendable {
    /// The selected declaration and retained image.
    public var symbol: ResolvedSymbol { implementation.symbol }

    private let implementation: SwiftAsyncImplementation
    private let type: NativeSwiftType
    private let receiver: SwiftReceiverPlan
    private let call: SwiftAsyncCall<Result, repeat each Argument>

    init(symbol: ResolvedSymbol, type: NativeSwiftType, receiver: SwiftReceiverPlan,
         errorPlan: SwiftErrorPlan?, inheritsCallerIsolation: Bool) throws {
        implementation = try SwiftAsyncImplementation(symbol: symbol, resolver: type.resolver)
        self.type = type
        self.receiver = receiver
        call = try SwiftAsyncCall(trailingType: receiver.trailingType, errorPlan: errorPlan,
                                   inheritsCallerIsolation: inheritsCallerIsolation,
                                   opaqueResult: SwiftOpaqueResultPlan.make(for: Result.self, symbol: symbol, resolver: type.resolver))
    }

    /// Retains an object for repeated calls to this captured async implementation.
    ///
    /// Binding reuses the prepared call and validates the object representation
    /// without calling the member. The native effects and isolation contract
    /// remain unchanged. Value receivers use explicit invocation.
    public func bind(to receiver: AnyObject) throws -> NativeBoundSwiftAsyncMethod<Result, repeat each Argument> {
        guard self.receiver.mode == .object else {
            throw ABIResolutionError.unsupportedDeclaration("Only Swift class members can bind a retained object.")
        }
        _ = try self.receiver.codec.encode(receiver)
        return NativeBoundSwiftAsyncMethod(method: self, receiver: receiver)
    }

    /// Awaits a class member or nonmutating value member.
    ///
    /// The supplied receiver and native signature must match. The caller
    /// satisfies the target's actor/thread contract. Consuming members transfer
    /// a receiver copy; cancellation remains cooperative until native completion.
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver>(
        on receiver: Receiver, _ values: repeat each Argument
    ) async throws -> Result {
        guard !self.receiver.isMutating || self.receiver.mode == .object else {
            throw ABIResolutionError.unsupportedDeclaration("A mutating Swift value member requires an inout receiver.")
        }
        let storage = try self.receiver.codec.encode(receiver)
        return try unsafe await invoke(storage, repeat each values)
    }

    /// Awaits a member and writes its modified receiver back, including on native failure.
    ///
    /// Native effects precede writeback. If writeback also fails, a
    /// NativeSwiftWritebackError preserves the invocation and conversion errors.
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) async throws -> Result {
        let storage = try self.receiver.codec.encode(receiver)
        var invoked = false
        let outcome: Swift.Result<Result, any Error>
        do { outcome = .success(try unsafe await invoke(storage, didInvoke: { invoked = true }, repeat each values)) }
        catch { outcome = .failure(error) }
        return try self.receiver.finishInvocation(outcome, storage: storage, invoked: invoked, receiver: &receiver,
            retaining: storage.writebackOwner(retaining: [symbol.image, type.image]))
    }

    @unsafe private nonisolated(nonsending) func invoke(
        _ storage: NativeValueStorage, didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) async throws -> Result {
        let context = try unsafe receiver.context(for: storage)
        let consumedObject = receiver.isConsuming && receiver.mode == .object
            ? Unmanaged<AnyObject>.fromOpaque(context!).retain() : nil
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        return try unsafe await call.unsafeInvoke(implementation: implementation, context: context,
            trailingValue: receiver.mode == .value ? storage : nil, retaining: (implementation, type, storage),
            retainingCode: type.image, didInvoke: {
                invoked = true
                if receiver.isConsuming && receiver.mode != .object { storage.relinquishValue() }
                didInvoke?()
            }, repeat each values)
    }
}

/// An async Swift implementation bound to a retained object.
///
/// The receiver remains alive across suspension and until the final handle copy
/// is released. Its actor requirements are those of the native declaration.
public struct NativeBoundSwiftAsyncMethod<Result, each Argument> {
    /// The prepared async implementation, independent of this retained receiver.
    ///
    /// Copies retain metadata, the async descriptor, and implementation images.
    /// They preserve the native effects without retaining this receiver binding.
    public let method: NativeSwiftAsyncMethod<Result, repeat each Argument>
    private let binding: SwiftObjectMethodBinding
    init(method: NativeSwiftAsyncMethod<Result, repeat each Argument>, receiver: AnyObject) {
        self.method = method
        binding = SwiftObjectMethodBinding(receiver: receiver, owner: method)
    }

    /// Awaits the captured implementation on the caller's task.
    @unsafe public nonisolated(nonsending) func unsafeInvoke(_ values: repeat each Argument) async throws -> Result {
        try unsafe await method.unsafeInvoke(on: binding.receiver!, repeat each values)
    }
}
