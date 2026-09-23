import ABIBridgeCore
import Foundation

private final class NativeSymbolBox {
    let symbol: ResolvedSymbol
    let path: UnsafeMutablePointer<CChar>

    init(_ symbol: ResolvedSymbol) {
        self.symbol = symbol
        path = strdup(symbol.image.path)!
    }

    deinit { free(path) }
}

private func nativeFailure(_ error: Error) -> OpaquePointer {
    let code: Int32
    switch error {
    case ABIResolutionError.imageUnavailable: code = Int32(ABIFailureImageUnavailable)
    case ABIResolutionError.imageNotLoaded: code = Int32(ABIFailureImageNotLoaded)
    case ABIResolutionError.declarationNotFound: code = Int32(ABIFailureDeclarationNotFound)
    case ABIResolutionError.ambiguousDeclaration: code = Int32(ABIFailureAmbiguousDeclaration)
    case ABIResolutionError.signatureMismatch: code = Int32(ABIFailureSignatureMismatch)
    case ABIResolutionError.unsupportedDeclaration: code = Int32(ABIFailureUnsupportedDeclaration)
    case ABIResolutionError.metadataUnavailable: code = Int32(ABIFailureMetadataUnavailable)
    case ABIResolutionError.imageChanged: code = Int32(ABIFailureImageChanged)
    case ABIResolutionError.invalidAddress: code = Int32(ABIFailureInvalidAddress)
    case is InvalidNativeRequest: code = Int32(ABIFailureInvalidRequest)
    default: code = Int32(ABIFailureOther)
    }
    return String(describing: error).withCString { ABICreateResolutionFailure(code, $0)! }
}

private struct InvalidNativeRequest: Error {
    let description: String
}

private func retained<T: AnyObject>(_ object: T) -> OpaquePointer {
    OpaquePointer(Unmanaged.passRetained(object).toOpaque())
}

private func borrowed<T: AnyObject>(_ pointer: OpaquePointer, as type: T.Type) -> T {
    Unmanaged<T>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
}

// Package access preserves external C linkage through Xcode's optimized
// relocatable link while keeping these names out of the public Swift API.
// Inspection.h documents their ownership and pointer contracts.
@_cdecl("ABICreateSymbolRuntime")
package func nativeCreateSymbolRuntime() -> OpaquePointer {
    retained(SymbolResolver())
}

@_cdecl("ABICopySharedSymbolRuntime")
package func nativeCopySharedSymbolRuntime() -> OpaquePointer {
    retained(SymbolResolver.shared)
}

@_cdecl("ABIReleaseSymbolRuntime")
package func nativeReleaseSymbolRuntime(_ runtime: OpaquePointer) {
    Unmanaged<SymbolResolver>.fromOpaque(UnsafeRawPointer(runtime)).release()
}

@_cdecl("ABIRuntimeRemoveCachedResults")
package func nativeRemoveCachedResults(_ runtime: OpaquePointer) {
    borrowed(runtime, as: SymbolResolver.self).removeCachedResults()
}

@_cdecl("ABIResolveSymbol")
package func nativeResolveSymbol(
    _ runtime: OpaquePointer,
    _ name: UnsafePointer<CChar>,
    _ language: Int32,
    _ kind: Int32,
    _ scope: Int32,
    _ selector: UnsafePointer<CChar>?,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        let sourceLanguage: NativeLanguage
        switch language {
        case Int32(ABILanguageSwift): sourceLanguage = .swift
        case Int32(ABILanguageObjectiveC): sourceLanguage = .objectiveC
        case Int32(ABILanguageC): sourceLanguage = .c
        case Int32(ABILanguageCXX): sourceLanguage = .cxx
        default: throw InvalidNativeRequest(description: "Unknown source language: \(language)")
        }
        let symbolKind: NativeSymbolKind
        switch kind {
        case Int32(ABISymbolFunction): symbolKind = .function
        case Int32(ABISymbolData): symbolKind = .data
        case Int32(ABISymbolVTable): symbolKind = .vtable
        default: throw InvalidNativeRequest(description: "Unknown symbol kind: \(kind)")
        }
        let imageSelector: ImageSelector
        switch scope {
        case Int32(ABIImageAutomatic): imageSelector = .automatic
        case Int32(ABIImageFramework), Int32(ABIImagePath):
            guard let selector else {
                throw InvalidNativeRequest(description: "A framework or executable path is required.")
            }
            let value = String(cString: selector)
            imageSelector = scope == Int32(ABIImageFramework)
                ? .framework(named: value) : .path(URL(fileURLWithPath: value))
        default: throw InvalidNativeRequest(description: "Unknown image scope: \(scope)")
        }
        let declaration = NativeDeclaration(
            name: String(cString: name), language: sourceLanguage, kind: symbolKind
        )
        let symbol = try borrowed(runtime, as: SymbolResolver.self)
            .resolve(declaration, in: imageSelector)
        return retained(NativeSymbolBox(symbol))
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

@_cdecl("ABIReleaseResolvedSymbol")
package func nativeReleaseResolvedSymbol(_ symbol: OpaquePointer) {
    Unmanaged<NativeSymbolBox>.fromOpaque(UnsafeRawPointer(symbol)).release()
}

@_cdecl("ABIResolvedSymbolAddress")
package func nativeResolvedSymbolAddress(_ symbol: OpaquePointer) -> UnsafeRawPointer {
    let box = borrowed(symbol, as: NativeSymbolBox.self)
    return UnsafeRawPointer(bitPattern: UInt(box.symbol.address))!
}

@_cdecl("ABIResolvedSymbolImage")
package func nativeResolvedSymbolImage(_ symbol: OpaquePointer, _ info: UnsafeMutablePointer<ABIImageInfo>) {
    let box = borrowed(symbol, as: NativeSymbolBox.self)
    let identity = box.symbol.image.identity
    info.pointee = ABIImageInfo(
        header: UInt(identity.headerAddress),
        slide: Int(identity.slide),
        generation: identity.loadGeneration,
        uuid: identity.uuid?.uuid ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        path: UnsafePointer(box.path)
    )
}
