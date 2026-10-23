import ABIBridgeCore

/// A compiled method replacement in one selected Swift class's metadata.
///
/// Preparation captures the current implementation without changing dispatch. Initialize replacement-owned state before calling `install()`. Restore explicitly: releasing the plan does not undo a potentially fallible mutation. Published and captured code owners remain retained for process lifetime. See <doc:SwiftVirtualReplacements> for dispatch and inheritance boundaries.
public final class NativeSwiftVirtualReplacement<Implementation> {
    /// The same observation states used by compiled importing replacements.
    public typealias Status = NativeSwiftImportedReplacement<Implementation>.Status
    private let plan: NativeSwiftImportedReplacement<Implementation>
    init(storage: SwiftReplacementStorage, capture: (SwiftImplementation) -> Implementation) throws
    {
        guard let entry = storage.snapshots()[0].original else {
            throw ABIResolutionError.invalidAddress
        }
        original = capture(entry)
        plan = NativeSwiftImportedReplacement(storage: storage, capture: capture)
    }
    /// Address of the selected class metadata entry, not its implementation.
    public var address: UInt { plan.slots[0].address }
    /// The captured predecessor, callable without virtual redispatch.
    public let original: Implementation
    /// Logical state together with the current pointer observation.
    public var status: Status { plan.slots[0].status }
    /// Most recent publication result, including any partial write.
    public var mutation: NativeSwiftReplacementMutation? { plan.slots[0].mutation }
    /// Most recent restoration or rollback result.
    public var restoration: NativeSwiftReplacementMutation? { plan.slots[0].restoration }
    /// Most recent repair of protections left by a partial mutation.
    public var protectionRecovery: NativeSwiftReplacementMutation? {
        plan.slots[0].protectionRecovery
    }

    /// Publishes the ABI-compatible compiled method. Calls may enter immediately.
    /// - Throws: `NativeSwiftReplacementError`; index zero denotes this entry.
    @unsafe public func install() throws { try unsafe plan.install() }
    /// Restores owned changes, preserving a different pointer from another writer. Failed pointer or protection restoration remains inspectable and retryable.
    public func restore() throws { try plan.restore() }
}

extension NativeSwiftVirtualReplacement: @unchecked Sendable where Implementation: Sendable {}

extension NativeSwiftMethod {
    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Prepares replacement of this method's entry in the lookup type's metadata.
    ///
    /// Inherited and overridden methods select the copied slot in the requested type. Existing superclass and sibling metadata are unchanged. Subclasses initialized later can inherit the changed entry. Direct, devirtualized, inlined and previously captured implementations bypass this operation.
    ///
    /// Search and capture run synchronously on the caller's thread. The async counterpart prepares the same uninstalled plan on a worker.
    ///
    /// The replacement must accept every receiver reaching this slot and match its Swift context, ownership, lowering and isolation contract. Equal argument/result metatypes alone do not establish that compatibility.
    /// - Parameters:
    ///   - replacement: An already compiled synchronous class method.
    ///   - owner: Optional additional owner of code outside loader images.
    /// - Returns: An uninstalled plan with a typed predecessor.
    /// - Throws: A metadata layout, declaration, capture or image error.
    @unsafe
    public func prepareVirtualReplacementAndWait<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe _prepareVirtualReplacementAndWait(with: replacement, retaining: owner)
    }

    /// Prepares an uninstalled class-method replacement without blocking the caller's executor.
    ///
    /// Descriptor lookup and predecessor capture run on a worker. ABI, receiver, ownership, and publication requirements match prepareVirtualReplacementAndWait.
    /// - Returns: An uninstalled plan with the captured typed predecessor.
    /// - Throws: The same lookup, layout, and capture errors as synchronous preparation.
    @_transparent
    @unsafe
    public nonisolated(nonsending) func prepareVirtualReplacement<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _prepareVirtualReplacement(with: replacement, retaining: owner)
    }

    @unsafe
    public func prepareVirtualReplacementAndWait<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe _prepareVirtualReplacementAndWait(with: replacement, retaining: owner)
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func prepareVirtualReplacement<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _prepareVirtualReplacement(with: replacement, retaining: owner)
    }

    @unsafe
    public func prepareVirtualReplacementAndWait<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            @Sendable (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe _prepareVirtualReplacementAndWait(with: replacement, retaining: owner)
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func prepareVirtualReplacement<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            @Sendable (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _prepareVirtualReplacement(with: replacement, retaining: owner)
    }

    @unsafe
    public func prepareVirtualReplacementAndWait<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            @Sendable (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe _prepareVirtualReplacementAndWait(with: replacement, retaining: owner)
    }

    @_transparent
    @unsafe
    public nonisolated(nonsending) func prepareVirtualReplacement<
        Result,
        Failure: Error,
        ReplacementFailure: Error,
        each Argument
    >(
        with replacement: NativeSwiftMethod<
            @Sendable (repeat each Argument) throws(ReplacementFailure) -> Result
        >,
        retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>>
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _prepareVirtualReplacement(with: replacement, retaining: owner)
    }

    @usableFromInline nonisolated(nonsending) func _prepareVirtualReplacement<ReplacementSignature>(
        with replacement: NativeSwiftMethod<ReplacementSignature>,
        retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>> {
        try await NativePreparation.run { [self] in
            try unsafe _prepareVirtualReplacementAndWait(with: replacement, retaining: owner)
        }
    }

    @unsafe private func _prepareVirtualReplacementAndWait<ReplacementSignature>(
        with replacement: NativeSwiftMethod<ReplacementSignature>,
        retaining owner: (any Sendable)? = nil
    ) throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>> {
        guard receiver.mode == .object, replacement.receiver.mode == .object else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Virtual replacement requires Swift class instance methods."
            )
        }
        try requireReplacement(replacement)
        let dispatch = try virtualDispatch()
        let storage = try SwiftReplacementStorage(
            slots: [(dispatch.address, dispatch.authentication)],
            replacement: replacement.entry,
            retaining: (self, replacement, dispatch.image),
            codeOwner: owner
        )
        return try NativeSwiftVirtualReplacement(storage: storage) {
            NativeSwiftMethodImplementation(self, $0)
        }
    }
}
