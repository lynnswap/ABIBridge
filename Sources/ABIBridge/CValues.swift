import ABIBridgeCore
import Foundation
import CoreGraphics

func consumeCCallFailure(_ failure: OpaquePointer?) -> any Error {
    guard let failure else {
        return ABIResolutionError.metadataUnavailable("The native C call interface returned no failure details.")
    }
    defer { ABIReleaseResolutionFailure(failure) }
    return NSError(
        domain: "ABIBridge.CInvocation", code: Int(ABIResolutionFailureCode(failure)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: ABIResolutionFailureMessage(failure))]
    )
}

// Layout is finalized by the C++ backend before publication. It retains nested
// field types and permits concurrent preparation without mutating them.
final class CValueType: @unchecked Sendable {
    let handle: OpaquePointer
    var size: Int { ABIValueTypeSize(handle) }
    var alignment: Int { ABIValueTypeAlignment(handle) }

    init(scalar: Int) throws {
        var failure: OpaquePointer?
        guard let handle = ABICreateScalarType(Int32(scalar), &failure) else {
            throw consumeCCallFailure(failure)
        }
        self.handle = handle
    }

    init(fields: [CValueType]) throws {
        let handles: [OpaquePointer?] = fields.map(\.handle)
        var failure: OpaquePointer?
        guard let handle = handles.withUnsafeBufferPointer({
            ABICreateStructType($0.baseAddress, $0.count, &failure)
        }) else { throw consumeCCallFailure(failure) }
        self.handle = handle
    }

    deinit { ABIReleaseValueType(handle) }
}

struct CValueCodec<Value>: Sendable {
    enum Kind: Sendable { case void, boolean, bytes, pointer }
    let kind: Kind
    let type: CValueType
    private let pointerType: (any NativePointerValue.Type)?

    init() throws {
        let baseType = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        pointerType = baseType as? any NativePointerValue.Type
        if Value.self == Void.self {
            kind = .void
            type = try CValueType(scalar: ABIValueVoid)
        } else if Value.self == Bool.self {
            kind = .boolean
            type = try CValueType(scalar: ABIValueUInt8)
        } else if let scalar = Self.scalarKind() {
            kind = .bytes
            type = try CValueType(scalar: scalar)
        } else if pointerType != nil {
            kind = .pointer
            type = try CValueType(scalar: ABIValuePointer)
        } else if let valueType = try Self.standardValueType() {
            kind = .bytes
            type = valueType
        } else {
            throw ABIResolutionError.unsupportedDeclaration(
                "No C ABI representation for \(String(reflecting: Value.self))."
            )
        }
        guard kind == .void || (type.size == MemoryLayout<Value>.size
                               && type.alignment == MemoryLayout<Value>.alignment) else {
            throw ABIResolutionError.signatureMismatch(
                expected: "Swift layout of \(String(reflecting: Value.self))",
                found: ["C size \(type.size), alignment \(type.alignment)"]
            )
        }
    }

    func encode(_ value: Value) throws -> NativeValueStorage {
        let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
        switch kind {
        case .void:
            throw ABIResolutionError.unsupportedDeclaration("Void is only supported as a result.")
        case .boolean: storage.store((value as! Bool) ? UInt8(1) : UInt8(0))
        case .bytes: storage.store(value)
        case .pointer:
            let unwrapped: Any?
            if let optional = value as? any NativeOptionalValue { unwrapped = optional.wrappedValue }
            else { unwrapped = value }
            storage.store((unwrapped as? any NativePointerValue)?.rawPointer)
        }
        return storage
    }

    func decode(_ storage: NativeValueStorage) throws -> Value {
        switch kind {
        case .void: return () as! Value
        case .boolean: return (storage.address.load(as: UInt8.self) != 0) as! Value
        case .bytes: return storage.address.load(as: Value.self)
        case .pointer:
            let optional = Value.self as? any NativeOptionalValue.Type
            guard let pointer = storage.address.load(as: UnsafeRawPointer?.self) else {
                guard let optional else {
                    throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
                }
                return optional.nilValue as! Value
            }
            let value = pointerType!.fromRawPointer(pointer)
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
        if Value.self == Int.self { return MemoryLayout<Int>.size == 8 ? ABIValueInt64 : ABIValueInt32 }
        if Value.self == UInt.self { return MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32 }
        if Value.self == Float.self { return ABIValueFloat }
        if Value.self == Double.self { return ABIValueDouble }
        if Value.self == CGFloat.self { return MemoryLayout<CGFloat>.size == 8 ? ABIValueDouble : ABIValueFloat }
        return nil
    }

    private static func standardValueType() throws -> CValueType? {
        if Value.self == NSRange.self {
            let field = try CValueType(scalar: MemoryLayout<UInt>.size == 8 ? ABIValueUInt64 : ABIValueUInt32)
            return try CValueType(fields: [field, field])
        }
        guard Value.self == CGPoint.self || Value.self == CGSize.self || Value.self == CGRect.self else {
            return nil
        }
        let field = try CValueType(scalar: MemoryLayout<CGFloat>.size == 8 ? ABIValueDouble : ABIValueFloat)
        let pair = try CValueType(fields: [field, field])
        return Value.self == CGRect.self ? try CValueType(fields: [pair, pair]) : pair
    }
}
