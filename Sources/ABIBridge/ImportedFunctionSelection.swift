import ABIBridgeRuntime
import ABIBridgeCore

final class ImportedFunctionSelection: Sendable {
    let value: RuntimeImportedFunctionSelection
    var references: [ImportedReference] { value.references.map { ImportedReference(value: $0) } }
    var slots: [ABIImportSlot] { value.slots }

    init(
        resolver: SymbolResolver,
        declaration: NativeDeclaration,
        importer: ImageSelector,
        provider: ImageSelector?,
        language: NativeLanguage? = nil
    ) throws {
        value = try withRuntimeErrors {
            try RuntimeImportedFunctionSelection(
                resolver: resolver.runtime,
                declaration: declaration.runtimeValue,
                importer: importer.runtimeValue,
                provider: provider?.runtimeValue,
                language: language?.runtimeValue
            )
        }
    }

    /// The references to any of `symbols`, which name one Swift declaration.
    init(
        resolver: SymbolResolver,
        symbols: [NativeDeclaration],
        importer: ImageSelector,
        provider: ImageSelector?
    ) throws {
        value = try withRuntimeErrors {
            try RuntimeImportedFunctionSelection(
                resolver: resolver.runtime,
                symbols: symbols.map(\.runtimeValue),
                importer: importer.runtimeValue,
                provider: provider?.runtimeValue,
                language: .swift
            )
        }
    }

    func retainedHandle() -> OpaquePointer { value.retainedHandle() }
}
