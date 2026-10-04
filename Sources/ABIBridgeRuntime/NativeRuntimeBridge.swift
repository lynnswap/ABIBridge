import ABIBridgeCore
import Foundation

private final class NativeSymbolBox {
    let symbol: RuntimeSymbol
    let path: UnsafeMutablePointer<CChar>

    init(_ symbol: RuntimeSymbol) {
        self.symbol = symbol
        path = strdup(symbol.image.path)!
    }

    deinit { free(path) }
}

package func nativeFailure(_ error: Error) -> OpaquePointer {
    let code: Int32
    switch error {
    case RuntimeResolutionError.imageUnavailable: code = Int32(ABIFailureImageUnavailable)
    case RuntimeResolutionError.imageNotLoaded: code = Int32(ABIFailureImageNotLoaded)
    case RuntimeResolutionError.imageLoadFailed: code = Int32(ABIFailureImageLoadFailed)
    case RuntimeResolutionError.ambiguousImage: code = Int32(ABIFailureAmbiguousImage)
    case RuntimeResolutionError.invalidImageTarget: code = Int32(ABIFailureInvalidRequest)
    case RuntimeResolutionError.declarationNotFound: code = Int32(ABIFailureDeclarationNotFound)
    case RuntimeResolutionError.ambiguousDeclaration: code = Int32(ABIFailureAmbiguousDeclaration)
    case RuntimeResolutionError.signatureMismatch: code = Int32(ABIFailureSignatureMismatch)
    case RuntimeResolutionError.unsupportedDeclaration:
        code = Int32(ABIFailureUnsupportedDeclaration)
    case RuntimeResolutionError.metadataUnavailable: code = Int32(ABIFailureMetadataUnavailable)
    case RuntimeResolutionError.imageChanged: code = Int32(ABIFailureImageChanged)
    case RuntimeResolutionError.invalidAddress: code = Int32(ABIFailureInvalidAddress)
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
@c(ABICreateSymbolRuntime)
package func nativeCreateSymbolRuntime() -> OpaquePointer {
    retained(RuntimeSymbolResolver())
}

@c(ABICopySharedSymbolRuntime)
package func nativeCopySharedSymbolRuntime() -> OpaquePointer {
    retained(RuntimeSymbolResolver.shared)
}

@c(ABIReleaseSymbolRuntime)
package func nativeReleaseSymbolRuntime(_ runtime: OpaquePointer) {
    Unmanaged<RuntimeSymbolResolver>.fromOpaque(UnsafeRawPointer(runtime)).release()
}

@c(ABIRuntimeRemoveCachedResults)
package func nativeRemoveCachedResults(_ runtime: OpaquePointer) {
    borrowed(runtime, as: RuntimeSymbolResolver.self).removeCachedResults()
}

@c(ABIResolveSymbol)
package func nativeResolveSymbol(
    _ runtime: OpaquePointer,
    _ name: UnsafePointer<CChar>,
    _ language: Int32,
    _ kind: Int32,
    _ scope: Int32,
    _ selector: UnsafePointer<CChar>?,
    _ loading: Int32,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    nativeResolveSymbolWithNameForm(
        runtime,
        name,
        Int32(ABINameSource),
        language,
        kind,
        scope,
        selector,
        loading,
        error
    )
}

@c(ABIResolveSymbolWithNameForm)
package func nativeResolveSymbolWithNameForm(
    _ runtime: OpaquePointer,
    _ name: UnsafePointer<CChar>,
    _ nameForm: Int32,
    _ language: Int32,
    _ kind: Int32,
    _ scope: Int32,
    _ selector: UnsafePointer<CChar>?,
    _ loading: Int32,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        let declaration = try nativeDeclaration(
            name,
            language: language,
            kind: kind,
            nameForm: nameForm
        )
        let imageSelector = try nativeImageSelector(scope: scope, selector: selector)
        let symbol = try borrowed(runtime, as: RuntimeSymbolResolver.self)
            .resolve(declaration, in: imageSelector, loading: try nativeLoadingPolicy(loading))
        return retained(NativeSymbolBox(symbol))
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

@c(ABIResolveCXXVTable)
package func nativeResolveCXXVTable(
    _ runtime: OpaquePointer,
    _ typeName: UnsafePointer<CChar>,
    _ scope: Int32,
    _ selector: UnsafePointer<CChar>?,
    _ loading: Int32,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        let declaration = RuntimeDeclaration(vtableFor: String(cString: typeName))
        let imageSelector = try nativeImageSelector(scope: scope, selector: selector)
        let symbol = try borrowed(runtime, as: RuntimeSymbolResolver.self).resolve(
            declaration,
            in: imageSelector,
            loading: try nativeLoadingPolicy(loading)
        )
        return retained(NativeSymbolBox(symbol))
    } catch let failure {
        error?.pointee = nativeFailure(failure)
        return nil
    }
}

extension RuntimeSymbol {
    @unsafe package init(retainingNativeHandle handle: OpaquePointer) {
        self = borrowed(handle, as: NativeSymbolBox.self).symbol
    }

    @unsafe package func copyNativeHandle() -> OpaquePointer {
        retained(NativeSymbolBox(self))
    }
}

@c(ABIRetainResolvedSymbol)
package func nativeRetainResolvedSymbol(_ symbol: OpaquePointer) -> OpaquePointer {
    retained(borrowed(symbol, as: NativeSymbolBox.self))
}

@c(ABIReleaseResolvedSymbol)
package func nativeReleaseResolvedSymbol(_ symbol: OpaquePointer) {
    Unmanaged<NativeSymbolBox>.fromOpaque(UnsafeRawPointer(symbol)).release()
}

@c(ABIResolvedSymbolAddress)
package func nativeResolvedSymbolAddress(_ symbol: OpaquePointer) -> UnsafeRawPointer {
    let box = borrowed(symbol, as: NativeSymbolBox.self)
    return UnsafeRawPointer(bitPattern: UInt(box.symbol.address))!
}

@c(ABIResolvedSymbolImage)
package func nativeResolvedSymbolImage(
    _ symbol: OpaquePointer,
    _ info: UnsafeMutablePointer<ABIImageInfo>
) {
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

@c(ABIResolvedSymbolKind)
package func nativeResolvedSymbolKind(_ symbol: OpaquePointer) -> Int32 {
    switch borrowed(symbol, as: NativeSymbolBox.self).symbol.declaration.kind {
    case .function: Int32(ABISymbolFunction)
    case .data: Int32(ABISymbolData)
    case .vtable: Int32(ABISymbolVTable)
    }
}

@c(ABIResolvedSymbolLanguage)
package func nativeResolvedSymbolLanguage(_ symbol: OpaquePointer) -> Int32 {
    switch borrowed(symbol, as: NativeSymbolBox.self).symbol.declaration.language {
    case .swift: Int32(ABILanguageSwift)
    case .objectiveC: Int32(ABILanguageObjectiveC)
    case .c: Int32(ABILanguageC)
    case .cxx: Int32(ABILanguageCXX)
    }
}

private func nativeDeclaration(
    _ name: UnsafePointer<CChar>?,
    language: Int32,
    kind: Int32,
    nameForm: Int32 = Int32(ABINameSource)
) throws -> RuntimeDeclaration {
    guard let name else {
        throw InvalidNativeRequest(description: "A declaration name is required.")
    }
    let sourceLanguage: RuntimeLanguage
    switch language {
    case Int32(ABILanguageSwift): sourceLanguage = .swift
    case Int32(ABILanguageObjectiveC): sourceLanguage = .objectiveC
    case Int32(ABILanguageC): sourceLanguage = .c
    case Int32(ABILanguageCXX): sourceLanguage = .cxx
    default: throw InvalidNativeRequest(description: "Unknown source language: \(language)")
    }
    let symbolKind: RuntimeSymbolKind
    switch kind {
    case Int32(ABISymbolFunction): symbolKind = .function
    case Int32(ABISymbolData): symbolKind = .data
    case Int32(ABISymbolVTable): symbolKind = .vtable
    default: throw InvalidNativeRequest(description: "Unknown symbol kind: \(kind)")
    }

    guard let form = RuntimeSymbolNameForm(rawValue: nameForm) else {
        throw InvalidNativeRequest(description: "Unknown name representation: \(nameForm)")
    }
    return RuntimeDeclaration(
        name: String(cString: name),
        language: sourceLanguage,
        kind: symbolKind,
        nameForm: form
    )
}

private func nativeImageSelector(
    scope: Int32,
    selector: UnsafePointer<CChar>?
) throws -> RuntimeImageSelector {
    let imageSelector: RuntimeImageSelector
    switch scope {
    case Int32(ABIImageAutomatic): imageSelector = .automatic
    case Int32(ABIImageFramework), Int32(ABIImagePath), Int32(ABIImageInstallName):
        guard let selector else {
            throw InvalidNativeRequest(
                description: "A framework, executable path, or install name is required."
            )
        }
        let value = String(cString: selector)
        switch scope {
        case Int32(ABIImageFramework): imageSelector = .framework(named: value)
        case Int32(ABIImageInstallName): imageSelector = .installName(value)
        default: imageSelector = .path(URL(fileURLWithPath: value))
        }
    default: throw InvalidNativeRequest(description: "Unknown image scope: \(scope)")
    }

    return imageSelector
}

private func nativeLoadingPolicy(_ value: Int32) throws -> RuntimeImageLoadingPolicy {
    guard let policy = RuntimeImageLoadingPolicy(rawValue: value) else {
        throw InvalidNativeRequest(description: "Unknown image loading policy: \(value)")
    }
    return policy
}

@c(ABICopyImportSelection)
package func copyImportSelection(
    _ runtime: OpaquePointer?,
    _ declaration: UnsafePointer<ABIDeclaration>?,
    _ importer: ABIImageSelector,
    _ provider: UnsafePointer<ABIImageSelector>?,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        guard let runtime, let declaration = declaration?.pointee else {
            throw InvalidNativeRequest(description: "A runtime and declaration are required.")
        }
        let request = try nativeDeclaration(
            declaration.name,
            language: declaration.language,
            kind: declaration.kind,
            nameForm: declaration.nameForm
        )
        let importing = try nativeImageSelector(scope: importer.scope, selector: importer.selector)
        let defining = try provider.map {
            try nativeImageSelector(scope: $0.pointee.scope, selector: $0.pointee.selector)
        }
        return try RuntimeImportedFunctionSelection(
            resolver: borrowed(runtime, as: RuntimeSymbolResolver.self),
            declaration: request,
            importer: importing,
            provider: defining
        ).retainedHandle()
    } catch let failure { error?.pointee = nativeFailure(failure); return nil }
}

@c(ABIInstallImportedFunctionHook)
package func installImportedFunctionHook(
    _ runtime: OpaquePointer?,
    _ declaration: UnsafePointer<ABIDeclaration>?,
    _ importer: ABIImageSelector,
    _ provider: UnsafePointer<ABIImageSelector>?,
    _ result: OpaquePointer?,
    _ parameters: UnsafePointer<OpaquePointer?>?,
    _ count: Int,
    _ context: UnsafeMutableRawPointer?,
    _ callback: ABIImportedCallback?,
    _ onFailure: ABIImportedFailureHandler?,
    _ release: ABIImportedContextRelease?
) -> OpaquePointer? {
    guard let release else { return nil }
    var error: OpaquePointer?
    guard let selection = copyImportSelection(runtime, declaration, importer, provider, &error)
    else {
        release(context)
        return ABICreateFailedImportedHook(error)
    }
    defer { ABIReleaseImportSelection(selection) }
    return ABICreateImportedHook(
        selection,
        result,
        parameters,
        count,
        context,
        callback,
        onFailure,
        release
    )
}

@c(ABICopyImportedSelectionForImage)
package func copyImportedSelectionForImage(
    _ query: OpaquePointer,
    _ info: ABIImageInfo,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    do {
        return try borrowed(query, as: RuntimeImportedFunctionQuery.self).select(
            RuntimeImageSnapshot(info)
        )?.retainedHandle()
    } catch let failure { error?.pointee = nativeFailure(failure); return nil }
}

@c(ABIMonitorImportedFunction)
package func monitorImportedFunction(
    _ declaration: UnsafePointer<ABIDeclaration>?,
    _ importer: ABIImageSelector,
    _ provider: UnsafePointer<ABIImageSelector>?,
    _ result: OpaquePointer?,
    _ parameters: UnsafePointer<OpaquePointer?>?,
    _ count: Int,
    _ context: UnsafeMutableRawPointer?,
    _ callback: ABIImportedCallback?,
    _ failure: ABIImportedFailureHandler?,
    _ update: ABIImportedImageHandler?,
    _ release: ABIImportedContextRelease?,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    error?.pointee = nil
    guard let release else {
        error?.pointee = nativeFailure(
            InvalidNativeRequest(description: "A context release callback is required.")
        )
        return nil
    }
    let query: RuntimeImportedFunctionQuery
    do {
        guard let declaration = declaration?.pointee else {
            throw InvalidNativeRequest(description: "A declaration is required.")
        }
        query = try RuntimeImportedFunctionQuery(
            declaration: nativeDeclaration(
                declaration.name,
                language: declaration.language,
                kind: declaration.kind,
                nameForm: declaration.nameForm
            ),
            importer: nativeImageSelector(scope: importer.scope, selector: importer.selector),
            provider: provider.map {
                try nativeImageSelector(scope: $0.pointee.scope, selector: $0.pointee.selector)
            }
        )
    } catch let failure {
        release(context); error?.pointee = nativeFailure(failure); return nil
    }
    return ABICreateImportedHookMonitor(
        query.retainedHandle(),
        result,
        parameters,
        count,
        context,
        callback,
        failure,
        update,
        release,
        error
    )
}

private func nativeRequest(_ request: ABISymbolRequest) throws -> RuntimeSymbolRequest {
    guard request.alternativeCount >= 0, request.imageScopeCount >= 0, request.fallbackCount >= 0,
        request.alternativeCount == 0 || request.alternatives != nil,
        request.fallbackCount == 0 || request.fallbacks != nil,
        request.imageScopeCount == 0 || request.imageScopes != nil
    else {
        throw InvalidNativeRequest(description: "Nonempty request arrays require valid storage.")
    }
    let declaration = try nativeDeclaration(
        request.declaration.name,
        language: request.declaration.language,
        kind: request.declaration.kind,
        nameForm: request.declaration.nameForm
    )
    let alternatives = try UnsafeBufferPointer(
        start: request.alternatives,
        count: request.alternativeCount
    ).map {
        try nativeDeclaration($0.name, language: $0.language, kind: $0.kind, nameForm: $0.nameForm)
    }
    let scopes = try UnsafeBufferPointer(start: request.imageScopes, count: request.imageScopeCount)
        .map {
            try nativeImageSelector(scope: $0.scope, selector: $0.selector)
        }
    let fallbacks = try UnsafeBufferPointer(start: request.fallbacks, count: request.fallbackCount)
        .map {
            try nativeDeclaration(
                $0.name,
                language: $0.language,
                kind: $0.kind,
                nameForm: $0.nameForm
            )
        }
    return RuntimeSymbolRequest(
        declaration,
        alternatives: alternatives,
        fallbacks: fallbacks,
        in: scopes,
        loading: try nativeLoadingPolicy(request.loading)
    )
}

@c(ABIResolveSymbols)
package func nativeResolveSymbols(
    _ runtime: OpaquePointer,
    _ requests: UnsafePointer<ABISymbolRequest>?,
    _ count: Int,
    _ results: UnsafeMutablePointer<ABISymbolResult>?
) {
    let decoded = UnsafeBufferPointer(start: requests, count: count).map { request in
        Result { try nativeRequest(request) }
    }
    let valid = decoded.compactMap { try? $0.get() }
    var resolved = borrowed(runtime, as: RuntimeSymbolResolver.self).resolve(valid).makeIterator()
    for (index, request) in decoded.enumerated() {
        switch request.flatMap({ _ in resolved.next()! }) {
        case .success(let symbol):
            results![index] = ABISymbolResult(
                symbol: retained(NativeSymbolBox(symbol)),
                failure: nil
            )
        case .failure(let error):
            results![index] = ABISymbolResult(symbol: nil, failure: nativeFailure(error))
        }
    }
}
