import ABIBridgeCore
import Foundation

/// A virtual continuation was used after return or on another thread.
public enum NativeVirtualInvocationError: Error, Sendable { case expiredInvocation, wrongThread }

/// The incoming subobject and a callback-scoped continuation. The receiver and
/// other pointers remain borrowed; this value does not extend the native call.
public struct NativeVirtualInvocation<Result, each Argument> {
    /// The exact incoming base-subobject pointer, without a complete-object cast.
    public let receiver: UnsafeMutableRawPointer
    fileprivate let frame: FunctionCallbackFrame
    fileprivate let signature: FunctionCallbackSignature<Result, repeat each Argument>

    /// Calls the next callback or captured adjustment thunk with the same receiver.
    /// May run only on the incoming thread before this callback returns.
    public func proceed(_ values: repeat each Argument) throws -> Result {
        do {
            return try frame.use { pointer in
                let storage = NativeValueStorage(size: MemoryLayout<UnsafeMutableRawPointer>.size, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
                storage.store(receiver)
                return try signature.proceed(pointer, prefix: [storage], repeat each values)
            }
        }
        catch FunctionCallbackFrameError.expiredInvocation { throw NativeVirtualInvocationError.expiredInvocation }
        catch FunctionCallbackFrameError.wrongThread { throw NativeVirtualInvocationError.wrongThread }
    }
}

/// Owns one shared-table callback. Copies of the reference share registration.
/// Later callbacks wrap earlier ones. In-flight calls retain immutable snapshots.
/// Published callable storage, image leases and table owners remain process-lived;
/// invalidation releases callback captures after the last active snapshot ends.
public final class NativeVirtualHook: @unchecked Sendable {
    /// Logical registration state and observed contents of its shared slot.
    public enum Status: Sendable { case invalidated, active, displaced, unreadable }
    /// A copied publication or rollback outcome, including incomplete cleanup.
    public struct Mutation: Sendable {
        /// Native mutation status; zero is complete. Fields not reached by the
        /// operation remain zero; interpret them together with this status.
        public let status: Int32
        /// Whether this operation published its pointer, including partial failure.
        public let didWrite: Bool
        /// Stored pointer bits observed before the comparison, when read succeeded.
        public let observed: UInt
        /// Original Mach failure code, or zero.
        public let systemErrorCode: Int32
        /// Failures restoring current and maximum page protection, respectively.
        public let restoreProtectionError: Int32
        public let restoreMaximumError: Int32
        /// Current/maximum protection and VM flags from the original region query.
        public let protectionBefore: Int32
        public let maximumBefore: Int32
        public let regionFlags: UInt32
        init(_ value: ABIPointerSlotResult) {
            status = value.status; didWrite = value.didWrite; observed = value.observed
            systemErrorCode = value.systemErrorCode
            restoreProtectionError = value.restoreProtectionError; restoreMaximumError = value.restoreMaximumError
            protectionBefore = value.protectionBefore; maximumBefore = value.maximumBefore; regionFlags = value.regionFlags
        }
    }
    /// The selected slot's state and immutable installation/rollback effects.
    public struct Slot: Sendable {
        public let address: UInt
        public let status: Status
        public let mutation: Mutation
        public let rollback: Mutation
    }
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    /// Nil if preparation failed before selecting a slot. Remains available after
    /// invalidation or external displacement; status is a point-in-time observation.
    public var slot: Slot? {
        guard ABIVirtualHookHasEntry(handle) else { return nil }
        let status: Status
        switch ABIVirtualHookStatus(handle) {
        case 0: status = .invalidated
        case 1: status = .active
        case 2: status = .displaced
        default: status = .unreadable
        }
        return Slot(address: ABIVirtualHookSlot(handle), status: status,
            mutation: Mutation(ABIVirtualHookMutation(handle)), rollback: Mutation(ABIVirtualHookRollback(handle)))
    }
    /// Removes this callback from future snapshots without waiting or restoring
    /// the slot. A pointer copied after publication stays callable as pass-through.
    public func invalidate() { ABIInvalidateVirtualHook(handle) }
    deinit { ABIReleaseVirtualHook(handle) }
}

/// An install failure retaining any partial effects and rollback results.
public struct NativeVirtualHookInstallationError: Error {
    public let underlyingError: any Error
    /// Invalidated registration; inspect its slot for partial publication/cleanup.
    public let registration: NativeVirtualHook
}

extension NativeVTable.Entry {
    /// Intercepts calls through this entry for every object using the shared table.
    ///
    /// The signature describes explicit C-compatible arguments, excluding this.
    /// The callback runs synchronously on the incoming thread; its continuation
    /// preserves the incoming subobject and any adjustment/covariant-return thunk.
    /// If it throws before proceeding, the original arguments pass through;
    /// otherwise the last completed result is preserved and onFailure is notified.
    ///
    /// Direct/devirtualized calls bypass the entry. Construction/destruction,
    /// native exception unwinding and nontrivial C++ ownership need native adapters.
    /// Table layout, actual signature, thread requirements and synchronization with
    /// external writers remain caller responsibilities. Protected tables can refuse
    /// installation. Published entries retain table owners for process lifetime;
    /// use callback captures for resources that should release on invalidation.
    /// - Throws: Signature/conversion errors or `NativeVirtualHookInstallationError`
    ///   preserving partial publication and failed cleanup.
    @unsafe public func hookSharedCalls<Result, each Argument>(
        as signature: ((repeat each Argument) -> Result).Type,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeVirtualInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeVirtualHook {
        let prepared = try FunctionCallbackSignature<Result, repeat each Argument>()
        var types: [CValueType] = []
        for codec in repeat each prepared.arguments { types.append(codec.type) }
        let box = FunctionCallbackBox(result: prepared.result.type, parameters: types, invoke: { pointer in
            let frame = FunctionCallbackFrame(pointer); defer { frame.expire() }
            var error: OpaquePointer?
            guard let receiver = ABIVirtualInvocationReceiver(pointer, &error) else {
                if let error { throw consumeNativeCallFailure(error) }
                throw ABIResolutionError.invalidAddress
            }
            let values = try prepared.decodeArguments(pointer, startingAt: 1)
            let output = try body(.init(receiver: receiver, frame: frame, signature: prepared), repeat each values)
            if Result.self == Void.self {
                guard ABIVirtualSetResult(pointer, nil, 0, &error) else { throw consumeNativeCallFailure(error) }
            } else {
                let result = try prepared.result.encode(output)
                guard ABIVirtualSetResult(pointer, result.address, prepared.result.type.size, &error) else { throw consumeNativeCallFailure(error) }
            }
        }, failure: onFailure)
        let parameters: [OpaquePointer?] = types.map(\.handle)
        let context = Unmanaged.passRetained(box).toOpaque()
        let owner = Unmanaged.passRetained(table.storage).toOpaque()
        let hook = withExtendedLifetime(image) { unsafe table.storage.withUnsafeBytes { bytes in
            let info = ABIVirtualEntryInfo(addressPoint: bytes.baseAddress, entryCount: table.entryCount, index: index,
                key: authentication.keyCode, discriminator: authentication.discriminator, addressDiversity: authentication.addressDiversity)
            return parameters.withUnsafeBufferPointer { parameters in
                ABIInstallSharedVirtualHook(info, owner, { Unmanaged<NativeValue>.fromOpaque($0!).release() },
                    box.result.handle, parameters.baseAddress, parameters.count, context,
                    { context, call, _ in invokeFunctionCallback(Unmanaged<FunctionCallbackBox>.fromOpaque(context!).takeUnretainedValue(), call!) },
                    { context, error in
                        Unmanaged<FunctionCallbackBox>.fromOpaque(context!).takeUnretainedValue().failure(virtualHookFailure(error!))
                    }, { Unmanaged<FunctionCallbackBox>.fromOpaque($0!).release() })!
            }
        } }
        let registration = NativeVirtualHook(hook)
        if let error = ABIVirtualHookFailure(hook) {
            throw NativeVirtualHookInstallationError(underlyingError: virtualHookFailure(error), registration: registration)
        }
        return registration
    }
}

private func virtualHookFailure(_ error: OpaquePointer) -> NSError {
    NSError(domain: "ABIBridge.VirtualHook", code: Int(ABIResolutionFailureCode(error)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: ABIResolutionFailureMessage(error))])
}
