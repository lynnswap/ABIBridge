import ABIBridgeCore

struct SwiftValueCodec<Value>: Sendable {
    let type: CValueType
    private let cValue: CValueCodec<Value>?
    private let objectResult: Bool
    private let closure: SwiftClosureCodec?

    init() throws {
        if let closureType = Value.self as? any SwiftClosureValue.Type {
            let codec = try closureType.makeClosureCodec()
            closure = codec; type = codec.type; cValue = nil; objectResult = false
            return
        }
        closure = nil
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
        if closure != nil { return (value as! any SwiftClosureValue).closureStorage.encoded() }
        if Value.self == Void.self { return NativeValueStorage(size: 0, alignment: 1) }
        if let cValue { return try cValue.encode(value) }
        let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
        storage.initialize(value)
        return storage
    }

    func copy(from storage: NativeValueStorage, retaining owner: Any?) throws -> Value {
        if let closure { return try closure.makeValue(storage.address.load(as: ABISwiftClosureValue.self), owner, false) as! Value }
        if let cValue { return try cValue.decode(storage, retaining: owner) }
        if objectResult, !(Value.self is any NativeOptionalValue.Type), storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        return storage.address.load(as: Value.self)
    }

    func copyNativeStorage(_ storage: NativeValueStorage) throws -> NativeValueStorage {
        if closure != nil {
            return SwiftClosureStorage.copy(storage.address.load(as: ABISwiftClosureValue.self), retaining: storage)
        }
        if cValue != nil {
            let copy = NativeValueStorage(size: type.size, alignment: type.alignment)
            if type.size != 0 { copy.address.copyMemory(from: storage.address, byteCount: type.size) }
            return copy
        }
        return try encode(copy(from: storage, retaining: nil))
    }

    func destroyNativeValue(at address: UnsafeMutableRawPointer) {
        if closure != nil { SwiftClosureStorage.destroy(address); return }
        if cValue == nil { address.assumingMemoryBound(to: Value.self).deinitialize(count: 1) }
    }

    func decode(_ storage: NativeValueStorage, retaining owner: Any?) throws -> Value {
        if let closure { return try closure.makeValue(storage.address.load(as: ABISwiftClosureValue.self), owner, true) as! Value }
        if let cValue { return try cValue.decode(storage, retaining: owner) }
        if objectResult, !(Value.self is any NativeOptionalValue.Type),
           storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        // A Swift result is +1. Taking it avoids adding another retain or
        // destroying bytes whose ownership has already moved to the caller.
        return storage.take(as: Value.self)
    }
}
