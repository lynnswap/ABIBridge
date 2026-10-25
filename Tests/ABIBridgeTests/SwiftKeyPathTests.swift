#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import ABIBridgeCore
import ABIBridgeCore.Backend
import ABIBridgeRuntime
import ABIBridgeTestSupport
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

struct SwiftKeyPathTests {
    @MainActor @Test func explicitObjectiveCKeySurvivesExtractionAndSupportsObservation()
        async throws
    {
        func makePath() async throws -> ReferenceWritableKeyPath<RuntimeKeyPathObservedRoot, String>
        {
            let runtime = ABIRuntime()
            let root = try await runtime.resolve(
                .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathObservedRoot"))
            )
            let string = try await runtime.resolve(.swift(.type("Swift.String")))
            let value = try await root.resolve(
                .swift(.writableKeyPath("text", valueType: string, keyValueCodingKey: "nativeText"))
            )
            let copy = try value.copy()
            return try copy.take(
                as: ReferenceWritableKeyPath<RuntimeKeyPathObservedRoot, String>.self
            )
        }

        weak var releasedPath: AnyKeyPath?
        do {
            let path = try await makePath()
            releasedPath = path
            let canonical = \RuntimeKeyPathObservedRoot.text
            #expect(path == canonical)
            #expect(path._kvcKeyPathString == canonical._kvcKeyPathString)
            let receiver = RuntimeKeyPathObservedRoot()
            let observed = Mutex<[String]>([])
            let observation = receiver.observe(path, options: [.new]) { _, change in
                if let value = change.newValue { observed.withLock { $0.append(value) } }
            }
            receiver[keyPath: path] = "updated"
            #expect(observed.withLock { $0 } == ["updated"])
            #expect(receiver.value(forKey: "nativeText") as? String == "updated")
            observation.invalidate()
        }
        #expect(releasedPath == nil)
    }

    @MainActor @Test func computedPropertyPreservesNativeIdentityAndWriteback() async throws {
        let runtime = ABIRuntime()
        let root = try await runtime.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathRoot"))
        )
        let payload = try await runtime.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathPayload"))
        )
        let request = NativeRequest.swift(.writableKeyPath("payload", valueType: payload))
        let value = try await root.resolve(request)
        let canonical = runtimePayloadKeyPath()
        try value.withCopy {
            let path = try #require($0 as? AnyKeyPath)
            #expect(path == canonical)
            #expect(path.hashValue == canonical.hashValue)
            #expect([canonical: "matched"][path] == "matched")
            #expect(writeRuntimePayload(through: path, text: "updated") == "updated:1")
        }
        let copy = try value.copy()
        let path = try copy.take(
            as: WritableKeyPath<RuntimeKeyPathRoot, RuntimeKeyPathPayload>.self
        )
        #expect(path == canonical)
        #expect(copy.isConsumed)
        #expect(!value.isConsumed)
    }

    @Test func constrainedExistentialPropertiesPreserveIdentityAndWriteback() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveAndWait(
            .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathSequenceRoot"))
        )
        let getter = try root.resolveAndWait(
            .swift(.getter("sequence", as: (() -> NativeSwiftValue).self))
        )
        let sequence = try unsafe getter.unsafeInvoke(on: RuntimeKeyPathSequenceRoot())
        let value = try root.resolveAndWait(
            .swift(.writableKeyPath("sequence", valueType: sequence.type))
        )
        let path = try value.copy().take(
            as: WritableKeyPath<RuntimeKeyPathSequenceRoot, any Sequence<Int>>.self
        )
        #expect(path == \RuntimeKeyPathSequenceRoot.sequence)
        var receiver = RuntimeKeyPathSequenceRoot()
        receiver[keyPath: path] = [2, 3]
        #expect(Array(receiver.sequence) == [2, 3])
        let otherGetter = try root.resolveAndWait(
            .swift(.getter("otherSequence", as: (() -> NativeSwiftValue).self))
        )
        let other = try unsafe otherGetter.unsafeInvoke(on: RuntimeKeyPathSequenceRoot())
        #expect {
            try root.resolveAndWait(.swift(.writableKeyPath("sequence", valueType: other.type)))
        } throws: { error in
            guard case ABIResolutionError.signatureMismatch = error else { return false }
            return true
        }
    }

    @Test func extensionPropertyUsesItsOwnIdentityAndImplementation() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveAndWait(.swift(.type("Swift.String")))
        let payload = try runtime.resolveAndWait(
            .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathPayload"))
        )
        let value = try root.resolveAndWait(
            .swift(
                .writableKeyPath(
                    "(extension in ManagedSwiftFixtures):Swift.String.runtimeKeyPathPayload",
                    valueType: payload
                )
            )
        )
        try value.withCopy {
            let path = try #require($0 as? AnyKeyPath)
            let canonical = runtimeExtensionPayloadKeyPath()
            #expect(path == canonical)
            #expect([canonical: "extension"][path] == "extension")
            #expect(path != runtimePayloadKeyPath())
            #expect(writeRuntimeExtensionPayload(through: path, text: "updated") == "updated!")
        }
    }

    @Test func propertiesOfTypesDeclaredInExtensionsKeepTheirOwnerContext() throws {
        let runtime = ABIRuntime()
        let owner = "(extension in ManagedSwiftFixtures):Swift.Int.RuntimeNestedCounter"
        let root = try runtime.resolveAndWait(.swift(.type(owner)))
        let string = try runtime.resolveAndWait(.swift(.type("Swift.String")))
        for (name, expected) in [
            ("text", \Int.RuntimeNestedCounter.text),
            (owner + ".text", \Int.RuntimeNestedCounter.text),
            (owner + ".extraText", \Int.RuntimeNestedCounter.extraText),
        ] {
            let value = try root.resolveAndWait(.swift(.writableKeyPath(name, valueType: string)))
            let path = try value.copy().take(
                as: ReferenceWritableKeyPath<Int.RuntimeNestedCounter, String>.self
            )
            #expect(path == expected)
        }
    }

    @Test func propertyNamesNeedOnlyBeSwiftIdentifiers() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveAndWait(
            .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathReferenceRoot"))
        )
        let string = try runtime.resolveAndWait(.swift(.type("Swift.String")))
        for (name, expected) in [
            ("🐱", \RuntimeKeyPathReferenceRoot.🐱),
            // Spelled like a destructor, which names nothing to a property.
            ("deinit", \RuntimeKeyPathReferenceRoot.`deinit`),
        ] {
            let value = try root.resolveAndWait(.swift(.writableKeyPath(name, valueType: string)))
            let path = try value.copy().take(
                as: ReferenceWritableKeyPath<RuntimeKeyPathReferenceRoot, String>.self
            )
            #expect(path == expected)
        }
    }

    #if DEBUG
    @Test func objectiveCRootsResolveTheirExtensionProperties() throws {
        let runtime = ABIRuntime()
        let root = try runtime.swiftType(for: NSObject.self)
        let string = try runtime.resolveAndWait(.swift(.type("Swift.String")))
        let value = try root.resolveAndWait(
            .swift(
                .writableKeyPath(
                    "(extension in ManagedSwiftFixtures):__C.NSObject.runtimeKeyPathTag",
                    valueType: string
                )
            )
        )
        let path = try value.copy().take(as: ReferenceWritableKeyPath<NSObject, String>.self)
        #expect(path == \NSObject.runtimeKeyPathTag)
    }
    #endif

    #if os(macOS) && DEBUG
    @Test func descriptorsBothSourcesDescribeResolveOnce() async throws {
        let module = "SharedKeyPath_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public struct Root {
                    private var storage = "stored"
                    public init() {}
                    public var payload: String {
                        get { storage }
                        set { storage = newValue }
                    }
                }
                """,
            stripped: true,
            linkArguments: [
                "-parse-as-library", "-enable-library-evolution",
                "-Xlinker", "-unexported_symbol", "-Xlinker", "_$s*4RootVMn",
            ]
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        // The image names no type descriptor of `Root`, so only the shared
        // cache's local symbols name it, and they repeat the exported
        // property descriptor.
        let exports = RuntimeSymbolResolver().exportedSymbols(withPrefix: "_$s", in: image)
        #expect(!exports.contains { $0.name.hasSuffix("4RootVMn") })
        let metadata = try #require(exports.first { $0.name.hasSuffix("4RootVN") })
        let exported = try #require(exports.first { $0.name.hasSuffix("7payloadSSvpMV") })
        let typeDescriptor = try #require(
            ABISwiftTypeDescriptor(UnsafeRawPointer(bitPattern: UInt(metadata.address)))
        )
        let locals = [
            (
                name: String(metadata.name.dropLast()) + "Mn",
                address: UInt64(UInt(bitPattern: typeDescriptor))
            ),
            (name: exported.name, address: exported.address),
        ]
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [
                    { record in
                        for local in locals { local.name.withCString { record($0, local.address) } }
                    }
                ],
                imageIdentity: image.identity
            )
        })
        let runtime = ABIRuntime(resolver: SymbolResolver(resolver))
        let root = try await runtime.resolve(
            .swift(.type(module + ".Root")),
            in: .path(fixture.libraryURL)
        )
        let string = try await runtime.resolve(.swift(.type("Swift.String")))
        // Key path lookup starts from indexes without the local symbols.
        runtime.removeCachedResults()
        let value = try await root.resolve(.swift(.writableKeyPath("payload", valueType: string)))
        try value.withCopy {
            let path = try #require($0 as? AnyKeyPath)
            #expect(type(of: path).valueType == String.self)
        }
    }

    @Test func descriptorsThatOnlyLocalSymbolsDescribeResolve() async throws {
        let module = "LocalKeyPath_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public final class Root {
                    private var storage = "stored"
                    public init() {}
                    public var payload: String {
                        get { storage }
                        set { storage = newValue }
                    }
                }
                """,
            linkArguments: ["-parse-as-library", "-enable-library-evolution"]
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        // Only a local symbol names the exported descriptor of `payload` as
        // the descriptor of a property `other`.
        let exported = try #require(
            RuntimeSymbolResolver().exportedSymbols(withPrefix: "_$s", in: image).first {
                $0.name.hasSuffix("7payloadSSvpMV")
            }
        )
        let local = (
            name: String(exported.name.dropLast("7payloadSSvpMV".count)) + "5otherSSvpMV",
            address: exported.address
        )
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [{ record in local.name.withCString { record($0, local.address) } }],
                imageIdentity: image.identity
            )
        })
        let runtime = ABIRuntime(resolver: SymbolResolver(resolver))
        let root = try await runtime.resolve(
            .swift(.type(module + ".Root")),
            in: .path(fixture.libraryURL)
        )
        let string = try await runtime.resolve(.swift(.type("Swift.String")))
        let value = try await root.resolve(.swift(.writableKeyPath("other", valueType: string)))
        let make = try await root.resolve(
            .swift(.initializer("init()", as: (() -> AnyObject).self))
        )
        let object = try unsafe make.unsafeInvoke()
        // An `AnyObject` value cannot apply a key path itself.
        func read<Root>(_ root: Root, through path: AnyKeyPath) -> Any? { root[keyPath: path] }
        try value.withCopy {
            let path = try #require($0 as? AnyKeyPath)
            #expect(read(object, through: path) as? String == "stored")
        }
    }

    @Test func extensionPropertiesOfOtherModulesDoNotHideSharedCacheDescriptors() async throws {
        let module = "VisibleKeyPath_KeyPath"
        let source = """
            extension String {
                public var sharedName: String {
                    get { self + "!" }
                    set {}
                }
            }
            """
        let arguments = ["-parse-as-library", "-enable-library-evolution"]
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: source,
            linkArguments: arguments
        )
        defer { fixture.cleanup() }
        let image = try #require(
            try await RuntimeSymbolResolver().images(matching: .path(fixture.libraryURL)).first
        )
        // The image exports this module's `sharedName`; only a local symbol
        // describes another module's property of that name.
        let exported = try #require(
            RuntimeSymbolResolver().exportedSymbols(withPrefix: "_$s", in: image).first {
                $0.name.hasSuffix("10sharedNameSSvpMV")
            }
        )
        let other = "Other" + module
        let otherFixture = try FixtureLibrary(
            load: false,
            swiftModule: other,
            swiftSource: source,
            linkArguments: arguments
        )
        defer { otherFixture.cleanup() }
        let localName = try #require(
            try otherFixture.exportedSymbols().first { $0.hasSuffix("10sharedNameSSvpMV") }
        )
        let local = (
            name: localName,
            address: exported.address
        )
        #expect(local.name != exported.name)
        let resolver = RuntimeSymbolResolver(capturingSharedCacheSymbols: { _, _, source in
            guard source == .loaded else { return nil }
            return SharedCacheSymbols.CapturedSymbols(
                slide: 0,
                readers: [{ record in local.name.withCString { record($0, local.address) } }],
                imageIdentity: image.identity
            )
        })
        let runtime = ABIRuntime(resolver: SymbolResolver(resolver))
        let string = try await runtime.resolve(.swift(.type("Swift.String")))
        let value = try await string.resolve(
            .swift(
                .writableKeyPath(
                    "(extension in \(other)):Swift.String.sharedName",
                    valueType: string
                )
            )
        )
        try value.withCopy {
            let path = try #require($0 as? KeyPath<String, String>)
            #expect("text"[keyPath: path] == "text!")
        }
    }
    #endif

    @Test func unavailableAndMismatchedPropertiesReportFailure() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveAndWait(
            .swift(.type("ManagedSwiftFixtures.RuntimeKeyPathRoot"))
        )
        let string = try runtime.resolveAndWait(.swift(.type("Swift.String")))
        #expect(throws: ABIResolutionError.self) {
            try root.resolveAndWait(.swift(.writableKeyPath("missing", valueType: string)))
        }
        #expect(throws: ABIResolutionError.self) {
            try root.resolveAndWait(.swift(.writableKeyPath("payload", valueType: string)))
        }
        let integer = try runtime.resolveAndWait(.swift(.type("Swift.Int")))
        #expect(throws: ABIResolutionError.self) {
            try root.resolveAndWait(
                .swift(
                    .writableKeyPath(
                        "ManagedSwiftFixtures.RuntimeKeyPathStoredRoot.number",
                        valueType: integer
                    )
                )
            )
        }
    }
}
