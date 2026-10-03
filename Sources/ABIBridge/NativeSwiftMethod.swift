/// A native invocation and receiver writeback both failed.
///
/// The native member ran and either threw or failed its result conversion. The receiver's
/// writeback conversion then failed too; both errors remain available.
public struct NativeSwiftWritebackError: Error {
    /// The invocation or result-conversion failure.
    public let invocationError: any Error
    /// The subsequent receiver-conversion failure.
    public let writebackError: any Error
}

/// A captured Swift member implementation with an explicit receiver.
///
/// Invocation calls the implementation selected during lookup. It does not
/// perform virtual redispatch. Handles retain their type and implementation
/// images, while callers satisfy receiver lifetime and isolation requirements.
public struct NativeSwiftMethod<Signature>: Sendable {
    /// The selected source-level declaration and retained implementation image.
    public let symbol: ResolvedSymbol

    private var implementation: SwiftImplementation?
    let type: NativeSwiftType
    let receiver: SwiftReceiverPlan
    let consumesArguments: Bool
    var errorPlan: SwiftErrorPlan? { call.errorPlan }
    private let call: SwiftCallablePlan

    init(symbol: ResolvedSymbol, type: NativeSwiftType, receiver: SwiftReceiverPlan,
         consumesArguments: Bool = false, generic: SwiftGenericCallPlan? = nil) throws {
        self.symbol = symbol
        self.type = type
        self.receiver = receiver
        self.consumesArguments = consumesArguments
        call = try SwiftCallablePlan(signature: Signature.self, symbol: symbol, resolver: type.resolver,
            trailingType: receiver.trailingType, consumesArguments: consumesArguments, generic: generic)
    }

    func capturing(_ implementation: SwiftImplementation) -> Self {
        var result = self
        result.implementation = implementation
        return result
    }

    /// Retains an object for repeated calls to this captured implementation.
    ///
    /// Binding reuses the prepared call without calling the member. Invocation
    /// validates the object representation and receiver type using the original
    /// plan, and honors its ownership and isolation contract. Value receivers
    /// use explicit invocation.
    public func bind(to receiver: AnyObject) throws -> NativeBoundSwiftMethod<Signature> {
        guard self.receiver.mode == .object else {
            throw ABIResolutionError.unsupportedDeclaration("Only Swift class members can bind a retained object.")
        }
        return NativeBoundSwiftMethod(method: self, receiver: receiver)
    }

    /// Calls a class member or nonmutating value member.
    ///
    /// Typed receivers transfer an independent copy to consuming members.
    /// NativeSwiftValue accesses its owned storage directly: mutating members
    /// update that value and consuming members leave its handle consumed.
    /// NativeSwiftBorrowedValue permits mutation when supplied by a native inout
    /// callback; other borrows are read-only. Borrowed storage cannot be consumed.
    /// The lookup's ownership options must match the actual native declaration.
    ///
    /// - Parameters:
    ///   - receiver: An instance or adapter matching the declaring native type.
    ///   - values: Explicit method arguments.
    /// - Returns: The converted result.
    /// - Throws: A NativeSwiftError or a receiver conversion/invocation error. Use the inout
    ///   overload for a mutating typed value; owned runtime values update in place.
    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) throws -> Result where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe invoke(on: receiver, repeat each values)
    }

    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) throws -> Result where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe invoke(on: receiver, repeat each values)
    }

    /// Calls a member and writes the receiver value back to the caller.
    ///
    /// The receiver's adapter must describe the actual native value layout.
    /// Native side effects occur before a possible writeback conversion failure.
    /// - Parameters:
    ///   - receiver: A caller-owned value updated by a mutating member.
    ///   - values: Explicit method arguments.
    /// - Returns: The converted method result.
    /// - Throws: A NativeSwiftError or a receiver, result, or writeback conversion error.
    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) throws -> Result where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe invoke(on: &receiver, repeat each values)
    }

    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) throws -> Result where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe invoke(on: &receiver, repeat each values)
    }

    @unsafe private func invoke<Result, each Argument>(
        _ storage: NativeValueStorage, didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) throws -> Result {
        guard case .synchronous(let call) = call else { preconditionFailure("A synchronous signature has a synchronous call plan.") }
        defer { withExtendedLifetime(storage) {} }
        let context = try unsafe receiver.context(for: storage)
        // Typed and raw-pointer receivers need a separate +1. An owned runtime
        // receiver already transfers its reference through its access lease.
        let consumedObject = receiver.isConsuming && receiver.mode == .object && !storage.transfersOwnership
            ? Unmanaged<AnyObject>.fromOpaque(context!).retain() : nil
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        return try unsafe call.unsafeInvoke(
            symbol: symbol, context: context,
            trailingValue: receiver.mode == .value ? storage : nil, receiverStorage: storage,
            retaining: (symbol, type, storage.ownerForResult), retainingCode: type.image, didInvoke: {
                invoked = true
                if receiver.isConsuming && (receiver.mode != .object || storage.transfersOwnership) { storage.relinquishValue() }
                didInvoke?()
            }, implementation: implementation, repeat each values
        )
    }
}

// Releasing a receiver may execute native destruction code. Keep the captured
// method (and its images) alive until that release finishes.
final class SwiftObjectMethodBinding {
    var receiver: AnyObject?
    let owner: Any
    init(receiver: AnyObject, owner: Any) {
        self.receiver = receiver
        self.owner = owner
    }
    deinit { withExtendedLifetime(owner) { receiver = nil } }
}

/// A captured Swift implementation bound to a retained object.
///
/// The handle remains in the caller's isolation domain and retains the receiver
/// and implementation images until its last copy is released.
public struct NativeBoundSwiftMethod<Signature> {
    /// The prepared implementation, independent of this retained receiver.
    ///
    /// Copies retain the type and implementation images, but not this binding.
    /// Calls on another compatible receiver preserve the captured implementation.
    public let method: NativeSwiftMethod<Signature>
    private let binding: SwiftObjectMethodBinding

    init(method: NativeSwiftMethod<Signature>, receiver: AnyObject) {
        self.method = method
        binding = SwiftObjectMethodBinding(receiver: receiver, owner: method)
    }

    /// Calls the implementation with the retained receiver.
    ///
    /// - Parameter values: Explicit arguments in declaration order.
    /// - Returns: The converted result.
    /// - Throws: A conversion or invocation error.
    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe method.unsafeInvoke(on: binding.receiver!, repeat each values)
    }

    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe method.unsafeInvoke(on: binding.receiver!, repeat each values)
    }
}

extension NativeSwiftMethod {
    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Awaits a class member or nonmutating value member.
    ///
    /// The supplied receiver and native signature must match. The caller
    /// satisfies the target's actor/thread contract. NativeSwiftValue retains
    /// access across suspension and transfers its owned value to consuming
    /// members. Typed receivers transfer a copy. Cancellation remains cooperative.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: receiver, repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: receiver, repeat each values)
    }

    /// Awaits a member and writes its modified receiver back, including on native failure.
    ///
    /// Native effects precede writeback. If writeback also fails, a
    /// NativeSwiftWritebackError preserves the invocation and conversion errors.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: &receiver, repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: &receiver, repeat each values)
    }

    /// Awaits a class member or nonmutating value member.
    ///
    /// The supplied receiver and native signature must match. The caller
    /// satisfies the target's actor/thread contract. NativeSwiftValue retains
    /// access across suspension and transfers its owned value to consuming
    /// members. Typed receivers transfer a copy. Cancellation remains cooperative.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: receiver, repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: receiver, repeat each values)
    }

    /// Awaits a member and writes its modified receiver back, including on native failure.
    ///
    /// Native effects precede writeback. If writeback also fails, a
    /// NativeSwiftWritebackError preserves the invocation and conversion errors.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: &receiver, repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(on: &receiver, repeat each values)
    }

    @unsafe private nonisolated(nonsending) func invokeAsync<Result, each Argument>(
        _ storage: NativeValueStorage, didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) async throws -> Result {
        guard case .asynchronous(let call, let implementation) = call else { preconditionFailure("An async signature has an async call plan.") }
        defer { withExtendedLifetime(storage) {} }
        let context = try unsafe receiver.context(for: storage)
        let consumedObject = receiver.isConsuming && receiver.mode == .object && !storage.transfersOwnership
            ? Unmanaged<AnyObject>.fromOpaque(context!).retain() : nil
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        return try unsafe await call.unsafeInvoke(implementation: implementation, context: context,
            trailingValue: receiver.mode == .value ? storage : nil, receiverStorage: storage, retaining: (implementation, type, storage.ownerForResult),
            retainingCode: type.image, didInvoke: {
                invoked = true
                if receiver.isConsuming && (receiver.mode != .object || storage.transfersOwnership) { storage.relinquishValue() }
                didInvoke?()
            }, repeat each values)
    }
}

extension NativeBoundSwiftMethod {
    /// Awaits the captured implementation on the caller's task, retaining the receiver across suspension.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    /// Awaits a bound implementation using the concurrent calling convention.
    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try unsafe await invokeAsync(repeat each values)
    }

    @unsafe @usableFromInline nonisolated(nonsending) func invokeAsync<Result, each Argument>(
        _ values: repeat each Argument
    ) async throws -> Result {
        try unsafe await method.invokeAsync(on: binding.receiver!, repeat each values)
    }

}

extension NativeSwiftMethod {
    @unsafe private func invoke<Receiver, Result, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) throws -> Result {
        guard !self.receiver.isMutating || self.receiver.mode == .object || receiver is NativeSwiftValue || receiver is NativeSwiftBorrowedValue else {
            throw ABIResolutionError.unsupportedDeclaration("A mutating Swift value member requires an inout receiver.")
        }
        let storage = try self.receiver.encode(receiver)
        return try unsafe invoke(storage, repeat each values)
    }

    @unsafe private func invoke<Receiver, Result, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) throws -> Result {
        let storage = try self.receiver.encode(receiver)
        var invoked = false
        let outcome = Swift.Result<Result, any Error> {
            try unsafe invoke(storage, didInvoke: { invoked = true }, repeat each values)
        }
        return try self.receiver.finishInvocation(outcome, storage: storage, invoked: invoked, receiver: &receiver,
            retaining: (storage.writebackOwner(retaining: [symbol.image, type.image]), implementation))
    }

    @unsafe @usableFromInline nonisolated(nonsending) func invokeAsync<Receiver, Result, each Argument>(
        on receiver: Receiver, _ values: repeat each Argument
    ) async throws -> Result {
        guard !self.receiver.isMutating || self.receiver.mode == .object || receiver is NativeSwiftValue || receiver is NativeSwiftBorrowedValue else {
            throw ABIResolutionError.unsupportedDeclaration("A mutating Swift value member requires an inout receiver.")
        }
        let storage = try self.receiver.encode(receiver, asynchronous: true)
        return try unsafe await invokeAsync(storage, repeat each values)
    }

    @unsafe @usableFromInline nonisolated(nonsending) func invokeAsync<Receiver, Result, each Argument>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) async throws -> Result {
        let storage = try self.receiver.encode(receiver, asynchronous: true)
        var invoked = false
        let outcome: Swift.Result<Result, any Error>
        do { outcome = .success(try unsafe await invokeAsync(storage, didInvoke: { invoked = true }, repeat each values)) }
        catch { outcome = .failure(error) }
        return try self.receiver.finishInvocation(outcome, storage: storage, invoked: invoked, receiver: &receiver,
            retaining: storage.writebackOwner(retaining: [symbol.image, type.image]))
    }

}
