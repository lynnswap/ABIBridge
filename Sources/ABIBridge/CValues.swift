import ABIBridgeRuntime
import ABIBridgeCore
import Foundation
import CoreGraphics

func consumeNativeCallFailure(
    _ failure: OpaquePointer?,
    domain: String = "ABIBridge.CInvocation"
) -> any Error {
    let error = consumeRuntimeCallFailure(failure, domain: domain)
    return (error as? RuntimeResolutionError).map(ABIResolutionError.init) ?? error
}

// Layout is finalized by the C++ backend before publication. It retains nested
// field types and permits concurrent preparation without mutating them.
final class CValueType: Sendable {
    let runtime: RuntimeValueType
    var handle: OpaquePointer { runtime.handle }
    var size: Int { runtime.size }
    var alignment: Int { runtime.alignment }
    init(_ runtime: RuntimeValueType) { self.runtime = runtime }
    convenience init(adopting handle: OpaquePointer) {
        self.init(RuntimeValueType(adopting: handle))
    }
    convenience init(scalar: Int) throws {
        self.init(try withRuntimeErrors { try RuntimeValueType(scalar: scalar) })
    }
    convenience init(fields: [CValueType]) throws {
        self.init(try withRuntimeErrors { try RuntimeValueType(fields: fields.map(\.runtime)) })
    }
    convenience init(indirectSwiftSize size: Int, alignment: Int) throws {
        self.init(
            try withRuntimeErrors {
                try RuntimeValueType(indirectSwiftSize: size, alignment: alignment)
            }
        )
    }
    convenience init(
        swiftTuple fields: [CValueType],
        offsets: [Int],
        size: Int,
        alignment: Int,
        isPack: Bool = false
    ) throws {
        self.init(
            try withRuntimeErrors {
                try RuntimeValueType(
                    swiftTuple: fields.map(\.runtime),
                    offsets: offsets,
                    size: size,
                    alignment: alignment,
                    isPack: isPack
                )
            }
        )
    }
    convenience init(swiftOptionalSingleton: Void) {
        self.init(RuntimeValueType(swiftOptionalSingleton: ()))
    }
    convenience init(
        swiftAggregate fields: [CValueType],
        offsets: [Int],
        size: Int,
        alignment: Int
    ) throws {
        self.init(
            try withRuntimeErrors {
                try RuntimeValueType(
                    swiftAggregate: fields.map(\.runtime),
                    offsets: offsets,
                    size: size,
                    alignment: alignment
                )
            }
        )
    }
    convenience init(swiftComponents components: CValueType, size: Int, alignment: Int) throws {
        self.init(
            try withRuntimeErrors {
                try RuntimeValueType(
                    swiftComponents: components.runtime,
                    size: size,
                    alignment: alignment
                )
            }
        )
    }
}

// Swift 6.3 IRGen crashes when this payload enum is nested in the generic
// codec and its destruction is emitted for a parameter pack.
private enum CValueKind: Sendable {
    case void, boolean, bytes
    case pointer(any NativePointerValue.Type)
    case foreign(any ABIBridgeValue.Type, NativeType)
}

struct CArgumentCodec: Sendable {
    let type: CValueType
    let encode: @Sendable (UnsafeRawPointer, UnsafeMutableRawPointer) throws -> NativeValue?

    init<Value>(_ value: Value.Type) throws {
        let codec = try CValueCodec<Value>()
        type = codec.type
        encode = { try codec.encode($0.load(as: Value.self), into: $1) }
    }
}

struct CValueCodec<Value>: Sendable {
    private let kind: CValueKind
    let type: CValueType

    init() throws {
        let baseType = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        let pointerType = baseType as? any NativePointerValue.Type
        if Value.self == Void.self {
            kind = .void
            type = try CValueType(scalar: ABIValueVoid)
        } else if Value.self == Bool.self {
            kind = .boolean
            type = try CValueType(scalar: ABIValueUInt8)
        } else if let scalar = Self.scalarKind() {
            kind = .bytes
            type = try CValueType(scalar: scalar)
        } else if let pointerType {
            kind = .pointer(pointerType)
            type = try CValueType(scalar: ABIValuePointer)
        } else if let valueType = try Self.standardValueType() {
            kind = .bytes
            type = valueType
        } else if let bridge = baseType as? any ABIBridgeValue.Type {
            let nativeType = bridge.abiType
            if Value.self is any NativeOptionalValue.Type, !nativeType.isPointer {
                throw ABIResolutionError.unsupportedDeclaration(
                    "Optional wrappers require a pointer ABI representation."
                )
            }
            kind = .foreign(bridge, nativeType)
            type = try nativeType.requireCType()
        } else {
            throw ABIResolutionError.unsupportedDeclaration(
                "No C ABI representation for \(String(reflecting: Value.self))."
            )
        }
        switch kind {
        case .void, .foreign: break
        default:
            guard type.size == MemoryLayout<Value>.size,
                type.alignment == MemoryLayout<Value>.alignment
            else {
                throw ABIResolutionError.signatureMismatch(
                    .init(
                        expected: "Swift layout of \(String(reflecting: Value.self))",
                        found: ["C size \(type.size), alignment \(type.alignment)"]
                    )
                )
            }
        }
    }

    /// Whether Value belongs to a supported C codec category.
    ///
    /// This does not construct or validate its layout. `init` can still reject
    /// an optional wrapper, an opaque representation, or a Swift layout mismatch.
    static var hasRepresentation: Bool {
        let baseType = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        return Value.self == Void.self || Value.self == Bool.self || isScalar
            || baseType is any NativePointerValue.Type || isStandardValue
            || baseType is any ABIBridgeValue.Type
    }

    static var isScalar: Bool { scalarKind() != nil }

    /// Whether values go through a foreign representation instead of their Swift storage.
    var convertsValue: Bool {
        if case .foreign = kind { return true }
        return false
    }

    func encode(_ value: Value) throws -> NativeValueStorage {
        let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
        storage.retainOwner(try encode(value, into: storage.address))
        return storage
    }

    func encode(_ value: Value, into address: UnsafeMutableRawPointer) throws -> NativeValue? {
        func store<Representation>(_ representation: Representation) {
            withUnsafeBytes(of: representation) { bytes in
                if let base = bytes.baseAddress, !bytes.isEmpty {
                    address.copyMemory(from: base, byteCount: bytes.count)
                }
            }
        }
        switch kind {
        case .void:
            throw ABIResolutionError.unsupportedDeclaration("Void is only supported as a result.")
        case .boolean: store((value as! Bool) ? UInt8(1) : UInt8(0))
        case .bytes: store(value)
        case .pointer:
            let unwrapped: Any?
            if let optional = value as? any NativeOptionalValue {
                unwrapped = optional.wrappedValue
            } else {
                unwrapped = value
            }
            store((unwrapped as? any NativePointerValue)?.rawPointer)
        case .foreign(_, let nativeType):
            let unwrapped: Any?
            if let optional = value as? any NativeOptionalValue {
                unwrapped = optional.wrappedValue
            } else {
                unwrapped = value
            }
            guard let unwrapped else {
                store(UnsafeRawPointer?.none)
                return nil
            }
            let nativeValue = try (unwrapped as! any ABIBridgeValue).nativeValueForCall()
            try nativeValue.requireLayout(nativeType)
            unsafe nativeValue.withUnsafeBytes {
                if let base = $0.baseAddress, !$0.isEmpty {
                    address.copyMemory(from: base, byteCount: $0.count)
                }
            }
            return nativeValue
        }
        return nil
    }

    func decode(_ storage: NativeValueStorage, retaining owner: Any? = nil) throws -> Value {
        try decode(storage.address, retaining: owner)
    }

    func decode(_ address: UnsafeRawPointer, retaining owner: Any? = nil) throws -> Value {
        switch kind {
        case .void: return () as! Value
        case .boolean: return (address.load(as: UInt8.self) != 0) as! Value
        case .bytes: return address.load(as: Value.self)
        case .pointer(let pointerType):
            let optional = Value.self as? any NativeOptionalValue.Type
            guard let pointer = address.load(as: UnsafeRawPointer?.self) else {
                guard let optional else {
                    throw ABIInvocationError.unexpectedNilResult(
                        expected: String(reflecting: Value.self)
                    )
                }
                return optional.nilValue as! Value
            }
            let value = pointerType.fromRawPointer(pointer)
            if let optional { return try optional.wrapping(value) as! Value }
            return value as! Value
        case .foreign(let bridge, let nativeType):
            let optional = Value.self as? any NativeOptionalValue.Type
            if let optional, address.load(as: UnsafeRawPointer?.self) == nil {
                return optional.nilValue as! Value
            }
            let nativeValue = NativeValue(type: nativeType, retaining: owner) {
                $0.copyMemory(from: .init(start: address, count: type.size))
            }
            let value = try bridge.init(nativeValue: nativeValue)
            if let optional { return try optional.wrapping(value) as! Value }
            return value as! Value
        }
    }

    private static func scalarKind() -> Int? {
        if Value.self == Int8.self { return ABIValueInt8 }
        if Value.self == UInt8.self { return ABIValueUInt8 }
        if Value.self == Int16.self { return ABIValueInt16 }
        if Value.self == UInt16.self { return ABIValueUInt16 }
        if Value.self == Int32.self { return ABIValueInt32 }
        if Value.self == UInt32.self { return ABIValueUInt32 }
        if Value.self == Int64.self { return ABIValueInt64 }
        if Value.self == UInt64.self { return ABIValueUInt64 }
        if Value.self == Int.self {
            return MemoryLayout<Int>.size == 8 ? ABIValueInt64 : ABIValueInt32
        }
        if Value.self == UInt.self {
            return MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32
        }
        if Value.self == Float.self { return ABIValueFloat }
        if Value.self == Double.self { return ABIValueDouble }
        if Value.self == CGFloat.self {
            return MemoryLayout<CGFloat>.size == 8 ? ABIValueDouble : ABIValueFloat
        }
        return nil
    }

    private static var isStandardValue: Bool {
        Value.self == NSRange.self || Value.self == CGPoint.self || Value.self == CGSize.self
            || Value.self == CGRect.self
    }

    private static func standardValueType() throws -> CValueType? {
        if Value.self == NSRange.self {
            let field = try CValueType(
                scalar: MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32
            )
            return try CValueType(fields: [field, field])
        }
        guard Value.self == CGPoint.self || Value.self == CGSize.self || Value.self == CGRect.self
        else {
            return nil
        }
        let field = try CValueType(
            scalar: MemoryLayout<CGFloat>.size == 8 ? ABIValueDouble : ABIValueFloat
        )
        let pair = try CValueType(fields: [field, field])
        return Value.self == CGRect.self ? try CValueType(fields: [pair, pair]) : pair
    }
}
