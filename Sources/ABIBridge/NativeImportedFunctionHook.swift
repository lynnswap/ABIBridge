import ABIBridgeCore
import Foundation
import Darwin

/// A scoped imported-function continuation was used after return or on another thread.
public enum NativeImportedInvocationError: Error, Sendable { case expiredInvocation, wrongThread }

/// A continuation valid only during this callback and on its incoming thread.
/// `proceed` calls the next registered callback and then this slot's predecessor;
/// it does not call the imported symbol again. Escaping this value does not keep
/// its invocation alive. Native arguments and pointer results remain borrowed.
public struct NativeImportedFunctionInvocation<Result, each Argument> {
    fileprivate let frame: FunctionCallbackFrame
    fileprivate let signature: FunctionCallbackSignature<Result, repeat each Argument>
    /// Calls the next implementation with the supplied arguments. A later
    /// callback error preserves the most recently completed continuation result.
    public func proceed(_ values: repeat each Argument) throws -> Result {
        do { return try frame.use { try signature.proceed($0,repeat each values) } }
        catch FunctionCallbackFrameError.expiredInvocation { throw NativeImportedInvocationError.expiredInvocation }
        catch FunctionCallbackFrameError.wrongThread { throw NativeImportedInvocationError.wrongThread }
    }
}

/// Owns an imported-function registration across the selected loaded images.
/// Later registrations wrap earlier ones. In-flight calls retain snapshots;
/// invalidation affects future calls and never overwrites another writer.
/// Published entries and their image/code leases remain process-lived, including
/// empty pass-through entries. Callback captures are released independently.
public final class NativeImportedFunctionHook: @unchecked Sendable {
    /// Logical registration state and a snapshot of the slot's current contents.
    public enum Status: Sendable { case invalidated, active, displaced, unreadable }
    /// A copied publication or physical rollback result.
    public struct Mutation: Sendable {
        /// Native mutation status; zero is complete, other values identify failure.
        public let status: Int32
        /// Whether this operation published its pointer, including partial failure.
        public let didWrite: Bool
        /// Original native Mach failure code, or zero.
        public let systemErrorCode: Int32
        /// Failure restoring current and maximum protections, respectively.
        public let restoreProtectionError: Int32
        public let restoreMaximumError: Int32
        init(_ value: ABIPointerSlotResult) {
            status=value.status; didWrite=value.didWrite; systemErrorCode=value.systemErrorCode
            restoreProtectionError=value.restoreProtectionError; restoreMaximumError=value.restoreMaximumError
        }
    }
    /// A slot's copied state and installation/rollback outcomes.
    public struct Slot: Sendable {
        public let address: UInt
        public let status: Status
        public let mutation: Mutation
        public let rollback: Mutation
    }
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle=handle }
    /// Snapshots remain available after invalidation or external displacement.
    public var slots: [Slot] {
        (0..<ABIImportedHookCount(handle)).map { index in
            let status: Status
            switch ABIImportedHookStatus(handle,index) { case 0: status = .invalidated; case 1: status = .active; case 2: status = .displaced; default: status = .unreadable }
            return Slot(address: ABIImportedHookSlot(handle,index),status: status,
                mutation: Mutation(ABIImportedHookMutation(handle,index)),rollback: Mutation(ABIImportedHookRollback(handle,index)))
        }
    }
    /// Idempotently removes this callback without waiting for incoming calls.
    /// Does not restore import pointers or free published callable storage.
    public func invalidate() { ABIInvalidateImportedHook(handle) }
    deinit { ABIReleaseImportedHook(handle) }
}

/// Preserves the original install failure, failed slot and any partial effects.
public struct NativeImportedHookInstallationError: Error {
    public let underlyingError: any Error
    /// Nil for declaration/signature preparation failure before a slot is selected.
    public let failedIndex: Int?
    /// Invalidated registration; inspect its slots for publication/rollback results.
    public let registration: NativeImportedFunctionHook
}

func prepareImportedCallback<Result, each Argument>(
    as signature: ((repeat each Argument) -> Result).Type,
    onFailure: @escaping @Sendable (any Error) -> Void,
    body: @escaping @Sendable (NativeImportedFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
) throws -> FunctionCallbackBox {
    let prepared = try FunctionCallbackSignature<Result, repeat each Argument>()
    var types: [CValueType] = []
    for codec in repeat each prepared.arguments { types.append(codec.type) }
    return FunctionCallbackBox(result: prepared.result.type, parameters: types, invoke: { pointer in
        let frame = FunctionCallbackFrame(pointer); defer { frame.expire() }
        let values = try prepared.decodeArguments(pointer)
        let output = try body(.init(frame: frame,signature: prepared),repeat each values)
        var error: OpaquePointer?
        if Result.self == Void.self {
            guard ABIImportedSetResult(pointer,nil,0,&error) else { throw consumeNativeCallFailure(error) }
        } else {
            let storage = try prepared.result.encode(output)
            guard ABIImportedSetResult(pointer,storage.address,prepared.result.type.size,&error) else { throw consumeNativeCallFailure(error) }
        }
    }, failure: onFailure)
}

func importedHookFailure(_ error: OpaquePointer) -> NSError {
    NSError(domain: "ABIBridge.ImportedHook", code: Int(ABIResolutionFailureCode(error)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: ABIResolutionFailureMessage(error))])
}

extension ABIRuntime {
    /// Hooks supported C ABI calls through references in the selected loaded images.
    ///
    /// `importer` identifies callers, while `provider` optionally filters the
    /// recorded dependency name (including a reexport facade). Neither loads images.
    /// Source names are resolved automatically; no mangled string is required.
    /// Callbacks run synchronously on the incoming thread, without an actor hop.
    /// If a callback throws before proceeding, its original arguments pass through;
    /// otherwise its latest completed result is preserved and the error is reported.
    ///
    /// Signature, pointee/code lifetime and external-writer synchronization are
    /// caller requirements. Unresolved lazy imports must first be called normally.
    /// TPRO pages can reject installation. Direct/inlined calls and previously
    /// copied function pointers that bypass these slots are not intercepted.
    /// - Returns: An owner for this callback across the matched import slots.
    /// - Throws: Resolution/signature errors or `NativeImportedHookInstallationError`
    ///   preserving partial publication and rollback failures.
    @unsafe public func hookImportedFunction<Result, each Argument>(
        _ declaration: NativeDeclaration, as signature: ((repeat each Argument) -> Result).Type,
        in importer: ImageSelector, from provider: ImageSelector? = nil,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeImportedFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) throws -> NativeImportedFunctionHook {
        let selection = try ImportedFunctionSelection(resolver: resolver, declaration: declaration, importer: importer, provider: provider)
        let box = try prepareImportedCallback(as: signature, onFailure: onFailure, body: body)
        let types = box.parameters
        let context = Unmanaged.passRetained(box).toOpaque()
        let selected = selection.retainedHandle(); defer { ABIReleaseImportSelection(selected) }
        let handles: [OpaquePointer?] = types.map(\.handle)
        let handle = withExtendedLifetime(box) {
            handles.withUnsafeBufferPointer { parameters in
                ABICreateImportedHook(selected,box.result.handle,parameters.baseAddress,parameters.count,context,
                    { context, call, error in
                        invokeFunctionCallback(Unmanaged<FunctionCallbackBox>.fromOpaque(context!).takeUnretainedValue(), call!)
                    }, { context, error in
                        Unmanaged<FunctionCallbackBox>.fromOpaque(context!).takeUnretainedValue().failure(importedHookFailure(error!))
                    }, { context in Unmanaged<FunctionCallbackBox>.fromOpaque(context!).release() })!
            }
        }
        let hook = NativeImportedFunctionHook(handle)
        if let error = ABIImportedHookFailure(handle) {
            let index=ABIImportedHookFailedIndex(handle)
            throw NativeImportedHookInstallationError(underlyingError: NSError(domain: "ABIBridge.ImportedHook",code: Int(ABIResolutionFailureCode(error)),
                userInfo: [NSLocalizedDescriptionKey: String(cString: ABIResolutionFailureMessage(error))]),
                failedIndex: index < 0 ? nil : index, registration: hook)
        }
        return hook
    }
}
