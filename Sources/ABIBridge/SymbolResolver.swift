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
    func swiftDeclarationCandidates(
        _ declaration: NativeDeclaration,
        in selector: ImageSelector,
        loading: ImageLoadingPolicy,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [SwiftCandidate] {
        try withRuntimeErrors {
            try runtime.swiftDeclarationCandidates(
                declaration.runtimeValue,
                in: selector.runtimeValue,
                loading: loading.runtimeValue,
                extensionsOnly: extensionsOnly,
                includingSharedCache: includingSharedCache
            ).map(SwiftCandidate.init)
        }
    }
    func swiftDeclarationCandidates(
        _ declaration: NativeDeclaration,
        in image: NativeImage?,
        loading: ImageLoadingPolicy = .loadedOnly,
        module: String? = nil,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [SwiftCandidate] {
        try withRuntimeErrors {
            try runtime.swiftDeclarationCandidates(
                declaration.runtimeValue,
                in: image?.runtimeValue,
                loading: loading.runtimeValue,
                module: module,
                extensionsOnly: extensionsOnly,
                includingSharedCache: includingSharedCache
            ).map(SwiftCandidate.init)
        }
    }
    func swiftTypeIdentity(
        of metadata: Any.Type,
        in image: NativeImage
    ) throws -> RuntimeSwiftTypeIdentity {
        try withRuntimeErrors {
            try RuntimeSwiftTypeIdentity(
                metadata: metadata,
                in: image.runtimeValue,
                resolver: runtime
            )
        }
    }

    /// The candidates of a member of `owner`, whose records `match` accepts.
    func swiftMemberCandidates(
        _ match: SwiftMemberMatch,
        owner: String,
        in image: NativeImage?,
        loading: ImageLoadingPolicy = .loadedOnly,
        module: String? = nil,
        extensionsOnly: Bool = false,
        includingSharedCache: Bool = false
    ) throws -> [SwiftCandidate] {
        try withRuntimeErrors {
            try runtime.swiftMemberCandidates(
                match,
                owner: owner,
                in: image?.runtimeValue,
                loading: loading.runtimeValue,
                module: module,
                extensionsOnly: extensionsOnly,
                includingSharedCache: includingSharedCache
            ).map(SwiftCandidate.init)
        }
    }
    func swiftWitnesses(
        ofConformanceAt descriptor: UnsafeRawPointer,
        in image: NativeImage
    ) -> [SwiftCandidate] {
        runtime.swiftWitnesses(
            ofConformanceAt: UInt64(UInt(bitPattern: descriptor)),
            in: image.runtimeValue
        ).map(SwiftCandidate.init)
    }
    func swiftConformanceDescriptor(
        named name: String,
        in image: NativeImage
    ) -> UnsafeRawPointer? {
        runtime.swiftConformanceDescriptor(named: name, in: image.runtimeValue).flatMap {
            UnsafeRawPointer(bitPattern: UInt($0))
        }
    }
    func swiftMethodDescriptorRequirements(
        at address: UnsafeRawPointer,
        in image: NativeImage
    ) -> Set<String> {
        runtime.swiftMethodDescriptorRequirements(
            at: UInt64(UInt(bitPattern: address)),
            in: image.runtimeValue
        )
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
