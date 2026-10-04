import ABIBridgeRuntime
import ABIBridgeCore
import Synchronization

/// Owns an authenticated code pointer and its containing image, when available.
final class SwiftImplementation: Sendable {
    let runtime: RuntimeImplementation
    var handle: OpaquePointer { runtime.handle }
    var owner: (any Sendable)? { runtime.owner }
    var image: NativeImage? { runtime.image.map(NativeImage.init) }
    var function: ABIUnmanagedFunction { runtime.function }
    var generation: UInt64 { runtime.generation }
    init(_ runtime: RuntimeImplementation) { self.runtime = runtime }
    init?(
        bits: UInt,
        storage: UnsafeRawPointer,
        authentication: NativePointerAuthentication,
        retaining owner: (any Sendable)?
    ) throws {
        guard
            let runtime = try withRuntimeErrors({
                try RuntimeImplementation(
                    bits: bits,
                    storage: storage,
                    authentication: authentication.runtimeValue,
                    retaining: owner
                )
            })
        else { return nil }
        self.runtime = runtime
    }
    init(function: ABIUnmanagedFunction, retaining owner: (any Sendable)?) throws {
        runtime = try withRuntimeErrors {
            try RuntimeImplementation(function: function, retaining: owner)
        }
    }
}

// Saved native pointers can outlive restoration and their Swift handles. Pin
// image generations once; anonymous code or additional owners need their own
// keepalive. No owner is released while holding this lock.
private enum PublishedSwiftCode {
    struct Pins {
        var images: [UInt64: SwiftImplementation] = [:]
        var owned: [ObjectIdentifier: SwiftImplementation] = [:]
    }
    static let pins = Mutex(Pins())
    static func retain(_ implementation: SwiftImplementation) {
        pins.withLock { pins in
            if implementation.generation != 0 && implementation.owner == nil {
                if pins.images[implementation.generation] == nil {
                    pins.images[implementation.generation] = implementation
                }
            } else {
                pins.owned[ObjectIdentifier(implementation)] = implementation
            }
        }
    }
}

/// A captured previous function with the source request's supplied Swift ABI.
/// It calls the captured entry directly, bypassing the replaced import slot.
/// The entry may itself be compiler-instrumented or interposed.
public struct NativeSwiftFunctionImplementation<Signature>: Sendable {
    private let function: NativeSwiftFunction<Signature>
    /// The declaration whose importing reference was captured, not the name of
    /// an implementation installed earlier by another writer.
    public var declaration: NativeDeclaration { function.symbol.declaration }
    init(_ prototype: NativeSwiftFunction<Signature>, _ entry: SwiftImplementation) {
        function = prototype.capturing(entry)
    }
    /// Invokes the captured code with the original function's supplied contract.
    /// The caller satisfies the function's ABI, ownership and isolation rules.
    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) throws -> Result where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe function.unsafeInvoke(repeat each values)
    }

    @unsafe public func unsafeInvoke<Result, Failure: Error, each Argument>(
        _ values: repeat each Argument
    ) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe function.unsafeInvoke(repeat each values)
    }
}

/// A previous member implementation with the original receiver contract.
/// This does not redispatch the member or discover a different receiver layout.
public struct NativeSwiftMethodImplementation<Signature>: Sendable {
    private let method: NativeSwiftMethod<Signature>
    /// The declaration whose reference was captured; not an inferred code identity.
    public var declaration: NativeDeclaration { method.symbol.declaration }
    init(_ prototype: NativeSwiftMethod<Signature>, _ entry: SwiftImplementation) {
        method = prototype.capturing(entry)
    }
    /// Invokes a captured class or nonmutating value method on the supplied receiver.
    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver,
        _ values: repeat each Argument
    ) throws -> Result where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe method.unsafeInvoke(on: receiver, repeat each values)
    }

    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: Receiver,
        _ values: repeat each Argument
    ) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe method.unsafeInvoke(on: receiver, repeat each values)
    }
    /// Invokes the captured member and performs its declared receiver writeback.
    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver,
        _ values: repeat each Argument
    ) throws -> Result where Signature == (repeat each Argument) throws(Failure) -> Result {
        try unsafe method.unsafeInvoke(on: &receiver, repeat each values)
    }

    @unsafe public func unsafeInvoke<Receiver, Result, Failure: Error, each Argument>(
        on receiver: inout Receiver,
        _ values: repeat each Argument
    ) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try unsafe method.unsafeInvoke(on: &receiver, repeat each values)
    }
}

/// Publication or restoration results from a compiled Swift replacement.
public struct NativeSwiftReplacementMutation: Sendable {
    /// The pointer-slot operation status. Zero means the operation completed.
    public let status: Int32
    /// Whether the pointer was written, including a partial protection failure.
    public let didWrite: Bool
    /// The pointer bits observed by the operation, when available.
    public let observed: UInt
    /// The original Mach error, or zero.
    public let systemErrorCode: Int32
    /// Errors restoring current and maximum protections, respectively.
    public let restoreProtectionError: Int32
    public let restoreMaximumError: Int32
    /// Original page protections and VM flags.
    public let protectionBefore: Int32
    public let maximumBefore: Int32
    public let regionFlags: UInt32
    init(_ value: ABIPointerSlotResult) {
        status = value.status; didWrite = value.didWrite; observed = value.observed
        systemErrorCode = value.systemErrorCode
        restoreProtectionError = value.restoreProtectionError;
        restoreMaximumError = value.restoreMaximumError
        protectionBefore = value.protectionBefore; maximumBefore = value.maximumBefore;
        regionFlags = value.regionFlags
    }
}

/// A compiled replacement could not complete every requested pointer operation.
/// The plan remains available for inspecting each slot and retrying restoration.
public struct NativeSwiftReplacementError: Error, Sendable {
    /// Which explicit operation failed.
    public enum Operation: Sendable { case install, restore }
    public let operation: Operation
    /// Slot indexes that failed publication or restoration. Rollback failures
    /// remain visible in the plan's slot snapshots too.
    public let failedIndices: [Int]
    /// Failures during rollback after a failed installation.
    public let restorationFailedIndices: [Int]
    init(operation: Operation, failedIndices: [Int], restorationFailedIndices: [Int] = []) {
        self.operation = operation; self.failedIndices = failedIndices;
        self.restorationFailedIndices = restorationFailedIndices
    }
}

struct SwiftReplacementTransport: Sendable {
    var exchange: @Sendable (UInt, UInt, UInt) -> ABIPointerSlotResult
    var repair: @Sendable (UInt, UInt, Int32, Int32, Bool, Bool) -> ABIPointerSlotResult
    static let live = Self(
        exchange: {
            ABICompareExchangePointerSlot(UnsafeMutableRawPointer(bitPattern: $0), $1, $2)
        },
        repair: {
            ABIRestorePointerSlotProtection(
                UnsafeMutableRawPointer(bitPattern: $0),
                $1,
                $2,
                $3,
                $4,
                $5
            )
        }
    )
}

final class SwiftReplacementStorage: @unchecked Sendable {
    struct Slot {
        let address: UInt
        let before: UInt
        let after: UInt
        let original: SwiftImplementation?
        var pending = false
        var wasPublished = false
        var mutation: NativeSwiftReplacementMutation?
        var restoration: NativeSwiftReplacementMutation?
        var protectionRecovery: NativeSwiftReplacementMutation?
        var desiredProtection: Int32?
        var desiredMaximum: Int32?
        var needsRepair: Bool { desiredProtection != nil || desiredMaximum != nil }
        mutating func recordProtectionFailure(_ result: ABIPointerSlotResult) {
            if result.restoreProtectionError != 0 && desiredProtection == nil {
                desiredProtection = result.protectionBefore
            }
            if result.restoreMaximumError != 0 && desiredMaximum == nil {
                desiredMaximum = result.maximumBefore
            }
        }
    }
    struct State { var slots: [Slot] }
    private let state: Mutex<State>
    private let replacement: SwiftImplementation
    private let storageOwners: Any
    private let transport: SwiftReplacementTransport

    struct CapturedSlot {
        let address: UInt
        let before: UInt
        let original: SwiftImplementation?
        let authentication: NativePointerAuthentication
        let asyncEntry: SwiftAsyncEntry?
    }

    static func capture(
        _ slots: [(UInt, NativePointerAuthentication)],
        retaining owner: (any Sendable)?,
        asyncDescriptors: Bool = false
    ) throws -> [CapturedSlot] {
        try slots.map { address, authentication in
            var before: UInt = 0
            guard
                ABIReadMemory(address, MemoryLayout<UInt>.size, &before).status
                    == ABIMemoryReadComplete,
                let storage = UnsafeRawPointer(bitPattern: address)
            else { throw ABIResolutionError.invalidAddress }
            if asyncDescriptors {
                guard
                    let descriptor = ABIUnsafeAuthenticatePointerSlot(
                        before,
                        storage,
                        authentication.keyCode,
                        authentication.discriminator,
                        authentication.addressDiversity
                    )
                else { throw ABIResolutionError.invalidAddress }
                let entry = try SwiftAsyncEntry(descriptor: descriptor)
                let image = try swiftImplementationImage(containing: descriptor)
                let original = try SwiftImplementation(
                    function: entry.function,
                    retaining: (owner, entry, image)
                )
                return CapturedSlot(
                    address: address,
                    before: before,
                    original: original,
                    authentication: authentication,
                    asyncEntry: entry
                )
            }
            return CapturedSlot(
                address: address,
                before: before,
                original: try SwiftImplementation(
                    bits: before,
                    storage: storage,
                    authentication: authentication,
                    retaining: owner
                ),
                authentication: authentication,
                asyncEntry: nil
            )
        }
    }

    convenience init(
        slots: [(UInt, NativePointerAuthentication)],
        replacement symbol: ResolvedSymbol,
        retaining owners: Any,
        codeOwner: (any Sendable)?,
        transport: SwiftReplacementTransport = .live
    ) throws {
        let replacement = try unsafe symbol.withUnsafeAddress { address in
            try SwiftImplementation(
                bits: UInt(bitPattern: address),
                storage: address,
                authentication: .unsigned,
                retaining: codeOwner
            )!
        }
        try self.init(
            captured: Self.capture(slots, retaining: codeOwner),
            replacement: replacement,
            retaining: owners,
            transport: transport
        )
    }

    init(
        captured: [CapturedSlot],
        replacement: SwiftImplementation,
        retaining owners: Any,
        replacementDescriptor: UnsafeRawPointer? = nil,
        transport: SwiftReplacementTransport = .live
    ) throws {
        self.transport = transport
        storageOwners = owners
        self.replacement = replacement
        let prepared = try captured.map { slot in
            let authentication = slot.authentication
            var after: UInt = 0
            let encoded =
                if let replacementDescriptor {
                    ABIEncodePointerSlotData(
                        replacementDescriptor,
                        UnsafeRawPointer(bitPattern: slot.address),
                        authentication.keyCode,
                        authentication.discriminator,
                        authentication.addressDiversity,
                        &after
                    )
                } else {
                    ABIEncodePointerSlotFunction(
                        replacement.function,
                        UnsafeRawPointer(bitPattern: slot.address),
                        authentication.keyCode,
                        authentication.discriminator,
                        authentication.addressDiversity,
                        &after
                    )
                }
            guard encoded else { throw ABIResolutionError.invalidAddress }
            return Slot(
                address: slot.address,
                before: slot.before,
                after: after,
                original: slot.original
            )
        }
        state = Mutex(State(slots: prepared))
    }

    func snapshots() -> [Slot] { state.withLock { $0.slots } }

    func install() throws {
        try state.withLock { state in
            let pending = state.slots.indices.filter {
                state.slots[$0].pending || state.slots[$0].needsRepair
            }
            guard pending.isEmpty else {
                throw NativeSwiftReplacementError(operation: .install, failedIndices: pending)
            }
            for index in state.slots.indices {
                let slot = state.slots[index]
                let result = transport.exchange(slot.address, slot.before, slot.after)
                state.slots[index].mutation = NativeSwiftReplacementMutation(result)
                state.slots[index].restoration = nil
                state.slots[index].protectionRecovery = nil
                state.slots[index].recordProtectionFailure(result)
                if result.didWrite {
                    state.slots[index].pending = true
                    state.slots[index].wasPublished = true
                    PublishedSwiftCode.retain(replacement)
                    if let original = slot.original { PublishedSwiftCode.retain(original) }
                }
                if result.status != ABIPointerSlotComplete {
                    let failures = restore(&state)
                    throw NativeSwiftReplacementError(
                        operation: .install,
                        failedIndices: [index],
                        restorationFailedIndices: failures
                    )
                }
            }
        }
    }

    func restore() throws {
        try state.withLock { state in
            let failures = restore(&state)
            if !failures.isEmpty {
                throw NativeSwiftReplacementError(operation: .restore, failedIndices: failures)
            }
        }
    }

    private func restore(_ state: inout State) -> [Int] {
        for index in state.slots.indices.reversed() where state.slots[index].pending {
            let slot = state.slots[index]
            let result = transport.exchange(slot.address, slot.after, slot.before)
            state.slots[index].restoration = NativeSwiftReplacementMutation(result)
            state.slots[index].recordProtectionFailure(result)
            if result.didWrite
                || (result.status == ABIPointerSlotDisplaced && result.observed == slot.before)
            {
                state.slots[index].pending = false
            }
        }
        for index in state.slots.indices where state.slots[index].needsRepair {
            let slot = state.slots[index]
            let result = transport.repair(
                slot.address,
                slot.pending ? slot.after : slot.before,
                slot.desiredProtection ?? 0,
                slot.desiredMaximum ?? 0,
                slot.desiredProtection != nil,
                slot.desiredMaximum != nil
            )
            state.slots[index].protectionRecovery = NativeSwiftReplacementMutation(result)
            if result.status == ABIPointerSlotComplete {
                state.slots[index].desiredProtection = nil
                state.slots[index].desiredMaximum = nil
            }
        }
        return state.slots.indices.filter { state.slots[$0].pending || state.slots[$0].needsRepair }
    }
}
