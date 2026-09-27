import ABIBridge
import ABIBridgeCore
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

    @MainActor static func snapshots(_ url: URL) async throws -> (UInt64, [NativeLazyLibrary], OpaquePointer) {
        guard let loader = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw Failure.loadFailed }
        defer { dlclose(loader) }
        let runtime = ABIRuntime()
        guard let image = try await runtime.images(matching: .path(url)).first else { throw Failure.loadFailed }
        let values = try await runtime.lazyLibraries(in: image)
        var error: OpaquePointer?
        guard let native = ABICopyLazyLibrariesForImage(image.identity.loadGeneration, &error) else { throw Failure.loadFailed }
        precondition(error == nil && ABILazyLibraryListCount(native) == values.count)
        return (image.identity.loadGeneration, values, native)
    }

    @MainActor static func handedOffSymbol(_ url: URL) async throws -> ResolvedSymbol {
        guard let loader = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw Failure.loadFailed }
        defer { dlclose(loader) }
        let runtime = ABIRuntime()
        var original: ResolvedSymbol? = try await runtime.resolve(
            .init(name: "ABIBridgeFixture::counter", language: .cxx, kind: .data), in: .path(url))
        let exported = unsafe original!.copyNativeHandle()
        original = nil
        await runtime.removeCachedResults()
        guard let retained = ABIRetainResolvedSymbol(exported) else { throw Failure.loadFailed }
        ABIReleaseResolvedSymbol(exported)
        let symbol = unsafe ResolvedSymbol(retainingNativeHandle: retained)
        ABIReleaseResolvedSymbol(retained)
        return symbol
    }

    @MainActor static func checkSnapshotAndHandoffLifetime(_ url: URL) async throws {
        let (generation, values, native) = try await snapshots(url)
        defer { ABIFreeLazyLibraryList(native) }
        let snapshotLease = ABIRetainLoadedImage(generation)
        if let snapshotLease { ABIReleaseImage(snapshotLease) }
        precondition(snapshotLease == nil, "Copied Swift/native diagnostics must not retain their source image")
        precondition(ABILazyLibraryListCount(native) == values.count)
        var symbol: ResolvedSymbol? = try await handedOffSymbol(url)
        let symbolGeneration = symbol!.image.identity.loadGeneration
        precondition(unsafe symbol!.withUnsafeAddress { $0.load(as: Int32.self) } == 42)
        symbol = nil
        let remaining = ABIRetainLoadedImage(symbolGeneration)
        if let remaining { ABIReleaseImage(remaining) }
        precondition(remaining == nil, "Released handoff handles must not retain the image")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw Failure.missingPath }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        try await checkSnapshotAndHandoffLifetime(url)
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
