import ABIBridge
import ABIBridgeCore
import Foundation
import Darwin
import Testing

struct NativeRuntimeTests {
    @Test func nativeAndSwiftEntriesShareImageIdentity() async throws {
        let runtime = try #require(ABICopySharedSymbolRuntime())
        defer { ABIReleaseSymbolRuntime(runtime) }
        var failure: OpaquePointer?
        let handle = "getpid".withCString { name in
            var scope = ABIImageSelector(scope: Int32(ABIImageAutomatic), selector: nil)
            return withUnsafePointer(to: &scope) { scope in
                var request = ABISymbolRequest()
                request.declaration = ABIDeclaration(
                    name: name,
                    language: Int32(ABILanguageC),
                    kind: Int32(ABISymbolFunction),
                    nameForm: Int32(ABINameSource)
                )
                request.imageScopes = scope
                request.imageScopeCount = 1
                request.loading = Int32(ABIImageLoadIfNeeded)
                return ABIResolveSymbol(runtime, &request, &failure)
            }
        }
        let symbol = try #require(handle)
        defer { ABIReleaseResolvedSymbol(symbol) }
        #expect(failure == nil)
        var info = ABIImageInfo()
        ABIResolvedSymbolGetImage(symbol, &info)

        let swift = try ABIRuntime.shared.resolveAndWait(.c(.symbol("getpid")))
        #expect(info.generation == swift.image.identity.loadGeneration)
        #expect(info.header == UInt(swift.image.identity.headerAddress))
        let swiftAddress = unsafe swift.withUnsafeAddress { UInt(bitPattern: $0) }
        #expect(UInt(bitPattern: ABIResolvedSymbolGetAddress(symbol)) == swiftAddress)
        ABIRuntime.shared.removeCachedResults()
        #expect(ABIResolvedSymbolGetAddress(symbol) != nil)
    }

    @Test func swiftAndNativeHandoffsPreserveSymbolMetadata() async throws {
        let original = try ABIRuntime().resolveAndWait(.c(.symbol("getpid")))
        let exported = unsafe original.copyNativeHandle()
        #expect(ABIResolvedSymbolGetKind(exported) == Int32(ABISymbolFunction))
        #expect(ABIResolvedSymbolGetLanguage(exported) == Int32(ABILanguageC))
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
        let symbol = try ABIRuntime.shared.resolveAndWait(.c(.symbol("getpid")))
        var result: Int32 = 0
        let success = unsafe symbol.withUnsafeAddress {
            ABIUnsafeInvokeCCallInterface(
                interface,
                ABIUnsafeFunctionAtAddress($0),
                &result,
                nil,
                &failure
            )
        }
        #expect(success)
        #expect(failure == nil)
        #expect(result == ProcessInfo.processInfo.processIdentifier)
    }

    @Test func exactObjectiveCSymbolsDoNotUseSelectorLookup() async throws {
        let process = try #require(dlopen(nil, RTLD_NOW))
        defer { dlclose(process) }
        let expected = try #require(dlsym(process, "OBJC_CLASS_$_NSObject"))
        let symbol = try ABIRuntime.shared.resolveAndWait(
            .objc(.symbol(machOName: "_OBJC_CLASS_$_NSObject", kind: .data))
        )
        #expect(symbol.declaration.language == .objectiveC)
        #expect(unsafe symbol.withUnsafeAddress { $0 == UnsafeRawPointer(expected) })
    }

}
