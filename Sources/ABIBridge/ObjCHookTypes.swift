import ABIBridgeRuntime
import ObjCTypeDecodeKit

func objcValueType(_ type: ObjCType) throws -> OpaquePointer {
    try withRuntimeErrors { try ABIBridgeRuntime.objcValueType(type) }
}
