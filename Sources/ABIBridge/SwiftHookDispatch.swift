import ABIBridgeCore
import Foundation
import Synchronization

final class SwiftHookHandler: @unchecked Sendable {
    let invoke: ((SwiftHookFrame, [NativeValueStorage]) throws -> NativeValueStorage)?
    let invokeAsync: ((SwiftHookFrame, [NativeValueStorage]) async throws -> NativeValueStorage)?
    let failure: @Sendable (any Error) -> Void
    let requiresMainActor: Bool
    let owner: (any Sendable)?
    init(requiresMainActor: Bool = false, retaining owner: (any Sendable)? = nil, failure: @escaping @Sendable (any Error) -> Void,
         invoke: @escaping (SwiftHookFrame, [NativeValueStorage]) throws -> NativeValueStorage) {
        self.requiresMainActor = requiresMainActor; self.owner = owner; self.failure = failure; self.invoke = invoke; self.invokeAsync = nil
    }
    init(requiresMainActor: Bool = false, retaining owner: (any Sendable)? = nil, failure: @escaping @Sendable (any Error) -> Void,
         invokeAsync: @escaping (SwiftHookFrame, [NativeValueStorage]) async throws -> NativeValueStorage) {
        self.requiresMainActor = requiresMainActor; self.owner = owner; self.failure = failure
        invoke = nil; self.invokeAsync = invokeAsync
    }

}

final class SwiftHookNode: Sendable {
    private let state: Mutex<SwiftHookHandler?>
    let signature: SwiftHookSignature
    init(_ handler: SwiftHookHandler, signature: SwiftHookSignature) {
        state = Mutex(handler); self.signature = signature
    }
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

// Each call owns its execution buffers; async continuations verify the entering
// task before reaching them, even if a consumer transfers the public view.
private final class SwiftHookExecution: @unchecked Sendable {
    let call: OpaquePointer
    let handlers: [SwiftHookHandler]
    let signature: SwiftHookSignature
    init(call: OpaquePointer, handlers: [SwiftHookHandler], signature: SwiftHookSignature) {
        self.call = call; self.handlers = handlers; self.signature = signature
    }
    func invoke(_ count: Int, arguments: [NativeValueStorage], recovery: SwiftHookRecoveryScope? = nil) throws -> NativeValueStorage {
        guard count != 0 else { return try signature.proceed(call, arguments: arguments, recovery: recovery) }
        let handler = handlers[count - 1]
        if handler.requiresMainActor && !Thread.isMainThread {
            handler.failure(NativeSwiftHookInvocationError.wrongThread)
            return try invoke(count - 1, arguments: arguments, recovery: recovery)
        }
        let recovery = SwiftHookRecoveryScope(protectsOwnership: signature.errorPlan == nil || signature.errorPlan!.isTyped)
        for value in arguments {
            if let owner = value.runtimeValueOwner { recovery.retainInput(owner) }
        }
        let step = SwiftHookStep()
        let readReceiver: (() throws -> NativeValueStorage)? = signature.receiver == nil ? nil : { [self] in try signature.readReceiver(call, arguments: arguments) }
        let frame = SwiftHookFrame(receiver: readReceiver, recovery: recovery) { [self] values in
            let result: NativeValueStorage
            do { result = try invoke(count - 1, arguments: signature.preservingReceiver(values, from: arguments), recovery: recovery) }
            catch let error as SwiftHookCompletedResultError {
                step.record(.failure(error)); throw error
            }
            step.record(.success(result))
            if signature.takeResult != nil { recovery.retainResult(result) }
            do { return try signature.cloneResult(result) }
            catch { throw SwiftHookCompletedResultError(underlying: error) }
        }
        do {
            let result = try handler.invoke!(frame, arguments)
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
            return try invoke(count - 1, arguments: arguments, recovery: recovery)
        }
    }
    nonisolated(nonsending) func invokeAsync(_ count: Int, arguments: [NativeValueStorage], recovery: SwiftHookRecoveryScope? = nil) async throws -> NativeValueStorage {
        guard count != 0 else { return try await signature.proceedAsync(call, arguments: arguments, recovery: recovery) }
        let handler = handlers[count - 1]
        let recovery = SwiftHookRecoveryScope(protectsOwnership: signature.errorPlan == nil || signature.errorPlan!.isTyped)
        for value in arguments {
            if let owner = value.runtimeValueOwner { recovery.retainInput(owner) }
        }
        let step = SwiftHookStep()
        let readReceiver: (() throws -> NativeValueStorage)? = signature.receiver == nil ? nil : { [self] in try signature.readReceiver(call, arguments: arguments) }
        let frame = SwiftHookFrame(receiver: readReceiver, recovery: recovery, asynchronous: { [self] values in
            do {
                let result = try await invokeAsync(count - 1, arguments: signature.preservingReceiver(values, from: arguments), recovery: recovery)
                step.record(.success(result))
            if signature.takeResult != nil { recovery.retainResult(result) }
                return try signature.cloneResult(result)
            } catch let error as SwiftHookCompletedResultError {
                step.record(.failure(error)); throw error
            }
        })
        do {
            let result = try await handler.invokeAsync!(frame, arguments)
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
            return try await invokeAsync(count - 1, arguments: arguments, recovery: recovery)
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
        let nodes = nodes.withLock { $0.compactMap { node in node.snapshot().map { (node.signature, $0) } } }
        var snapshot: [SwiftHookHandler] = []
        var selected = signature
        do {
            for (signature, handler) in nodes where try signature.matchesIncoming(call) {
                selected = signature
                snapshot.append(handler)
            }
            guard !snapshot.isEmpty else { return }
            try selected.prepareIncoming(call)
            let arguments = try selected.readArguments(call)
            let execution = SwiftHookExecution(call: call, handlers: snapshot, signature: selected)
            let result = try execution.invoke(snapshot.count, arguments: arguments)
            let value = try result.runtimeValueOwner?.access(.consuming) ?? result
            var error: OpaquePointer?
            guard ABISwiftIncomingSetResult(call, value.address, selected.result.size, &error) else {
                throw consumeNativeCallFailure(error)
            }
            value.relinquishValue()
        } catch let completed as SwiftHookCompletedResultError {
            if let nativeError = completed.nativeError, let errorPlan = selected.errorPlan {
                var error: OpaquePointer?
                if ABISwiftIncomingSetError(call, nativeError.address, errorPlan.type.size, &error) {
                    nativeError.relinquishValue()
                } else { snapshot.last?.failure(consumeNativeCallFailure(error)) }
            }
            // A node already reported conversion failure. Preserve the native
            // entry's owned result without decoding it or executing it twice.
        } catch {
            (snapshot.last ?? nodes.last?.1)?.failure(error)
        }
    }
    func makeAsyncBody(_ call: OpaquePointer) -> ABISwiftClosureValue {
        let nodes = nodes.withLock { $0.compactMap { node in node.snapshot().map { (node.signature, $0) } } }
        var snapshot: [SwiftHookHandler] = []
        var selected = signature
        do {
            for (signature, handler) in nodes where try signature.matchesIncoming(call) {
                if handler.requiresMainActor && !Thread.isMainThread {
                    handler.failure(NativeSwiftHookInvocationError.wrongThread)
                    continue
                }
                selected = signature; snapshot.append(handler)
            }
            guard !snapshot.isEmpty else { return ABISwiftClosureValue() }
            try selected.prepareIncoming(call)
            let arguments = try selected.readArguments(call)
            let execution = SwiftHookAsyncBody(call: call, handlers: snapshot, signature: selected, arguments: arguments)
            if selected.asyncInterface!.inheritsCallerIsolation {
                let body: nonisolated(nonsending) @Sendable () async -> Void = { await execution.run() }
                return retainedValue(body)
            }
            let body: @Sendable @concurrent () async -> Void = { await execution.run() }
            return retainedValue(body)
        } catch {
            (snapshot.last ?? nodes.last?.1)?.failure(error)
            return ABISwiftClosureValue()
        }
    }

}

private final class SwiftHookAsyncBody: @unchecked Sendable {
    let call: OpaquePointer
    let handlers: [SwiftHookHandler]
    let signature: SwiftHookSignature
    let arguments: [NativeValueStorage]
    init(call: OpaquePointer, handlers: [SwiftHookHandler], signature: SwiftHookSignature, arguments: [NativeValueStorage]) {
        self.call = call; self.handlers = handlers; self.signature = signature; self.arguments = arguments
    }
    nonisolated(nonsending) func run() async {
        do {
            let execution = SwiftHookExecution(call: call, handlers: handlers, signature: signature)
            let result = try await execution.invokeAsync(handlers.count, arguments: arguments)
            let value = try result.runtimeValueOwner?.access(.consuming) ?? result
            var failure: OpaquePointer?
            guard ABISwiftIncomingSetResult(call, value.address, signature.result.size, &failure) else {
                throw consumeNativeCallFailure(failure)
            }
            value.relinquishValue()
            return
        } catch let completed as SwiftHookCompletedResultError {
            if let nativeError = completed.nativeError, let errorPlan = signature.errorPlan {
                var failure: OpaquePointer?
                if ABISwiftIncomingSetError(call, nativeError.address, errorPlan.type.size, &failure) {
                    nativeError.relinquishValue()
                    return
                }
                handlers.last?.failure(consumeNativeCallFailure(failure))
            }
        } catch { handlers.last?.failure(error) }
        if ABISwiftIncomingResultAddress(call) == nil {
            // Prepared arguments are the unchanged native storage. This path
            // transfers original consumed ownership exactly once.
            let invocation = ABISwiftIncomingCreateAsyncProceed(call, nil, 0, nil, true, nil)!
            await invokeSwiftAsync(invocation)
            ABISwiftIncomingCompleteAsyncProceed(call, invocation)
            ABIReleaseSwiftAsyncInvocation(invocation)
        }
    }
}

final class SwiftGeneratedCallback: @unchecked Sendable {
    let handle: OpaquePointer
    private let asynchronous: Bool
    private let original: SwiftImplementation
    var function: ABIUnmanagedFunction {
        asynchronous ? ABISwiftAsyncHookCallbackFunction(handle)! : ABISwiftCallbackFunction(handle)!
    }
    var descriptor: UnsafeRawPointer? { asynchronous ? ABISwiftAsyncClosureCallbackDescriptor(handle) : nil }
    init(dispatcher: SwiftHookDispatcher, original: SwiftImplementation, contextSize: UInt32? = nil) throws {
        self.original = original
        asynchronous = dispatcher.signature.asyncInterface != nil
        if let interface = dispatcher.signature.asyncInterface {
            let context = Unmanaged.passRetained(dispatcher)
            var failure: OpaquePointer?
            guard let handle = ABICreateSwiftAsyncHookCallback(interface.handle, original.function,
                contextSize ?? dispatcher.signature.contextSize!, { context, call in
                    Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().makeAsyncBody(call!)
                }, context.toOpaque(), { Unmanaged<SwiftHookDispatcher>.fromOpaque($0!).release() }, &failure) else {
                context.release(); throw consumeNativeCallFailure(failure)
            }
            self.handle = handle
            return
        }
        var functions = ABISwiftCallbackFunctions()
        functions.invoke = { context, call in
            Unmanaged<SwiftHookDispatcher>.fromOpaque(context!).takeUnretainedValue().invoke(call!)
        }
        functions.preparesArguments = true
        functions.releaseContext = { Unmanaged<SwiftHookDispatcher>.fromOpaque($0!).release() }
        let context = Unmanaged.passRetained(dispatcher), owner = Unmanaged.passRetained(original)
        var error: OpaquePointer?
        guard let handle = ABICreateSwiftCallback(dispatcher.signature.interface.handle, original.function,
            functions, context.toOpaque(), owner.toOpaque(), { Unmanaged<SwiftImplementation>.fromOpaque($0!).release() }, &error) else {
            context.release(); owner.release(); throw consumeNativeCallFailure(error)
        }
        self.handle = handle
    }
    deinit {
        if asynchronous { ABIReleaseSwiftAsyncClosureCallback(handle) }
        else { ABIReleaseSwiftCallback(handle) }
    }
}

extension SwiftHookSignature {
    func prepareIncoming(_ call: OpaquePointer) throws {
        var functions = ABISwiftCallbackFunctions()
        functions.releaseContext = { Unmanaged<SwiftHookIncomingOwner>.fromOpaque($0!).release() }
        functions.destroyResult = { context, value in
            Unmanaged<SwiftHookIncomingOwner>.fromOpaque(context!).takeUnretainedValue().signature.destroyResult(value!)
        }
        functions.destroyError = { context, value in
            Unmanaged<SwiftHookIncomingOwner>.fromOpaque(context!).takeUnretainedValue().signature.errorPlan?.destroy(value!)
        }
        functions.initializeResult = { context, offset, size, destination, source in
            let signature = Unmanaged<SwiftHookIncomingOwner>.fromOpaque(context!).takeUnretainedValue().signature
            if let initialize = signature.initializeResult { initialize(offset, size, destination!, source!) }
            else { destination!.copyMemory(from: source!, byteCount: size) }
        }
        functions.initializeError = { context, offset, size, destination, source in
            let signature = Unmanaged<SwiftHookIncomingOwner>.fromOpaque(context!).takeUnretainedValue().signature
            signature.errorPlan!.initialize(offset, size, destination!, source!)
        }
        functions.destroyConsumedArguments = { context, receiver, arguments, count in
            let signature = Unmanaged<SwiftHookIncomingOwner>.fromOpaque(context!).takeUnretainedValue().signature
            let owner = Unmanaged<SwiftHookIncomingOwner>.fromOpaque(context!).takeUnretainedValue()
            signature.destroyConsumedInputs(context: receiver, arguments: UnsafeBufferPointer(start: arguments, count: count), excluding: owner.claimedInputs)
        }
        let context = Unmanaged.passRetained(SwiftHookIncomingOwner(self))
        var error: OpaquePointer?
        let success = if let asyncInterface {
            ABISwiftAsyncIncomingPrepare(call, asyncInterface.handle, functions, context.toOpaque(), &error)
        } else { ABISwiftIncomingPrepare(call, interface.handle, functions, context.toOpaque(), &error) }
        guard success else {
            context.release(); throw consumeNativeCallFailure(error)
        }
    }
}
