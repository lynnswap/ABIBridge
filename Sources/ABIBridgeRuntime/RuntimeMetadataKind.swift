package enum RuntimeMetadataKind: UInt {
    case structure = 0x200
    case enumeration = 0x201
    case optional = 0x202
    case opaque = 0x300
    case tuple = 0x301
    case function = 0x302
    case existential = 0x303
    case metatype = 0x304
    case existentialMetatype = 0x306
    case extendedExistential = 0x307
}

package func runtimeMetadataKind(_ type: Any.Type) -> RuntimeMetadataKind? {
    RuntimeMetadataKind(
        rawValue: unsafeBitCast(type, to: UnsafeRawPointer.self).load(as: UInt.self)
    )
}
