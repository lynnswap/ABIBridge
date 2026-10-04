import ABIBridgeRuntime
import ABIBridgeCore

/// Symbolic type references retain their descriptor identity and defining image.
struct SwiftNominalDescriptor: Sendable, Equatable {
    let runtime: RuntimeNominalDescriptor
    var image: NativeImage? { runtime.image.map(NativeImage.init) }
    var name: String { runtime.name }
    init(address: UnsafeRawPointer) throws {
        runtime = try withRuntimeErrors { try RuntimeNominalDescriptor(address: address) }
    }
    init(_ symbol: ResolvedSymbol) throws {
        runtime = try withRuntimeErrors { try RuntimeNominalDescriptor(symbol.runtimeValue) }
    }
    @unsafe func withUnsafeAddress<Result>(
        _ body: (UnsafeRawPointer) throws -> Result
    ) rethrows -> Result {
        try unsafe runtime.withUnsafeAddress(body)
    }
}
