import ABIBridgeRuntime
import ABIBridgeCore
import ObjectiveC

/// Reads the stable Swift class ABI, not the current contents of virtual slots.
/// Resolve the introducing descriptor by declaration: unrelated optimized
/// methods can share code addresses, and current slots can contain interposers.
/// Layouts follow swift/ABI/Metadata.h; arm64e descriptor-pointer constants
/// and method discriminators are also checked against compiler-generated IR.
struct SwiftClassDispatch {
    let runtime: RuntimeClassDispatch
    var address: UInt { runtime.address }
    var authentication: NativePointerAuthentication {
        NativePointerAuthentication(runtime.authentication)
    }
    var isSetter: Bool { runtime.isSetter }
    var descriptor: ResolvedSymbol { ResolvedSymbol(runtime.descriptor) }
    init(
        metadata: Any.Type,
        declaration: NativeDeclaration,
        resolver: SymbolResolver,
        asynchronous: Bool = false
    ) throws {
        runtime = try withRuntimeErrors {
            try RuntimeClassDispatch(
                metadata: metadata,
                declaration: declaration.runtimeValue,
                resolver: resolver.runtime,
                asynchronous: asynchronous
            )
        }
    }
    static func nominalDescriptor(of type: AnyClass) throws -> UInt? {
        try withRuntimeErrors { try RuntimeClassDispatch.nominalDescriptor(of: type) }
    }
}
