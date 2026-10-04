import ABIBridgeRuntime
import ABIBridgeTestSupport
#if DEBUG && os(macOS)
@testable import ABIBridge
import ABIBridgeCore
import Foundation
import Darwin
import Testing

final class CompiledSwiftReplacementFixture {
    let module = "Replacement_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let provider: FixtureLibrary
    let caller: FixtureLibrary
    let runtime = ABIRuntime()
    var callerModule: String { module + "Caller" }

    init(
        interposable: Bool = false,
        writable: Bool = true,
        providerExtra: String = "",
        callerExtra: String = ""
    ) throws {
        // Writable linking is confined to this disposable validation library.
        let writableFlags = writable ? ["-Xlinker", "-no_data_const"] : []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ArchitectureValidation/Sources")
        let source = try String(
            contentsOf: root.appendingPathComponent("SwiftReplacementFixtures/Provider.swift"),
            encoding: .utf8
        )
        provider = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: source + "\n" + providerExtra,
            linkArguments: ["-O", "-swift-version", "6", "-emit-module"] + writableFlags
        )
        if interposable {
            let declaration = module + ".scalar(Swift.Int64) -> Swift.Int64"
            let symbols = try provider.exportedSymbols().filter {
                DeclarationKey.demangle(String($0.dropFirst()), language: .swift) == declaration
            }
            let symbol = try #require(symbols.count == 1 ? symbols.first : nil)
            let list = provider.directory.appendingPathComponent("interposable-symbols.txt")
            try (symbol + "\n").write(to: list, atomically: true, encoding: .utf8)
            // Whole-image interposition also binds hidden Swift witness thunks
            // that the linker does not export. This control only interposes scalar.
            try provider.rebuild(linkingWith: [
                "-Xlinker", "-interposable_list", "-Xlinker", list.path,
            ])
        }
        // swiftc places a module next to the output library when no path is given.
        let callerSource = try String(
            contentsOf: root.appendingPathComponent("SwiftReplacementCaller/Caller.swift"),
            encoding: .utf8
        )
        .replacingOccurrences(of: "SwiftReplacementFixtures", with: module)
        caller = try FixtureLibrary(
            load: false,
            swiftModule: module + "Caller",
            swiftSource: callerSource + "\n" + callerExtra,
            linkArguments: [
                "-O", "-swift-version", "6", "-I", provider.directory.path,
                provider.libraryURL.path,
            ] + writableFlags
        )
        try provider.load(); try caller.load()
    }
    func cleanup() { caller.cleanup(); provider.cleanup() }
    var providerScope: ImageSelector { .path(provider.libraryURL) }
    var callerScope: ImageSelector { .path(caller.libraryURL) }
    func symbol(_ name: String) async throws -> ResolvedSymbol {
        try await runtime.resolve(
            .init(name: module + "." + name, language: .swift),
            in: providerScope
        )
    }

    func withClassMethod(
        _ name: String,
        replacement: String,
        _ body: () throws -> Void
    ) async throws {
        let original = try await symbol("ReplacementRenderer." + name)
        let replacement = try await symbol("ReplacementRenderer." + replacement)
        let type = try await runtime.swiftType(
            named: module + ".ReplacementRenderer",
            in: providerScope
        )
        let descriptor = try await runtime.resolve(
            .init(
                name: "nominal type descriptor for " + type.name,
                language: .swift,
                kind: .data
            ),
            in: providerScope
        )
        let metadata = unsafeBitCast(await type.metadata, to: UnsafeMutableRawPointer.self)
        try unsafe descriptor.withUnsafeAddress { descriptor in
            // This layout is limited to the fixture's nongeneric root class,
            // with no superclass descriptor or stored properties.
            let flags = descriptor.load(as: UInt32.self)
            try #require(flags & 0x1f == 16 && flags & 0x80 == 0 && flags & 0x80000000 != 0)
            try #require(descriptor.load(fromByteOffset: 20, as: Int32.self) == 0)
            try #require(descriptor.load(fromByteOffset: 36, as: UInt32.self) == 0)
            let positiveWords = Int(descriptor.load(fromByteOffset: 28, as: UInt32.self))
            let offset = Int(descriptor.load(fromByteOffset: 44, as: UInt32.self))
            let count = Int(descriptor.load(fromByteOffset: 48, as: UInt32.self))
            try #require(count > 0 && offset + count <= positiveWords)
            try unsafe original.withUnsafeAddress { originalAddress in
                var matches: [(UnsafeMutableRawPointer, NativePointerAuthentication)] = []
                for index in 0..<count {
                    let method = descriptor.advanced(by: 52 + 8 * index)
                    let methodFlags = method.load(as: UInt32.self)
                    let implementationField = method.advanced(by: 4)
                    let implementation = implementationField.advanced(
                        by: Int(implementationField.load(as: Int32.self))
                    )
                    guard implementation == originalAddress else { continue }
                    try #require(methodFlags & 0x7f == 0x10)
                    let slot = metadata.advanced(by: (offset + index) * MemoryLayout<UInt>.size)
                    let authentication: NativePointerAuthentication =
                        NativePointerAuthentication.isEnabled
                        ? .signed(
                            key: .instructionA,
                            discriminator: UInt(methodFlags >> 16),
                            addressDiversity: true
                        ) : .unsigned
                    matches.append((slot, authentication))
                }
                let match = try #require(matches.count == 1 ? matches.first : nil)
                try withSwiftFixtureReplacement(
                    slot: match.0,
                    authentication: match.1,
                    original: original,
                    replacement: replacement,
                    body
                )
            }
        }
    }

    @discardableResult func withImport(
        _ name: String,
        replacement: String,
        sameImage: Bool = false,
        allowProtectedRefusal: Bool = false,
        _ body: () throws -> Void
    ) async throws -> ABIPointerSlotResult {
        let original = try await symbol(name), replacement = try await symbol(replacement)
        let images = try SymbolResolver().images(matching: sameImage ? providerScope : callerScope)
        let index = try ABIBridge.ImportIndex(image: #require(images.first))
        let references = try index.matches(original.declaration)
        try #require(!references.isEmpty)
        // Each fixture has exactly one reference to the selected declaration.
        let reference = try #require(references.count == 1 ? references.first : nil)
        let auth = try #require(reference.authentication)
        let slot = try #require(UnsafeMutableRawPointer(bitPattern: UInt(reference.address)))
        return try withSwiftFixtureReplacement(
            slot: slot,
            authentication: auth,
            original: original,
            replacement: replacement,
            allowProtectedRefusal: allowProtectedRefusal,
            body
        )
    }
}

// This test uses only symbols and slots from its compiler-owned fixture. It is
// not an installation API and does not infer an arbitrary replacement's ABI.
@discardableResult private func withSwiftFixtureReplacement(
    slot: UnsafeMutableRawPointer,
    authentication: NativePointerAuthentication,
    original: ResolvedSymbol,
    replacement: ResolvedSymbol,
    allowProtectedRefusal: Bool = false,
    _ body: () throws -> Void
) throws -> ABIPointerSlotResult {
    try unsafe original.withUnsafeAddress { originalAddress in
        try unsafe replacement.withUnsafeAddress { replacementAddress in
            let current = slot.load(as: UInt.self)
            let target = ABIUnsafeReadAuthenticatedPointer(
                slot,
                authentication.keyCode,
                authentication.discriminator,
                authentication.addressDiversity
            )
            try #require(target == originalAddress)
            var next: UInt = 0
            try #require(
                ABIEncodePointerSlotFunction(
                    ABIUnsafeFunctionAtAddress(replacementAddress),
                    slot,
                    authentication.keyCode,
                    authentication.discriminator,
                    authentication.addressDiversity,
                    &next
                )
            )
            let mutation = ABICompareExchangePointerSlot(slot, current, next)
            defer {
                if mutation.didWrite {
                    let restored = ABICompareExchangePointerSlot(slot, next, current)
                    #expect(restored.status == ABIPointerSlotComplete && restored.didWrite)
                }
                #expect(slot.load(as: UInt.self) == current)
            }
            if allowProtectedRefusal && !mutation.didWrite
                && mutation.status == ABIPointerSlotProtectFailed
                && mutation.systemErrorCode == KERN_PROTECTION_FAILURE
                && mutation.regionFlags & UInt32(VM_REGION_FLAG_TPRO_ENABLED) != 0
            {
                return mutation
            }
            try #require(
                mutation.status == ABIPointerSlotComplete && mutation.didWrite,
                "status=\(mutation.status), wrote=\(mutation.didWrite), kernel=\(mutation.systemErrorCode), flags=\(mutation.regionFlags)"
            )
            try body()
            return mutation
        }
    }
}

@Suite(.serialized)
struct SwiftReplacementTests {
    @Test func classMetadataUsesCompiledMethodsAndPreservesDirectControls() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let make = try await fixture.runtime.swiftFunction(
            named: fixture.module + ".makeRenderer() -> " + fixture.module + ".ReplacementRenderer",
            as: (() -> AnyObject).self,
            in: fixture.providerScope
        )
        let object = try unsafe make.unsafeInvoke()
        let className = fixture.module + ".ReplacementRenderer"
        let scalar = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".classScalar(\(className), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self,
            in: fixture.callerScope
        )
        let final = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".classFinal(\(className), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self,
            in: fixture.callerScope
        )
        let devirtualized = try await fixture.runtime.swiftFunction(
            named: fixture.module + ".knownClassScalar(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.providerScope
        )
        let captured = try await fixture.runtime.object(object).method(
            named: "scalar(_:)",
            as: ((Int64) -> Int64).self
        )
        #expect(try unsafe scalar.unsafeInvoke(object, 40) == 42)
        try await fixture.withClassMethod(
            "scalar(Swift.Int64) -> Swift.Int64",
            replacement: "replacementScalar(Swift.Int64) -> Swift.Int64"
        ) { () throws -> Void in
            #expect(try unsafe scalar.unsafeInvoke(object, 40) == 240)
            #expect(try unsafe final.unsafeInvoke(object, 40) == 43)
            #expect(try unsafe devirtualized.unsafeInvoke(40) == 42)
            #expect(try unsafe captured.unsafeInvoke(40) == 42)
        }
        #expect(try unsafe scalar.unsafeInvoke(object, 40) == 42)

        let text = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".classText(\(className), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self,
            in: fixture.callerScope
        )
        let input = String(repeating: "method input", count: 200)
        #expect(try unsafe text.unsafeInvoke(object, input) == "method:" + input)
        try await fixture.withClassMethod(
            "text(Swift.String) -> Swift.String",
            replacement: "replacementText(Swift.String) -> Swift.String"
        ) { () throws -> Void in
            for _ in 0..<20 {
                #expect(
                    try unsafe text.unsafeInvoke(object, input) == "replacement-method:" + input
                )
            }
        }
        #expect(try unsafe text.unsafeInvoke(object, input) == "method:" + input)

        let payload = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".classPayload(\(className), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self,
            in: fixture.callerScope
        )
        #expect(try unsafe payload.unsafeInvoke(object, 40) == 220)
        try await fixture.withClassMethod(
            "payload(Swift.Int64) -> \(fixture.module).ReplacementPayload",
            replacement: "replacementPayload(Swift.Int64) -> \(fixture.module).ReplacementPayload"
        ) { () throws -> Void in
            #expect(try unsafe payload.unsafeInvoke(object, 40) == 1210)
        }
        #expect(try unsafe payload.unsafeInvoke(object, 40) == 220)
    }

    @Test func compilerDynamicReplacementIsAnIndependentInstrumentedPath() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let captured = try await fixture.runtime.swiftFunction(
            named: fixture.module + ".dynamicScalar(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.providerScope
        )
        #expect(try unsafe captured.unsafeInvoke(40) == 41)
        let replacement = try FixtureLibrary(
            swiftModule: fixture.module + "Dynamic",
            swiftSource: """
                import \(fixture.module)
                @_dynamicReplacement(for: dynamicScalar(_:))
                public func replacedDynamic(_ value: Int64) -> Int64 { dynamicScalar(value) + 100 }
                """,
            linkArguments: [
                "-O", "-swift-version", "6", "-I", fixture.provider.directory.path,
                fixture.provider.libraryURL.path,
            ]
        )
        defer { replacement.cleanup() }
        // The original compiled entry itself consults replacement instrumentation;
        // unlike a captured ordinary method, it observes this change too.
        #expect(try unsafe captured.unsafeInvoke(40) == 141)
    }

    @Test func compiledImportsPreserveScalarStringIndirectResultAndStructContext() async throws {
        let fixture = try CompiledSwiftReplacementFixture(); defer { fixture.cleanup() }
        let scalar = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".importedScalar(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.callerScope
        )
        let original = try await fixture.runtime.swiftFunction(
            named: fixture.module + ".scalar(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.providerScope
        )
        #expect(try unsafe scalar.unsafeInvoke(40) == 41)
        try await fixture.withImport(
            "scalar(Swift.Int64) -> Swift.Int64",
            replacement: "replacementScalar(Swift.Int64) -> Swift.Int64"
        ) { () throws -> Void in
            #expect(try unsafe scalar.unsafeInvoke(40) == 140)
            #expect(try unsafe original.unsafeInvoke(40) == 41)
        }
        #expect(try unsafe scalar.unsafeInvoke(40) == 41)

        let text = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".importedText(_:)",
            as: ((String) -> String).self,
            in: fixture.callerScope
        )
        let input = String(repeating: "input", count: 200)
        #expect(try unsafe text.unsafeInvoke(input) == "original:" + input)
        try await fixture.withImport(
            "text(Swift.String) -> Swift.String",
            replacement: "replacementText(Swift.String) -> Swift.String"
        ) { () throws -> Void in
            for _ in 0..<20 {
                #expect(try unsafe text.unsafeInvoke(input) == "replacement:" + input)
            }
        }
        #expect(try unsafe text.unsafeInvoke(input) == "original:" + input)

        let large = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".importedPayload(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.callerScope
        )
        #expect(try unsafe large.unsafeInvoke(40) == 210)
        try await fixture.withImport(
            "payload(Swift.Int64) -> \(fixture.module).ReplacementPayload",
            replacement: "replacementPayload(Swift.Int64) -> \(fixture.module).ReplacementPayload"
        ) { () throws -> Void in
            #expect(try unsafe large.unsafeInvoke(40) == 710)
        }
        #expect(try unsafe large.unsafeInvoke(40) == 210)

        let valueMethod = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".importedValueMethod(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.callerScope
        )
        #expect(try unsafe valueMethod.unsafeInvoke(2) == 42)
        try await fixture.withImport(
            "ReplacementValue.scalar(Swift.Int64) -> Swift.Int64",
            replacement: "ReplacementValue.replacementScalar(Swift.Int64) -> Swift.Int64"
        ) { () throws -> Void in
            #expect(try unsafe valueMethod.unsafeInvoke(2) == 142)
        }
        #expect(try unsafe valueMethod.unsafeInvoke(2) == 42)
    }

    @Test func normalImportProtectionsReportTheirActualOutcome() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false);
        defer { fixture.cleanup() }
        let oracle = try await fixture.runtime.swiftFunction(
            named: fixture.callerModule + ".importedScalar(_:)",
            as: ((Int64) -> Int64).self,
            in: fixture.callerScope
        )
        var entered = false
        let mutation = try await fixture.withImport(
            "scalar(Swift.Int64) -> Swift.Int64",
            replacement: "replacementScalar(Swift.Int64) -> Swift.Int64",
            allowProtectedRefusal: true
        ) { () throws -> Void in
            entered = true
            #expect(try unsafe oracle.unsafeInvoke(40) == 140)
        }
        #expect(entered == mutation.didWrite)
        #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        print(
            "Swift import normal protection: wrote=\(mutation.didWrite), status=\(mutation.status), kernel=\(mutation.systemErrorCode), flags=\(mutation.regionFlags)"
        )
    }

    @Test func sameImageCallsRequireInterposableLinking() async throws {
        for interposable in [false, true] {
            let fixture = try CompiledSwiftReplacementFixture(interposable: interposable)
            defer { fixture.cleanup() }
            let oracle = try await fixture.runtime.swiftFunction(
                named: fixture.module + ".sameImageScalar(_:)",
                as: ((Int64) -> Int64).self,
                in: fixture.providerScope
            )
            #expect(try unsafe oracle.unsafeInvoke(40) == 41)
            if interposable {
                try await fixture.withImport(
                    "scalar(Swift.Int64) -> Swift.Int64",
                    replacement: "replacementScalar(Swift.Int64) -> Swift.Int64",
                    sameImage: true
                ) { () throws -> Void in
                    #expect(try unsafe oracle.unsafeInvoke(40) == 140)
                }
            } else {
                let image = try #require(
                    SymbolResolver().images(matching: fixture.providerScope).first
                )
                let matches = try ABIBridge.ImportIndex(image: image).matches(
                    .init(
                        name: fixture.module + ".scalar(Swift.Int64) -> Swift.Int64",
                        language: .swift
                    )
                )
                #expect(matches.isEmpty)
            }
            #expect(try unsafe oracle.unsafeInvoke(40) == 41)
        }
    }
}
#endif
