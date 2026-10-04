import ABIBridgeRuntime
import CoreFoundation
import Testing

struct ImageAcquisitionPlatformTests {
    @Test func systemFrameworkAcquisitionMatchesItsCatalogImage() throws {
        let runtime = RuntimeSymbolResolver()
        let scope = RuntimeImageSelector.framework(named: "CoreFoundation")
        let image = try #require(runtime.images(matching: scope).first)
        let declaration = RuntimeDeclaration(name: "CFRunLoopGetTypeID", language: .c)
        let function = try runtime.resolve(declaration, in: scope)
        #expect(function.image.identity == image.identity)
        try unsafe function.withUnsafeAddress { address in
            #expect(
                unsafeBitCast(address, to: (@convention(c) () -> UInt).self)()
                    == CFRunLoopGetTypeID()
            )
        }
        let fromLease = try runtime.resolve(declaration, in: image)
        #expect(fromLease.image.identity == image.identity)
        #expect(function.address == fromLease.address)
        runtime.removeCachedResults()
        unsafe fromLease.withUnsafeAddress { address in
            #expect(
                unsafeBitCast(address, to: (@convention(c) () -> UInt).self)()
                    == CFRunLoopGetTypeID()
            )
        }
    }
}
