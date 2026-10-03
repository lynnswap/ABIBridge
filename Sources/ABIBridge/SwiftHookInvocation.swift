import ABIBridgeCore
import Foundation
import Darwin

/// A Swift hook continuation was used outside its synchronous invocation.
public enum NativeSwiftHookInvocationError: Error, Sendable {
    /// The callback that provided the continuation has returned.
    case expiredInvocation
    /// The continuation or MainActor callback was entered from another thread.
    case wrongThread
}

// Only the scoped operation owns the execution snapshot. Expiry drops it even
// when a consumer saves the public invocation for later diagnostics.
final class SwiftHookFrame {
    typealias Operation = ([NativeValueStorage]) throws -> NativeValueStorage
    struct Operations {
        let invoke: Operation
        let receiver: (() throws -> NativeValueStorage)?
    }
    private let lock = NSLock()
    private let thread = pthread_self()
    private var operations: Operations?
    init(receiver: (() throws -> NativeValueStorage)? = nil, _ operation: @escaping Operation) {
        operations = Operations(invoke: operation, receiver: receiver)
    }
    private func current() throws -> Operations {
        lock.lock()
        guard let operations else { lock.unlock(); throw NativeSwiftHookInvocationError.expiredInvocation }
        guard pthread_equal(thread, pthread_self()) != 0 else { lock.unlock(); throw NativeSwiftHookInvocationError.wrongThread }
        lock.unlock()
        return operations
    }
    func use<T>(_ body: (Operation) throws -> T) throws -> T {
        try body(current().invoke)
    }
    func receiver<T>(_ body: (NativeValueStorage) throws -> T) throws -> T {
        guard let read = try current().receiver else {
            throw ABIResolutionError.unsupportedDeclaration("This invocation has no instance receiver.")
        }
        return try body(read())
    }
    func expire() {
        lock.lock(); let previous = operations; operations = nil; lock.unlock()
        withExtendedLifetime(previous) {}
    }
}

/// The next implementation of a concrete Swift function, scoped to one callback.
///
/// Later hooks wrap earlier hooks. `proceed` traverses that snapshot and then
/// calls the captured predecessor with the incoming Swift context. It does not
/// resolve the source declaration again. Saving this value preserves diagnostics,
/// but does not extend its call frame or retain callback captures after return.
public struct NativeSwiftFunctionInvocation<Result, each Argument>: CustomStringConvertible {
    let frame: SwiftHookFrame
    let prepared: SwiftHookCallbackSignature<Result, repeat each Argument>
    /// The declaration used for registration, not an inferred predecessor name.
    public let declaration: NativeDeclaration
    /// The caller-supplied explicit argument and result types.
    public var signature: ((repeat each Argument) -> Result).Type { ((repeat each Argument) -> Result).self }
    /// A cached description that does not read native state or format argument objects.
    public let description: String

    /// Calls the next implementation with replacement arguments and returns its value.
    /// Reference arguments retain their ordinary identity, so edits to their
    /// properties are visible to subsequent callbacks and native code.
    /// - Throws: Scope, argument/result conversion, or continuation errors.
    public func proceed(_ values: repeat each Argument) throws -> Result {
        try frame.use { operation in
            let storage = try prepared.encodeArguments(repeat each values)
            let result = try operation(storage)
            return try prepared.result.copy(from: result, retaining: result)
        }
    }
}

struct SwiftHookCallbackSignature<Result, each Argument>: Sendable {
    let result: SwiftValueCodec<Result>
    private let resultType: CValueType
    let arguments: (repeat SwiftValueCodec<each Argument>)
    init(declaration: SwiftGenericCallPlan? = nil) throws {
        if let declaration {
            guard declaration.binding.declaration.parameters.isEmpty else {
                throw ABIResolutionError.unsupportedDeclaration("Generic hooks require polymorphic incoming arguments and metadata; use direct invocation.")
            }
            let convertsResult: Bool
            switch declaration.result {
            case .runtimeValue: convertsResult = true
            case .closure(let codec): convertsResult = codec.nativePlan?.convertsValues == true
            default: convertsResult = false
            }
            guard !convertsResult, !declaration.arguments.contains(where: { $0.runtimeValue != nil }) else {
                throw ABIResolutionError.unsupportedDeclaration("Managed hooks require declaration-based runtime value conversion; use direct invocation.")
            }
        }
        for type in repeat (each Argument).self {
            if type is any SwiftClosureValue.Type {
                // A native nonescaping closure can carry a stack context that
                // cannot be retained as an owned closure value.
                throw ABIResolutionError.unsupportedDeclaration(
                    "Incoming Swift closure hook arguments require a scoped nonescaping representation."
                )
            }
        }
        result = try SwiftValueCodec()
        // An opaque result can use indirect native return storage even when its
        // known payload has an ordinary scalar or reference representation.
        resultType = declaration?.result.type ?? result.type
        arguments = (repeat try SwiftValueCodec<each Argument>())
    }
    func encodeArguments(_ values: repeat each Argument) throws -> [NativeValueStorage] {
        var storage: [NativeValueStorage] = []
        for (codec, value) in repeat (each arguments, each values) { storage.append(try codec.encode(value)) }
        return storage
    }
    func decodeArguments(_ storage: [NativeValueStorage]) throws -> (repeat each Argument) {
        var index = 0
        func decode<T>(_ codec: SwiftValueCodec<T>) throws -> T {
            defer { index += 1 }
            return try codec.copy(from: storage[index], retaining: storage[index])
        }
        return (repeat try decode(each arguments))
    }
    func erased(consumingArguments: Bool, receiver: SwiftReceiverPlan? = nil, retaining owner: any Sendable) throws -> SwiftHookSignature {
        var types: [CValueType] = [], identities: [ObjectIdentifier] = [ObjectIdentifier(Result.self)]
        for codec in repeat each arguments { types.append(codec.type) }
        for type in repeat (each Argument).self { identities.append(ObjectIdentifier(type)) }
        return try SwiftHookSignature(result: resultType, arguments: types, identities: identities,
            consumesArguments: consumingArguments, receiver: receiver, owner: owner, cloneArguments: { storage in
                var index = 0, result: [NativeValueStorage] = []
                for codec in repeat each arguments {
                    result.append(try codec.copyNativeStorage(storage[index])); index += 1
                }
                return result
            }, cloneResult: { try result.copyNativeStorage($0) }, destroyResult: { result.destroyNativeValue(at: $0) },
            destroyArguments: { addresses in
                var index = 0
                for codec in repeat each arguments { codec.destroyNativeValue(at: addresses[index]!); index += 1 }
            })
    }
}

final class SwiftHookSignature: @unchecked Sendable {
    let result: CValueType
    let arguments: [CValueType]
    let identities: [ObjectIdentifier]
    let consumesArguments: Bool
    let explicitArgumentCount: Int
    let receiver: SwiftReceiverPlan?
    let owner: any Sendable
    let interface: SwiftCallInterface
    let cloneArguments: ([NativeValueStorage]) throws -> [NativeValueStorage]
    let cloneResult: (NativeValueStorage) throws -> NativeValueStorage
    let destroyResult: (UnsafeMutableRawPointer) -> Void
    let destroyArguments: (UnsafeBufferPointer<UnsafeMutableRawPointer?>) -> Void
    init(result: CValueType, arguments: [CValueType], identities: [ObjectIdentifier], consumesArguments: Bool,
         receiver: SwiftReceiverPlan?,
         owner: any Sendable, cloneArguments: @escaping ([NativeValueStorage]) throws -> [NativeValueStorage],
         cloneResult: @escaping (NativeValueStorage) throws -> NativeValueStorage,
         destroyResult: @escaping (UnsafeMutableRawPointer) -> Void,
         destroyArguments: @escaping (UnsafeBufferPointer<UnsafeMutableRawPointer?>) -> Void) throws {
        self.result = result; self.identities = identities
        explicitArgumentCount = arguments.count
        self.arguments = arguments + (receiver?.trailingType.map { [$0] } ?? [])
        self.consumesArguments = consumesArguments; self.owner = owner
        self.receiver = receiver
        self.cloneArguments = cloneArguments; self.cloneResult = cloneResult
        self.destroyResult = destroyResult; self.destroyArguments = destroyArguments
        interface = try SwiftCallInterface(result: result, parameters: self.arguments)
    }
    func matches(_ other: SwiftHookSignature) -> Bool {
        identities == other.identities && consumesArguments == other.consumesArguments && matchesReceiver(other.receiver)
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

    func preservingReceiver(_ explicit: [NativeValueStorage], from incoming: [NativeValueStorage]) -> [NativeValueStorage] {
        receiver?.mode == .value ? explicit + [incoming[explicitArgumentCount]] : explicit
    }
    func readArguments(_ call: OpaquePointer) throws -> [NativeValueStorage] {
        try arguments.enumerated().map { index, type in
            let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
            var error: OpaquePointer?
            guard ABISwiftIncomingReadArgument(call, index, storage.address, type.size, &error) else { throw consumeNativeCallFailure(error) }
            return storage
        }
    }
    func proceed(_ call: OpaquePointer, arguments: [NativeValueStorage]) throws -> NativeValueStorage {
        var values = consumesArguments ? try cloneArguments(arguments) : Array(arguments.prefix(explicitArgumentCount))
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
        let addresses: [UnsafeMutableRawPointer?] = values.map(\.address)
        var invoked = false
        defer { if !invoked { consumedObject?.release() } }
        let ok = withExtendedLifetime((values, consumedValue)) { addresses.withUnsafeBufferPointer {
            ABISwiftIncomingProceed(call, $0.baseAddress, $0.count, context, &error)
        } }
        guard ok else { throw consumeNativeCallFailure(error) }
        invoked = true
        if consumesArguments { for value in values.prefix(explicitArgumentCount) { value.relinquishValue() } }
        if receiver?.isConsuming == true && receiver?.mode == .value { values[explicitArgumentCount].relinquishValue() }
        consumedValue?.relinquishValue()
        let bytes = NativeValueStorage(size: result.size, alignment: result.alignment)
        do {
            guard ABISwiftIncomingCopyResult(call, bytes.address, result.size, &error) else { throw consumeNativeCallFailure(error) }
            return try cloneResult(bytes)
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

    func destroyConsumedInputs(context: UnsafeRawPointer?, arguments: UnsafeBufferPointer<UnsafeMutableRawPointer?>) {
        if consumesArguments { destroyArguments(arguments) }
        guard let receiver, receiver.isConsuming else { return }
        switch receiver.mode {
        case .object:
            if let context { Unmanaged<AnyObject>.fromOpaque(context).release() }
        case .address:
            if let context { receiver.codec.destroy(UnsafeMutableRawPointer(mutating: context)) }
        case .value:
            receiver.codec.destroy(arguments[explicitArgumentCount]!)
        }
    }
}

// A native call already ran, but its result cannot be represented by the
// supplied Swift codec. The C entry still owns the raw result for pass-through.
struct SwiftHookCompletedResultError: Error { let underlying: any Error }
