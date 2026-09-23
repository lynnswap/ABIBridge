import ABIBridge
import ABIBridgeCore
import Foundation
import Testing

struct NativeRuntimeTests {
    @Test func nativeAndSwiftEntriesShareImageIdentity() async throws {
        let runtime = try #require(ABICopySharedSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        var failure: OpaquePointer?
        let handle = "getpid".withCString {
            ABIResolveSymbol(runtime, $0, Int32(ABILanguageC), Int32(ABISymbolFunction),
                             Int32(ABIImageAutomatic), nil, &failure)
        }
        let symbol = try #require(handle)
        defer { ABIReleaseResolvedSymbol(symbol) }
        #expect(failure == nil)
        var info = ABIImageInfo()
        ABIResolvedSymbolImage(symbol, &info)

        let swift = try await ABIRuntime.shared.resolve(.init(name: "getpid", language: .c))
        #expect(info.generation == swift.image.identity.loadGeneration)
        #expect(info.header == UInt(swift.image.identity.headerAddress))
        let swiftAddress = unsafe swift.withUnsafeAddress { UInt(bitPattern: $0) }
        #expect(UInt(bitPattern: ABIResolvedSymbolAddress(symbol)) == swiftAddress)
        await ABIRuntime.shared.removeCachedResults()
        #expect(ABIResolvedSymbolAddress(symbol) != nil)
    }

    @Test func swiftAndNativeHandoffsPreserveSymbolMetadata() async throws {
        let original = try await ABIRuntime().resolve(.init(name: "getpid", language: .c))
        let exported = unsafe original.copyNativeHandle()
        let retained = try #require(ABIRetainResolvedSymbol(exported))
        ABIReleaseResolvedSymbol(exported)
        let restored = unsafe ResolvedSymbol(retainingNativeHandle: retained)
        ABIReleaseResolvedSymbol(retained)

        #expect(restored.declaration == original.declaration)
        #expect(restored.image.identity == original.image.identity)
        #expect(restored.sectionRange == original.sectionRange)
        #expect(restored.source == original.source)
        let pid = unsafe restored.withUnsafeAddress {
            unsafeBitCast($0, to: (@convention(c) () -> Int32).self)()
        }
        #expect(pid == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func dynamicCInterfaceIsCallableFromSwift() async throws {
        var failure: OpaquePointer?
        let resultType = try #require(ABICreateScalarType(Int32(ABIValueInt32), &failure))
        defer { ABIReleaseValueType(resultType) }
        let interface = try #require(ABICreateCCallInterface(resultType, nil, 0, &failure))
        defer { ABIReleaseCallInterface(interface) }
        let symbol = try await ABIRuntime.shared.resolve(.init(name: "getpid", language: .c))
        var result: Int32 = 0
        let success = unsafe symbol.withUnsafeAddress {
            ABIUnsafeInvokeCCallInterface(interface, ABIUnsafeFunctionAtAddress($0), &result, nil, &failure)
        }
        #expect(success)
        #expect(failure == nil)
        #expect(result == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func nativeBatchesReturnOwnedPerRequestOutcomes() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        ABIResolveSymbols(runtime, nil, 0, nil)
        try "getpid".withCString { name in
            var scope = ABIImageSelector(scope: Int32(ABIImageAutomatic), selector: nil)
            try withUnsafePointer(to: &scope) { scope in
                let declaration = ABIDeclaration(name: name, language: Int32(ABILanguageC), kind: Int32(ABISymbolFunction))
                let valid = ABISymbolRequest(declaration: declaration, alternatives: nil, alternativeCount: 0,
                                             imageScopes: scope, imageScopeCount: 1)
                var malformed = valid
                malformed.alternativeCount = 1
                var empty = valid
                empty.imageScopeCount = 0
                let requests = [valid, malformed, empty, valid]
                var results = Array(repeating: ABISymbolResult(), count: requests.count)
                requests.withUnsafeBufferPointer { requests in
                    results.withUnsafeMutableBufferPointer { results in
                        ABIResolveSymbols(runtime, requests.baseAddress, requests.count, results.baseAddress)
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
                #expect(ABIResolutionFailureCode(malformedFailure) == Int32(ABIFailureInvalidRequest))
                let emptyFailure = try #require(results[2].failure)
                #expect(ABIResolutionFailureCode(emptyFailure) == Int32(ABIFailureImageNotLoaded))
                ABIRuntimeRemoveCachedResults(runtime)
                let symbol = try #require(results[0].symbol)
                #expect(ABIResolvedSymbolAddress(symbol) != nil)
            }
        }
    }

    @Test func nativeErrorsAreOwnedAndKeepTheirDetail() throws {
        let runtime = try #require(ABICreateSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        var failure: OpaquePointer?
        let symbol = "missing".withCString {
            ABIResolveSymbol(runtime, $0, -1, Int32(ABISymbolFunction),
                             Int32(ABIImageAutomatic), nil, &failure)
        }
        #expect(symbol == nil)
        let error = try #require(failure)
        defer { ABIReleaseResolutionFailure(error) }
        #expect(ABIResolutionFailureCode(error) == Int32(ABIFailureInvalidRequest))
        #expect(String(cString: ABIResolutionFailureMessage(error)).contains("Unknown source language"))
    }
}
