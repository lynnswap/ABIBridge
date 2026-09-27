import ABIBridgeCore
import Foundation
import Darwin

/// A scoped imported-function continuation was used after return or on another thread.
public enum NativeImportedInvocationError: Error, Sendable { case expiredInvocation, wrongThread }

private final class ImportedFrame {
    let lock = NSLock()
    let thread = pthread_self()
    var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func use<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        guard let pointer else { lock.unlock(); throw NativeImportedInvocationError.expiredInvocation }
        guard pthread_equal(thread, pthread_self()) != 0 else { lock.unlock(); throw NativeImportedInvocationError.wrongThread }
        lock.unlock()
        return try body(pointer)
    }
    func expire() { lock.lock(); pointer = nil; lock.unlock() }
}

private struct ImportedSignature<Result, each Argument>: Sendable {
    let result: CValueCodec<Result>
    let arguments: (repeat CValueCodec<each Argument>)
    init() throws { result = try CValueCodec(); arguments = (repeat try CValueCodec<each Argument>()) }
    func proceed(_ pointer: OpaquePointer, _ values: repeat each Argument) throws -> Result {
        var storage: [NativeValueStorage] = []
        for (codec, value) in repeat (each arguments, each values) { storage.append(try codec.encode(value)) }
        let addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        var error: OpaquePointer?
        let ok = withExtendedLifetime(storage) { addresses.withUnsafeBufferPointer { ABIImportedProceed(pointer,$0.baseAddress,$0.count,&error) } }
        guard ok else { throw consumeNativeCallFailure(error) }
        let output = NativeValueStorage(size: result.type.size, alignment: result.type.alignment)
        guard ABIImportedCopyResult(pointer,output.address,result.type.size,&error) else { throw consumeNativeCallFailure(error) }
        return try result.decode(output)
    }
    func decodeArguments(_ pointer: OpaquePointer) throws -> (repeat each Argument) {
        var index = 0
        func decode<T>(_ codec: CValueCodec<T>) throws -> T {
            defer { index += 1 }
            let storage = NativeValueStorage(size: codec.type.size, alignment: codec.type.alignment)
            var error: OpaquePointer?
            guard ABIImportedReadArgument(pointer,index,storage.address,codec.type.size,&error) else { throw consumeNativeCallFailure(error) }
            return try codec.decode(storage)
        }
        return (repeat try decode(each arguments))
    }
}

/// A continuation valid only during this callback and on its incoming thread.
/// `proceed` calls the next registered callback and then this slot's predecessor;
/// it does not call the imported symbol again. Escaping this value does not keep
/// its invocation alive. Native arguments and pointer results remain borrowed.
public struct NativeImportedFunctionInvocation<Result, each Argument> {
    fileprivate let frame: ImportedFrame
    fileprivate let signature: ImportedSignature<Result, repeat each Argument>
    /// Calls the next implementation with the supplied arguments. A later
    /// callback error preserves the most recently completed continuation result.
    public func proceed(_ values: repeat each Argument) throws -> Result {
        try frame.use { try signature.proceed($0,repeat each values) }
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

final class ImportedCallbackBox {
    let result: CValueType
    let parameters: [CValueType]
    let invoke: (OpaquePointer) throws -> Void
    let failure: @Sendable (any Error) -> Void
    init(result: CValueType, parameters: [CValueType], invoke: @escaping (OpaquePointer) throws -> Void,
         failure: @escaping @Sendable (any Error) -> Void) {
        self.result=result; self.parameters=parameters; self.invoke=invoke; self.failure=failure
    }
}

func prepareImportedCallback<Result, each Argument>(
    as signature: ((repeat each Argument) -> Result).Type,
    onFailure: @escaping @Sendable (any Error) -> Void,
    body: @escaping @Sendable (NativeImportedFunctionInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
) throws -> ImportedCallbackBox {
    let prepared = try ImportedSignature<Result, repeat each Argument>()
    var types: [CValueType] = []
    for codec in repeat each prepared.arguments { types.append(codec.type) }
    return ImportedCallbackBox(result: prepared.result.type, parameters: types, invoke: { pointer in
        let frame = ImportedFrame(pointer); defer { frame.expire() }
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

func invokeImportedCallback(_ box: ImportedCallbackBox, _ call: OpaquePointer) -> Bool {
    do { try box.invoke(call) }
    catch { box.failure(error) }
    // A failure without an assigned result uses native fallback or the latest
    // completed continuation, while preserving the original Swift error above.
    return true
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
                        invokeImportedCallback(Unmanaged<ImportedCallbackBox>.fromOpaque(context!).takeUnretainedValue(), call!)
                    }, { context, error in
                        Unmanaged<ImportedCallbackBox>.fromOpaque(context!).takeUnretainedValue().failure(importedHookFailure(error!))
                    }, { context in Unmanaged<ImportedCallbackBox>.fromOpaque(context!).release() })!
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
