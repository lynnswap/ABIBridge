import ABIBridgeCore

/// A compiled method replacement in one selected Swift class's metadata.
///
/// Preparation captures the current implementation without changing dispatch.
/// Initialize replacement-owned state before calling `install()`. Restore
/// explicitly: releasing the plan does not undo a potentially fallible mutation.
/// Published and captured code owners remain retained for process lifetime.
/// See <doc:SwiftVirtualReplacements> for dispatch and inheritance boundaries.
public final class NativeSwiftVirtualReplacement<Implementation> {
    /// The same observation states used by compiled importing replacements.
    public typealias Status = NativeSwiftImportedReplacement<Implementation>.Status
    private let plan: NativeSwiftImportedReplacement<Implementation>
    init(storage: SwiftReplacementStorage, capture: (SwiftImplementation) -> Implementation) throws {
        guard let entry = storage.snapshots()[0].original else { throw ABIResolutionError.invalidAddress }
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
    public var protectionRecovery: NativeSwiftReplacementMutation? { plan.slots[0].protectionRecovery }

    /// Publishes the ABI-compatible compiled method. Calls may enter immediately.
    /// - Throws: `NativeSwiftReplacementError`; index zero denotes this entry.
    @unsafe public func install() throws { try unsafe plan.install() }
    /// Restores owned changes, preserving a different pointer from another writer.
    /// Failed pointer or protection restoration remains inspectable and retryable.
    public func restore() throws { try plan.restore() }
}

extension NativeSwiftVirtualReplacement: @unchecked Sendable where Implementation: Sendable {}

extension NativeSwiftMethod {
    /// Prepares replacement of this method's entry in the lookup type's metadata.
    ///
    /// Inherited and overridden methods select the copied slot in the requested
    /// type. Existing superclass and sibling metadata are unchanged. Subclasses
    /// initialized later can inherit the changed entry. Direct, devirtualized,
    /// inlined and previously captured implementations bypass this operation.
    ///
    /// The replacement must accept every receiver reaching this slot and match
    /// its Swift context, ownership, lowering and isolation contract. Equal
    /// argument/result metatypes alone do not establish that compatibility.
    /// - Parameters:
    ///   - replacement: An already compiled synchronous class method.
    ///   - owner: Optional additional owner of code outside loader images.
    /// - Returns: An uninstalled plan with a typed predecessor.
    /// - Throws: A metadata layout, declaration, capture or image error.
    @unsafe public func prepareVirtualReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftMethod<(repeat each Argument) throws(ReplacementFailure) -> Result>, retaining owner: (any Sendable)? = nil
    ) throws -> NativeSwiftVirtualReplacement<NativeSwiftMethodImplementation<Signature>> where Signature == (repeat each Argument) throws(Failure) -> Result {
        try SwiftErrorPlan.validateReplacement(replacement.errorPlan, for: errorPlan)
        guard receiver.mode == .object, replacement.receiver.mode == .object else {
            throw ABIResolutionError.unsupportedDeclaration("Virtual replacement requires Swift class instance methods.")
        }
        let metadata = type.metadata
        let entry = try SwiftClassDispatch(metadata: metadata, declaration: symbol.declaration, resolver: type.resolver)
        let storage = try SwiftReplacementStorage(slots: [(entry.address, entry.authentication)],
            replacement: replacement.symbol, retaining: (self, replacement, entry.descriptor), codeOwner: owner)
        return try NativeSwiftVirtualReplacement(storage: storage) { NativeSwiftMethodImplementation(self, $0) }
    }
}
