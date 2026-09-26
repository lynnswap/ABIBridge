import ABIBridge
import CoreFoundation
import Testing

struct ImageAcquisitionPlatformTests {
    @Test func systemFrameworkAcquisitionMatchesItsCatalogImage() async throws {
        let runtime = ABIRuntime()
        let scope = ImageSelector.framework(named: "CoreFoundation")
        let before = try await runtime.images(matching: scope)
        let image = try #require(before.first)
        let function = try await runtime.cFunction(named: "CFRunLoopGetTypeID", as: (() -> UInt).self, in: scope)
        #expect(function.symbol.image.identity == image.identity)
        #expect(try unsafe function.unsafeInvoke() == CFRunLoopGetTypeID())
        let fromLease = try await runtime.cFunction(named: "CFRunLoopGetTypeID", as: (() -> UInt).self, in: image)
        #expect(fromLease.symbol.image.identity == image.identity)
        #expect(try unsafe fromLease.unsafeInvoke() == CFRunLoopGetTypeID())
        await runtime.removeCachedResults()
    }
}
