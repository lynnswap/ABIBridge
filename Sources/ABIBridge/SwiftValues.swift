import ABIBridgeCore

// The typed owner keeps the original Swift representation alive. Bridging a
// String to AnyObject could retain a different representation of its contents.
private final class SwiftArgumentOwner<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

struct SwiftValueCodec<Value>: Sendable {
    let type: CValueType
    private let cValue: CValueCodec<Value>?
    private let objectResult: Bool

    init() throws {
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        let isObject = base is AnyClass || base == AnyObject.self
        let isAdapter = base is any ABIBridgeValue.Type
        objectResult = isObject && !isAdapter
        if isAdapter {
            let codec = try CValueCodec<Value>()
            cValue = codec
            type = codec.type
        } else if isObject {
            type = try CValueType(scalar: ABIValuePointer)
            cValue = nil
        } else if Value.self == String.self {
            let word = try CValueType(scalar: MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32)
            type = try CValueType(fields: Array(repeating: word, count: MemoryLayout<String>.size / MemoryLayout<UInt>.size))
            cValue = nil
        } else {
            let codec = try CValueCodec<Value>()
            cValue = codec
            type = codec.type
        }
        if cValue == nil {
            guard type.size == MemoryLayout<Value>.size, type.alignment == MemoryLayout<Value>.alignment else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Unsupported Swift storage layout for \(String(reflecting: Value.self))."
                )
            }
        }
    }

    func encode(_ value: Value) throws -> NativeValueStorage {
        if let cValue { return try cValue.encode(value) }
        let owner = SwiftArgumentOwner(value)
        let storage = NativeValueStorage(size: type.size, alignment: type.alignment, owner: owner)
        storage.store(owner.value)
        return storage
    }

    func decode(_ storage: NativeValueStorage, retaining owner: Any?) throws -> Value {
        if let cValue { return try cValue.decode(storage, retaining: owner) }
        if objectResult, !(Value.self is any NativeOptionalValue.Type),
           storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        // A Swift result is +1. Taking it avoids adding another retain or
        // destroying bytes whose ownership has already moved to the caller.
        return storage.address.assumingMemoryBound(to: Value.self).move()
    }
}
