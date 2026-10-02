import ABIBridgeCore

/// Symbolic type references retain their descriptor identity and defining image.
struct SwiftNominalDescriptor: Sendable, Equatable {
    private let address: UInt
    let image: NativeImage?
    let name: String

    init(address: UnsafeRawPointer) throws {
        self.address = UInt(bitPattern: address)
        image = try swiftImplementationImage(containing: address)
        let field = address.advanced(by: 8)
        let offset = Int(field.loadUnaligned(as: Int32.self))
        name = String(cString: field.advanced(by: offset).assumingMemoryBound(to: CChar.self))
    }

    init(_ symbol: ResolvedSymbol) throws {
        self = try unsafe symbol.withUnsafeAddress { try Self(address: $0) }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.address == rhs.address }

    @unsafe func withUnsafeAddress<Result>(_ body: (UnsafeRawPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawPointer(bitPattern: address)!)
    }
}
