import ABIBridgeCore
import ObjectiveC

struct SwiftReceiverCodec: Sendable {
    let type: CValueType
    let encode: @Sendable (Any) throws -> NativeValueStorage
    let decode: @Sendable (NativeValueStorage, Any?) throws -> Any

    init<Value>(_ valueType: Value.Type) throws {
        let codec = try SwiftValueCodec<Value>()
        type = codec.type
        encode = { value in
            guard let value = value as? Value else {
                throw ABIInvocationError.incompatibleValue(
                    expected: String(reflecting: Value.self), actual: String(reflecting: Swift.type(of: value))
                )
            }
            return try codec.encode(value)
        }
        decode = { try codec.copy(from: $0, retaining: $1) }
    }

    static func make(for type: Any.Type) throws -> Self {
        func open<Value>(_ type: Value.Type) throws -> Self { try Self(type) }
        return try _openExistential(type, do: open)
    }
}

enum SwiftReceiverMode: Sendable { case object, address, value }

struct SwiftReceiverPlan: Sendable {
    let codec: SwiftReceiverCodec
    let mode: SwiftReceiverMode
    let isMutating: Bool
    let expectedClass: AnyClass?

    init(codec: SwiftReceiverCodec, metadata: Any.Type, isMutating: Bool, validateClass: Bool) throws {
        self.codec = codec
        self.isMutating = isMutating
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
                var type: AnyClass? = Swift.type(of: object)
                while let candidate = type {
                    if candidate === expectedClass { return pointer }
                    type = class_getSuperclass(candidate)
                }
                throw ABIInvocationError.incompatibleValue(
                    expected: String(reflecting: expectedClass), actual: String(reflecting: Swift.type(of: object))
                )
            }
            return pointer
        }
    }
}
