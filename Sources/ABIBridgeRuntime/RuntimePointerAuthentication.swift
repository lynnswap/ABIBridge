import ABIBridgeCore

package enum RuntimePointerAuthentication: Sendable, Hashable {
    case unsigned
    case signed(key: Key, discriminator: UInt = 0, addressDiversity: Bool = false)

    package enum Key: Int32, Sendable, Hashable {
        case instructionA = 0
        case instructionB = 1
        case dataA = 2
        case dataB = 3
    }

    package static var isEnabled: Bool { ABIUsesPointerAuthentication() }

    package static func cxxVTablePointer(discriminator: UInt) -> Self {
        .signed(key: .dataA, discriminator: discriminator, addressDiversity: true)
    }

    package static func cxxVirtualFunction(discriminator: UInt) -> Self {
        .signed(key: .instructionA, discriminator: discriminator, addressDiversity: true)
    }

    package var keyCode: Int32 {
        switch self {
        case .unsigned: Int32(ABIAuthenticationUnsigned)
        case .signed(let key, _, _): key.rawValue
        }
    }
    package var discriminator: UInt {
        switch self {
        case .unsigned: 0
        case .signed(_, let value, _): value
        }
    }
    package var addressDiversity: Bool {
        switch self {
        case .unsigned: false
        case .signed(_, _, let value): value
        }
    }
}
