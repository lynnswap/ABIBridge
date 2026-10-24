import ABIBridge
import ABIBridgeTestSupport
import CoreFoundation
import Darwin
import MachO
import Testing

struct ImageMetadataTests {
    #if os(macOS)
    @Test func loadedImageMetadataUsesRuntimeAddresses() async throws {
        let fixture = try FixtureLibrary(
            cxxSource: """
                #include <cstdint>
                extern "C" {
                __attribute__((noinline, used)) int32_t ABIFixtureAdd(int32_t a, int32_t b) {
                    return a + b;
                }
                int32_t ABIFixtureCounter = 42;
                uintptr_t ABIFixtureAddress(int kind) {
                    if (kind == 0) return reinterpret_cast<uintptr_t>(&ABIFixtureAdd);
                    if (kind == 1) return reinterpret_cast<uintptr_t>(&ABIFixtureCounter);
                    return reinterpret_cast<uintptr_t>("ABIBridge image metadata");
                }
                }
                """
        )
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(
            runtime.resolveImagesAndWait(matching: .path(fixture.libraryURL)).first
        )
        let metadata = try runtime.resolveImageMetadataAndWait(in: image)
        #expect(metadata.image.identity == image.identity)
        let header = try #require(
            UnsafePointer<mach_header_64>(bitPattern: UInt(image.identity.headerAddress))
        )
        #expect(metadata.is64Bit)
        #expect(metadata.architecture.cpuType == header.pointee.cputype)
        #expect(metadata.architecture.cpuSubtype == header.pointee.cpusubtype)

        let functionAddress = UInt64(try fixture.address(kind: 0))
        let starts = try #require(metadata.functionStartAddresses)
        #expect(starts.contains(functionAddress))
        #expect(!starts.contains(functionAddress + 1))
        #expect(!starts.contains(UInt64(try fixture.address(kind: 1))))
        #expect(Set(starts).count == starts.count)
        let function = try runtime.resolveAndWait(
            .init(name: "ABIFixtureAdd", language: .c),
            in: image
        )
        #expect(
            unsafe function.withUnsafeAddress { UInt64(UInt(bitPattern: $0)) == functionAddress }
        )
        let text = try #require(
            metadata.sections.first {
                $0.segmentName == "__TEXT" && $0.name == "__text"
            }
        )
        #expect(text.addressRange == function.sectionRange)

        let cstring = try #require(
            metadata.sections.first {
                $0.segmentName == "__TEXT" && $0.name == "__cstring"
            }
        )
        var size: UInt = 0
        let sectionAddress = try #require(getsectiondata(header, "__TEXT", "__cstring", &size))
        let start = UInt64(UInt(bitPattern: sectionAddress))
        #expect(cstring.addressRange == start..<(start + UInt64(size)))
        let stringAddress = UInt64(try fixture.address(kind: 2))
        #expect(cstring.addressRange.contains(stringAddress))
        #expect(
            cstring.addressRange.contains(
                stringAddress + UInt64("ABIBridge image metadata".utf8.count)
            )
        )
    }

    @Test func metadataKeepsTheImageLoadedAfterOtherOwnersReleaseIt() async throws {
        let fixture = try FixtureLibrary()
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(fixture.libraryURL)
        var metadata: NativeImageMetadata? = try {
            let image = try #require(runtime.resolveImagesAndWait(matching: scope).first)
            return try runtime.resolveImageMetadataAndWait(in: image)
        }()
        fixture.close()
        runtime.removeCachedResults()
        try {
            let retained = try #require(metadata)
            let function = try runtime.resolveAndWait(
                .cxx(
                    .function(
                        fixture.namespace + "::add(int, int)",
                        as: ((Int32, Int32) -> Int32).self
                    )
                ),
                in: retained.image
            )
            let starts = try #require(retained.functionStartAddresses)
            #expect(
                unsafe function.symbol.withUnsafeAddress {
                    starts.contains(UInt64(UInt(bitPattern: $0)))
                }
            )
            #expect(try unsafe function.unsafeInvoke(20, 22) == 42)
        }()
        metadata = nil
        runtime.removeCachedResults()
        #expect(try runtime.resolveImagesAndWait(matching: scope).isEmpty)
    }

    @Test func absentFunctionStartsRemainUnavailable() async throws {
        let fixture = try FixtureLibrary(linkArguments: ["-Wl,-no_function_starts"])
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let image = try #require(
            runtime.resolveImagesAndWait(matching: .path(fixture.libraryURL)).first
        )
        let metadata = try runtime.resolveImageMetadataAndWait(in: image)
        #expect(metadata.functionStartAddresses == nil)
        #expect(!metadata.sections.isEmpty)
    }
    #endif

    @Test func loadedSystemFrameworkMetadataMatchesItsHeaderAndSymbols() async throws {
        _ = CFRunLoopGetTypeID()
        let runtime = ABIRuntime()
        let image = try #require(
            runtime.resolveImagesAndWait(matching: .framework(named: "CoreFoundation")).first
        )
        let metadata = try await runtime.resolveImageMetadata(in: image)
        let header = try #require(
            UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))
        ).pointee
        #expect(metadata.image.identity == image.identity)
        #expect(metadata.is64Bit == (header.magic == MH_MAGIC_64))
        #expect(metadata.architecture.cpuType == header.cputype)
        #expect(metadata.architecture.cpuSubtype == header.cpusubtype)
        let function = try runtime.resolveAndWait(
            .init(name: "CFRunLoopGetTypeID", language: .c),
            in: image
        )
        try unsafe function.withUnsafeAddress {
            let address = UInt64(UInt(bitPattern: $0))
            let section = try #require(
                metadata.sections.first { $0.addressRange.contains(address) }
            )
            #expect(section.addressRange == function.sectionRange)
            if let starts = metadata.functionStartAddresses {
                #expect(starts.contains(address))
            }
        }
    }
}
