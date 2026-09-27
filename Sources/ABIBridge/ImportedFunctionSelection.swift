import ABIBridgeCore
import Foundation
import MachO
import MachOKit

final class ImportedFunctionSelection {
    let references: [ImportedReference]
    let slots: [ABIImportSlot]

    static func validate(_ declaration: NativeDeclaration, language: NativeLanguage? = nil) throws {
        guard declaration.kind == .function, (language.map { declaration.language == $0 } ?? [.c, .cxx].contains(declaration.language)), !declaration.name.utf8.contains(0) else {
            throw ABIResolutionError.unsupportedDeclaration("The imported declaration does not match this operation's function language.")
        }
    }

    convenience init(resolver: SymbolResolver, declaration: NativeDeclaration, importer: ImageSelector, provider: ImageSelector?, language: NativeLanguage? = nil) throws {
        try Self.validate(declaration, language: language)
        let images = try resolver.images(matching: importer)
        try self.init(resolver: resolver, declaration: declaration, images: images, provider: provider, language: language)
    }

    init(resolver: SymbolResolver, declaration: NativeDeclaration, images: [NativeImage], provider: ImageSelector?, language: NativeLanguage? = nil) throws {
        try Self.validate(declaration, language: language)
        guard !images.isEmpty else { throw ABIResolutionError.imageNotLoaded }
        var found: [ImportedReference] = []
        for image in images {
            found += try resolver.importIndex(for: image).matches(declaration).filter { reference in
                guard let provider else { return true }
                switch provider {
                case .automatic: return true
                case .installName(let value): return reference.libraryName?.utf8.elementsEqual(value.utf8) == true
                case .path(let url):
                    return reference.libraryName.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() } ?? false
                case .framework(let name):
                    return reference.libraryName.map { path in
                        let url = URL(fileURLWithPath: path)
                        return url.lastPathComponent == name && url.pathComponents.contains("\(name).framework")
                    } ?? false
                }
            }
        }
        guard !found.isEmpty else { throw ABIResolutionError.declarationNotFound(declaration) }
        var seen = Set<UInt64>()
        found = found.filter { seen.insert($0.address).inserted }
        slots = try found.map { reference in
            guard reference.width == MemoryLayout<UnsafeRawPointer>.size, reference.addend == 0,
                  let authentication = reference.authentication else {
                throw ABIResolutionError.unsupportedDeclaration("The imported function needs a pointer-width zero-addend slot with a known authentication schema.")
            }
            if reference.isLazyBinding {
                let image = MachOImage(ptr: UnsafePointer<mach_header>(bitPattern: UInt(reference.image.identity.headerAddress))!)
                var bits: UInt = 0
                let read = ABIReadMemory(UInt(reference.address), MemoryLayout<UInt>.size, &bits)
                guard read.status == ABIMemoryReadComplete else { throw ABIResolutionError.invalidAddress }
                // Only reject the actual lazy binder entry, not every record
                // originating in the lazy stream. Do not warm up arbitrary calls.
                if image.sections.contains(where: { section in
                    let start = Int64(section.address) + reference.image.identity.slide
                    return section.sectionName == "__stub_helper" && UInt64(bits) >= UInt64(bitPattern: start)
                        && UInt64(bits) - UInt64(bitPattern: start) < UInt64(section.size)
                }) { throw ABIResolutionError.unsupportedDeclaration("The import is still lazy-bound; call it normally before installing its hook.") }
            }
            return ABIImportSlot(slot: UInt(reference.address), generation: reference.image.identity.loadGeneration,
                key: authentication.keyCode, discriminator: authentication.discriminator, addressDiversity: authentication.addressDiversity)
        }
        references = found
    }

    func retainedHandle() -> OpaquePointer { OpaquePointer(Unmanaged.passRetained(self).toOpaque()) }
}

/// An immutable monitoring request. Per-image resolvers are short-lived so a
/// no-match or failure cannot keep every inspected image in a resolver cache.
final class ImportedFunctionQuery {
    let declaration: NativeDeclaration
    let importer: ImageSelector
    let provider: ImageSelector?

    init(declaration: NativeDeclaration, importer: ImageSelector, provider: ImageSelector?) throws {
        try ImportedFunctionSelection.validate(declaration)
        try importer.validateTarget()
        try provider?.validateTarget()
        self.declaration = declaration
        self.importer = importer
        self.provider = provider
    }

    func select(_ snapshot: ImageSnapshot) throws -> ImportedFunctionSelection? {
        guard try !ImageSnapshot.matching(importer, in: [snapshot]).isEmpty else { return nil }
        return try ImportedFunctionSelection(resolver: SymbolResolver(), declaration: declaration,
            images: [snapshot.retain()], provider: provider)
    }

    func retainedHandle() -> OpaquePointer { OpaquePointer(Unmanaged.passRetained(self).toOpaque()) }
}

@_cdecl("ABIReleaseImportedQuery")
package func releaseImportedQuery(_ query: OpaquePointer) {
    Unmanaged<ImportedFunctionQuery>.fromOpaque(UnsafeRawPointer(query)).release()
}

@_cdecl("ABIRetainImportSelection")
package func retainImportSelection(_ value: OpaquePointer) { _ = Unmanaged<ImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value)).retain() }
@_cdecl("ABIReleaseImportSelection")
package func releaseImportSelection(_ value: OpaquePointer) { Unmanaged<ImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value)).release() }
@_cdecl("ABIImportSelectionCount")
package func importSelectionCount(_ value: OpaquePointer) -> Int {
    Unmanaged<ImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value)).takeUnretainedValue().slots.count
}
@_cdecl("ABIImportSelectionGet")
package func importSelectionGet(_ value: OpaquePointer, _ index: Int) -> ABIImportSlot {
    Unmanaged<ImportedFunctionSelection>.fromOpaque(UnsafeRawPointer(value)).takeUnretainedValue().slots[index]
}
