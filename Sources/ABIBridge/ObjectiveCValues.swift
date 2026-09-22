import ABIBridgeObjCXX
import Foundation
import CoreGraphics
import ObjCTypeDecodeKit

protocol ObjCOptionalValue {
    var wrappedValue: Any? { get }
    static var wrappedType: Any.Type { get }
    static var nilValue: Any { get }
    static func wrapping(_ value: Any) throws -> Any
}
extension Optional: ObjCOptionalValue {
    var wrappedValue: Any? {
        switch self {
        case .some(let value): value as Any
        case .none: nil
        }
    }
    static var wrappedType: Any.Type { Wrapped.self }
    static var nilValue: Any { Self.none as Any }
    static func wrapping(_ value: Any) throws -> Any {
        guard let value = value as? Wrapped else {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: Wrapped.self),
                                                      actual: String(reflecting: type(of: value)))
        }
        return Self.some(value) as Any
    }
}

protocol ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { get }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any
}
extension UnsafeRawPointer: ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { self }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { pointer }
}
extension UnsafeMutableRawPointer: ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { UnsafeMutableRawPointer(mutating: pointer) }
}
extension UnsafePointer: ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { pointer.assumingMemoryBound(to: Pointee.self) }
}
extension UnsafeMutablePointer: ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any {
        UnsafeMutableRawPointer(mutating: pointer).assumingMemoryBound(to: Pointee.self)
    }
}
extension OpaquePointer: ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { UnsafeRawPointer(self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { OpaquePointer(pointer) }
}
extension Selector: ObjCPointerValue {
    var rawPointer: UnsafeRawPointer { unsafeBitCast(self, to: UnsafeRawPointer.self) }
    static func fromRawPointer(_ pointer: UnsafeRawPointer) -> Any { unsafeBitCast(pointer, to: Selector.self) }
}

final class ObjCValueStorage {
    let address: UnsafeMutableRawPointer
    let owner: AnyObject?

    init(size: Int, alignment: Int, owner: AnyObject? = nil) {
        address = .allocate(byteCount: max(size, 1), alignment: max(alignment, 1))
        address.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, 1))
        self.owner = owner
    }
    deinit { address.deallocate() }

    func store<T>(_ value: T) {
        withUnsafeBytes(of: value) {
            if let base = $0.baseAddress, !$0.isEmpty { address.copyMemory(from: base, byteCount: $0.count) }
        }
    }
}

struct ObjCValueCodec<Value> {
    enum Kind { case void, boolean, bytes, object, classObject, pointer }
    let kind: Kind
    let size: Int
    let alignment: Int
    private let pointerType: (any ObjCPointerValue.Type)?

    init(encoding: String, size: Int) throws {
        guard let decoded = ObjCTypeDecoder.decode(encoding) else {
            throw ABIResolutionError.metadataUnavailable("Invalid Objective-C type encoding: \(encoding)")
        }
        var type = decoded
        while case .modified(_, let base) = type { type = base }
        self.size = size
        alignment = max(MemoryLayout<Value>.alignment, MemoryLayout<UnsafeRawPointer>.alignment)
        let baseType = (Value.self as? any ObjCOptionalValue.Type)?.wrappedType ?? Value.self
        pointerType = baseType as? any ObjCPointerValue.Type

        if type == .void && Value.self == Void.self {
            kind = .void
        } else if (type == .bool || type == .char) && Value.self == Bool.self && size == 1 {
            kind = .boolean
        } else if case .object = type {
            kind = .object
        } else if type == .class {
            kind = .classObject
        } else if Self.matchesInteger(type), size == MemoryLayout<Value>.size {
            kind = .bytes
        } else if (type == .float && (Value.self == Float.self || Value.self == CGFloat.self))
                    || (type == .double && (Value.self == Double.self || Value.self == CGFloat.self)) {
            guard size == MemoryLayout<Value>.size else { throw Self.mismatch(encoding) }
            kind = .bytes
        } else if let expected = Self.standardValueEncoding(),
                  let expectedType = ObjCTypeDecoder.decode(expected),
                  type == expectedType, size == MemoryLayout<Value>.size {
            kind = .bytes
        } else if pointerType != nil, Self.isPointer(type), size == MemoryLayout<UnsafeRawPointer>.size {
            kind = .pointer
        } else {
            throw Self.mismatch(encoding)
        }
    }

    func encode(_ value: Value) throws -> ObjCValueStorage {
        switch kind {
        case .void: throw Self.mismatch("void parameter")
        case .boolean:
            let storage = ObjCValueStorage(size: size, alignment: alignment)
            storage.store((value as! Bool) ? UInt8(1) : UInt8(0))
            return storage
        case .bytes:
            let storage = ObjCValueStorage(size: size, alignment: alignment)
            storage.store(value)
            return storage
        case .object, .classObject:
            let unwrapped: Any?
            if let optional = value as? any ObjCOptionalValue { unwrapped = optional.wrappedValue }
            else { unwrapped = value }
            // Class metadata and object instances both occupy one pointer, but
            // sending an instance where Objective-C expects Class is invalid.
            // Validate before bridging, which erases this distinction.
            if kind == .classObject, let unwrapped, !(unwrapped is AnyClass) {
                throw ABIInvocationError.incompatibleValue(
                    expected: String(reflecting: AnyClass.self),
                    actual: String(reflecting: type(of: unwrapped))
                )
            }
            let object = unwrapped.map { $0 as AnyObject }
            let storage = ObjCValueStorage(size: size, alignment: alignment, owner: object)
            storage.store(object.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
            return storage
        case .pointer:
            let unwrapped: Any?
            if let optional = value as? any ObjCOptionalValue { unwrapped = optional.wrappedValue }
            else { unwrapped = value }
            let pointer = (unwrapped as? any ObjCPointerValue)?.rawPointer
            let storage = ObjCValueStorage(size: size, alignment: alignment)
            storage.store(pointer)
            return storage
        }
    }

    func decode(_ storage: ObjCValueStorage) throws -> Value {
        switch kind {
        case .void: return () as! Value
        case .boolean: return (storage.address.load(as: UInt8.self) != 0) as! Value
        case .bytes: return storage.address.load(as: Value.self)
        case .object, .classObject:
            guard let pointer = storage.address.load(as: UnsafeRawPointer?.self) else { return try nilResult() }
            let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
            if kind == .classObject {
                guard let type = object as? AnyClass else {
                    throw ABIInvocationError.incompatibleValue(
                        expected: String(reflecting: AnyClass.self),
                        actual: String(reflecting: Swift.type(of: object))
                    )
                }
                // Converting the metatype as Any preserves its identity; casting
                // the bridged class object could accept an NSObject instance type.
                return try convert(type)
            }
            return try convert(object)
        case .pointer:
            guard let pointer = storage.address.load(as: UnsafeRawPointer?.self) else { return try nilResult() }
            return try convert(pointerType!.fromRawPointer(pointer))
        }
    }

    private func convert(_ value: Any) throws -> Value {
        if let optional = Value.self as? any ObjCOptionalValue.Type {
            return try optional.wrapping(value) as! Value
        }
        guard let result = value as? Value else {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: Value.self),
                                                      actual: String(reflecting: type(of: value)))
        }
        return result
    }

    private func nilResult() throws -> Value {
        guard let optional = Value.self as? any ObjCOptionalValue.Type else {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        return optional.nilValue as! Value
    }

    private static func mismatch(_ encoding: String) -> ABIResolutionError {
        .signatureMismatch(expected: String(reflecting: Value.self), found: [encoding])
    }

    private static func isPointer(_ type: ObjCType) -> Bool {
        switch type {
        case .pointer, .charPtr, .functionPointer, .selector: true
        default: false
        }
    }

    private static func matchesInteger(_ type: ObjCType) -> Bool {
        let signed = Value.self == Int.self || Value.self == Int8.self || Value.self == Int16.self
            || Value.self == Int32.self || Value.self == Int64.self
        let unsigned = Value.self == UInt.self || Value.self == UInt8.self || Value.self == UInt16.self
            || Value.self == UInt32.self || Value.self == UInt64.self
        switch type {
        case .char, .short, .int, .long, .longLong: return signed
        case .uchar, .ushort, .uint, .ulong, .ulongLong: return unsigned
        default: return false
        }
    }

    private static func standardValueEncoding() -> String? {
        if Value.self == CGPoint.self { return String(cString: ABIObjCEncodingPoint()) }
        if Value.self == CGSize.self { return String(cString: ABIObjCEncodingSize()) }
        if Value.self == CGRect.self { return String(cString: ABIObjCEncodingRect()) }
        if Value.self == NSRange.self { return String(cString: ABIObjCEncodingRange()) }
        return nil
    }
}
