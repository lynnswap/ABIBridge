import ABIBridgeCore
import ABIBridgeRuntime

// Array, Dictionary, and Set each hold one storage reference regardless of
// their element types, so they are passed as one pointer.
protocol SwiftCollectionValue {
    /// The standard substitution that mangles the collection's declaration.
    static var mangledDeclaration: String { get }
}
extension Array: SwiftCollectionValue { static var mangledDeclaration: String { "Sa" } }
extension Dictionary: SwiftCollectionValue { static var mangledDeclaration: String { "SD" } }
extension Set: SwiftCollectionValue { static var mangledDeclaration: String { "Sh" } }

struct SwiftValueCodec<Value>: Sendable {
    let type: CValueType
    private let cValue: CValueCodec<Value>?
    private let objectResult: Bool
    private let closure: SwiftClosureCodec?
    private let tuple: SwiftTupleValuePlan?
    private let constants = SwiftValueConstants(Value.self)

    init(nativeStorage type: CValueType) {
        self.type = type
        cValue = nil; closure = nil; tuple = nil
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        objectResult = base is AnyClass || base == AnyObject.self
    }

    init(closure: SwiftClosureCodec) {
        self.closure = closure; type = closure.type
        cValue = nil; tuple = nil; objectResult = false
    }

    var initializeNativeResult: SwiftResultInitializer {
        if cValue != nil {
            return { _, size, destination, source in destination.copyMemory(from: source, byteCount: size) }
        }
        return swiftResultInitializer(nativeMetadata: Value.self, tuple: tuple)
    }

    /// - Parameter position: Where the value occurs, which decides how an
    ///   undecided inferred value is passed. Optional payloads are nested;
    ///   tuple elements take the tuple's element position.
    init(position: SwiftValuePosition) throws {
        let preparedTuple = try SwiftGenericCallPlan.concreteTuple(Value.self, position: position)
        tuple = preparedTuple?.needsConversion == true ? preparedTuple : nil
        if let tuple {
            type = tuple.type; closure = nil; cValue = nil; objectResult = false
            return
        }
        if let closureType = Value.self as? any SwiftClosureValue.Type {
            let codec = try closureType.makeClosureCodec()
            closure = codec; type = codec.type; cValue = nil; objectResult = false
            return
        }
        closure = nil
        let schema = try SwiftValueSchema.host(Value.self, position: position)
        type = schema.type
        cValue = schema.kind == .scalar ? try CValueCodec<Value>() : nil
        let base = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        let isObject = base is AnyClass || base == AnyObject.self
        // A type with its own Swift ABI keeps it, even in an Optional.
        let isAdapter = base is any ABIBridgeValue.Type && !(base is any ABIBridgeSwiftValue.Type)
        objectResult = isObject && (!isAdapter || Value.self is any ABIBridgeSwiftValue.Type)
    }

    func makeStorage() -> NativeValueStorage {
        if let tuple { return tuple.makeResultStorage() }
        return NativeValueStorage(size: cValue == nil && closure == nil ? MemoryLayout<Value>.stride : type.size,
                           alignment: type.alignment, codeLifetime: closure == nil ? nil : SwiftValueCodeLifetime([]))
    }

    func encode(_ value: Value, consuming: Bool = false) throws -> NativeValueStorage {
        if let tuple {
            let initialize = try withUnsafePointer(to: value) {
                try tuple.prepareNativeCopy(fromHost: $0)
            }
            let storage = tuple.makeResultStorage()
            initialize(storage.address)
            storage.assumeInitialized {
                ABISwiftDestroyValue(unsafeBitCast(tuple.nativeMetadata, to: UnsafeRawPointer.self), $0)
            }
            return storage
        }
        if let closure {
            if closure.nativePlan != nil, let encode = closure.encodeValue { return try encode(value, nil) }
            return try (value as! any SwiftClosureValue).encodeClosure(consuming: consuming)
        }
        if Value.self == Void.self { return NativeValueStorage(size: 0, alignment: 1) }
        if let cValue { return try cValue.encode(value) }
        let storage = makeStorage()
        storage.initialize(value)
        return storage
    }

    func copy(from storage: NativeValueStorage, retaining owner: Any?) throws -> Value {
        if let tuple {
            return try tuple.copyNativeValue(from: storage.address, retainingCode: owner,
                codeLifetime: storage.codeLifetime, as: Value.self)
        }
        if let closure { return try closure.makeValue(storage.address.load(as: ABISwiftClosureValue.self), owner, false, storage.codeLifetime) as! Value }
        if let cValue { return try cValue.decode(storage, retaining: owner) }
        if objectResult, !(Value.self is any NativeOptionalValue.Type), storage.address.load(as: UnsafeRawPointer?.self) == nil {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        return constants.load(from: storage.address, as: Value.self)
    }

    func copyNativeStorage(_ storage: NativeValueStorage) throws -> NativeValueStorage {
        if let tuple {
            let result = tuple.makeResultStorage()
            ABISwiftCopyValue(unsafeBitCast(tuple.nativeMetadata, to: UnsafeRawPointer.self), result.address, storage.address)
            result.assumeInitialized {
                ABISwiftDestroyValue(unsafeBitCast(tuple.nativeMetadata, to: UnsafeRawPointer.self), $0)
            }
            return result
        }
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
        if let tuple {
            ABISwiftDestroyValue(unsafeBitCast(tuple.nativeMetadata, to: UnsafeRawPointer.self), address)
            return
        }
        if closure != nil { SwiftClosureStorage.destroy(address); return }
        if cValue == nil { address.assumingMemoryBound(to: Value.self).deinitialize(count: 1) }
    }

    func decode(_ storage: NativeValueStorage, retaining owner: Any?, retainingCode codeOwner: Any? = nil) throws -> Value {
        if let tuple {
            return try tuple.decodeResult(storage, retaining: owner, retainingCode: codeOwner, as: Value.self)
        }
        // Receiver/argument storage can belong to the object receiving this
        // closure later. Only code dependencies belong in its escaping context.
        if let closure {
            let value = storage.address.load(as: ABISwiftClosureValue.self)
            storage.relinquishValue()
            return try closure.makeValue(value, codeOwner, true, storage.codeLifetime) as! Value
        }
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
