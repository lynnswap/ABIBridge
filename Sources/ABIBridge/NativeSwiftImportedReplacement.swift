import ABIBridgeCore

/// A prepared, explicit replacement of compiled Swift importing references.
///
/// Preparation captures each previous entry without changing dispatch. Use
/// `slots` to initialize any state required by the compiled replacement, then
/// call `install()`. Calls may arrive as soon as its first pointer is published.
/// Changes across multiple slots are not atomic.
///
/// Call `restore()` to undo owned pointer changes. Releasing this plan does not
/// restore pointers or run a potentially failing hidden cleanup. Code images
/// published or captured by a successful write stay retained for process lifetime
/// so copied native function pointers remain callable after restoration. Supplied
/// additional code owners have that same lifetime. Importing images remain held
/// while the plan exists. Coordinate all other writers and native code lifetimes.
/// See <doc:SwiftImportedReplacements>.
public final class NativeSwiftImportedReplacement<Implementation> {
    /// Logical state and the current pointer observation.
    public enum Status: Sendable { case prepared, installed, restored, restorationRequired, displaced, unreadable }
    /// One original importing reference and its latest operation results.
    public struct Slot {
        /// Address of the importing pointer, not its code target.
        public let address: UInt
        /// The entry captured during preparation. Nil represents a null weak
        /// reference. It is not a new lookup of the target declaration.
        public let original: Implementation?
        public let status: Status
        /// Last installation and subsequent restoration/rollback results.
        public let mutation: NativeSwiftReplacementMutation?
        public let restoration: NativeSwiftReplacementMutation?
        /// Latest attempt to repair protections left by a partial pointer operation.
        public let protectionRecovery: NativeSwiftReplacementMutation?
    }
    private let storage: SwiftReplacementStorage
    private let originals: [Implementation?]
    init(storage: SwiftReplacementStorage, capture: (SwiftImplementation) -> Implementation) {
        self.storage = storage
        originals = storage.snapshots().map { $0.original.map(capture) }
    }
    /// Copied observations. Reading state never installs or restores anything.
    public var slots: [Slot] {
        storage.snapshots().enumerated().map { index, slot in
            var current: UInt = 0
            let read = ABIReadMemory(slot.address, MemoryLayout<UInt>.size, &current)
            let status: Status
            if read.status != ABIMemoryReadComplete { status = .unreadable }
            else if slot.pending { status = current == slot.after ? .installed : .displaced }
            else if slot.needsRepair { status = .restorationRequired }
            else if slot.wasPublished { status = current == slot.before ? .restored : .displaced }
            else { status = current == slot.before ? .prepared : .displaced }
            return Slot(address: slot.address, original: originals[index], status: status,
                mutation: slot.mutation, restoration: slot.restoration, protectionRecovery: slot.protectionRecovery)
        }
    }
    /// Publishes the compiled replacement at the prepared references.
    ///
    /// The current pointer must still match the captured representation. A
    /// failure attempts to restore earlier writes and preserves both outcomes in
    /// `slots`. Restore outstanding writes before installing this plan again.
    /// The replacement must match Swift context, argument/result lowering,
    /// ownership, and isolation. Matching Swift metatypes alone do not prove this.
    /// - Throws: `NativeSwiftReplacementError` with the failed slot indexes.
    @unsafe public func install() throws { try storage.install() }

    /// Restores captured bits wherever this plan still has an outstanding write.
    /// Never overwrites a different current pointer. Failed restorations can be
    /// retried; inspect `slots` for partial writes and protection errors.
    /// Pointer comparisons cannot detect an unrelated writer's ABA changes.
    public func restore() throws { try storage.restore() }
}

extension NativeSwiftImportedReplacement: @unchecked Sendable where Implementation: Sendable {}

extension ABIRuntime {
    func prepareSwiftImportReplacement(target: ResolvedSymbol, replacement: ResolvedSymbol,
        importer: ImageSelector, provider: ImageSelector?, owner: (any Sendable)?) throws -> SwiftReplacementStorage {
        let selection = try ImportedFunctionSelection(resolver: resolver, declaration: target.declaration,
            importer: importer, provider: provider, language: .swift)
        return try SwiftReplacementStorage(slots: selection.references.map { (UInt($0.address), $0.authentication!) },
            replacement: replacement, retaining: selection, codeOwner: owner)
    }
}

extension NativeSwiftFunction {
    // Swift 6.3 mismanages async task allocations when a same-type requirement
    // decomposes Signature into a parameter pack. Transparent entry thunks keep
    // that requirement out of the implementation frame, including in Debug builds.

    /// Prepares compiled Swift replacement at references in loaded importing images.
    ///
    /// The receiver is the source declaration to select; `replacement` is an
    /// already resolved compiled entry with an exact compatible Swift ABI.
    /// Neither preparation nor installation loads importing images. Direct,
    /// inlined or specialized calls bypassing those references are unaffected.
    /// Same-image references require interposable linking of that image.
    /// - Parameters:
    ///   - replacement: Compiled code, not a capturing Swift closure.
    ///   - importer: Explicit scope of images containing references to change.
    ///   - provider: Optional filter on the dependency recorded in each binding.
    ///   - runtime: Runtime whose import indexes are reused.
    ///   - owner: Additional lifetime owner for previously generated code outside
    ///     loader images. Keep such code alive yourself if no owner is supplied.
    /// - Returns: A plan whose typed originals are available before publication.
    /// - Throws: Declaration, image, import metadata or capture errors.
    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftFunction<(repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftFunctionImplementation<Signature>> where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftFunction<(repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftFunctionImplementation<Signature>> where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftFunction<@Sendable (repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftFunctionImplementation<Signature>> where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftFunction<@Sendable (repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftFunctionImplementation<Signature>> where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @usableFromInline nonisolated(nonsending) func _prepareImportedReplacement<ReplacementSignature>(
        with replacement: NativeSwiftFunction<ReplacementSignature>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftFunctionImplementation<Signature>> {
        guard !isGeneric, !replacement.isGeneric else {
            throw ABIResolutionError.unsupportedDeclaration("Generic imported replacement requires a polymorphic replacement contract; use direct invocation.")
        }
        try SwiftErrorPlan.validateReplacement(replacement.errorPlan, for: errorPlan)
        let storage = try await runtime.prepareSwiftImportReplacement(target: symbol, replacement: replacement.symbol,
            importer: importer, provider: provider, owner: owner)
        return NativeSwiftImportedReplacement(storage: storage) { NativeSwiftFunctionImplementation(self, $0) }
    }
}

extension NativeSwiftMethod {
    /// Prepares replacement of references to a concrete Swift member implementation.
    ///
    /// This changes importing pointers, not a class's metadata dispatch table.
    /// The replacement must have the same physical receiver/context and ownership
    /// contract as the original member. Slot originals use this member's receiver
    /// plan, including mutating/consuming behavior selected at lookup.
    /// Other scope and lifetime requirements match function preparation.
    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftMethod<(repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftMethodImplementation<Signature>> where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftMethod<(repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftMethodImplementation<Signature>> where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftMethod<@Sendable (repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftMethodImplementation<Signature>> where Signature == (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @_transparent
    @unsafe public nonisolated(nonsending) func prepareImportedReplacement<Result, Failure: Error, ReplacementFailure: Error, each Argument>(
        with replacement: NativeSwiftMethod<@Sendable (repeat each Argument) throws(ReplacementFailure) -> Result>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftMethodImplementation<Signature>> where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try await _prepareImportedReplacement(with: replacement, in: importer, from: provider, using: runtime, retaining: owner)
    }

    @usableFromInline nonisolated(nonsending) func _prepareImportedReplacement<ReplacementSignature>(
        with replacement: NativeSwiftMethod<ReplacementSignature>, in importer: ImageSelector,
        from provider: ImageSelector? = nil, using runtime: ABIRuntime = .shared, retaining owner: (any Sendable)? = nil
    ) async throws -> NativeSwiftImportedReplacement<NativeSwiftMethodImplementation<Signature>> {
        try SwiftErrorPlan.validateReplacement(replacement.errorPlan, for: errorPlan)
        let storage = try await runtime.prepareSwiftImportReplacement(target: symbol, replacement: replacement.symbol,
            importer: importer, provider: provider, owner: owner)
        return NativeSwiftImportedReplacement(storage: storage) { NativeSwiftMethodImplementation(self, $0) }
    }
}
