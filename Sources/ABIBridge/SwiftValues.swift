import ABIBridgeCore

func explicitSwiftValueType(_ metadata: Any.Type, abi: NativeType) throws -> CValueType {
    let layout = ABISwiftGetValueLayout(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
    if let components = abi.cType {
        guard (layout.size...layout.stride).contains(components.size) else {
            throw ABIResolutionError.unsupportedDeclaration("Swift ABI components must cover the native value without exceeding its stride.")
        }
        return try CValueType(swiftComponents: components, size: layout.size, alignment: layout.alignment)
    }
    return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
}

// Array's frozen representation holds one buffer reference regardless of Element.
protocol SwiftArrayValue {}
extension Array: SwiftArrayValue {}

struct SwiftValueCodec<Value>: Sendable {
    let type: CValueType
    private let cValue: CValueCodec<Value>?
    private let objectResult: Bool
    private let closure: SwiftClosureCodec?
    private let constants = SwiftValueConstants(Value.self)

    init() throws {
        guard !(Value.self is any SwiftConventionArgument.Type) else {
            throw ABIResolutionError.unsupportedDeclaration("Swift argument convention markers require the invocation argument path; results and managed callbacks cannot use them.")
        }
        if let closureType = Value.self as? any SwiftClosureValue.Type {
            let codec = try closureType.makeClosureCodec()
            closure = codec; type = codec.type; cValue = nil; objectResult = false
            return
        }
        closure = nil
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        let isObject = base is AnyClass || base == AnyObject.self
        let isAdapter = base is any ABIBridgeValue.Type
        let managed = Value.self as? any ABIBridgeSwiftValue.Type
        objectResult = isObject && (!isAdapter || managed != nil)
        if let tuple = SwiftTupleMetadata(Value.self) {
            func field<Element>(_ type: Element.Type) throws -> CValueType {
                guard !(type is any ABIBridgeValue.Type) || type is any ABIBridgeSwiftValue.Type,
                      !(type is any SwiftClosureValue.Type) else {
                    throw ABIResolutionError.unsupportedDeclaration("Tuple elements require their native Swift storage representation.")
                }
                return try SwiftValueCodec<Element>().type
            }
            type = try tuple.layout(for: Value.self, fields: tuple.elements.map {
                try _openExistential($0.type, do: field)
            })
            cValue = nil
        } else if let metatype = SwiftMetatypeMetadata(base) {
            type = Value.self is any NativeOptionalValue.Type && metatype.isSingleton
                ? CValueType(swiftOptionalSingleton: ()) : try metatype.valueType(for: Value.self)
            cValue = nil
        } else if let managed {
            if let components = managed.swiftABIType.cType {
                guard (MemoryLayout<Value>.size...MemoryLayout<Value>.stride).contains(components.size) else {
                    throw ABIResolutionError.unsupportedDeclaration(
                        "Swift ABI components must cover the value without exceeding its stride: \(String(reflecting: Value.self))."
                    )
                }
                type = try CValueType(swiftComponents: components, size: MemoryLayout<Value>.size,
                                      alignment: MemoryLayout<Value>.alignment)
            } else {
                type = try CValueType(indirectSwiftSize: MemoryLayout<Value>.size,
                                      alignment: MemoryLayout<Value>.alignment)
            }
            cValue = nil
        } else if isAdapter {
            let codec = try CValueCodec<Value>()
            cValue = codec
            type = codec.type
        } else if isObject {
            type = try CValueType(scalar: ABIValuePointer)
            cValue = nil
        } else if let existential = SwiftExistentialRepresentation(base) {
            type = try existential.valueType(for: Value.self)
            cValue = nil
        } else if base is any SwiftArrayValue.Type {
            type = try CValueType(scalar: ABIValuePointer)
            cValue = nil
        } else if base == String.self {
            let word = try CValueType(scalar: MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32)
            type = try CValueType(fields: Array(repeating: word, count: MemoryLayout<String>.size / MemoryLayout<UInt>.size))
            cValue = nil
        } else {
            let codec = try CValueCodec<Value>()
            cValue = codec
            type = codec.type
        }
        if cValue == nil && managed == nil {
            guard type.size == MemoryLayout<Value>.size, type.alignment == MemoryLayout<Value>.alignment else {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Unsupported Swift storage layout for \(String(reflecting: Value.self))."
                )
            }
        }
    }

    func makeStorage() -> NativeValueStorage {
        NativeValueStorage(size: cValue == nil && closure == nil ? MemoryLayout<Value>.stride : type.size,
                           alignment: type.alignment, codeLifetime: closure == nil ? nil : SwiftValueCodeLifetime([]))
    }

    func encode(_ value: Value) throws -> NativeValueStorage {
        if closure != nil { return try (value as! any SwiftClosureValue).encodeClosure() }
        if Value.self == Void.self { return NativeValueStorage(size: 0, alignment: 1) }
        if let cValue { return try cValue.encode(value) }
        let storage = makeStorage()
        storage.initialize(value)
        return storage
    }

    func copy(from storage: NativeValueStorage, retaining owner: Any?) throws -> Value {
        if let closure { return try closure.makeValue(storage.address.load(as: ABISwiftClosureValue.self), owner, false, storage.codeLifetime) as! Value }
        if let cValue { return try cValue.decode(storage, retaining: owner) }
        if objectResult, !(Value.self is any NativeOptionalValue.Type), storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        return constants.load(from: storage.address, as: Value.self)
    }

    func copyNativeStorage(_ storage: NativeValueStorage) throws -> NativeValueStorage {
        if closure != nil {
            return SwiftClosureStorage.copy(storage.address.load(as: ABISwiftClosureValue.self), retaining: storage,
                                            codeLifetime: storage.codeLifetime)
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

    func decode(_ storage: NativeValueStorage, retaining owner: Any?, retainingCode codeOwner: Any? = nil) throws -> Value {
        // Receiver/argument storage can belong to the object receiving this
        // closure later. Only code dependencies belong in its escaping context.
        if let closure { return try closure.makeValue(storage.address.load(as: ABISwiftClosureValue.self), codeOwner, true, storage.codeLifetime) as! Value }
        if let cValue { return try cValue.decode(storage, retaining: owner) }
        if objectResult, !(Value.self is any NativeOptionalValue.Type),
           storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        // A Swift result is +1. Taking it avoids adding another retain or
        // destroying bytes whose ownership has already moved to the caller.
        constants.initialize(at: storage.address)
        return storage.take(as: Value.self)
    }
}
