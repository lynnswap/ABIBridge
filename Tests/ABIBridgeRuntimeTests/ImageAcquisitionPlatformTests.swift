import ABIBridgeRuntime
import CoreFoundation
import Foundation
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
        let path = RuntimeImageSelector.path(URL(fileURLWithPath: image.path))
        let first = try #require(runtime.acquireImages(path, loading: .ifNeeded).first)
        let repeated = try #require(runtime.acquireImages(path, loading: .ifNeeded).first)
        #expect(repeated.lease === first.lease)
        runtime.removeCachedResults()
        unsafe fromLease.withUnsafeAddress { address in
            #expect(
                unsafeBitCast(address, to: (@convention(c) () -> UInt).self)()
                    == CFRunLoopGetTypeID()
            )
        }
    }
}
