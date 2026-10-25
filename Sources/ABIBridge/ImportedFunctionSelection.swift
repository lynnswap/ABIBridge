import ABIBridgeRuntime
import ABIBridgeCore
import ABIBridgeCore.Backend

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

    /// The references to any of `symbols`, which name the Swift
    /// `declaration` that a failure to find any reference names.
    init(
        resolver: SymbolResolver,
        declaration: NativeDeclaration,
        symbols: [NativeDeclaration],
        importer: ImageSelector,
        provider: ImageSelector?
    ) throws {
        do {
            value = try withRuntimeErrors {
                try RuntimeImportedFunctionSelection(
                    resolver: resolver.runtime,
                    symbols: symbols.map(\.runtimeValue),
                    importer: importer.runtimeValue,
                    provider: provider?.runtimeValue,
                    language: .swift
                )
            }
        } catch ABIResolutionError.declarationNotFound {
            throw ABIResolutionError.declarationNotFound(declaration)
        }
    }

    func retainedHandle() -> OpaquePointer { value.retainedHandle() }
}
