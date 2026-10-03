import ABIBridgeCore
import Foundation
import Darwin
import ObjectiveC

/// A Swift hook continuation was used outside its active invocation.
public enum NativeSwiftHookInvocationError: Error, Sendable {
    /// The callback that provided the continuation has returned.
    case expiredInvocation
    /// A synchronous continuation or MainActor callback entered from another thread.
    case wrongThread
    /// An asynchronous continuation was used by another Swift task.
    case wrongTask
}

// Only the scoped operation owns the execution snapshot. Expiry drops it even
// when a consumer saves the public invocation for later diagnostics.
final class SwiftHookFrame {
    typealias Operation = ([NativeValueStorage]) throws -> NativeValueStorage
    typealias AsyncOperation = ([NativeValueStorage]) async throws -> NativeValueStorage
    struct Operations {
        let invoke: Operation?
        let invokeAsync: AsyncOperation?
        let receiver: (() throws -> NativeValueStorage)?
    }
    private(set) var recovery: SwiftHookRecoveryScope?
    private let lock = NSLock()
    private let thread = pthread_self()
    private let task: UnsafeRawPointer?
    private var operations: Operations?
    init(receiver: (() throws -> NativeValueStorage)? = nil, recovery: SwiftHookRecoveryScope? = nil, _ operation: @escaping Operation) {
        self.recovery = recovery
        task = nil
        operations = Operations(invoke: operation, invokeAsync: nil, receiver: receiver)
    }
    init(receiver: (() throws -> NativeValueStorage)? = nil, recovery: SwiftHookRecoveryScope? = nil, asynchronous operation: @escaping AsyncOperation) {
        self.recovery = recovery
        task = ABISwiftCurrentTask()
        operations = Operations(invoke: nil, invokeAsync: operation, receiver: receiver)
    }
    private func current() throws -> Operations {
        lock.lock()
        guard let operations else { lock.unlock(); throw NativeSwiftHookInvocationError.expiredInvocation }
        if operations.invokeAsync != nil {
            guard task == ABISwiftCurrentTask() else { lock.unlock(); throw NativeSwiftHookInvocationError.wrongTask }
        } else {
            guard pthread_equal(thread, pthread_self()) != 0 else { lock.unlock(); throw NativeSwiftHookInvocationError.wrongThread }
        }
        lock.unlock()
        return operations
    }
    func use<T>(_ body: (Operation) throws -> T) throws -> T {
        try body(current().invoke!)
    }
    nonisolated(nonsending) func useAsync<T>(_ body: (AsyncOperation) async throws -> T) async throws -> T {
        try await body(current().invokeAsync!)
    }
    func invoke<Result, each Argument>(prepared: SwiftCallValues, _ values: repeat each Argument) throws -> Result {
        try use { operation in
            let storage = try recovery.map { scope in try scope.withTransfer { try prepared.encode(repeat each values, retainingCode: nil) } }
                ?? prepared.encode(repeat each values, retainingCode: nil)
            let outcome = Swift.Result<Result, any Error> {
                let result: NativeValueStorage
                do { result = try operation(storage) }
                catch let completed as SwiftHookCompletedResultError {
                    throw completed.underlying
                }
                return try prepared.decode(result, retaining: result, retainingCode: nil)
            }
            return try prepared.finishInvocation(outcome, storage: storage)
        }
    }

    nonisolated(nonsending) func invokeAsync<Result, each Argument>(prepared: SwiftCallValues,
        _ values: repeat each Argument) async throws -> Result {
        try await useAsync { operation in
            let storage = try recovery.map { scope in try scope.withTransfer { try prepared.encode(repeat each values, retainingCode: nil) } }
                ?? prepared.encode(repeat each values, retainingCode: nil)
            let outcome: Swift.Result<Result, any Error>
            do {
                let result: NativeValueStorage
                do { result = try await operation(storage) }
                catch let completed as SwiftHookCompletedResultError {
                    throw completed.underlying
                }
                outcome = .success(try prepared.decode(result, retaining: result, retainingCode: nil))
            } catch { outcome = .failure(error) }
            return try prepared.finishInvocation(outcome, storage: storage)
        }
    }

    func receiver<T>(_ body: (NativeValueStorage) throws -> T) throws -> T {
        guard let read = try current().receiver else {
            throw ABIResolutionError.unsupportedDeclaration("This invocation has no instance receiver.")
        }
        return try body(read())
    }
    func expire() {
        lock.lock(); let previous = (operations, recovery); operations = nil; recovery = nil; lock.unlock()
        withExtendedLifetime(previous) {}
    }
}

/// The next implementation of a concrete Swift function, scoped to one callback.
///
/// Later hooks wrap earlier hooks. `proceed` traverses that snapshot and then
/// calls the captured predecessor with the incoming Swift context. It does not
/// resolve the source declaration again. Saving this value preserves diagnostics,
/// but does not extend its call frame or retain callback captures after return.
/// Synchronous continuations stay on the entering thread. Async continuations
/// remain valid across suspension on the same Swift task until the callback ends.
public struct NativeSwiftFunctionInvocation<Signature>: CustomStringConvertible {
    let frame: SwiftHookFrame
    let prepared: SwiftCallValues
    /// The declaration used for registration, not an inferred predecessor name.
    public let declaration: NativeDeclaration
    /// The caller-supplied argument, result, and effect signature.
    public var signature: Signature.Type { Signature.self }
    /// A cached description that does not read native state or format argument objects.
    public let description: String

    /// Calls the next implementation with replacement arguments and returns its value.
    /// Reference arguments retain their ordinary identity, so edits to their
    /// properties are visible to subsequent callbacks and native code.
    /// - Throws: Scope, argument/result conversion, or continuation errors.
    public func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == (repeat each Argument) throws(Failure) -> Result {
        try invoke(repeat each values)
    }

    public func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) throws -> Result
    where Signature == @Sendable (repeat each Argument) throws(Failure) -> Result {
        try invoke(repeat each values)
    }

    /// Awaits the captured predecessor on this callback's native task.
    /// The continuation remains usable across suspension until the callback returns.
    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @Sendable (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @_transparent
    public nonisolated(nonsending) func proceed<Result, Failure: Error, each Argument>(_ values: repeat each Argument) async throws -> Result
    where Signature == @Sendable @concurrent (repeat each Argument) async throws(Failure) -> Result {
        try await invokeAsync(repeat each values)
    }

    @usableFromInline nonisolated(nonsending) func invokeAsync<Result, each Argument>(_ values: repeat each Argument) async throws -> Result {
        try await frame.invokeAsync(prepared: prepared, repeat each values)
    }

    private func invoke<Result, each Argument>(_ values: repeat each Argument) throws -> Result {
        try frame.invoke(prepared: prepared, repeat each values)
    }
}

// Recovery keeps native values in their declaration's representation. Callback
// decoding and encoding remain shared with ordinary Swift closure callbacks.
final class SwiftHookRecoveryScope: @unchecked Sendable {
    @TaskLocal private static var transfer: SwiftHookRecoveryScope?
    private let protectsOwnership: Bool
    private var inputs: [ObjectIdentifier: SwiftRuntimeValueOwner] = [:]
    private var result: SwiftRuntimeValueOwner?
    init(protectsOwnership: Bool) { self.protectsOwnership = protectsOwnership }
    static func authorizes(_ owner: SwiftRuntimeValueOwner) -> Bool {
        guard let transfer else { return false }
        return transfer.inputs[ObjectIdentifier(owner)] != nil || transfer.result === owner
    }
    func retainInput(_ owner: SwiftRuntimeValueOwner) {
        guard inputs.updateValue(owner, forKey: ObjectIdentifier(owner)) == nil else { return }
        if protectsOwnership { owner.reserve() }
    }
    func retainResult(_ storage: NativeValueStorage) {
        let owner = storage.runtimeValueOwner ?? SwiftRuntimeValueOwner(storage: storage)
        storage.runtimeValueOwner = owner
        guard result !== owner else { return }
        let previous = result
        result = owner
        if protectsOwnership { owner.reserve(); previous?.releaseReservation() }
    }
    func withTransfer<Output>(_ body: () throws -> Output) rethrows -> Output {
        try Self.$transfer.withValue(self, operation: body)
    }
    deinit {
        if protectsOwnership {
            inputs.values.forEach { $0.releaseReservation() }
            result?.releaseReservation()
        }
    }
}

final class SwiftHookIncomingOwner {
    let signature: SwiftHookSignature
    var claimedInputs: Set<Int> = []
    var values: [NativeSwiftValue] = []
    init(_ signature: SwiftHookSignature) { self.signature = signature }
}

struct SwiftHookValueOperations: Sendable {
    let copy: @Sendable (NativeValueStorage) throws -> NativeValueStorage
    let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

    private init(copy: @escaping @Sendable (NativeValueStorage) throws -> NativeValueStorage,
                 destroy: @escaping @Sendable (UnsafeMutableRawPointer) -> Void) {
        self.copy = copy; self.destroy = destroy
    }

    init<Value>(_ host: Value.Type, result: SwiftGenericResult, type: CValueType) throws {
        switch result {
        case .runtimeValue(let plan): self.init(metadata: plan.valueType.metadata, type: type, makeStorage: { plan.makeStorage() })
        case .tuple(let tuple): self.init(metadata: tuple.nativeMetadata, type: type, makeStorage: { tuple.makeResultStorage() })
        default:
            let codec: SwiftValueCodec<Value>
            switch result {
            case .value: codec = SwiftValueCodec(nativeStorage: type)
            case .closure(let closure): codec = SwiftValueCodec(closure: closure)
            default: codec = try SwiftValueCodec()
            }
            self.init(copy: { try codec.copyNativeStorage($0) }, destroy: { codec.destroyNativeValue(at: $0) })
        }
    }

    private init(metadata: Any.Type, type: CValueType, makeStorage: @escaping @Sendable () -> NativeValueStorage) {
        let constants = SwiftValueConstants(ABISwiftValueIsIndirect(type.handle) ? Void.self : metadata)
        copy = { source in
            guard SwiftCopyability.accepts(metadata) else { return source }
            let restored = constants.isEmpty ? nil : constants.copyStorage(from: source.address)
            let result = makeStorage()
            SwiftValueCodeLifetime.connect([source.codeLifetime, result.codeLifetime].compactMap { $0 }, retaining: [])
            ABISwiftCopyValue(unsafeBitCast(metadata, to: UnsafeRawPointer.self), result.address, restored?.address ?? source.address)
            result.assumeInitialized { ABISwiftDestroyValue(unsafeBitCast(metadata, to: UnsafeRawPointer.self), $0) }
            return result
        }
        destroy = { address in
            constants.initialize(at: address)
            ABISwiftDestroyValue(unsafeBitCast(metadata, to: UnsafeRawPointer.self), address)
        }
    }

    init(host: Any.Type, argument: SwiftGenericArgument, type: CValueType) throws {
        if case .convention(let codec) = argument {
            try self.init(host: (host as! any SwiftConventionArgument.Type).wrappedType,
                          argument: codec.argument, type: type)
            return
        }
        if let tuple = SwiftGenericParameters.expandedTuple(argument) {
            self.init(copy: { source in
                guard SwiftCopyability.accepts(tuple.nativeMetadata) else { throw NativeSwiftValueError.noncopyableType }
                let value = tuple.materializeArgument(from: source.address, consuming: false, retaining: source)
                let addresses = tuple.nativeArgumentAddresses(value.address)
                let vector = NativeValueStorage(size: addresses.count * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                    alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment, owner: value, codeLifetime: value.codeLifetime,
                    didRelinquish: { value.relinquishValue() })
                for (index, address) in addresses.enumerated() {
                    vector.address.storeBytes(of: address, toByteOffset: index * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                                               as: UnsafeMutableRawPointer?.self)
                }
                return vector
            }, destroy: { source in
                let addresses = source.assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
                for (index, leaf) in tuple.leaves.enumerated() {
                    SwiftValueConstants(leaf.nativeType).initialize(at: addresses[index]!)
                    ABISwiftDestroyValue(unsafeBitCast(leaf.nativeType, to: UnsafeRawPointer.self), addresses[index]!)
                }
            })
            return
        }
        if let runtime = argument.runtimeValue {
            self.init(metadata: runtime.valueType.metadata, type: type, makeStorage: { runtime.makeStorage() })
            return
        }
        if argument.closure != nil || host is any SwiftClosureValue.Type {
            self.init(copy: { SwiftClosureStorage.copy($0.address.load(as: ABISwiftClosureValue.self), retaining: $0, codeLifetime: $0.codeLifetime) },
                      destroy: { SwiftClosureStorage.destroy($0) })
            return
        }
        let result: SwiftGenericResult = if case .value = argument { .value(type) } else { .concrete }
        func prepare<Value>(_ value: Value.Type) throws -> Self { try Self(value, result: result, type: type) }
        self = try _openExistential(host, do: prepare)
    }
}

struct SwiftHookCallbackSignature<Result, each Argument>: Sendable {
    private let callbackValues: SwiftCallbackValues
    private let callbackResult: SwiftCallbackResult<Result>
    private let argumentOperations: [SwiftHookValueOperations]
    private let resultOperations: SwiftHookValueOperations
    let values: SwiftCallValues
    let parameters: SwiftGenericParameters
    let generic: SwiftGenericCallPlan?
    let interface: SwiftCallInterface?
    let asyncInterface: SwiftAsyncCallInterface?
    let contextSize: UInt32?
    init(call: SwiftCall? = nil) throws {
        let call = try call ?? SwiftCall(signature: ((repeat each Argument) -> Result).self)
        try self.init(values: call.values, parameters: call.parameters, generic: call.generic,
            interface: call.interface, asyncInterface: nil, contextSize: nil)
    }
    init(call: SwiftAsyncCall, contextSize: UInt32) throws {
        try self.init(values: call.values, parameters: call.parameters, generic: call.generic,
            interface: nil, asyncInterface: call.interface, contextSize: contextSize)
    }
    private init(values: SwiftCallValues, parameters: SwiftGenericParameters, generic: SwiftGenericCallPlan?,
                 interface: SwiftCallInterface?, asyncInterface: SwiftAsyncCallInterface?, contextSize: UInt32?) throws {
        self.values = values; self.parameters = parameters; self.generic = generic
        self.interface = interface; self.asyncInterface = asyncInterface; self.contextSize = contextSize
        // The hook dispatcher owns error recovery even for a nonthrowing native
        // entry, so every conversion error has a host-side reporting channel.
        let signature = try SwiftFunctionSignature(((repeat each Argument) throws -> Result).self)
        callbackValues = try SwiftCallbackValues(signature, arguments: parameters.arguments,
                                                 consumingArguments: values.arguments.map(\.consumes))
        callbackResult = try SwiftCallbackResult(failure: (any Error).self, generic: generic?.result ?? .concrete)
        resultOperations = try SwiftHookValueOperations(Result.self, result: generic?.result ?? .concrete,
                                                        type: values.result.type)
        argumentOperations = try zip(signature.parameters, parameters.arguments).enumerated().map {
            try SwiftHookValueOperations(host: $0.element.0, argument: $0.element.1, type: values.arguments[$0.offset].type)
        }
    }

    func invoke(_ storage: [NativeValueStorage], recovery: SwiftHookRecoveryScope?, body: (repeat each Argument) throws -> Result) throws -> NativeValueStorage {
        let inputs = try zip(storage, values.arguments).enumerated().map { index, pair in
            pair.1.consumes && pair.0.runtimeValueOwner == nil ? try argumentOperations[index].copy(pair.0) : pair.0
        }
        let addresses: [UnsafeMutableRawPointer?] = inputs.map(\.address)
        let scope = addresses.withUnsafeBufferPointer { callbackValues.makeScope(asynchronous: false, arguments: $0.baseAddress) }
        for (index, input) in inputs.enumerated() {
            if let owner = input.runtimeValueOwner, let plan = parameters.arguments[index].runtimeValue {
                scope?.retainRuntimeInput(NativeSwiftValue(storage: try owner.ownedStorage(), type: plan.valueType),
                    at: input.address, index: index)
            } else if values.arguments[index].consumes { input.relinquishValue() }
        }
        return try withExtendedLifetime(inputs) {
            let outcome = Swift.Result<Result, any Error> {
                var index = 0
                func decode<Value>(_ type: Value.Type) throws -> Value {
                    defer { index += 1 }
                    return try callbackValues.decode(inputs[index].address, at: index, scope: scope, as: type)
                }
                let value = try body(repeat try decode((each Argument).self))
                return value
            }
            let value = try scope?.finishInvocation(outcome) ?? outcome.get()
            return try encodeResult(value, recovery: recovery)
        }
    }

    nonisolated(nonsending) func invokeAsync<Invocation>(_ storage: [NativeValueStorage], recovery: SwiftHookRecoveryScope?, invocation: Invocation,
        body: @Sendable (Invocation, repeat each Argument) async throws -> Result) async throws -> NativeValueStorage {
        let inputs = try zip(storage, values.arguments).enumerated().map { index, pair in
            pair.1.consumes && pair.0.runtimeValueOwner == nil ? try argumentOperations[index].copy(pair.0) : pair.0
        }
        let addresses: [UnsafeMutableRawPointer?] = inputs.map(\.address)
        let scope = addresses.withUnsafeBufferPointer { callbackValues.makeScope(asynchronous: true, arguments: $0.baseAddress) }
        for (index, input) in inputs.enumerated() {
            if let owner = input.runtimeValueOwner, let plan = parameters.arguments[index].runtimeValue {
                scope?.retainRuntimeInput(NativeSwiftValue(storage: try owner.ownedStorage(), type: plan.valueType),
                    at: input.address, index: index)
            } else if values.arguments[index].consumes { input.relinquishValue() }
        }
        defer { withExtendedLifetime(inputs) {} }
        let outcome: Swift.Result<Result, any Error>
        do {
            var index = 0
            func decode<Value>(_ type: Value.Type) throws -> Value {
                defer { index += 1 }
                return try callbackValues.decode(inputs[index].address, at: index, scope: scope, as: type)
            }
            let value = try await body(invocation, repeat try decode((each Argument).self))
            outcome = .success(value)
        } catch { outcome = .failure(error) }
        let value = try scope?.finishInvocation(outcome) ?? outcome.get()
        return try encodeResult(value, recovery: recovery)
    }

    private func encodeResult(_ value: Result, recovery: SwiftHookRecoveryScope?) throws -> NativeValueStorage {
        let initialize = try recovery.map { scope in try scope.withTransfer { try callbackResult.prepare(value) } }
            ?? callbackResult.prepare(value)
        let result = values.result.makeStorage()
        initialize(result.address)
        result.assumeInitialized { resultOperations.destroy($0) }
        return result
    }

    func erased(consumingArguments: Bool, receiver: SwiftReceiverPlan? = nil, errorPlan: SwiftErrorPlan? = nil,
                retaining owner: any Sendable) throws -> SwiftHookSignature {
        var identities: [ObjectIdentifier] = [ObjectIdentifier(Result.self)]
        for type in repeat (each Argument).self { identities.append(ObjectIdentifier(type)) }
        return try SwiftHookSignature(result: values.result.type, arguments: values.arguments.map(\.type), identities: identities,
            consumesArguments: consumingArguments, consumedArguments: values.arguments.map(\.consumes), receiver: receiver, errorPlan: errorPlan,
            parameters: parameters, generic: generic, interface: interface,
            asyncInterface: asyncInterface, contextSize: contextSize,
            owner: owner, cloneArguments: { storage in
                try zip(storage, values.arguments).enumerated().map { index, pair in
                    if pair.1.consumes, let valueOwner = pair.0.runtimeValueOwner, !pair.0.transfersOwnership {
                        return try valueOwner.access(.consuming)
                    }
                    return pair.1.consumes && pair.0.runtimeValueOwner == nil ? try argumentOperations[index].copy(pair.0) : pair.0
                }
            }, cloneResult: resultOperations.copy, destroyResult: resultOperations.destroy,
            initializeResult: callbackResult.initializeNativeResult,
            takeResult: {
                guard case .runtimeValue(let plan) = generic?.result,
                      !SwiftCopyability.accepts(plan.valueType.metadata) else { return nil }
                return { call in
                    let storage = plan.makeStorage()
                    var error: OpaquePointer?
                    guard ABISwiftIncomingTakeResult(call, storage.address, values.result.type.size, &error) else {
                        throw consumeNativeCallFailure(error)
                    }
                    _ = try plan.initializeResult(storage)
                    return storage
                }
            }(),
            destroyArguments: { addresses, excluding in
                for (index, argument) in values.arguments.enumerated() where argument.consumes && !excluding.contains(index) {
                    argumentOperations[index].destroy(addresses[index]!)
                }
            })
    }
}

final class SwiftHookSignature: @unchecked Sendable {
    let result: CValueType
    let arguments: [CValueType]
    let identities: [ObjectIdentifier]
    let consumesArguments: Bool
    let consumedArguments: [Bool]
    let explicitArgumentCount: Int
    let receiver: SwiftReceiverPlan?
    let errorPlan: SwiftErrorPlan?
    let owner: any Sendable
    let interface: SwiftCallInterface
    let asyncInterface: SwiftAsyncCallInterface?
    let contextSize: UInt32?
    let parameters: SwiftGenericParameters?
    let generic: SwiftGenericCallPlan?
    let nativeExplicitCount: Int
    private let metadataMatches: [SwiftGenericBinding.HookMetadataArgument]
    private let classMatches: [SwiftGenericCallPlan.HookClassArgument]
    let cloneArguments: ([NativeValueStorage]) throws -> [NativeValueStorage]
    let cloneResult: (NativeValueStorage) throws -> NativeValueStorage
    let destroyResult: (UnsafeMutableRawPointer) -> Void
    let initializeResult: SwiftResultInitializer?
    let takeResult: ((OpaquePointer) throws -> NativeValueStorage)?
    let destroyArguments: (UnsafeBufferPointer<UnsafeMutableRawPointer?>, Set<Int>) -> Void
    init(result: CValueType, arguments: [CValueType], identities: [ObjectIdentifier], consumesArguments: Bool, consumedArguments: [Bool],
         receiver: SwiftReceiverPlan?, errorPlan: SwiftErrorPlan? = nil,
         parameters: SwiftGenericParameters? = nil, generic: SwiftGenericCallPlan? = nil, interface: SwiftCallInterface? = nil,
         asyncInterface: SwiftAsyncCallInterface? = nil, contextSize: UInt32? = nil,
         owner: any Sendable, cloneArguments: @escaping ([NativeValueStorage]) throws -> [NativeValueStorage],
         cloneResult: @escaping (NativeValueStorage) throws -> NativeValueStorage,
         destroyResult: @escaping (UnsafeMutableRawPointer) -> Void,
         initializeResult: SwiftResultInitializer? = nil,
         takeResult: ((OpaquePointer) throws -> NativeValueStorage)? = nil,
         destroyArguments: @escaping (UnsafeBufferPointer<UnsafeMutableRawPointer?>, Set<Int>) -> Void) throws {
        self.result = result; self.identities = identities
        explicitArgumentCount = arguments.count
        let native = parameters?.types(from: arguments) ?? arguments
        nativeExplicitCount = native.count
        self.arguments = native + (receiver?.trailingType.map { [$0] } ?? [])
            + (try generic.map { Array(repeating: try CValueType(scalar: ABIValuePointer), count: $0.metadata.count) } ?? [])
        self.parameters = parameters; self.generic = generic
        self.asyncInterface = asyncInterface; self.contextSize = contextSize
        metadataMatches = try generic?.hookMetadataArguments() ?? []
        classMatches = try generic?.hookClassArguments() ?? []
        self.consumesArguments = consumesArguments; self.consumedArguments = consumedArguments; self.owner = owner
        self.receiver = receiver
        self.errorPlan = errorPlan
        self.cloneArguments = cloneArguments; self.cloneResult = cloneResult
        self.destroyResult = destroyResult; self.destroyArguments = destroyArguments
        self.initializeResult = initializeResult; self.takeResult = takeResult
        self.interface = try interface ?? SwiftCallInterface(result: result, parameters: self.arguments, errorPlan: errorPlan)
    }
    func matches(_ other: SwiftHookSignature) -> Bool {
        guard asyncInterface?.inheritsCallerIsolation == other.asyncInterface?.inheritsCallerIsolation else { return false }
        if let first = generic, let second = other.generic, !first.binding.declaration.parameters.isEmpty {
            return first.binding.declaration == second.binding.declaration
                && receiver?.mode == other.receiver?.mode && receiver?.isConsuming == other.receiver?.isConsuming
        }
        return identities == other.identities && consumesArguments == other.consumesArguments && matchesReceiver(other.receiver)
            && errorPlan?.identity == other.errorPlan?.identity
            && ABIValueTypesEqual(result.handle, other.result.handle) && arguments.count == other.arguments.count
            && zip(arguments, other.arguments).allSatisfy { ABIValueTypesEqual($0.handle, $1.handle) }
    }
    private func matchesReceiver(_ other: SwiftReceiverPlan?) -> Bool {
        switch (receiver, other) {
        case (nil, nil): return true
        case let (first?, second?):
            guard first.mode == second.mode, first.isConsuming == second.isConsuming else { return false }
            if first.mode == .object { return true }
            return first.isMutating == second.isMutating && first.codec.representation == second.codec.representation
                && ABIValueTypesEqual(first.codec.type.handle, second.codec.type.handle)
        default: return false
        }
    }

    func matchesIncoming(_ call: OpaquePointer) throws -> Bool {
        guard generic != nil else { return true }
        func pointer(at index: Int) throws -> UInt {
            var value: UInt = 0, error: OpaquePointer?
            let success = if let asyncInterface {
                ABISwiftAsyncIncomingReadPointer(call, asyncInterface.handle, index, &value, &error)
            } else { ABISwiftIncomingReadPointer(call, interface.handle, index, &value, &error) }
            guard success else {
                throw consumeNativeCallFailure(error)
            }
            return value
        }
        let metadataStart = nativeExplicitCount + (receiver?.trailingType == nil ? 0 : 1)
        let words = try metadataMatches.indices.map { try pointer(at: metadataStart + $0) }
        for (match, actual) in zip(metadataMatches, words) {
            if case .value(let expected) = match, expected != actual { return false }
        }
        func matchesClass(_ actual: AnyClass?, _ expected: AnyClass) -> Bool {
            var current: AnyClass? = actual
            while let type = current {
                if type === expected { return true }
                current = class_getSuperclass(type)
            }
            return false
        }
        if let expected = generic?.hookEnclosingClass {
            guard let context = ABISwiftIncomingContext(call),
                  matchesClass(object_getClass(Unmanaged<AnyObject>.fromOpaque(context).takeUnretainedValue()), expected) else { return false }
        }
        for source in classMatches {
            guard let value = UnsafeRawPointer(bitPattern: try pointer(at: source.index)) else { return false }
            let actual: AnyClass? = source.isMetatype ? unsafeBitCast(value, to: AnyClass.self)
                : object_getClass(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue())
            if !matchesClass(actual, source.expected) { return false }
        }
        for (match, actual) in zip(metadataMatches, words) {
            if case .pack(let expected) = match {
                guard let vector = UnsafeRawPointer(bitPattern: actual) else {
                    if expected.isEmpty { continue }
                    return false
                }
                for (index, word) in expected.enumerated() where vector.load(fromByteOffset: index * MemoryLayout<UInt>.size, as: UInt.self) != word {
                    return false
                }
            }
        }
        return true
    }

    func receivingForwardedArguments(_ arguments: [NativeValueStorage]) throws -> [NativeValueStorage] {
        try arguments.map { argument in
            argument.suspendHookAccess?()
            guard let transfer = argument.transferHookOwnership else { return argument }
            let storage = try transfer()
            let owner = SwiftRuntimeValueOwner(storage: storage)
            storage.runtimeValueOwner = owner
            return NativeValueStorage(borrowing: storage.address, owner: owner, retainingResourcesOf: storage)
        }
    }

    func preservingReceiver(_ explicit: [NativeValueStorage], from incoming: [NativeValueStorage]) -> [NativeValueStorage] {
        receiver?.mode == .value ? explicit + [incoming[explicitArgumentCount]] : explicit
    }
    func readArguments(_ call: OpaquePointer) throws -> [NativeValueStorage] {
        let native = arguments.indices.map { ABISwiftIncomingArgumentAddress(call, $0) }
        let logical = native.withUnsafeBufferPointer { parameters?.unpack($0.baseAddress) }
        let owner = SwiftHookArgumentOwner(logical?.storage ?? [])
        let incoming = Unmanaged<SwiftHookIncomingOwner>.fromOpaque(ABISwiftIncomingPreparedContext(call)!).takeUnretainedValue()
        var values = try (logical?.addresses ?? Array(native.prefix(explicitArgumentCount))).enumerated().map { index, address in
            guard consumedArguments[index], let plan = parameters?.arguments[index].runtimeValue,
                  !SwiftCopyability.accepts(plan.valueType.metadata) else {
                return NativeValueStorage(borrowing: address!, owner: owner)
            }
            let materialized = plan.nativeTuple?.materializeArgument(from: address!, consuming: true)
            let value = plan.takeCallbackArgument(from: materialized?.address ?? address!, type: plan.valueType)
            materialized?.relinquishValue()
            incoming.claimedInputs.insert(index)
            incoming.values.append(value)
            return try value.valueOwner.ownedStorage()
        }
        if receiver?.mode == .value {
            values.append(NativeValueStorage(borrowing: native[nativeExplicitCount]!, owner: owner))
        }
        return values
    }
    func proceed(_ call: OpaquePointer, arguments: [NativeValueStorage], recovery: SwiftHookRecoveryScope?) throws -> NativeValueStorage {
        var values = try recovery.map { scope in try scope.withTransfer { try cloneArguments(Array(arguments.prefix(explicitArgumentCount))) } }
            ?? cloneArguments(Array(arguments.prefix(explicitArgumentCount)))
        if let receiver, receiver.mode == .value {
            let value = arguments[explicitArgumentCount]
            values.append(receiver.isConsuming ? try receiver.codec.clone(value) : value)
        }
        var error: OpaquePointer?
        var context = ABISwiftIncomingContext(call)
        var consumedObject: Unmanaged<AnyObject>?
        var consumedValue: NativeValueStorage?
        if let receiver, receiver.isConsuming && receiver.mode != .value {
            guard let context else { throw ABIInvocationError.incompatibleValue(expected: "a live Swift receiver", actual: "nil") }
            if receiver.mode == .object {
                consumedObject = Unmanaged<AnyObject>.fromOpaque(context).retain()
            } else {
                consumedValue = try receiver.codec.clone(readReceiver(call, arguments: arguments))
            }
        }
        if let consumedValue { context = UnsafeRawPointer(consumedValue.address) }
        let logical: [UnsafeMutableRawPointer?] = values.prefix(explicitArgumentCount).map(\.address)
        let encoded = parameters?.encode(logical, retaining: Array(values.prefix(explicitArgumentCount)))
        var addresses = encoded?.addresses ?? logical
        if receiver?.mode == .value { addresses.append(values[explicitArgumentCount].address) }
        if let generic {
            let start = nativeExplicitCount + (receiver?.trailingType == nil ? 0 : 1)
            addresses += (0..<generic.metadata.count).map { ABISwiftIncomingArgumentAddress(call, start + $0) }
        }
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        for value in values { try value.resumeHookAccess?() }
        let ok = withExtendedLifetime((values, consumedValue, encoded)) { addresses.withUnsafeBufferPointer {
            ABISwiftIncomingProceed(call, $0.baseAddress, $0.count, context, &error)
        } }
        guard ok else { throw consumeNativeCallFailure(error) }
        invoked = true
        encoded?.finishInvocation()
        for (value, consumes) in zip(values, consumedArguments) where consumes { value.relinquishValue() }
        if receiver?.isConsuming == true && receiver?.mode == .value { values[explicitArgumentCount].relinquishValue() }
        consumedValue?.relinquishValue()
        let bytes = NativeValueStorage(borrowing: ABISwiftIncomingResultAddress(call)!, owner: self)
        if ABISwiftIncomingDidThrow(call), let errorPlan {
            let native = NativeSwiftError(try errorPlan.decode(errorPlan.copy(bytes)), retainingCode: owner)
            throw SwiftHookCompletedResultError(underlying: native, nativeError: errorPlan.copy(bytes))
        }
        do {
            return try takeResult?(call) ?? cloneResult(bytes)
        } catch { throw SwiftHookCompletedResultError(underlying: error) }
    }

    nonisolated(nonsending) func proceedAsync(_ call: OpaquePointer, arguments: [NativeValueStorage], recovery: SwiftHookRecoveryScope?) async throws -> NativeValueStorage {
        var values = try recovery.map { scope in try scope.withTransfer { try cloneArguments(Array(arguments.prefix(explicitArgumentCount))) } }
            ?? cloneArguments(Array(arguments.prefix(explicitArgumentCount)))
        if let receiver, receiver.mode == .value {
            let value = arguments[explicitArgumentCount]
            values.append(receiver.isConsuming ? try receiver.codec.clone(value) : value)
        }
        var error: OpaquePointer?
        var context = ABISwiftIncomingContext(call)
        var consumedObject: Unmanaged<AnyObject>?
        var consumedValue: NativeValueStorage?
        if let receiver, receiver.isConsuming && receiver.mode != .value {
            guard let context else { throw ABIInvocationError.incompatibleValue(expected: "a live Swift receiver", actual: "nil") }
            if receiver.mode == .object {
                consumedObject = Unmanaged<AnyObject>.fromOpaque(context).retain()
            } else {
                consumedValue = try receiver.codec.clone(readReceiver(call, arguments: arguments))
            }
        }
        if let consumedValue { context = UnsafeRawPointer(consumedValue.address) }
        let logical: [UnsafeMutableRawPointer?] = values.prefix(explicitArgumentCount).map(\.address)
        let encoded = parameters?.encode(logical, retaining: Array(values.prefix(explicitArgumentCount)))
        var addresses = encoded?.addresses ?? logical
        if receiver?.mode == .value { addresses.append(values[explicitArgumentCount].address) }
        if let generic {
            let start = nativeExplicitCount + (receiver?.trailingType == nil ? 0 : 1)
            addresses += (0..<generic.metadata.count).map { ABISwiftIncomingArgumentAddress(call, start + $0) }
        }
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        for value in values { try value.resumeHookAccess?() }
        let invocation = addresses.withUnsafeBufferPointer {
            ABISwiftIncomingCreateAsyncProceed(call, $0.baseAddress, $0.count, context, false, &error)
        }
        guard let invocation else { throw consumeNativeCallFailure(error) }
        defer { withExtendedLifetime((values, consumedValue, encoded)) { ABIReleaseSwiftAsyncInvocation(invocation) } }
        await invokeSwiftAsync(invocation)
        ABISwiftIncomingCompleteAsyncProceed(call, invocation)
        invoked = true
        encoded?.finishInvocation()
        for (value, consumes) in zip(values, consumedArguments) where consumes { value.relinquishValue() }
        if receiver?.isConsuming == true && receiver?.mode == .value { values[explicitArgumentCount].relinquishValue() }
        consumedValue?.relinquishValue()
        let bytes = NativeValueStorage(borrowing: ABISwiftIncomingResultAddress(call)!, owner: self)
        if ABISwiftIncomingDidThrow(call), let errorPlan {
            let native = NativeSwiftError(try errorPlan.decode(errorPlan.copy(bytes)), retainingCode: owner)
            throw SwiftHookCompletedResultError(underlying: native, nativeError: errorPlan.copy(bytes))
        }
        do {
            return try takeResult?(call) ?? cloneResult(bytes)
        } catch { throw SwiftHookCompletedResultError(underlying: error) }
    }

    func readReceiver(_ call: OpaquePointer, arguments: [NativeValueStorage]) throws -> NativeValueStorage {
        guard let receiver else {
            throw ABIResolutionError.unsupportedDeclaration("This invocation has no instance receiver.")
        }
        if receiver.mode == .value { return arguments[explicitArgumentCount] }
        guard let context = ABISwiftIncomingContext(call) else {
            throw ABIInvocationError.incompatibleValue(expected: "a live Swift receiver", actual: "nil")
        }
        let storage = NativeValueStorage(size: receiver.codec.type.size, alignment: receiver.codec.type.alignment)
        if receiver.mode == .object { storage.address.storeBytes(of: context, as: UnsafeRawPointer.self) }
        else { storage.address.copyMemory(from: context, byteCount: receiver.codec.type.size) }
        return storage
    }

    func destroyConsumedInputs(context: UnsafeRawPointer?, arguments: UnsafeBufferPointer<UnsafeMutableRawPointer?>, excluding: Set<Int> = []) {
        let logical = parameters?.unpack(arguments.baseAddress)
        if let logical { logical.addresses.withUnsafeBufferPointer { destroyArguments($0, excluding) } }
        else { destroyArguments(arguments, excluding) }
        guard let receiver, receiver.isConsuming else { return }
        switch receiver.mode {
        case .object:
            if let context { Unmanaged<AnyObject>.fromOpaque(context).release() }
        case .address:
            if let context { receiver.codec.destroy(UnsafeMutableRawPointer(mutating: context)) }
        case .value:
            receiver.codec.destroy(arguments[nativeExplicitCount]!)
        }
    }
}

private final class SwiftHookArgumentOwner {
    let storage: [NativeValueStorage]
    init(_ storage: [NativeValueStorage]) { self.storage = storage }
}

// A native call already ran, but its result cannot be represented by the
// supplied Swift codec. The C entry still owns the raw result for pass-through.
// This internal carrier stays inside the active hook frame; public continuations
// expose only its underlying error, never its owned native storage.
struct SwiftHookCompletedResultError: Error, @unchecked Sendable {
    let underlying: any Error
    var nativeError: NativeValueStorage? = nil
}
