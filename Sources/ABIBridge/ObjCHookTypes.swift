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
        return try hookValueType(type)
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

private func hookValueType(_ type: ObjCType) throws -> OpaquePointer {
    let kind: Int
    switch type {
    case .modified(_, let type): return try hookValueType(type)
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
    case .pointer, .charPtr, .functionPointer, .object, .class, .selector, .block: kind = ABIValuePointer
    case .struct(_, let fields):
        guard let fields, !fields.isEmpty, fields.allSatisfy({ $0.bitWidth == nil }) else {
            throw ABIResolutionError.unsupportedDeclaration("Opaque or bitfield structures need an adapter.")
        }
        var types: [OpaquePointer?] = []
        defer { for case let type? in types { ABIReleaseValueType(type) } }
        for field in fields { types.append(try hookValueType(field.type)) }
        var failure: OpaquePointer?
        guard let result = types.withUnsafeBufferPointer({ ABICreateStructType($0.baseAddress, $0.count, &failure) }) else {
            throw consumeNativeCallFailure(failure)
        }
        return result
    default:
        throw ABIResolutionError.unsupportedDeclaration("The Objective-C value needs an explicit ABI adapter.")
    }
    var failure: OpaquePointer?
    guard let result = ABICreateScalarType(Int32(kind), &failure) else { throw consumeNativeCallFailure(failure) }
    return result
}
