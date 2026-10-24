import ABIBridgeCore
import ABIBridgeRuntime
import ObjectiveC
import ObjectiveCFixtures
import Testing

struct NativeRuntimeContractTests {
    @Test func nativeBatchesReturnOwnedPerRequestOutcomes() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        let imagePath = try #require(class_getImageName(ABIReplacementFixture.self))
        ABIResolveSymbols(runtime, nil, 0, nil)
        try "ABICAnswer".withCString { name in
            var scope = ABIImageSelector(scope: Int32(ABIImagePath), selector: imagePath)
            try withUnsafePointer(to: &scope) { scope in
                let declaration = ABIDeclaration(
                    name: name,
                    language: Int32(ABILanguageC),
                    kind: Int32(ABISymbolFunction),
                    nameForm: Int32(ABINameSource)
                )
                let valid = ABISymbolRequest(
                    declaration: declaration,
                    alternatives: nil,
                    alternativeCount: 0,
                    imageScopes: scope,
                    imageScopeCount: 1,
                    fallbacks: nil,
                    fallbackCount: 0,
                    loading: Int32(ABIImageLoadIfNeeded)
                )
                var malformed = valid
                malformed.alternativeCount = 1
                var empty = valid
                empty.imageScopeCount = 0
                var invalidForm = valid
                invalidForm.declaration.nameForm = -1
                let requests = [valid, malformed, empty, valid, invalidForm]
                var results = Array(repeating: ABISymbolResult(), count: requests.count)
                requests.withUnsafeBufferPointer { requests in
                    results.withUnsafeMutableBufferPointer { results in
                        ABIResolveSymbols(
                            runtime,
                            requests.baseAddress,
                            requests.count,
                            results.baseAddress
                        )
                    }
                }
                defer {
                    for result in results {
                        if let symbol = result.symbol { ABIReleaseResolvedSymbol(symbol) }
                        if let failure = result.failure { ABIReleaseResolutionFailure(failure) }
                    }
                }
                for index in [0, 3] {
                    #expect(results[index].symbol != nil)
                    #expect(results[index].failure == nil)
                }
                let malformedFailure = try #require(results[1].failure)
                #expect(results[1].symbol == nil)
                #expect(
                    ABIResolutionFailureGetCode(malformedFailure) == Int32(ABIFailureInvalidRequest)
                )
                let emptyFailure = try #require(results[2].failure)
                #expect(
                    ABIResolutionFailureGetCode(emptyFailure) == Int32(ABIFailureImageNotLoaded)
                )
                let formFailure = try #require(results[4].failure)
                #expect(ABIResolutionFailureGetCode(formFailure) == Int32(ABIFailureInvalidRequest))
                ABISymbolRuntimeRemoveCachedResults(runtime)
                let symbol = try #require(results[0].symbol)
                #expect(ABIResolvedSymbolGetAddress(symbol) != nil)
            }
        }
    }

    @Test func nativeExactSpellingsPreserveTheirFormAndErrorCategory() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        let imagePath = try #require(class_getImageName(ABIReplacementFixture.self))
        for (name, form) in [
            ("ABICAnswer", Int32(ABINameLinker)), ("_ABICAnswer", Int32(ABINameMachO)),
        ] {
            var failure: OpaquePointer?
            let handle = name.withCString { name in
                var scope = ABIImageSelector(scope: Int32(ABIImagePath), selector: imagePath)
                return withUnsafePointer(to: &scope) { scope in
                    var request = ABISymbolRequest()
                    request.declaration = ABIDeclaration(
                        name: name,
                        language: Int32(ABILanguageC),
                        kind: Int32(ABISymbolFunction),
                        nameForm: form
                    )
                    request.imageScopes = scope
                    request.imageScopeCount = 1
                    request.loading = Int32(ABIImageLoadIfNeeded)
                    return ABIResolveSymbol(runtime, &request, &failure)
                }
            }
            let owned = try #require(handle)
            #expect(failure == nil)
            let imported = unsafe RuntimeSymbol(retainingNativeHandle: owned)
            ABIReleaseResolvedSymbol(owned)
            #expect(imported.declaration.nameForm.rawValue == form)
            #expect(imported.declaration.name == name)
            #expect(
                unsafe imported.withUnsafeAddress {
                    unsafeBitCast($0, to: (@convention(c) () -> Int32).self)()
                } == ABICAnswer()
            )
        }
        var failure: OpaquePointer?
        let invalid = "getpid".withCString { name in
            var scope = ABIImageSelector(scope: Int32(ABIImageAutomatic), selector: nil)
            return withUnsafePointer(to: &scope) { scope in
                var request = ABISymbolRequest()
                request.declaration = ABIDeclaration(
                    name: name,
                    language: Int32(ABILanguageC),
                    kind: Int32(ABISymbolFunction),
                    nameForm: -1
                )
                request.imageScopes = scope
                request.imageScopeCount = 1
                request.loading = Int32(ABIImageLoadIfNeeded)
                return ABIResolveSymbol(runtime, &request, &failure)
            }
        }
        #expect(invalid == nil)
        let error = try #require(failure)
        #expect(ABIResolutionFailureGetCode(error) == Int32(ABIFailureInvalidRequest))
        ABIReleaseResolutionFailure(error)
    }

    @Test func nativeVTableErrorsPreserveLookupCategories() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        let imagePath = try #require(class_getImageName(ABIReplacementFixture.self))
        for (scope, expected) in [
            (-1, Int32(ABIFailureInvalidRequest)),
            (Int32(ABIImagePath), Int32(ABIFailureDeclarationNotFound)),
        ] {
            var failure: OpaquePointer?
            let symbol = "ABIBridgeMissingType::Renderer".withCString {
                ABIResolveCXXVTable(
                    runtime,
                    $0,
                    ABIImageSelector(scope: scope, selector: imagePath),
                    Int32(ABIImageLoadIfNeeded),
                    &failure
                )
            }
            #expect(symbol == nil)
            let error = try #require(failure)
            #expect(ABIResolutionFailureGetCode(error) == expected)
            if expected == Int32(ABIFailureDeclarationNotFound) {
                // The message is the failure's description.
                #expect(
                    String(cString: ABIResolutionFailureGetMessage(error))
                        == "Cannot find vtable for ABIBridgeMissingType::Renderer."
                )
            }
            ABIReleaseResolutionFailure(error)
        }
    }

    @Test func nativeErrorsAreOwnedAndKeepTheirDetail() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        var failure: OpaquePointer?
        let symbol = "missing".withCString { name in
            var scope = ABIImageSelector(scope: Int32(ABIImageAutomatic), selector: nil)
            return withUnsafePointer(to: &scope) { scope in
                var request = ABISymbolRequest()
                request.declaration = ABIDeclaration(
                    name: name,
                    language: -1,
                    kind: Int32(ABISymbolFunction),
                    nameForm: Int32(ABINameSource)
                )
                request.imageScopes = scope
                request.imageScopeCount = 1
                request.loading = Int32(ABIImageLoadIfNeeded)
                return ABIResolveSymbol(runtime, &request, &failure)
            }
        }
        #expect(symbol == nil)
        let error = try #require(failure)
        defer { ABIReleaseResolutionFailure(error) }
        #expect(ABIResolutionFailureGetCode(error) == Int32(ABIFailureInvalidRequest))
        #expect(
            String(cString: ABIResolutionFailureGetMessage(error)).contains(
                "Unknown source language"
            )
        )
    }
}
