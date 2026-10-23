import ABIBridgeRuntime
import ABIBridgeCore
import ObjectiveC

/// Reads the stable Swift class ABI, not the current contents of virtual slots. Resolve the introducing descriptor by declaration: unrelated optimized methods can share code addresses, and current slots can contain interposers. Layouts follow swift/ABI/Metadata.h; arm64e descriptor-pointer constants and method discriminators are also checked against compiler-generated IR.
struct SwiftClassDispatch: Sendable {
    let runtime: RuntimeClassDispatch
    var address: UInt { runtime.address }
    var authentication: NativePointerAuthentication {
        NativePointerAuthentication(runtime.authentication)
    }
    var isAsync: Bool { runtime.isAsync }
    /// The image of the class that introduces the slot.
    var image: NativeImage { NativeImage(runtime.image) }

    /// The virtual-table entry that calls of `entry`'s declaration read in
    /// the metadata of `metadata`.
    ///
    /// - Parameter asynchronous: The requested effect, when known. An entry
    ///   with another effect does not apply.
    init(
        metadata: Any.Type,
        entry: SwiftEntry,
        resolver: SymbolResolver,
        asynchronous: Bool?
    ) throws {
        guard let record = entry.record else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Virtual dispatch requires a Swift class member."
            )
        }
        runtime = try withRuntimeErrors {
            try RuntimeClassDispatch(
                metadata: metadata,
                declaration: record,
                resolver: resolver.runtime,
                asynchronous: asynchronous
            )
        }
    }

    static func nominalDescriptor(of type: AnyClass) throws -> UInt? {
        try withRuntimeErrors { try RuntimeClassDispatch.nominalDescriptor(of: type) }
    }
}
