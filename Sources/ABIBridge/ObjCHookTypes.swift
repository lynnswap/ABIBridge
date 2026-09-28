import ABIBridgeCore
import Foundation
import ObjCTypeDecodeKit

// Native clients use the same Objective-C decoder as Swift. No generated Swift
// header or second encoding parser is required by the C/C++ consumer surface.
@_cdecl("ABICopyObjCHookValueType")
package func nativeCopyObjCHookValueType(
    _ encoding: UnsafePointer<CChar>?, _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        guard let encoding, let node = ObjCTypeDecoder._decode(String(cString: encoding)),
              let type = node.decoded, node.trailing?.isEmpty != false else {
            throw ABIResolutionError.unsupportedDeclaration("Invalid Objective-C type encoding.")
        }
        return try objcValueType(type)
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

private func objcAggregateType(_ fields: [OpaquePointer?]) throws -> OpaquePointer {
    var failure: OpaquePointer?
    guard let result = fields.withUnsafeBufferPointer({ ABICreateStructType($0.baseAddress, $0.count, &failure) }) else {
        throw consumeNativeCallFailure(failure)
    }
    return result
}

func objcValueType(_ type: ObjCType) throws -> OpaquePointer {
    let kind: Int
    switch type {
    case .modified(_, let type): return try objcValueType(type)
    case .void: kind = ABIValueVoid
    case .char: kind = ABIValueInt8
    case .uchar, .bool: kind = ABIValueUInt8
    case .short: kind = ABIValueInt16
    case .ushort: kind = ABIValueUInt16
    case .int: kind = ABIValueInt32
    case .uint: kind = ABIValueUInt32
    case .long: kind = MemoryLayout<CLong>.size == 8 ? ABIValueInt64 : ABIValueInt32
    case .ulong: kind = MemoryLayout<CUnsignedLong>.size == 8 ? ABIValueUInt64 : ABIValueUInt32
    case .longLong: kind = ABIValueInt64
    case .ulongLong: kind = ABIValueUInt64
    case .float: kind = ABIValueFloat
    case .double: kind = ABIValueDouble
    case .longDouble:
#if arch(x86_64)
        throw ABIResolutionError.unsupportedDeclaration("x87 long double encodings require a native adapter.")
#else
        // Apple's ARM ABI gives long double the size and representation of double.
        kind = ABIValueDouble
#endif
    case .pointer, .charPtr, .functionPointer, .object, .class, .selector, .block: kind = ABIValuePointer
    case .array(let element, let count):
        guard let count, count > 0 else {
            throw ABIResolutionError.unsupportedDeclaration("An aggregate array field requires a positive element count.")
        }
        var chunk = try objcValueType(element)
        var owned = [chunk]
        defer { owned.forEach(ABIReleaseValueType) }
        // Nested groups of identical elements have the same offsets, alignment,
        // and aggregate ABI as a flat array. Keep descriptors logarithmic in the
        // element count instead of allocating one pointer for every element.
        var remaining = count
        var fields: [OpaquePointer?] = []
        while remaining > 0 {
            if remaining & 1 != 0 { fields.append(chunk) }
            remaining >>= 1
            if remaining > 0 {
                chunk = try objcAggregateType([chunk, chunk])
                owned.append(chunk)
            }
        }
        return try objcAggregateType(fields)
    case .struct(_, let fields):
        guard let fields, !fields.isEmpty, fields.allSatisfy({ $0.bitWidth == nil }) else {
            throw ABIResolutionError.unsupportedDeclaration("Opaque or bitfield structures need an adapter.")
        }
        var types: [OpaquePointer?] = []
        defer { for case let type? in types { ABIReleaseValueType(type) } }
        for field in fields { types.append(try objcValueType(field.type)) }
        return try objcAggregateType(types)
    default:
        throw ABIResolutionError.unsupportedDeclaration("The Objective-C value needs an explicit ABI adapter.")
    }
    var failure: OpaquePointer?
    guard let result = ABICreateScalarType(Int32(kind), &failure) else { throw consumeNativeCallFailure(failure) }
    return result
}
