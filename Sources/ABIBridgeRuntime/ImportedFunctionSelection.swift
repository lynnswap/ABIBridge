import ABIBridgeCore
import Foundation
import MachO
import MachOKit

// Selection metadata and retained image leases are immutable. The C slot records
// contain addresses; reading or changing their pointees uses the native transport.
package final class RuntimeImportedFunctionSelection: @unchecked Sendable {
    package let references: [RuntimeImportedReference]
    package let slots: [ABIImportSlot]

    package static func validate(
        _ declaration: RuntimeDeclaration,
        language: RuntimeLanguage? = nil
    ) throws {
        guard declaration.kind == .function,
            (language.map { declaration.language == $0 }
                ?? [.c, .cxx].contains(declaration.language)), !declaration.name.utf8.contains(0)
        else {
            throw RuntimeResolutionError.unsupportedDeclaration(
                "The imported declaration does not match this operation's function language."
            )
        }
    }

    package convenience init(
        resolver: RuntimeSymbolResolver,
        declaration: RuntimeDeclaration,
        importer: RuntimeImageSelector,
        provider: RuntimeImageSelector?,
        language: RuntimeLanguage? = nil
    ) throws {
        try Self.validate(declaration, language: language)
        let images = try resolver.images(matching: importer)
        try self.init(
            resolver: resolver,
            declaration: declaration,
            images: images,
            provider: provider,
            language: language
        )
    }

    package init(
        resolver: RuntimeSymbolResolver,
        declaration: RuntimeDeclaration,
        images: [RuntimeImage],
        provider: RuntimeImageSelector?,
        language: RuntimeLanguage? = nil
    ) throws {
        try Self.validate(declaration, language: language)
        guard !images.isEmpty else { throw RuntimeResolutionError.imageNotLoaded }
        var found: [RuntimeImportedReference] = []
        for image in images {
            found += try resolver.importIndex(for: image).matches(declaration).filter { reference in
                guard let provider else { return true }
                switch provider {
                case .automatic: return true
                case .installName(let value):
                    return reference.libraryName?.utf8.elementsEqual(value.utf8) == true
                case .path(let url):
                    return reference.libraryName.map {
                        URL(fileURLWithPath: $0).resolvingSymlinksInPath()
                            == url.resolvingSymlinksInPath()
                    } ?? false
                case .framework(let name):
                    return reference.libraryName.map { path in
                        let url = URL(fileURLWithPath: path)
                        return url.lastPathComponent == name
                            && url.pathComponents.contains("\(name).framework")
                    } ?? false
                }
            }
        }
        guard !found.isEmpty else { throw RuntimeResolutionError.declarationNotFound(declaration) }
        var seen = Set<UInt64>()
        found = found.filter { seen.insert($0.address).inserted }
        slots = try found.map { reference in
            guard reference.width == MemoryLayout<UnsafeRawPointer>.size, reference.addend == 0,
                let authentication = reference.authentication
            else {
                throw RuntimeResolutionError.unsupportedDeclaration(
                    "The imported function needs a pointer-width zero-addend slot with a known authentication schema."
                )
            }
            if reference.isLazyBinding {
                let image = MachOImage(
                    ptr: UnsafePointer<mach_header>(
                        bitPattern: UInt(reference.image.identity.headerAddress)
                    )!
                )
                var bits: UInt = 0
                let read = ABIReadMemory(UInt(reference.address), MemoryLayout<UInt>.size, &bits)
                guard read.status == ABIMemoryReadComplete else {
                    throw RuntimeResolutionError.invalidAddress
                }
                // Only reject the actual lazy binder entry, not every record
                // originating in the lazy stream. Do not warm up arbitrary calls.
                if image.sections.contains(where: { section in
                    let start = Int64(section.address) + reference.image.identity.slide
                    return section.sectionName == "__stub_helper"
                        && UInt64(bits) >= UInt64(bitPattern: start)
                        && UInt64(bits) - UInt64(bitPattern: start) < UInt64(section.size)
                }) {
                    throw RuntimeResolutionError.unsupportedDeclaration(
                        "The import is still lazy-bound; call it normally before installing its hook."
                    )
                }
            }
            return ABIImportSlot(
                slot: UInt(reference.address),
                generation: reference.image.identity.loadGeneration,
                key: authentication.keyCode,
                discriminator: authentication.discriminator,
                addressDiversity: authentication.addressDiversity
            )
        }
        references = found
    }

    package func retainedHandle() -> OpaquePointer {
        OpaquePointer(Unmanaged.passRetained(self).toOpaque())
    }
}

package final class RuntimeImportedFunctionQuery {
    package let declaration: RuntimeDeclaration
    package let importer: RuntimeImageSelector
    package let provider: RuntimeImageSelector?

    package init(
        declaration: RuntimeDeclaration,
        importer: RuntimeImageSelector,
        provider: RuntimeImageSelector?
    ) throws {
        try RuntimeImportedFunctionSelection.validate(declaration)
        try importer.validateTarget()
        try provider?.validateTarget()
        self.declaration = declaration
        self.importer = importer
        self.provider = provider
    }

    package func select(
        _ snapshot: RuntimeImageSnapshot
    ) throws -> RuntimeImportedFunctionSelection? {
        guard try !RuntimeImageSnapshot.matching(importer, in: [snapshot]).isEmpty else {
            return nil
        }
        return try RuntimeImportedFunctionSelection(
            resolver: RuntimeSymbolResolver(),
            declaration: declaration,
            images: [snapshot.retain()],
            provider: provider
        )
    }

    package func retainedHandle() -> OpaquePointer {
        OpaquePointer(Unmanaged.passRetained(self).toOpaque())
    }
}

@c(ABIReleaseImportedQuery)
package func releaseImportedQuery(_ query: OpaquePointer) {
    Unmanaged<RuntimeImportedFunctionQuery>.fromOpaque(UnsafeRawPointer(query)).release()
}

@c(ABIRetainImportSelection)
package func retainImportSelection(_ value: OpaquePointer) {
    _ = Unmanaged<RuntimeImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value)).retain()
}
@c(ABIReleaseImportSelection)
package func releaseImportSelection(_ value: OpaquePointer) {
    Unmanaged<RuntimeImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value)).release()
}
@c(ABIImportSelectionCount)
package func importSelectionCount(_ value: OpaquePointer) -> Int {
    Unmanaged<RuntimeImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value))
        .takeUnretainedValue().slots.count
}
@c(ABIImportSelectionGet)
package func importSelectionGet(_ value: OpaquePointer, _ index: Int) -> ABIImportSlot {
    Unmanaged<RuntimeImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value))
        .takeUnretainedValue().slots[index]
}
