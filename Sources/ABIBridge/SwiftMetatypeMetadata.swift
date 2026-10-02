import ABIBridgeCore

/// Metadata.h and SIL/TypeLowering.cpp: a singleton metatype occupies a word
/// in generic value storage, but has no components in a concrete SIL signature.
struct SwiftMetatypeMetadata {
    let instance: Any.Type
    let isExistential: Bool
    let witnessCount: Int

    init?(_ type: Any.Type) {
        let metadata = unsafeBitCast(type, to: UnsafeRawPointer.self)
        let kind = metadata.load(as: UInt.self)
        guard kind == 0x304 || kind == 0x306 else { return nil }
        instance = metadata.load(fromByteOffset: MemoryLayout<UInt>.size, as: Any.Type.self)
        isExistential = kind == 0x306
        witnessCount = isExistential
            ? Int(metadata.load(fromByteOffset: 2 * MemoryLayout<UInt>.size, as: UInt32.self) & 0x00ffffff) : 0
    }

    var isSingleton: Bool { !isExistential && Self.hasSingletonMetatype(instance) }

    private static func hasSingletonMetatype(_ instance: Any.Type) -> Bool {
        if instance is AnyClass { return false }
        if let metatype = Self(instance), !metatype.isExistential {
            return hasSingletonMetatype(metatype.instance)
        }
        return true
    }

    func valueType<Value>(for type: Value.Type, thin: Bool? = nil) throws -> CValueType {
        let components: CValueType
        if thin ?? isSingleton {
            components = try CValueType(scalar: ABIValueVoid)
        } else {
            let pointer = try CValueType(scalar: ABIValuePointer)
            components = witnessCount == 0 ? pointer : try CValueType(fields: Array(repeating: pointer, count: 1 + witnessCount))
        }
        return try CValueType(swiftComponents: components, size: MemoryLayout<Value>.size,
            alignment: MemoryLayout<Value>.alignment)
    }
}

/// Restores values erased by concrete SIL lowering before interpreting their
/// generic memory representation. Only tuples expose their elements as SIL
/// values; fields of nominal types keep the nominal type's storage contract.
struct SwiftValueConstants: Sendable {
    private let words: [(offset: Int, value: UInt, optional: Bool)]
    private let size: Int
    private let alignment: Int
    var isEmpty: Bool { words.isEmpty }

    init(_ type: Any.Type) {
        func collect(_ type: Any.Type, offset: Int) -> [(Int, UInt, Bool)] {
            let wrapped = (type as? any NativeOptionalValue.Type)?.wrappedType
            if let metatype = SwiftMetatypeMetadata(wrapped ?? type), metatype.isSingleton {
                return [(offset, unsafeBitCast(metatype.instance, to: UInt.self), wrapped != nil)]
            }
            if let tuple = SwiftTupleMetadata(type) {
                return tuple.elements.flatMap { collect($0.type, offset: offset + $0.offset) }
            }
            return []
        }
        func layout<Value>(_ type: Value.Type) -> (Int, Int) {
            (MemoryLayout<Value>.size, MemoryLayout<Value>.alignment)
        }
        words = collect(type, offset: 0)
        (size, alignment) = _openExistential(type, do: layout)
    }

    func initialize(at address: UnsafeMutableRawPointer) {
        for word in words where !word.optional || address.load(fromByteOffset: word.offset, as: UInt.self) != 0 {
            address.storeBytes(of: word.value, toByteOffset: word.offset, as: UInt.self)
        }
    }

    func copyStorage(from address: UnsafeRawPointer) -> NativeValueStorage {
        let storage = NativeValueStorage(size: size, alignment: alignment)
        storage.address.copyMemory(from: address, byteCount: size)
        initialize(at: storage.address)
        return storage
    }

    func load<Value>(from address: UnsafeRawPointer, as type: Value.Type) -> Value {
        guard !isEmpty else { return address.load(as: type) }
        let storage = copyStorage(from: address)
        return storage.address.load(as: type)
    }
}
