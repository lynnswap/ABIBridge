import ABIBridgeCore

package struct RuntimeNominalDescriptor: Sendable, Equatable {
    private let address: UInt
    package let image: RuntimeImage?
    package let name: String

    package init(address: UnsafeRawPointer) throws {
        self.address = UInt(bitPattern: address)
        image = try runtimeImplementationImage(containing: address)
        let field = address.advanced(by: 8)
        let offset = Int(field.loadUnaligned(as: Int32.self))
        name = String(cString: field.advanced(by: offset).assumingMemoryBound(to: CChar.self))
    }

    package init(_ symbol: RuntimeSymbol) throws {
        self = try unsafe symbol.withUnsafeAddress { try Self(address: $0) }
    }

    package static func == (lhs: Self, rhs: Self) -> Bool { lhs.address == rhs.address }

    @unsafe package func withUnsafeAddress<Result>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try body(UnsafeRawPointer(bitPattern: address)!)
    }
}
