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
    _ runtime: OpaquePointer, _ name: UnsafePointer<CChar>,
    _ language: Int32, _ kind: Int32, _ scope: Int32,
    _ selector: UnsafePointer<CChar>?, _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    nativeResolveSymbolWithNameForm(runtime, name, Int32(ABINameSource), language, kind, scope, selector, error)
}

@_cdecl("ABIResolveSymbolWithNameForm")
package func nativeResolveSymbolWithNameForm(
    _ runtime: OpaquePointer, _ name: UnsafePointer<CChar>, _ nameForm: Int32,
    _ language: Int32, _ kind: Int32, _ scope: Int32,
    _ selector: UnsafePointer<CChar>?, _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        let declaration = try nativeDeclaration(name, language: language, kind: kind, nameForm: nameForm)
        let imageSelector = try nativeImageSelector(scope: scope, selector: selector)
        let symbol = try borrowed(runtime, as: SymbolResolver.self)
            .resolve(declaration, in: imageSelector)
        return retained(NativeSymbolBox(symbol))
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

@_cdecl("ABIResolveCXXVTable")
package func nativeResolveCXXVTable(
    _ runtime: OpaquePointer, _ typeName: UnsafePointer<CChar>,
    _ scope: Int32, _ selector: UnsafePointer<CChar>?,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        let declaration = NativeDeclaration(vtableFor: String(cString: typeName))
        let imageSelector = try nativeImageSelector(scope: scope, selector: selector)
        let symbol = try borrowed(runtime, as: SymbolResolver.self).resolve(declaration, in: imageSelector)
        return retained(NativeSymbolBox(symbol))
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

extension ResolvedSymbol {
    /// Acquires a Swift symbol from a borrowed native inspection handle.
    ///
    /// The handle must be a live, non-null `ABIResolvedSymbol *` returned by this
    /// library and remain alive during this call. This initializer does not consume
    /// its reference. The result independently retains the same image and metadata
    /// without repeating lookup; the native handle can then be released.
    ///
    /// - Parameter handle: A borrowed symbol from the C inspection interface.
    @unsafe public init(retainingNativeHandle handle: OpaquePointer) {
        self = borrowed(handle, as: NativeSymbolBox.self).symbol
    }

    /// Creates an owned native inspection handle for this resolved symbol.
    ///
    /// The returned `ABIResolvedSymbol *` owns one reference. Transfer it to a
    /// native owner or release it exactly once with `ABIReleaseResolvedSymbol`.
    /// It retains this symbol's image and metadata independently of the Swift
    /// value and runtime caches, without repeating lookup.
    ///
    /// - Returns: An owned, non-null C inspection handle.
    @unsafe public func copyNativeHandle() -> OpaquePointer {
        retained(NativeSymbolBox(self))
    }
}

@_cdecl("ABIRetainResolvedSymbol")
package func nativeRetainResolvedSymbol(_ symbol: OpaquePointer) -> OpaquePointer {
    retained(borrowed(symbol, as: NativeSymbolBox.self))
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

private func nativeDeclaration(
    _ name: UnsafePointer<CChar>?, language: Int32, kind: Int32,
    nameForm: Int32 = Int32(ABINameSource)
) throws -> NativeDeclaration {
    guard let name else { throw InvalidNativeRequest(description: "A declaration name is required.") }
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

    guard let form = NativeSymbolNameForm(rawValue: nameForm) else {
        throw InvalidNativeRequest(description: "Unknown name representation: \(nameForm)")
    }
    return NativeDeclaration(name: String(cString: name), language: sourceLanguage, kind: symbolKind, nameForm: form)
}

private func nativeImageSelector(
    scope: Int32, selector: UnsafePointer<CChar>?
) throws -> ImageSelector {
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

    return imageSelector
}

private func nativeRequest(_ request: ABISymbolRequest) throws -> NativeSymbolRequest {
    guard request.alternativeCount >= 0, request.imageScopeCount >= 0, request.fallbackCount >= 0,
          request.alternativeCount == 0 || request.alternatives != nil,
          request.fallbackCount == 0 || request.fallbacks != nil,
          request.imageScopeCount == 0 || request.imageScopes != nil else {
        throw InvalidNativeRequest(description: "Nonempty request arrays require valid storage.")
    }
    let declaration = try nativeDeclaration(
        request.declaration.name, language: request.declaration.language, kind: request.declaration.kind,
        nameForm: request.declaration.nameForm
    )
    let alternatives = try UnsafeBufferPointer(start: request.alternatives, count: request.alternativeCount).map {
        try nativeDeclaration($0.name, language: $0.language, kind: $0.kind, nameForm: $0.nameForm)
    }
    let scopes = try UnsafeBufferPointer(start: request.imageScopes, count: request.imageScopeCount).map {
        try nativeImageSelector(scope: $0.scope, selector: $0.selector)
    }
    let fallbacks = try UnsafeBufferPointer(start: request.fallbacks, count: request.fallbackCount).map {
        try nativeDeclaration($0.name, language: $0.language, kind: $0.kind, nameForm: $0.nameForm)
    }
    return NativeSymbolRequest(declaration, alternatives: alternatives, fallbacks: fallbacks, in: scopes)
}

@_cdecl("ABIResolveSymbols")
package func nativeResolveSymbols(
    _ runtime: OpaquePointer, _ requests: UnsafePointer<ABISymbolRequest>?,
    _ count: Int, _ results: UnsafeMutablePointer<ABISymbolResult>?
) {
    let decoded = UnsafeBufferPointer(start: requests, count: count).map { request in
        Result { try nativeRequest(request) }
    }
    let valid = decoded.compactMap { try? $0.get() }
    var resolved = borrowed(runtime, as: SymbolResolver.self).resolve(valid).makeIterator()
    for (index, request) in decoded.enumerated() {
        switch request.flatMap({ _ in resolved.next()! }) {
        case .success(let symbol):
            results![index] = ABISymbolResult(symbol: retained(NativeSymbolBox(symbol)), failure: nil)
        case .failure(let error):
            results![index] = ABISymbolResult(symbol: nil, failure: nativeFailure(error))
        }
    }
}
