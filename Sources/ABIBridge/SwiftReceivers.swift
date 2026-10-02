import ABIBridgeCore
import ObjectiveC

struct SwiftReceiverCodec: Sendable {
    let type: CValueType
    let representation: ObjectIdentifier
    let encode: @Sendable (Any) throws -> NativeValueStorage
    let decode: @Sendable (NativeValueStorage, Any?) throws -> Any
    let clone: @Sendable (NativeValueStorage) throws -> NativeValueStorage
    let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

    init<Value>(_ valueType: Value.Type) throws {
        let codec = try SwiftValueCodec<Value>()
        type = codec.type
        representation = ObjectIdentifier(Value.self)
        encode = { value in
            guard let value = value as? Value else {
                throw ABIInvocationError.incompatibleValue(
                    expected: String(reflecting: Value.self), actual: String(reflecting: Swift.type(of: value))
                )
            }
            return try codec.encode(value)
        }
        decode = { try codec.copy(from: $0, retaining: $1) }
        clone = { try codec.copyNativeStorage($0) }
        destroy = { codec.destroyNativeValue(at: $0) }
    }

    init(runtimeType metadata: Any.Type, formalType: CValueType) {
        type = formalType
        representation = ObjectIdentifier(metadata)
        encode = { value in
            func copy<Value>(_ type: Value.Type) throws -> NativeValueStorage {
                guard let value = value as? Value else {
                    throw ABIInvocationError.incompatibleValue(
                        expected: String(reflecting: metadata), actual: String(reflecting: Swift.type(of: value)))
                }
                let storage = NativeValueStorage(size: MemoryLayout<Value>.stride, alignment: MemoryLayout<Value>.alignment)
                storage.initialize(value)
                return storage
            }
            guard SwiftCopyability.accepts(metadata) else {
                throw NativeSwiftValueError.noncopyableType
            }
            return try _openExistential(metadata, do: copy)
        }
        decode = { source, _ in
            guard SwiftCopyability.accepts(metadata) else {
                throw NativeSwiftValueError.noncopyableType
            }
            func read<Value>(_ type: Value.Type) -> Any { source.address.load(as: Value.self) }
            return _openExistential(metadata, do: read)
        }
        clone = { source in
            let pointer = unsafeBitCast(metadata, to: UnsafeRawPointer.self)
            let layout = ABISwiftGetValueLayout(pointer)
            let copy = NativeValueStorage(size: layout.stride, alignment: layout.alignment)
            guard SwiftCopyability.accepts(metadata) else {
                throw NativeSwiftValueError.noncopyableType
            }
            ABISwiftCopyValue(pointer, copy.address, source.address)
            copy.assumeInitialized { ABISwiftDestroyValue(pointer, $0) }
            return copy
        }
        destroy = { ABISwiftDestroyValue(unsafeBitCast(metadata, to: UnsafeRawPointer.self), $0) }
    }

    static func make(for type: Any.Type) throws -> Self {
        func open<Value>(_ type: Value.Type) throws -> Self { try Self(type) }
        return try _openExistential(type, do: open)
    }
}

enum SwiftReceiverMode: Sendable { case object, address, value }

func swiftClass(_ actual: AnyClass, isSubclassOf expected: AnyClass) -> Bool {
    var current: AnyClass? = actual
    while let candidate = current {
        if candidate === expected { return true }
        current = class_getSuperclass(candidate)
    }
    return false
}

struct SwiftReceiverPlan: Sendable {
    let codec: SwiftReceiverCodec
    let mode: SwiftReceiverMode
    let isMutating: Bool
    let isConsuming: Bool
    let expectedClass: AnyClass?
    let metadata: Any.Type

    init(codec: SwiftReceiverCodec, metadata: Any.Type, isMutating: Bool,
         isConsuming: Bool, validateClass: Bool) throws {
        guard !(isMutating && isConsuming) else {
            throw ABIResolutionError.unsupportedDeclaration("Swift self cannot be both mutating and consuming.")
        }
        self.codec = codec
        self.metadata = metadata
        self.isMutating = isMutating
        self.isConsuming = isConsuming
        if let objectType = metadata as? AnyClass {
            guard ABIValueTypeIsPointer(codec.type.handle) else {
                throw ABIResolutionError.unsupportedDeclaration("A Swift class receiver requires a reference or pointer adapter.")
            }
            mode = .object
            expectedClass = validateClass ? objectType : nil
        } else {
            mode = isMutating || ABISwiftValueIsIndirect(codec.type.handle) ? .address : .value
            expectedClass = nil
        }
    }

    var trailingType: CValueType? { mode == .value ? codec.type : nil }

    func encode(_ receiver: Any, asynchronous: Bool = false) throws -> NativeValueStorage {
        let actual: NativeSwiftType
        if let value = receiver as? NativeSwiftValue {
            actual = value.type
        } else if let value = receiver as? NativeSwiftBorrowedValue {
            actual = value.type
        } else {
            return try codec.encode(receiver)
        }
        if let expected = metadata as? AnyClass, let objectType = actual.metadata as? AnyClass {
            guard swiftClass(objectType, isSubclassOf: expected) else {
                throw ABIInvocationError.incompatibleValue(expected: String(reflecting: metadata), actual: actual.name)
            }
        } else if actual.metadata != metadata {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: metadata), actual: actual.name)
        }
        if let value = receiver as? NativeSwiftValue {
            return try value.access(isConsuming ? .consuming : isMutating && mode != .object ? .inoutValue : .borrowing)
        }
        let value = receiver as! NativeSwiftBorrowedValue
        guard !isConsuming && (!isMutating || mode == .object) else {
            throw NativeSwiftValueError.valueInUse
        }
        return try value.borrow.access(asynchronous: asynchronous, type: value.type)
    }

    func finishInvocation<Result, Receiver>(
        _ outcome: Swift.Result<Result, any Error>, storage: NativeValueStorage, invoked: Bool,
        receiver: inout Receiver, retaining owner: Any?
    ) throws -> Result {
        if invoked && isMutating && mode != .object && !(receiver is NativeSwiftValue) {
            do {
                let value = try codec.decode(storage, owner)
                guard let updated = value as? Receiver else {
                    throw ABIInvocationError.incompatibleValue(
                        expected: String(reflecting: Receiver.self), actual: String(reflecting: Swift.type(of: value)))
                }
                receiver = updated
            } catch {
                if case .failure(let invocationError) = outcome {
                    throw NativeSwiftWritebackError(invocationError: invocationError, writebackError: error)
                }
                throw error
            }
        }
        return try outcome.get()
    }

    @unsafe func context(for storage: NativeValueStorage) throws -> UnsafeRawPointer? {
        switch mode {
        case .value: return nil
        case .address: return UnsafeRawPointer(storage.address)
        case .object:
            guard let pointer = storage.address.load(as: UnsafeRawPointer?.self) else {
                throw ABIInvocationError.incompatibleValue(expected: "a live Swift receiver", actual: "nil")
            }
            // Default typed codecs already downcast to the declaring class.
            // Explicit pointer/AnyObject adapters need this runtime class check.
            if let expectedClass {
                let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                if swiftClass(Swift.type(of: object), isSubclassOf: expectedClass) { return pointer }
                throw ABIInvocationError.incompatibleValue(
                    expected: String(reflecting: expectedClass), actual: String(reflecting: Swift.type(of: object))
                )
            }
            return pointer
        }
    }
}
