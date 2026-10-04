import ABIBridgeCore
import ABIBridgeRuntime
import Darwin
import Testing

struct NativeRuntimeContractTests {
    @Test func nativeBatchesReturnOwnedPerRequestOutcomes() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        ABIResolveSymbols(runtime, nil, 0, nil)
        try "getpid".withCString { name in
            var scope = ABIImageSelector(scope: Int32(ABIImageAutomatic), selector: nil)
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
                    ABIResolutionFailureCode(malformedFailure) == Int32(ABIFailureInvalidRequest)
                )
                let emptyFailure = try #require(results[2].failure)
                #expect(ABIResolutionFailureCode(emptyFailure) == Int32(ABIFailureImageNotLoaded))
                let formFailure = try #require(results[4].failure)
                #expect(ABIResolutionFailureCode(formFailure) == Int32(ABIFailureInvalidRequest))
                ABIRuntimeRemoveCachedResults(runtime)
                let symbol = try #require(results[0].symbol)
                #expect(ABIResolvedSymbolAddress(symbol) != nil)
            }
        }
    }

    @Test func nativeExactSpellingsPreserveTheirFormAndErrorCategory() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        for (name, form) in [("getpid", Int32(ABINameLinker)), ("_getpid", Int32(ABINameMachO))] {
            var failure: OpaquePointer?
            let handle = name.withCString {
                ABIResolveSymbolWithNameForm(
                    runtime,
                    $0,
                    form,
                    Int32(ABILanguageC),
                    Int32(ABISymbolFunction),
                    Int32(ABIImageAutomatic),
                    nil,
                    Int32(ABIImageLoadIfNeeded),
                    &failure
                )
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
                } == getpid()
            )
        }
        var failure: OpaquePointer?
        let invalid = "getpid".withCString {
            ABIResolveSymbolWithNameForm(
                runtime,
                $0,
                -1,
                Int32(ABILanguageC),
                Int32(ABISymbolFunction),
                Int32(ABIImageAutomatic),
                nil,
                Int32(ABIImageLoadIfNeeded),
                &failure
            )
        }
        #expect(invalid == nil)
        let error = try #require(failure)
        #expect(ABIResolutionFailureCode(error) == Int32(ABIFailureInvalidRequest))
        ABIReleaseResolutionFailure(error)
    }

    @Test func nativeVTableErrorsPreserveLookupCategories() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        for (scope, expected) in [
            (-1, Int32(ABIFailureInvalidRequest)),
            (Int32(ABIImageAutomatic), Int32(ABIFailureDeclarationNotFound)),
        ] {
            var failure: OpaquePointer?
            let symbol = "ABIBridgeMissingType::Renderer".withCString {
                ABIResolveCXXVTable(runtime, $0, scope, nil, Int32(ABIImageLoadIfNeeded), &failure)
            }
            #expect(symbol == nil)
            let error = try #require(failure)
            #expect(ABIResolutionFailureCode(error) == expected)
            ABIReleaseResolutionFailure(error)
        }
    }

    @Test func nativeErrorsAreOwnedAndKeepTheirDetail() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        var failure: OpaquePointer?
        let symbol = "missing".withCString {
            ABIResolveSymbol(
                runtime,
                $0,
                -1,
                Int32(ABISymbolFunction),
                Int32(ABIImageAutomatic),
                nil,
                Int32(ABIImageLoadIfNeeded),
                &failure
            )
        }
        #expect(symbol == nil)
        let error = try #require(failure)
        defer { ABIReleaseResolutionFailure(error) }
        #expect(ABIResolutionFailureCode(error) == Int32(ABIFailureInvalidRequest))
        #expect(
            String(cString: ABIResolutionFailureMessage(error)).contains("Unknown source language")
        )
    }
}
