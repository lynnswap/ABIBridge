import ABIBridgeRuntime

struct ImportedReference: Sendable {
    let value: RuntimeImportedReference
    var image: NativeImage { NativeImage(value.image) }
    var symbol: String { value.symbol }
    var libraryOrdinal: Int { value.libraryOrdinal }
    var libraryName: String? { value.libraryName }
    var weak: Bool { value.weak }
    var usesWeakCoalescing: Bool { value.usesWeakCoalescing }
    var isLazyBinding: Bool { value.isLazyBinding }
    var addend: Int64 { value.addend }
    var address: UInt64 { value.address }
    var width: Int { value.width }
    var authentication: NativePointerAuthentication? {
        value.authentication.map(NativePointerAuthentication.init)
    }
}

struct ImportIndex: Sendable {
    let value: ABIBridgeRuntime.ImportIndex
    init(_ value: ABIBridgeRuntime.ImportIndex) { self.value = value }
    init(image: NativeImage) throws {
        value = try withRuntimeErrors { try .init(image: image.runtimeValue) }
    }
    var image: NativeImage { NativeImage(value.image) }
    var references: [ImportedReference] { value.references.map { .init(value: $0) } }
    func matches(
        _ declaration: NativeDeclaration,
        libraryOrdinal: Int? = nil
    ) throws -> [ImportedReference] {
        try withRuntimeErrors {
            try value.matches(declaration.runtimeValue, libraryOrdinal: libraryOrdinal).map {
                .init(value: $0)
            }
        }
    }
}
