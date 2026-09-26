import ABIBridgeCore
import ABIBridgeObjCXX
import Darwin
import Foundation

package enum ObjCReplacementError: Error, Equatable {
    case unavailableReceiver
    case initializerRequiresDedicatedCallback
    case expectedInitializer
}

// A runtime-scoped frame keeps the Swift 6.3 boundary usable without requiring
// experimental lifetime features in consumer modules. No frame memory is read
// after expiry, or from a thread other than the native callback's caller.
private final class ObjCReplacementFrame {
    private let lock = NSLock()
    private var pointer: OpaquePointer?
    private let thread = pthread_self()

    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    func withCall<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        guard let pointer else { lock.unlock(); throw NativeObjCMethodHookError.expiredInvocation }
        guard pthread_equal(thread, pthread_self()) != 0 else {
            lock.unlock()
            throw NativeObjCMethodHookError.wrongThread
        }
        lock.unlock()
        // Expiry runs only on this thread after the callback returns. Native
        // calls and user code must not execute while holding the frame lock.
        return try body(pointer)
    }

    func expire() {
        lock.lock()
        pointer = nil
        lock.unlock()
    }
}

/// A scoped view of the receiver and next implementation in a method-hook call.
///
/// Use it synchronously on the callback's original thread. Saving this value
/// does not extend the call: later access throws, and it is not Sendable.
public struct NativeObjCMethodInvocation<Result, each Argument> {
    fileprivate let frame: ObjCReplacementFrame
    fileprivate let signature: ObjCMethodSignature<Result, repeat each Argument>

    /// The live instance or class object receiving this call.
    /// - Throws: An expired-invocation or wrong-thread error outside the scope.
    public var receiver: AnyObject {
        get throws {
            try frame.withCall {
                guard let receiver = ABIObjCReplacementReceiver($0) else {
                    throw ObjCReplacementError.unavailableReceiver
                }
                return Unmanaged<AnyObject>.fromOpaque(receiver).takeUnretainedValue()
            }
        }
    }

    /// Invokes the next hook in this call's snapshot, or the native implementation.
    ///
    /// This does not send the selector again. Arguments can be changed, and an
    /// ordinary method may proceed more than once. Each completed result replaces
    /// the prior result used if this callback subsequently throws.
    /// - Parameter values: Explicit arguments, excluding self and the selector.
    /// - Returns: The next implementation's converted result.
    /// - Throws: A scope, thread, value-conversion, or invocation error.
    public func proceed(_ values: repeat each Argument) throws -> Result {
        try frame.withCall { call in
            try signature.invoke(repeat each values, using: { arguments, output in
                var error: NSError?
                let success = arguments.withUnsafeBufferPointer {
                    ABIObjCReplacementProceed(call, $0.baseAddress, &error)
                }
                guard success else { throw error ?? ABIResolutionError.invalidAddress as NSError }
                guard ABICopyObjCReplacementResult(call, output, &error) else {
                    throw error ?? ABIResolutionError.invalidAddress as NSError
                }
            })
        }
    }
}

final class ObjCReplacementCallback {
    let body: (OpaquePointer) -> Void
    init(_ body: @escaping (OpaquePointer) -> Void) { self.body = body }
}

// Bridges Sendable constraints around synchronous assumeIsolated calls.
// Values are produced and consumed on the verified main thread.
struct ObjCReplacementIsolatedResult<Value>: @unchecked Sendable { let value: Value }
struct ObjCReplacementIsolatedArguments<Result, each Argument>: @unchecked Sendable {
    let call: NativeObjCMethodInvocation<Result, repeat each Argument>
    let values: (repeat each Argument)
}

/// Internal executable-entry owner. It does not install or restore a method.
/// Published entry code remains callable after invalidation; callback captures
/// can be released independently once in-flight snapshots have finished.
package final class ObjCReplacement<Result, each Argument> {
    private let handle: OpaquePointer

    package init(on type: AnyClass, selector: String,
         as: ((repeat each Argument) -> Result).Type,
         classMethod: Bool = false, options: NativeMethodOptions = .init(),
         requiresMainThread: Bool = false,
         retaining owner: Any? = nil,
         onFailure: @escaping @Sendable (any Error) -> Void,
         body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result) throws {
        handle = try Self.prepare(type, selector, classMethod, options, initializer: false, retaining: owner) { signature in
            Self.callback(signature, requiresMainThread: requiresMainThread, onFailure: onFailure, body: body)
        }
    }

    @MainActor package convenience init(mainActorOn type: AnyClass, selector: String,
         as signature: ((repeat each Argument) -> Result).Type,
         retaining owner: Any? = nil,
         onFailure: @escaping @Sendable (any Error) -> Void,
         body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result) throws {
        try self.init(on: type, selector: selector, as: signature, requiresMainThread: true, retaining: owner, onFailure: onFailure) {
            (call: NativeObjCMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
            let input = ObjCReplacementIsolatedArguments(call: call, values: (repeat each values))
            return try MainActor.assumeIsolated {
                ObjCReplacementIsolatedResult(value: try body(input.call, repeat each input.values))
            }.value
        }
    }

    package init(initializerOn type: AnyClass, selector: String,
         as: ((repeat each Argument) -> Result).Type,
         retaining owner: Any? = nil,
         onFailure: @escaping @Sendable (any Error) -> Void,
         before: @escaping @Sendable (repeat each Argument) throws -> Void,
         after: @escaping @Sendable (Result) throws -> Void) throws {
        handle = try Self.prepare(type, selector, false, .init(), initializer: true, retaining: owner) { signature in
            Self.initializerCallback(signature, requiresMainThread: false, onFailure: onFailure,
                transformingArguments: nil, before: before, after: after)
        }
    }

    static func callback(_ signature: ObjCMethodSignature<Result, repeat each Argument>,
        requiresMainThread: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> ObjCReplacementCallback {
        ObjCReplacementCallback { pointer in
            guard !requiresMainThread || Thread.isMainThread else {
                onFailure(NativeObjCMethodHookError.wrongThread)
                return
            }
            let frame = ObjCReplacementFrame(pointer)
            defer { frame.expire() }
            do {
                let values = try Self.decodeArguments(signature, pointer)
                let invocation = NativeObjCMethodInvocation(frame: frame, signature: signature)
                let result = try body(invocation, repeat each values)
                let storage = try signature.result.encodeResult(result)
                var error: NSError?
                let success = withExtendedLifetime(storage) {
                    ABISetObjCReplacementResult(pointer, storage.address, &error)
                }
                guard success else { throw error ?? ABIResolutionError.invalidAddress as NSError }
            } catch { onFailure(error) }
        }
    }

    static func mainActorCallback(_ signature: ObjCMethodSignature<Result, repeat each Argument>,
        onFailure: @escaping @Sendable (any Error) -> Void,
        body: @escaping @MainActor @Sendable (NativeObjCMethodInvocation<Result, repeat each Argument>, repeat each Argument) throws -> Result
    ) -> ObjCReplacementCallback {
        callback(signature, requiresMainThread: true, onFailure: onFailure) {
            (call: NativeObjCMethodInvocation<Result, repeat each Argument>, values: repeat each Argument) in
            let input = ObjCReplacementIsolatedArguments(call: call, values: (repeat each values))
            return try MainActor.assumeIsolated {
                ObjCReplacementIsolatedResult(value: try body(input.call, repeat each input.values))
            }.value
        }
    }

    static func mainActorInitializerCallback(_ signature: ObjCMethodSignature<Result, repeat each Argument>,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@MainActor @Sendable (repeat each Argument) throws -> (repeat each Argument))?,
        before: (@MainActor @Sendable (repeat each Argument) throws -> Void)?,
        after: @escaping @MainActor @Sendable (Result) throws -> Void
    ) -> ObjCReplacementCallback {
        let transform: (@Sendable (repeat each Argument) throws -> (repeat each Argument))?
        if let transformingArguments {
            transform = { (values: repeat each Argument) in
                let input = ObjCReplacementIsolatedResult(value: (repeat each values))
                return try MainActor.assumeIsolated {
                    ObjCReplacementIsolatedResult(value: try transformingArguments(repeat each input.value))
                }.value
            }
        } else { transform = nil }
        let prepare: (@Sendable (repeat each Argument) throws -> Void)?
        if let before {
            prepare = { (values: repeat each Argument) in
                let input = ObjCReplacementIsolatedResult(value: (repeat each values))
                try MainActor.assumeIsolated { try before(repeat each input.value) }
            }
        } else { prepare = nil }
        return initializerCallback(signature, requiresMainThread: true, onFailure: onFailure,
            transformingArguments: transform, before: prepare, after: { result in
                let input = ObjCReplacementIsolatedResult(value: result)
                try MainActor.assumeIsolated { try after(input.value) }
            })
    }

    static func initializerCallback(_ signature: ObjCMethodSignature<Result, repeat each Argument>,
        requiresMainThread: Bool,
        onFailure: @escaping @Sendable (any Error) -> Void,
        transformingArguments: (@Sendable (repeat each Argument) throws -> (repeat each Argument))?,
        before: (@Sendable (repeat each Argument) throws -> Void)?,
        after: @escaping @Sendable (Result) throws -> Void
    ) -> ObjCReplacementCallback {
        ObjCReplacementCallback { pointer in
            guard !requiresMainThread || Thread.isMainThread else {
                onFailure(NativeObjCMethodHookError.wrongThread)
                return
            }
            do {
                let result: Result
                if let transformingArguments {
                    let values = try Self.decodeArguments(signature, pointer)
                    try before?(repeat each values)
                    let adjusted = try transformingArguments(repeat each values)
                    result = try signature.invoke(repeat each adjusted, using: { arguments, output in
                        var error: NSError?
                        let success = arguments.withUnsafeBufferPointer {
                            ABIObjCReplacementProceed(pointer, $0.baseAddress, &error)
                        }
                        guard success else { throw error ?? ABIResolutionError.invalidAddress as NSError }
                        guard ABICopyObjCReplacementResult(pointer, output, &error) else {
                            throw error ?? ABIResolutionError.invalidAddress as NSError
                        }
                    })
                } else {
                    if let before {
                        let values = try Self.decodeArguments(signature, pointer)
                        try before(repeat each values)
                    }
                    // Observation must not round-trip native arguments through
                    // Swift bridging or normalize their original representation.
                    var error: NSError?
                    guard ABIObjCReplacementProceed(pointer, nil, &error) else {
                        throw error ?? ABIResolutionError.invalidAddress as NSError
                    }
                    let output = NativeValueStorage(size: signature.result.size, alignment: signature.result.alignment)
                    guard ABICopyObjCReplacementResult(pointer, output.address, &error) else {
                        throw error ?? ABIResolutionError.invalidAddress as NSError
                    }
                    result = try signature.result.decode(output)
                }
                try after(result)
            } catch { onFailure(error) }
        }
    }

    private static func decodeArguments(_ signature: ObjCMethodSignature<Result, repeat each Argument>,
                                        _ call: OpaquePointer) throws -> (repeat each Argument) {
        var index = 0
        func decode<Value>(_ codec: ObjCValueCodec<Value>) throws -> Value {
            defer { index += 1 }
            return try codec.decodeBorrowed(ABIObjCReplacementArgument(call, index))
        }
        return (repeat try decode(each signature.arguments))
    }

    private static func prepare(_ type: AnyClass, _ selector: String, _ classMethod: Bool,
        _ options: NativeMethodOptions, initializer: Bool, retaining owner: Any?,
        callback: (ObjCMethodSignature<Result, repeat each Argument>) -> ObjCReplacementCallback) throws -> OpaquePointer {
        var error: NSError?
        guard let binding = ABICopyObjCImplementation(type, NSSelectorFromString(selector), classMethod,
            options.returnsRetainedObject.map { $0 ? 1 : 0 } ?? -1,
            options.consumesReceiver.map { $0 ? 1 : 0 } ?? -1, &error) else {
            throw error ?? ABIResolutionError.invalidAddress as NSError
        }
        defer { ABIReleaseObjCInvocation(binding) }
        if initializer {
            guard ABIObjCInvocationConsumesReceiver(binding) && ABIObjCInvocationReturnsRetained(binding) else {
                throw ObjCReplacementError.expectedInitializer
            }
        } else if ABIObjCInvocationConsumesReceiver(binding) {
            throw ObjCReplacementError.initializerRequiresDedicatedCallback
        }
        let signature = try ObjCMethodSignature<Result, repeat each Argument>(handle: binding)
        let interface = try signature.callInterface()
        let context = Unmanaged.passRetained(callback(signature))
        guard let entry = ABICreateObjCReplacement(binding, interface.handle, { context, call in
            Unmanaged<ObjCReplacementCallback>.fromOpaque(context).takeUnretainedValue().body(call)
        }, context.toOpaque(), { context in
            Unmanaged<ObjCReplacementCallback>.fromOpaque(context).release()
        }, owner.map { $0 as AnyObject }, &error) else {
            context.release()
            throw error ?? ABIResolutionError.invalidAddress as NSError
        }
        return entry
    }

    package func publishImplementation() -> IMP { ABIPublishObjCReplacement(handle) }
    package func invalidate() { ABIInvalidateObjCReplacement(handle) }
    deinit { ABIReleaseObjCReplacement(handle) }
}
