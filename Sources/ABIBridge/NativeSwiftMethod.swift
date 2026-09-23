/// A native invocation and receiver writeback both failed.
///
/// The native member ran before its result conversion failed. The receiver's
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
public struct NativeSwiftMethod<Result, each Argument>: Sendable {
    /// The selected source-level declaration and retained implementation image.
    public let symbol: ResolvedSymbol

    private let type: NativeSwiftType
    private let receiver: SwiftReceiverPlan
    private let call: SwiftCall<Result, repeat each Argument>

    init(symbol: ResolvedSymbol, type: NativeSwiftType, receiver: SwiftReceiverPlan,
         consumesArguments: Bool = false) throws {
        self.symbol = symbol
        self.type = type
        self.receiver = receiver
        call = try SwiftCall(trailingType: receiver.trailingType, consumesArguments: consumesArguments)
    }

    /// Calls a class member or nonmutating value member.
    ///
    /// Consuming members transfer an independent receiver copy. The consuming
    /// option selected during lookup must match the actual Swift declaration.
    ///
    /// - Parameters:
    ///   - receiver: An instance or adapter matching the declaring native type.
    ///   - values: Explicit method arguments.
    /// - Returns: The converted result.
    /// - Throws: A receiver conversion or invocation error. Use the inout
    ///   overload for a mutating value member.
    @unsafe public func unsafeInvoke<Receiver>(
        on receiver: Receiver, _ values: repeat each Argument
    ) throws -> Result {
        guard !self.receiver.isMutating || self.receiver.mode == .object else {
            throw ABIResolutionError.unsupportedDeclaration("A mutating Swift value member requires an inout receiver.")
        }
        let storage = try self.receiver.codec.encode(receiver)
        return try unsafe invoke(storage, repeat each values)
    }

    /// Calls a member and writes the receiver value back to the caller.
    ///
    /// The receiver's adapter must describe the actual native value layout.
    /// Native side effects occur before a possible writeback conversion failure.
    /// - Parameters:
    ///   - receiver: A caller-owned value updated by a mutating member.
    ///   - values: Explicit method arguments.
    /// - Returns: The converted method result.
    /// - Throws: A receiver, result, or writeback conversion error.
    @unsafe public func unsafeInvoke<Receiver>(
        on receiver: inout Receiver, _ values: repeat each Argument
    ) throws -> Result {
        let storage = try self.receiver.codec.encode(receiver)
        var invoked = false
        let outcome = Swift.Result<Result, any Error> {
            try unsafe invoke(storage, didInvoke: { invoked = true }, repeat each values)
        }
        if invoked && self.receiver.isMutating && self.receiver.mode != .object {
            do {
                let value = try self.receiver.codec.decode(storage, storage.writebackOwner(retaining: [symbol.image, type.image]))
                guard let updated = value as? Receiver else {
                    throw ABIInvocationError.incompatibleValue(
                        expected: String(reflecting: Receiver.self), actual: String(reflecting: Swift.type(of: value))
                    )
                }
                receiver = updated
            } catch {
                if case .failure(let invocationError) = outcome {
                    throw NativeSwiftWritebackError(invocationError: invocationError, writebackError: error)
                }
                throw error
            }
        }
        return try outcome.get()
    }

    @unsafe private func invoke(
        _ storage: NativeValueStorage, didInvoke: (() -> Void)? = nil, _ values: repeat each Argument
    ) throws -> Result {
        let context = try unsafe receiver.context(for: storage)
        // A consuming class method gets its own +1, including when the receiver
        // was supplied by a raw-pointer adapter rather than a managed codec.
        let consumedObject = receiver.isConsuming && receiver.mode == .object
            ? Unmanaged<AnyObject>.fromOpaque(context!).retain() : nil
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        return try unsafe call.unsafeInvoke(
            symbol: symbol, context: context,
            trailingValue: receiver.mode == .value ? storage : nil,
            retaining: (symbol, type, storage), didInvoke: {
                invoked = true
                if receiver.isConsuming && receiver.mode != .object { storage.relinquishValue() }
                didInvoke?()
            }, repeat each values
        )
    }
}

// Releasing a receiver may execute native destruction code. Keep the captured
// method (and its images) alive until that release finishes.
private final class SwiftObjectMethodBinding {
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
public struct NativeBoundSwiftMethod<Result, each Argument> {
    private let method: NativeSwiftMethod<Result, repeat each Argument>
    private let binding: SwiftObjectMethodBinding

    init(method: NativeSwiftMethod<Result, repeat each Argument>, receiver: AnyObject) {
        self.method = method
        binding = SwiftObjectMethodBinding(receiver: receiver, owner: method)
    }

    /// Calls the implementation with the retained receiver.
    ///
    /// - Parameter values: Explicit arguments in declaration order.
    /// - Returns: The converted result.
    /// - Throws: A conversion or invocation error.
    @unsafe public func unsafeInvoke(_ values: repeat each Argument) throws -> Result {
        try unsafe method.unsafeInvoke(on: binding.receiver!, repeat each values)
    }
}
