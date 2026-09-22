import ABIBridge
import Darwin
import Foundation

@main
struct SwiftObjectConsumer {
    enum Failure: Error { case missingPath, loadFailed, allocationFailed }

    static func prepare(_ url: URL) async throws -> NativeCXXMethod<Int32> {
        guard let loader = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw Failure.loadFailed }
        defer { dlclose(loader) }
        let runtime = ABIRuntime()
        let make = try await runtime.cFunction(
            named: "ABIBridgeFixtureCreateVirtualCounter", as: ((Int32) -> UnsafeMutableRawPointer?).self,
            in: .path(url)
        )
        let size = try await runtime.cFunction(named: "ABIBridgeFixtureVirtualSize", as: (() -> Int).self, in: .path(url))
        let alignment = try await runtime.cFunction(named: "ABIBridgeFixtureVirtualAlignment", as: (() -> Int).self, in: .path(url))
        let tableDiscriminator = try await runtime.cFunction(
            named: "ABIBridgeFixtureVTableDiscriminator", as: (() -> UInt).self, in: .path(url)
        )
        let slotDiscriminator = try await runtime.cFunction(
            named: "ABIBridgeFixtureSlotDiscriminator", as: (() -> UInt).self, in: .path(url)
        )
        guard let address = try unsafe make.unsafeInvoke(42) else { throw Failure.allocationFailed }
        let layout = try unsafe NativeType.opaque(
            named: "VirtualCounter", size: size.unsafeInvoke(), alignment: alignment.unsafeInvoke()
        )
        // The fixture is placement-constructed in malloc storage and has a
        // trivial destructor, so release requires no library code.
        let storage = unsafe NativeValue(adopting: address, as: layout, release: { free($0) })
        let object = runtime.cxxObject(storage, typeNamed: "ABIBridgeFixture::VirtualCounter", in: .path(url))
        let direct = try await object.method(named: "current() const", as: (() -> Int32).self)
        let directValue = try unsafe direct.unsafeInvoke()
        precondition(directValue == 42)
        let table = try unsafe NativeVTable(
            readingFrom: storage, entryCount: 1,
            authentication: .cxxVTablePointer(discriminator: tableDiscriminator.unsafeInvoke())
        )
        let method = try unsafe object.virtualMethod(
            at: 0, in: table,
            authentication: .cxxVirtualFunction(discriminator: slotDiscriminator.unsafeInvoke()),
            as: (() -> Int32).self
        )
        await runtime.removeCachedResults()
        return method
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.missingPath }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        var method: NativeCXXMethod<Int32>? = try await prepare(url)
        let value = try unsafe method!.unsafeInvoke()
        precondition(value == 42)
        guard let retained = dlopen(url.path, RTLD_NOLOAD | RTLD_NOW) else { throw Failure.loadFailed }
        dlclose(retained)
        method = nil
        let released = dlopen(url.path, RTLD_NOLOAD | RTLD_NOW)
        if let released { dlclose(released) }
        precondition(released == nil)
        print("Swift C++ object consumer passed: direct/virtual calls and implementation image retention.")
    }
}
