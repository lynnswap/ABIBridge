/// Owns callback behavior for one selected Swift class metadata entry.
///
/// The stable dispatcher and its code/metadata owners remain process-lived.
/// Invalidation releases user captures after in-flight snapshots finish. Saved
/// pointers and subclass metadata that copied this dispatcher share its chain.
public final class NativeSwiftVirtualHook: Sendable {
    /// The same logical and pointer-observation states as imported Swift hooks.
    public typealias Status = NativeSwiftImportedFunctionHook.Status
    private let registration: NativeSwiftImportedFunctionHook
    init(_ registration: NativeSwiftImportedFunctionHook) { self.registration = registration }
    private var slot: NativeSwiftImportedFunctionHook.Slot { registration.slots[0] }
    /// Address of the selected class's method pointer.
    public var address: UInt { slot.address }
    /// Logical state and the currently observed pointer ownership.
    public var status: Status { slot.status }
    /// Physical publication performed by this registration, if any.
    public var mutation: NativeSwiftReplacementMutation? { slot.mutation }
    /// Latest rollback following failed installation.
    public var rollback: NativeSwiftReplacementMutation? { slot.rollback }
    /// Latest repair of protections left by a failed operation.
    public var protectionRecovery: NativeSwiftReplacementMutation? { slot.protectionRecovery }
    /// Removes this callback without overwriting the method pointer or blocking active calls.
    public func invalidate() { registration.invalidate() }
    /// Retries physical rollback still owned by this failed installation.
    public func recoverFailedInstallation() async throws { try await registration.recoverFailedInstallation() }
}

/// A class-method hook could not finish pointer publication or protection changes.
public struct NativeSwiftVirtualHookInstallationError: Error {
    /// The original publication failure; the slot remains available for inspection.
    public let underlyingError: any Error
    /// An invalidated owner preserving rollback and protection-recovery outcomes.
    public let registration: NativeSwiftVirtualHook
}

extension NativeSwiftMethod {
    /// Intercepts calls through the selected class's virtual method entry.
    ///
    /// Declaration descriptors select the lookup type's copied slot, including
    /// inherited and overridden methods. Already separate superclass/sibling
    /// entries are unchanged. Saved dispatchers and later-initialized subclasses
    /// that copy this entry share its chain, including future registrations.
    /// Direct, final, inlined and devirtualized calls bypass the selected slot.
    ///
    /// Callbacks run on the incoming thread with an initialized instance. The
    /// native ABI, ownership, isolation and external-writer coordination remain
    /// caller requirements. Initializers, deinitializers and yielding accessors
    /// need separate lifecycle/effect support. Source types alone do not establish
    /// those contracts. Native protection failures remain observable.
    /// - Parameters:
    ///   - owner: Additional lifetime owner for generated predecessor code.
    ///   - onFailure: Thread-safe observer of callback/conversion errors.
    ///   - body: Synchronous typed callback with scoped receiver/continuation access.
    /// - Throws: Preparation errors or `NativeSwiftVirtualHookInstallationError`
    ///   with partial publication and retryable rollback outcomes.
    @unsafe public nonisolated(nonsending) func hookVirtualCalls(
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftVirtualHook {
        try await installVirtualHook(retaining: owner, requiresMainActor: false, onFailure: onFailure, body: body)
    }

    /// Installs a virtual callback for a method with a caller-supplied MainActor contract.
    ///
    /// Background calls report `wrongThread` and bypass this callback before
    /// decoding arguments or the receiver. No actor hop occurs; `onFailure` must
    /// remain safe on any entering thread. Other scope/lifetime rules match
    /// `hookVirtualCalls`.
    @unsafe @MainActor public func hookMainActorVirtualCalls(
        retaining owner: (any Sendable)? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftVirtualHook {
        try await installVirtualHook(retaining: owner, requiresMainActor: true, onFailure: onFailure) {
            (call: NativeSwiftMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
            let input = ObjCReplacementIsolatedValue(value: (call, (repeat each values)))
            return try MainActor.assumeIsolated {
                ObjCReplacementIsolatedValue(value: try body(input.value.0, repeat each input.value.1))
            }.value
        }
    }

    private nonisolated(nonsending) func installVirtualHook(
        retaining owner: (any Sendable)?, requiresMainActor: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeSwiftMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) async throws -> NativeSwiftVirtualHook {
        let receiverView = try SwiftClassHookReceiver(self)
        let entry = try SwiftClassDispatch(metadata: type.metadata, declaration: symbol.declaration, resolver: type.resolver)
        guard !entry.isSetter || consumesArguments else {
            throw ABIResolutionError.unsupportedDeclaration("Resolve a Swift setter through setter(named:as:) to establish its consumed argument ownership.")
        }
        let prepared = try SwiftHookCallbackSignature<Result, repeat each Argument>()
        let signature = try prepared.erased(consumingArguments: consumesArguments,
            classReceiver: receiver.isConsuming, retaining: self)
        let handler = prepareSwiftMethodHandler(method: self, prepared: prepared, receiver: receiverView,
            requiresMainActor: requiresMainActor, onFailure: onFailure, body: body)
        // A file-backed inherited entry can also be an importing reference. Use
        // the storage type's generation so both operations share one dispatcher.
        let reference = SwiftHookReference(key: .init(address: entry.address, generation: type.image.identity.loadGeneration),
            authentication: entry.authentication)
        do {
            let registration = try await SwiftHookRegistry.shared.register(references: [reference],
                retaining: (self, entry.descriptor), signature: signature, handler: handler, codeOwner: owner)
            return NativeSwiftVirtualHook(registration)
        } catch let error as NativeSwiftHookInstallationError {
            throw NativeSwiftVirtualHookInstallationError(underlyingError: error.underlyingError,
                registration: NativeSwiftVirtualHook(error.registration))
        }
    }
}
