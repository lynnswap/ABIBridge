import ABIBridgeCore
import Foundation
import Synchronization

final class SwiftHookHandler: @unchecked Sendable {
    let invoke: (SwiftHookFrame, [NativeValueStorage]) throws -> NativeValueStorage
    let failure: @Sendable (any Error) -> Void
    let requiresMainActor: Bool
    let owner: (any Sendable)?
    init(requiresMainActor: Bool = false, retaining owner: (any Sendable)? = nil, failure: @escaping @Sendable (any Error) -> Void,
         invoke: @escaping (SwiftHookFrame, [NativeValueStorage]) throws -> NativeValueStorage) {
        self.requiresMainActor = requiresMainActor; self.owner = owner; self.failure = failure; self.invoke = invoke
    }
}

final class SwiftHookNode: Sendable {
    private let state: Mutex<SwiftHookHandler?>
    init(_ handler: SwiftHookHandler) { state = Mutex(handler) }
    func snapshot() -> SwiftHookHandler? { state.withLock { $0 } }
    func invalidate() {
        let previous = state.withLock { value in let previous = value; value = nil; return previous }
        withExtendedLifetime(previous) {}
    }
}

private final class SwiftHookStep {
    var last: Result<NativeValueStorage, SwiftHookCompletedResultError>?
    func record(_ value: Result<NativeValueStorage, SwiftHookCompletedResultError>) {
        let previous = last
        last = value
        // Releasing a value can run arbitrary object destruction and reenter a
        // continuation. Keep the old value alive until the new state is visible.
        withExtendedLifetime(previous) {}
    }
}

private final class SwiftHookExecution {
    let call: OpaquePointer
    let handlers: [SwiftHookHandler]
    let signature: SwiftHookSignature
    init(call: OpaquePointer, handlers: [SwiftHookHandler], signature: SwiftHookSignature) {
        self.call = call; self.handlers = handlers; self.signature = signature
    }
    func invoke(_ count: Int, arguments: [NativeValueStorage]) throws -> NativeValueStorage {
        guard count != 0 else { return try signature.proceed(call, arguments: arguments) }
        let handler = handlers[count - 1]
        if handler.requiresMainActor && !Thread.isMainThread {
            handler.failure(NativeSwiftHookInvocationError.wrongThread)
            return try invoke(count - 1, arguments: arguments)
        }
        let step = SwiftHookStep()
        let readReceiver: (() throws -> NativeValueStorage)? = signature.receiver == nil ? nil : { [self] in try signature.readReceiver(call, arguments: arguments) }
        let frame = SwiftHookFrame(receiver: readReceiver) { [self] values in
            do {
                let result = try invoke(count - 1, arguments: signature.preservingReceiver(values, from: arguments))
                step.record(.success(result))
                return result
            } catch let error as SwiftHookCompletedResultError {
                step.record(.failure(error)); throw error
            }
        }
        do {
            let result = try handler.invoke(frame, arguments)
            frame.expire()
            return result
        } catch {
            frame.expire()
            let underlying = (error as? SwiftHookCompletedResultError)?.underlying ?? error
            if let nativeError = signature.errorPlan?.encode(underlying) {
                throw SwiftHookCompletedResultError(underlying: underlying, nativeError: nativeError)
            }
            handler.failure(underlying)
            if let last = step.last { return try last.get() }
            if let completed = error as? SwiftHookCompletedResultError { throw completed }
            return try invoke(count - 1, arguments: arguments)
        }
    }
}

final class SwiftHookDispatcher: Sendable {
    let signature: SwiftHookSignature
    private let nodes = Mutex<[SwiftHookNode]>([])
    init(signature: SwiftHookSignature) { self.signature = signature }
    func append(_ node: SwiftHookNode) { nodes.withLock { $0.append(node) } }
    func remove(_ node: SwiftHookNode) {
        let previous = nodes.withLock { nodes in
            let previous = nodes; nodes = nodes.filter { $0 !== node }; return previous
        }
        withExtendedLifetime(previous) {}
    }
    func invoke(_ call: OpaquePointer) {
        let snapshot = nodes.withLock { $0.compactMap { $0.snapshot() } }
        guard !snapshot.isEmpty else { return } // Untouched native fallback, including consumed arguments.
        do {
            let arguments = try signature.readArguments(call)
            let execution = SwiftHookExecution(call: call, handlers: snapshot, signature: signature)
            let value = try execution.invoke(snapshot.count, arguments: arguments)
            var error: OpaquePointer?
            guard ABISwiftIncomingSetResult(call, value.address, signature.result.size, &error) else {
                throw consumeNativeCallFailure(error)
            }
            value.relinquishValue()
        } catch let completed as SwiftHookCompletedResultError {
            if let nativeError = completed.nativeError, let errorPlan = signature.errorPlan {
                var error: OpaquePointer?
                if ABISwiftIncomingSetError(call, nativeError.address, errorPlan.type.size, &error) {
                    nativeError.relinquishValue()
                } else { snapshot.last?.failure(consumeNativeCallFailure(error)) }
            }
            // A node already reported conversion failure. Preserve the native
            // entry's owned result without decoding it or executing it twice.
        } catch {
            snapshot.last?.failure(error)
        }
    }
}

final class SwiftGeneratedCallback: @unchecked Sendable {
    let handle: OpaquePointer
    var function: ABIUnmanagedFunction { ABISwiftCallbackFunction(handle)! }
    init(dispatcher: SwiftHookDispatcher, original: SwiftImplementation) throws {
        var functions = ABISwiftCallbackFunctions()
        functions.invoke = { context, call in
            Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().invoke(call!)
        }
        functions.releaseContext = { Unmanaged<SwiftHookDispatcher>.fromOpaque($0!).release() }
        functions.destroyResult = { context, value in
            Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().signature.destroyResult(value!)
        }
        functions.destroyError = { context, value in
            Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().signature.errorPlan?.destroy(value!)
        }
        functions.initializeResult = { context, offset, size, destination, source in
            let signature = Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().signature
            if let initialize = signature.initializeResult { initialize(offset, size, destination!, source!) }
            else { destination!.copyMemory(from: source!, byteCount: size) }
        }
        functions.initializeError = { context, offset, size, destination, source in
            let signature = Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().signature
            signature.errorPlan!.initialize(offset, size, destination!, source!)
        }
        functions.destroyConsumedArguments = { context, receiver, arguments, count in
            let signature = Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().signature
            signature.destroyConsumedInputs(context: receiver, arguments: UnsafeBufferPointer(start: arguments, count: count))
        }
        let context = Unmanaged.passRetained(dispatcher), owner = Unmanaged.passRetained(original)
        var error: OpaquePointer?
        guard let handle = ABICreateSwiftCallback(dispatcher.signature.interface.handle, original.function,
            functions, context.toOpaque(), owner.toOpaque(), { Unmanaged<SwiftImplementation>.fromOpaque($0!).release() }, &error) else {
            context.release(); owner.release(); throw consumeNativeCallFailure(error)
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftCallback(handle) }
}
