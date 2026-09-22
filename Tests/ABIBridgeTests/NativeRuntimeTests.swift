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
