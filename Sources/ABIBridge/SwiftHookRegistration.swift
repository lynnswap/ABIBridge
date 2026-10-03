import ABIBridgeCore
import Synchronization

struct SwiftHookSlotKey: Hashable, Sendable { let address: UInt; let generation: UInt64 }
struct SwiftHookReference: Sendable {
    let key: SwiftHookSlotKey
    let authentication: NativePointerAuthentication
    var asyncDescriptor = false
}

final class SwiftHookGroup: @unchecked Sendable {
    let key: SwiftHookSlotKey
    let authentication: NativePointerAuthentication
    let signature: SwiftHookSignature
    let dispatcher: SwiftHookDispatcher
    let storage: SwiftReplacementStorage
    private let additionalOwners = Mutex<[any Sendable]>([])
    init(key: SwiftHookSlotKey, authentication: NativePointerAuthentication, signature: SwiftHookSignature,
         retaining owner: Any, codeOwner: (any Sendable)?, transport: SwiftReplacementTransport, asyncDescriptor: Bool = false) throws {
        self.key = key; self.authentication = authentication; self.signature = signature
        let captured = try SwiftReplacementStorage.capture([(key.address, authentication)], retaining: codeOwner, asyncDescriptors: asyncDescriptor)
        guard let original = captured[0].original else {
            throw ABIResolutionError.unsupportedDeclaration("A managed Swift hook requires a nonnull predecessor for native fallback.")
        }
        dispatcher = SwiftHookDispatcher(signature: signature)
        let callback = try SwiftGeneratedCallback(dispatcher: dispatcher, original: original, contextSize: captured[0].asyncEntry?.contextSize)
        let code = try SwiftImplementation(function: callback.function, retaining: callback)
        storage = try SwiftReplacementStorage(captured: captured, replacement: code, retaining: owner, replacementDescriptor: asyncDescriptor ? callback.descriptor : nil, transport: transport)
    }
    func bits() -> UInt? {
        var bits: UInt = 0
        return ABIReadMemory(key.address, MemoryLayout<UInt>.size, &bits).status == ABIMemoryReadComplete ? bits : nil
    }
    func retainCodeOwner(_ owner: (any Sendable)?) {
        if let owner { additionalOwners.withLock { $0.append(owner) } }
    }
}

final class SwiftHookSlotRecord: Sendable {
    struct Outcomes: Sendable {
        var mutation: NativeSwiftReplacementMutation?
        var rollback: NativeSwiftReplacementMutation?
        var protectionRecovery: NativeSwiftReplacementMutation?
    }
    let group: SwiftHookGroup
    let outcomes = Mutex(Outcomes())
    init(_ group: SwiftHookGroup) { self.group = group }
    func captureMutation() { let snapshot = group.storage.snapshots()[0]; outcomes.withLock { $0.mutation = snapshot.mutation } }
    func captureRollback() {
        let snapshot = group.storage.snapshots()[0]
        outcomes.withLock { $0.rollback = snapshot.restoration; $0.protectionRecovery = snapshot.protectionRecovery }
    }
}

/// An imported Swift registration with independently released callback captures.
///
/// Later registrations wrap earlier ones. Published dispatcher code and its
/// importing/provider image leases remain process-lived, including when empty;
/// copied native pointers can still call the captured predecessor.
public final class NativeSwiftImportedFunctionHook: @unchecked Sendable {
    /// Logical registration state and current pointer observation.
    public enum Status: Sendable {
        /// This callback is inactive, regardless of the physical pointer contents.
        case invalidated
        /// The callback is active and the observed pointer selects its dispatcher.
        case active
        /// Another writer changed the pointer while this callback remains registered.
        case displaced
        /// The registered pointer could not be read for this observation.
        case unreadable
    }
    /// One selected reference and this registration's physical operation outcomes.
    public struct Slot: Sendable {
        /// Address of the importing reference, not its current code target.
        public let address: UInt
        /// Logical state combined with a current, non-atomic pointer observation.
        public let status: Status
        /// Nil when this registration reused an already installed dispatcher.
        public let mutation: NativeSwiftReplacementMutation?
        /// Latest physical rollback attempted after this registration failed.
        public let rollback: NativeSwiftReplacementMutation?
        /// Latest attempt to repair page protections left by a failed operation.
        public let protectionRecovery: NativeSwiftReplacementMutation?
    }
    let node: SwiftHookNode
    let records: [SwiftHookSlotRecord]
    init(node: SwiftHookNode, records: [SwiftHookSlotRecord]) { self.node = node; self.records = records }
    /// Copied observations, including partial effects of a failed installation.
    public var slots: [Slot] {
        let active = node.snapshot() != nil
        return records.map { record in
            let status: Status
            if !active { status = .invalidated }
            else if let bits = record.group.bits() { status = bits == record.group.storage.snapshots()[0].after ? .active : .displaced }
            else { status = .unreadable }
            let outcomes = record.outcomes.withLock { $0 }
            return Slot(address: record.group.key.address, status: status, mutation: outcomes.mutation,
                rollback: outcomes.rollback, protectionRecovery: outcomes.protectionRecovery)
        }
    }
    /// Removes this callback without waiting for already-entered calls. Leaves
    /// stable pass-through code installed and never overwrites another writer.
    public func invalidate() {
        node.invalidate()
        for record in records { record.group.dispatcher.remove(node) }
    }
    /// Retries pointer/protection rollback still owned by this failed installation.
    /// No operation is performed on slots that no longer need this recovery.
    public func recoverFailedInstallation() async throws {
        try await SwiftHookRegistry.shared.recover(node: ObjectIdentifier(node), records: records)
    }
    deinit { invalidate() }
}

/// A managed Swift registration failed after slot activation began.
public struct NativeSwiftHookInstallationError: Error {
    /// The publication failure that initiated invalidation and rollback.
    public let underlyingError: any Error
    /// Index into the registration's slots where publication failed.
    public let failedIndex: Int
    /// Already invalidated. Its observations preserve partial writes and rollback
    /// failures; use recoverFailedInstallation() to retry owned recovery.
    public let registration: NativeSwiftImportedFunctionHook
}

actor SwiftHookRegistry {
    static let shared = SwiftHookRegistry()
    private struct Entry { let group: SwiftHookGroup; var recoveryOwner: ObjectIdentifier? }
    private var entries: [SwiftHookSlotKey: Entry] = [:]

    func register(selection: ImportedFunctionSelection, signature: SwiftHookSignature, handler: SwiftHookHandler,
                  codeOwner: (any Sendable)? = nil, transport: SwiftReplacementTransport = .live) throws -> NativeSwiftImportedFunctionHook {
        try register(references: selection.references.map {
            SwiftHookReference(key: .init(address: UInt($0.address), generation: $0.image.identity.loadGeneration), authentication: $0.authentication!)
        }, retaining: selection, signature: signature, handler: handler, codeOwner: codeOwner, transport: transport)
    }

    func register(references: [SwiftHookReference], retaining owner: any Sendable,
                  signature: SwiftHookSignature, handler: SwiftHookHandler,
                  codeOwner: (any Sendable)? = nil, transport: SwiftReplacementTransport = .live) throws -> NativeSwiftImportedFunctionHook {
        var records: [SwiftHookSlotRecord] = []
        var install: [Bool] = []
        // Resolve/capture every predecessor and allocate callback state before
        // exposing the new node through any existing or newly written entry.
        for reference in references {
            let key = reference.key
            let authentication = reference.authentication
            let group: SwiftHookGroup
            if let entry = entries[key] {
                guard entry.recoveryOwner == nil else {
                    throw ABIResolutionError.unsupportedDeclaration("This slot has pending recovery from an earlier failed Swift hook installation.")
                }
                group = entry.group
                guard group.authentication == authentication && group.signature.matches(signature) else {
                    throw ABIResolutionError.unsupportedDeclaration("The existing Swift hook uses a different signature, ownership or authentication contract.")
                }
                let snapshot = group.storage.snapshots()[0]
                guard let current = group.bits(), current == snapshot.after || (!snapshot.pending && !snapshot.needsRepair && current == snapshot.before) else {
                    throw ABIResolutionError.unsupportedDeclaration("Another writer displaced this Swift hook entry.")
                }
                install.append(current != snapshot.after)
            } else {
                group = try SwiftHookGroup(key: key, authentication: authentication, signature: signature,
                    retaining: owner, codeOwner: codeOwner, transport: transport, asyncDescriptor: reference.asyncDescriptor)
                install.append(true)
            }
            records.append(SwiftHookSlotRecord(group))
        }
        let node = SwiftHookNode(handler, signature: signature)
        let registration = NativeSwiftImportedFunctionHook(node: node, records: records)
        var activated: [SwiftHookSlotRecord] = []
        for (index, record) in records.enumerated() {
            let group = record.group
            group.retainCodeOwner(codeOwner)
            group.dispatcher.append(node)
            do {
                if install[index] {
                    activated.append(record)
                    try group.storage.install()
                    record.captureMutation()
                }
                entries[group.key] = Entry(group: group)
            } catch {
                record.captureMutation(); record.captureRollback()
                registration.invalidate()
                for previous in activated.reversed() {
                    // restore() preserves displacement and records every failed
                    // protection repair; the original install error remains primary.
                    do { try previous.group.storage.restore() } catch { }
                    previous.captureRollback()
                    let snapshot = previous.group.storage.snapshots()[0]
                    if snapshot.wasPublished || snapshot.needsRepair {
                        entries[previous.group.key] = Entry(group: previous.group,
                            recoveryOwner: snapshot.pending || snapshot.needsRepair ? ObjectIdentifier(node) : nil)
                    }
                }
                throw NativeSwiftHookInstallationError(underlyingError: error, failedIndex: index, registration: registration)
            }
        }
        return registration
    }

    func recover(node: ObjectIdentifier, records: [SwiftHookSlotRecord]) throws {
        var failed: [Int] = []
        for (index, record) in records.enumerated() {
            let key = record.group.key
            guard entries[key]?.recoveryOwner == node else { continue }
            do { try record.group.storage.restore() } catch { failed.append(index) }
            record.captureRollback()
            let snapshot = record.group.storage.snapshots()[0]
            if !snapshot.pending && !snapshot.needsRepair {
                if snapshot.wasPublished { entries[key]?.recoveryOwner = nil }
                else { entries.removeValue(forKey: key) }
            }
        }
        if !failed.isEmpty { throw NativeSwiftReplacementError(operation: .restore, failedIndices: failed) }
    }
}
