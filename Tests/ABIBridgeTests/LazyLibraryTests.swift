#if os(macOS)
import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation
import ObjectiveCFixtures
import Testing
#if DEBUG
@testable import ABIBridge
#endif

struct LazyLibraryTests {
    @Test(arguments: [false, true], [false, true])
    func fileSnapshotsPreserveStatesAndDemangleNames(wide: Bool, swapped: Bool) async throws {
        let bytes = try #require(ABICreateLazyLibraryFixture(wide ? 1 : 0, swapped ? 1 : 0))
        defer { free(bytes) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes: bytes, count: ABILazyLibraryFixtureSize()).write(to: url)
        let result = try await ABIRuntime().lazyLibraries(inFileAt: url)
        try FileManager.default.removeItem(at: url)
        #expect(result.count == 3)
        #expect(result[0].path == "@rpath/Example.dylib")
        #expect(result[0].isOptional == true)
        #expect(result[0].areSymbolsPrebound == false)
        #expect(result[0].isInitialized == nil)
        #expect(result[0].symbols?.map(\.name) == ["Example::Renderer::refresh()", "LazyTests.echo() -> ()", "plainSymbol"])
        #expect(result[0].symbols?[0].rawName == "__ZN7Example8Renderer7refreshEv")
        #expect(result[1].areSymbolsPrebound == true)
        #expect(result[1].isInitialized == nil)
        #expect(result[1].symbols?.isEmpty == true)
        #expect(result[2].path == nil)
        #expect(result[2].isOptional == nil)
        #expect(result[2].symbols == nil)
        let firstOffset: UInt64 = wide ? 176 : 140
        let offsets: [UInt64] = [firstOffset, firstOffset + 16, firstOffset + 32]
        #expect(result.map(\.commandOffset) == offsets)
    }

    @Test func malformedNamesDoNotDiscardOtherMetadata() async throws {
        let bytes = try #require(ABICreateLazyLibraryFixture(1, 0))
        defer { free(bytes) }
        UnsafeMutableRawPointer(bytes).storeBytes(of: UInt32.max, toByteOffset: 4096 + 68, as: UInt32.self)
        UnsafeMutableRawPointer(bytes).storeBytes(of: UInt32(1), toByteOffset: 4096, as: UInt32.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes: bytes, count: ABILazyLibraryFixtureSize()).write(to: url)
        let first = try #require(try await ABIRuntime().lazyLibraries(inFileAt: url).first)
        #expect(first.path == nil)
        #expect(first.isOptional == true)
        #expect(first.symbols?.count == 3)
        #expect(first.symbols?[0].name == "Example::Renderer::refresh()")
        #expect(first.symbols?[1].rawName == nil)
        #expect(first.symbols?[2].name == "plainSymbol")
    }

    @Test func unavailableSymbolArrayDoesNotHideTheDependency() async throws {
        let bytes = try #require(ABICreateLazyLibraryFixture(1, 0))
        defer { free(bytes) }
        UnsafeMutableRawPointer(bytes).storeBytes(of: UInt32.max, toByteOffset: 4096 + 16, as: UInt32.self)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes: bytes, count: ABILazyLibraryFixtureSize()).write(to: url)
        let first = try #require(try await ABIRuntime().lazyLibraries(inFileAt: url).first)
        #expect(first.path == "@rpath/Example.dylib")
        #expect(first.areSymbolsPrebound == false)
        #expect(first.symbols == nil)
    }

    @Test func malformedContainersThrowAndEmptyContainersRemainEmpty() async throws {
        let bytes = try #require(ABICreateLazyLibraryFixture(1, 0))
        defer { free(bytes) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let runtime = ABIRuntime()
        for count in [0, 12, 31, 48] {
            try Data(bytes: bytes, count: count).write(to: url)
            await #expect(throws: ABIResolutionError.self) { try await runtime.lazyLibraries(inFileAt: url) }
        }
        UnsafeMutableRawPointer(bytes).storeBytes(of: UInt32(0), toByteOffset: 16, as: UInt32.self)
        UnsafeMutableRawPointer(bytes).storeBytes(of: UInt32(0), toByteOffset: 20, as: UInt32.self)
        try Data(bytes: bytes, count: 32).write(to: url)
        #expect(try await runtime.lazyLibraries(inFileAt: url).isEmpty)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await runtime.lazyLibraries(inFileAt: url)
            Issue.record("A missing file must report its I/O error")
        } catch { #expect(error is CocoaError) }
    }

    #if DEBUG
    @Test(arguments: [false, true], [false, true])
    func memorySnapshotsDistinguishInitializationAndPrebinding(wide: Bool, swapped: Bool) throws {
        let bytes = try #require(ABICreateLazyLibraryFixture(wide ? 1 : 0, swapped ? 1 : 0))
        defer { free(bytes) }
        let address = UInt64(UInt(bitPattern: bytes))
        let slide = Int64(address) - (wide ? 0x100000000 : 0x10000000)
        var result = try LazyLibraryReader.read(headerAddress: address, slide: slide)
        #expect(result[0].isInitialized == false)
        #expect(result[1].isInitialized == true)
        #expect(result[1].areSymbolsPrebound == true)
        let initialized: UInt32 = swapped ? UInt32(1).byteSwapped : 1
        UnsafeMutableRawPointer(bytes).storeBytes(of: initialized, toByteOffset: 512, as: UInt32.self)
        #expect(try LazyLibraryReader.read(headerAddress: address, slide: slide)[0].isInitialized == true)
        UnsafeMutableRawPointer(bytes).storeBytes(of: UInt32.max, toByteOffset: 4096 + 4, as: UInt32.self)
        result = try LazyLibraryReader.read(headerAddress: address, slide: slide)
        #expect(result[0].isInitialized == nil)
        #expect(result[0].symbols?[2].name == "plainSymbol")
        #expect(throws: ABIResolutionError.self) { try LazyLibraryReader.read(headerAddress: 1, slide: 0) }
    }
    #endif

    @Test func nativeSnapshotsCopyNamesAndRejectExpiredGenerations() throws {
        var error: OpaquePointer?
        #expect(ABICopyLazyLibrariesForImage(UInt64.max, &error) == nil)
        let failure = try #require(error)
        #expect(ABIResolutionFailureCode(failure) == ABIFailureImageChanged)
        ABIReleaseResolutionFailure(failure)
        let bytes = try #require(ABICreateLazyLibraryFixture(1, 0))
        defer { free(bytes) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(bytes: bytes, count: ABILazyLibraryFixtureSize()).write(to: url)
        let list = try #require(ABICopyLazyLibrariesInFile(url.path, &error))
        defer { ABIFreeLazyLibraryList(list) }
        try FileManager.default.removeItem(at: url)
        #expect(error == nil)
        #expect(ABILazyLibraryListCount(list) == 3)
        let first = ABILazyLibraryListGet(list, 0)
        #expect(first.isInitialized == ABIDiagnosticUnknown)
        #expect(first.symbolsAvailable == ABIDiagnosticTrue)
        #expect(first.symbolCount == 3)
        #expect(String(cString: ABILazyLibraryListSymbol(list, 0, 0).name) == "Example::Renderer::refresh()")
    }
}
#endif
