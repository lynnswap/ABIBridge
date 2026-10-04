import ABIBridgeRuntime
import ABIBridgeCore

/// Metadata.h and SIL/TypeLowering.cpp: a singleton metatype occupies a word
/// in generic value storage, but has no components in a concrete SIL signature.
typealias SwiftMetatypeMetadata = RuntimeMetatypeMetadata

extension RuntimeMetatypeMetadata {
    func valueType<Value>(for type: Value.Type, thin: Bool? = nil) throws -> CValueType {
        try withRuntimeErrors { CValueType(try runtimeValueType(for: type, thin: thin)) }
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
            if let metatype = SwiftMetatypeMetadata(wrapped ?? type), metatype.isSingleton,
                let instance = metatype.instance
            {
                return [(offset, unsafeBitCast(instance, to: UInt.self), wrapped != nil)]
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
        for word in words
        where !word.optional || address.load(fromByteOffset: word.offset, as: UInt.self) != 0 {
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
