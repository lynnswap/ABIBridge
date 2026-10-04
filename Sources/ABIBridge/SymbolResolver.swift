import ABIBridgeRuntime

// The public Swift API and C entry points share the runtime's single index owner.
final class SymbolResolver: Sendable {
    static let shared = SymbolResolver(RuntimeSymbolResolver.shared)
    let runtime: RuntimeSymbolResolver
    init(_ runtime: RuntimeSymbolResolver = RuntimeSymbolResolver()) { self.runtime = runtime }

    func images(matching selector: ImageSelector) throws -> [NativeImage] {
        try withRuntimeErrors {
            try runtime.images(matching: selector.runtimeValue).map(NativeImage.init)
        }
    }
    func resolve(
        _ declaration: NativeDeclaration,
        in selector: ImageSelector,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> ResolvedSymbol {
        try withRuntimeErrors {
            ResolvedSymbol(
                try runtime.resolve(
                    declaration.runtimeValue,
                    in: selector.runtimeValue,
                    loading: loading.runtimeValue
                )
            )
        }
    }
    func resolve(
        _ declaration: NativeDeclaration,
        in image: NativeImage,
        loading: ImageLoadingPolicy = .ifNeeded
    ) throws -> ResolvedSymbol {
        try withRuntimeErrors {
            ResolvedSymbol(
                try runtime.resolve(
                    declaration.runtimeValue,
                    in: image.runtimeValue,
                    loading: loading.runtimeValue
                )
            )
        }
    }
    func resolve(_ request: NativeSymbolRequest) throws -> ResolvedSymbol {
        try withRuntimeErrors { ResolvedSymbol(try runtime.resolve(request.runtimeValue)) }
    }
    func resolve(_ requests: [NativeSymbolRequest]) -> [Result<ResolvedSymbol, any Error>] {
        runtime.resolve(requests.map(\.runtimeValue)).map { result in
            Result { try withRuntimeErrors { ResolvedSymbol(try result.get()) } }
        }
    }
    func image(forSwiftClass type: AnyClass, lookup: () throws -> NativeImage) throws -> NativeImage
    {
        try withRuntimeErrors {
            NativeImage(try runtime.image(forSwiftClass: type) { try lookup().runtimeValue })
        }
    }
    func resolveSwiftExtension(
        _ declaration: NativeDeclaration,
        genericContext: SwiftGenericContext? = nil
    ) throws -> ResolvedSymbol {
        try withRuntimeErrors {
            ResolvedSymbol(
                try runtime.resolveSwiftExtension(
                    declaration.runtimeValue,
                    genericContext: genericContext
                )
            )
        }
    }
    func swiftDeclarationCandidates(
        _ declaration: NativeDeclaration,
        in selector: ImageSelector,
        loading: ImageLoadingPolicy
    ) throws -> [ResolvedSymbol] {
        try withRuntimeErrors {
            try runtime.swiftDeclarationCandidates(
                declaration.runtimeValue,
                in: selector.runtimeValue,
                loading: loading.runtimeValue
            ).map(ResolvedSymbol.init)
        }
    }
    func swiftDeclarationCandidates(
        _ declaration: NativeDeclaration,
        in image: NativeImage?,
        loading: ImageLoadingPolicy = .loadedOnly,
        extensionsOnly: Bool = false
    ) throws -> [ResolvedSymbol] {
        try withRuntimeErrors {
            try runtime.swiftDeclarationCandidates(
                declaration.runtimeValue,
                in: image?.runtimeValue,
                loading: loading.runtimeValue,
                extensionsOnly: extensionsOnly
            ).map(ResolvedSymbol.init)
        }
    }
    func removeCachedResults() { runtime.removeCachedResults() }
    func importIndex(for image: NativeImage) throws -> ImportIndex {
        try withRuntimeErrors { ImportIndex(try runtime.importIndex(for: image.runtimeValue)) }
    }
    func virtualEntry(
        named name: String,
        addressPoint: UInt,
        entryCount: Int
    ) throws -> VirtualEntryResolution {
        try withRuntimeErrors {
            let value = try runtime.virtualEntry(
                named: name,
                addressPoint: addressPoint,
                entryCount: entryCount
            )
            return .init(
                image: NativeImage(value.image),
                index: value.index,
                symbol: value.symbol,
                authentication: NativePointerAuthentication(value.authentication)
            )
        }
    }
    func swiftNominalTypeName(
        at address: UInt64,
        in image: NativeImage,
        suggestedName: String
    ) throws -> String? {
        try withRuntimeErrors {
            try runtime.swiftNominalTypeName(
                at: address,
                in: image.runtimeValue,
                suggestedName: suggestedName
            )
        }
    }
}

struct VirtualEntryResolution: Sendable {
    let image: NativeImage
    let index: Int
    let symbol: String
    let authentication: NativePointerAuthentication
}
