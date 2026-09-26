import ABIBridgeObjCXX
import ABIBridgeCore
import Foundation
import CoreGraphics
import ObjCTypeDecodeKit

struct ObjCValueCodec<Value> {
    enum Kind { case void, boolean, bytes, object, classObject, pointer, block }
    let kind: Kind
    let size: Int
    let alignment: Int
    private let pointerType: (any NativePointerValue.Type)?
    private let signedBoolean: Bool

    init(encoding: String, size: Int) throws {
        guard let decoded = ObjCTypeDecoder.decode(encoding) else {
            throw ABIResolutionError.metadataUnavailable("Invalid Objective-C type encoding: \(encoding)")
        }
        var type = decoded
        while case .modified(_, let base) = type { type = base }
        signedBoolean = type == .char
        self.size = size
        alignment = max(MemoryLayout<Value>.alignment, MemoryLayout<UnsafeRawPointer>.alignment)
        let baseType = (Value.self as? any NativeOptionalValue.Type)?.wrappedType ?? Value.self
        pointerType = baseType as? any NativePointerValue.Type

        if type == .void && Value.self == Void.self {
            kind = .void
        } else if (type == .bool || type == .char) && Value.self == Bool.self && size == 1 {
            kind = .boolean
        } else if case .block = type {
            guard Self.isBlockType(baseType), size == MemoryLayout<UnsafeRawPointer>.size,
                  MemoryLayout<Value>.size == size else { throw Self.mismatch(encoding) }
            kind = .block
        } else if case .object = type {
            if Self.isBlockType(baseType) {
                guard size == MemoryLayout<UnsafeRawPointer>.size, MemoryLayout<Value>.size == size else {
                    throw Self.mismatch(encoding)
                }
                kind = .block
            } else {
                kind = .object
            }
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

    func cType() throws -> CValueType {
        switch kind {
        case .object, .classObject, .pointer, .block:
            try CValueType(scalar: ABIValuePointer)
        case .boolean:
            try CValueType(scalar: signedBoolean ? ABIValueInt8 : ABIValueUInt8)
        case .void, .bytes:
            try CValueCodec<Value>().type
        }
    }

    func encode(_ value: Value) throws -> NativeValueStorage {
        switch kind {
        case .void: throw Self.mismatch("void parameter")
        case .boolean:
            let storage = NativeValueStorage(size: size, alignment: alignment)
            storage.store((value as! Bool) ? UInt8(1) : UInt8(0))
            return storage
        case .bytes:
            let storage = NativeValueStorage(size: size, alignment: alignment)
            storage.store(value)
            return storage
        case .block:
            // Block and optional-block values both use one nullable object word.
            let object = unsafeBitCast(value, to: AnyObject?.self)
            let copy = try object.map(Self.copyBlock)
            let storage = NativeValueStorage(size: size, alignment: alignment, owner: copy)
            storage.store(copy.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
            return storage
        case .object, .classObject:
            let unwrapped: Any?
            if let optional = value as? any NativeOptionalValue { unwrapped = optional.wrappedValue }
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
            let storage = NativeValueStorage(size: size, alignment: alignment, owner: object)
            storage.store(object.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
            return storage
        case .pointer:
            let unwrapped: Any?
            if let optional = value as? any NativeOptionalValue { unwrapped = optional.wrappedValue }
            else { unwrapped = value }
            let pointer = (unwrapped as? any NativePointerValue)?.rawPointer
            let storage = NativeValueStorage(size: size, alignment: alignment)
            storage.store(pointer)
            return storage
        }
    }

    func decode(_ storage: NativeValueStorage) throws -> Value {
        switch kind {
        case .void: return () as! Value
        case .boolean: return (storage.address.load(as: UInt8.self) != 0) as! Value
        case .bytes: return storage.address.load(as: Value.self)
        case .block:
            guard let pointer = storage.address.load(as: UnsafeRawPointer?.self) else { return try nilResult() }
            let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue()
            let copy: AnyObject? = try Self.copyBlock(object)
            return unsafeBitCast(copy, to: Value.self)
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

    // Incoming Objective-C values are borrowed. The existing decoder consumes
    // retainable results, so supply it with an independent +1 first.
    func decodeBorrowed(_ address: UnsafeRawPointer) throws -> Value {
        let storage = NativeValueStorage(size: size, alignment: alignment)
        storage.address.copyMemory(from: address, byteCount: size)
        if kind == .object || kind == .classObject || kind == .block,
           let pointer = storage.address.load(as: UnsafeRawPointer?.self) {
            _ = Unmanaged<AnyObject>.fromOpaque(pointer).retain()
        }
        return try decode(storage)
    }

    func encodeResult(_ value: Value) throws -> NativeValueStorage {
        if kind == .void { return NativeValueStorage(size: 0, alignment: alignment) }
        return try encode(value)
    }

    private func convert(_ value: Any) throws -> Value {
        if let optional = Value.self as? any NativeOptionalValue.Type {
            return try optional.wrapping(value) as! Value
        }
        guard let result = value as? Value else {
            throw ABIInvocationError.incompatibleValue(expected: String(reflecting: Value.self),
                                                      actual: String(reflecting: type(of: value)))
        }
        return result
    }

    private func nilResult() throws -> Value {
        guard let optional = Value.self as? any NativeOptionalValue.Type else {
            throw ABIInvocationError.unexpectedNilResult(expected: String(reflecting: Value.self))
        }
        return optional.nilValue as! Value
    }

    private static func mismatch(_ encoding: String) -> ABIResolutionError {
        .signatureMismatch(expected: String(reflecting: Value.self), found: [encoding])
    }

    private static func copyBlock(_ object: AnyObject) throws -> AnyObject {
        guard let copy = ABICopyObjCBlock(Unmanaged.passUnretained(object).toOpaque()) else {
            throw ABIInvocationError.incompatibleValue(
                expected: String(reflecting: Value.self), actual: String(reflecting: Swift.type(of: object))
            )
        }
        return Unmanaged<AnyObject>.fromOpaque(copy).takeRetainedValue()
    }

    private static func isBlockType(_ type: Any.Type) -> Bool {
        // Swift ABI FunctionTypeMetadata: kind word, then FunctionTypeFlags.
        // Block convention is 1 in bits 16...23; ordinary Swift/C functions differ.
        // https://github.com/swiftlang/swift/blob/main/include/swift/ABI/MetadataValues.h
        let metadata = unsafeBitCast(type, to: UnsafePointer<UInt>.self)
        return metadata[0] == 0x302 && metadata[1] & 0x00FF0000 == 0x00010000
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
