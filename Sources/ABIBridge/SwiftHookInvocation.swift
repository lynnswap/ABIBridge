import ABIBridgeCore
import Foundation
import Darwin
import ObjectiveC

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

    private func invoke<Result, each Argument>(_ values: repeat each Argument) throws -> Result {
        do {
            return try frame.use { operation in
                let storage = try prepared.encode(repeat each values, retainingCode: nil)
                let result = try operation(storage)
                return try prepared.decode(result, retaining: result, retainingCode: nil)
            }
        } catch let error as SwiftHookCompletedResultError { throw error.underlying }
    }
}

struct SwiftHookCallbackSignature<Result, each Argument>: Sendable {
    let result: SwiftValueCodec<Result>
    private let resultType: CValueType
    private let initializeResult: SwiftResultInitializer
    let arguments: (repeat SwiftValueCodec<each Argument>)
    let call: SwiftCall
    init(call: SwiftCall? = nil) throws {
        let call = try call ?? SwiftCall(signature: ((repeat each Argument) -> Result).self)
        self.call = call
        let declaration = call.generic
        if let declaration {
            let convertsResult: Bool
            switch declaration.result {
            case .runtimeValue: convertsResult = true
            case .closure(let codec): convertsResult = codec.nativePlan?.convertsValues == true
            case .tuple(let tuple): convertsResult = tuple.needsConversion
            default: convertsResult = false
            }
            guard !convertsResult, !declaration.arguments.contains(where: { $0.runtimeValue != nil || $0.tuple?.needsConversion == true }) else {
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
        initializeResult = swiftResultInitializer(nativeMetadata: Result.self,
            generic: declaration?.result ?? .concrete)
        // An opaque result can use indirect native return storage even when its
        // known payload has an ordinary scalar or reference representation.
        resultType = call.values.result.type
        arguments = (repeat try SwiftValueCodec<each Argument>())
    }
    func decodeArguments(_ storage: [NativeValueStorage]) throws -> (repeat each Argument) {
        var index = 0
        func decode<T>(_ codec: SwiftValueCodec<T>) throws -> T {
            defer { index += 1 }
            return try codec.copy(from: storage[index], retaining: storage[index])
        }
        return (repeat try decode(each arguments))
    }
    func erased(consumingArguments: Bool, receiver: SwiftReceiverPlan? = nil, errorPlan: SwiftErrorPlan? = nil,
                retaining owner: any Sendable) throws -> SwiftHookSignature {
        var types: [CValueType] = [], identities: [ObjectIdentifier] = [ObjectIdentifier(Result.self)]
        types = call.values.arguments.map(\.type)
        for type in repeat (each Argument).self { identities.append(ObjectIdentifier(type)) }
        return try SwiftHookSignature(result: resultType, arguments: types, identities: identities,
            consumesArguments: consumingArguments, receiver: receiver, errorPlan: errorPlan,
            parameters: call.parameters, generic: call.generic, interface: call.interface,
            owner: owner, cloneArguments: { storage in
                var index = 0, result: [NativeValueStorage] = []
                for codec in repeat each arguments {
                    result.append(try codec.copyNativeStorage(storage[index])); index += 1
                }
                return result
            }, cloneResult: { try result.copyNativeStorage($0) }, destroyResult: { result.destroyNativeValue(at: $0) },
            initializeResult: initializeResult,
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
    let errorPlan: SwiftErrorPlan?
    let owner: any Sendable
    let interface: SwiftCallInterface
    let parameters: SwiftGenericParameters?
    let generic: SwiftGenericCallPlan?
    let nativeExplicitCount: Int
    private let metadataMatches: [SwiftGenericBinding.HookMetadataArgument]
    private let classMatches: [SwiftGenericCallPlan.HookClassArgument]
    let cloneArguments: ([NativeValueStorage]) throws -> [NativeValueStorage]
    let cloneResult: (NativeValueStorage) throws -> NativeValueStorage
    let destroyResult: (UnsafeMutableRawPointer) -> Void
    let initializeResult: SwiftResultInitializer?
    let destroyArguments: (UnsafeBufferPointer<UnsafeMutableRawPointer?>) -> Void
    init(result: CValueType, arguments: [CValueType], identities: [ObjectIdentifier], consumesArguments: Bool,
         receiver: SwiftReceiverPlan?, errorPlan: SwiftErrorPlan? = nil,
         parameters: SwiftGenericParameters? = nil, generic: SwiftGenericCallPlan? = nil, interface: SwiftCallInterface? = nil,
         owner: any Sendable, cloneArguments: @escaping ([NativeValueStorage]) throws -> [NativeValueStorage],
         cloneResult: @escaping (NativeValueStorage) throws -> NativeValueStorage,
         destroyResult: @escaping (UnsafeMutableRawPointer) -> Void,
         initializeResult: SwiftResultInitializer? = nil,
         destroyArguments: @escaping (UnsafeBufferPointer<UnsafeMutableRawPointer?>) -> Void) throws {
        self.result = result; self.identities = identities
        explicitArgumentCount = arguments.count
        let native = parameters?.types(from: arguments) ?? arguments
        nativeExplicitCount = native.count
        self.arguments = native + (receiver?.trailingType.map { [$0] } ?? [])
            + (try generic.map { Array(repeating: try CValueType(scalar: ABIValuePointer), count: $0.metadata.count) } ?? [])
        self.parameters = parameters; self.generic = generic
        metadataMatches = try generic?.hookMetadataArguments() ?? []
        classMatches = try generic?.hookClassArguments() ?? []
        self.consumesArguments = consumesArguments; self.owner = owner
        self.receiver = receiver
        self.errorPlan = errorPlan
        self.cloneArguments = cloneArguments; self.cloneResult = cloneResult
        self.destroyResult = destroyResult; self.destroyArguments = destroyArguments
        self.initializeResult = initializeResult
        self.interface = try interface ?? SwiftCallInterface(result: result, parameters: self.arguments, errorPlan: errorPlan)
    }
    func matches(_ other: SwiftHookSignature) -> Bool {
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
            guard ABISwiftIncomingReadPointer(call, interface.handle, index, &value, &error) else {
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

    func preservingReceiver(_ explicit: [NativeValueStorage], from incoming: [NativeValueStorage]) -> [NativeValueStorage] {
        receiver?.mode == .value ? explicit + [incoming[explicitArgumentCount]] : explicit
    }
    func readArguments(_ call: OpaquePointer) throws -> [NativeValueStorage] {
        let native = arguments.indices.map { ABISwiftIncomingArgumentAddress(call, $0) }
        let logical = native.withUnsafeBufferPointer { parameters?.unpack($0.baseAddress) }
        let owner = SwiftHookArgumentOwner(logical?.storage ?? [])
        var values = (logical?.addresses ?? Array(native.prefix(explicitArgumentCount))).map {
            NativeValueStorage(borrowing: $0!, owner: owner)
        }
        if receiver?.mode == .value {
            values.append(NativeValueStorage(borrowing: native[nativeExplicitCount]!, owner: owner))
        }
        return values
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
        let ok = withExtendedLifetime((values, consumedValue, encoded)) { addresses.withUnsafeBufferPointer {
            ABISwiftIncomingProceed(call, $0.baseAddress, $0.count, context, &error)
        } }
        guard ok else { throw consumeNativeCallFailure(error) }
        invoked = true
        encoded?.finishInvocation()
        if consumesArguments { for value in values.prefix(explicitArgumentCount) { value.relinquishValue() } }
        if receiver?.isConsuming == true && receiver?.mode == .value { values[explicitArgumentCount].relinquishValue() }
        consumedValue?.relinquishValue()
        let bytes = NativeValueStorage(borrowing: ABISwiftIncomingResultAddress(call)!, owner: self)
        if ABISwiftIncomingDidThrow(call), let errorPlan {
            let native = NativeSwiftError(try errorPlan.decode(errorPlan.copy(bytes)), retainingCode: owner)
            throw SwiftHookCompletedResultError(underlying: native, nativeError: errorPlan.copy(bytes))
        }
        do {
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
        if consumesArguments {
            let logical = parameters?.unpack(arguments.baseAddress)
            if let logical { logical.addresses.withUnsafeBufferPointer(destroyArguments) }
            else { destroyArguments(arguments) }
        }
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
