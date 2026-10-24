#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
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
            let root = try await runtime.resolveSwiftType(
                named: "ManagedSwiftFixtures.RuntimeKeyPathObservedRoot"
            )
            let string = try await runtime.resolveSwiftType(named: "Swift.String")
            let value = try await root.resolveWritableKeyPath(
                named: "text",
                valueType: string,
                keyValueCodingKey: "nativeText"
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
        let root = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.RuntimeKeyPathRoot"
        )
        let payload = try await runtime.resolveSwiftType(
            named: "ManagedSwiftFixtures.RuntimeKeyPathPayload"
        )
        let value = try await root.resolveWritableKeyPath(named: "payload", valueType: payload)
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

    @Test func extensionPropertyUsesItsOwnIdentityAndImplementation() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveSwiftTypeAndWait(named: "Swift.String")
        let payload = try runtime.resolveSwiftTypeAndWait(
            named: "ManagedSwiftFixtures.RuntimeKeyPathPayload"
        )
        let value = try root.resolveWritableKeyPathAndWait(
            named:
                "(extension in ManagedSwiftFixtures):Swift.String.runtimeKeyPathPayload",
            valueType: payload
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

    @Test func propertyNamesNeedOnlyBeSwiftIdentifiers() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveSwiftTypeAndWait(
            named: "ManagedSwiftFixtures.RuntimeKeyPathReferenceRoot"
        )
        let string = try runtime.resolveSwiftTypeAndWait(named: "Swift.String")
        let value = try root.resolveWritableKeyPathAndWait(named: "🐱", valueType: string)
        let path = try value.copy().take(
            as: ReferenceWritableKeyPath<RuntimeKeyPathReferenceRoot, String>.self
        )
        #expect(path == \RuntimeKeyPathReferenceRoot.🐱)
    }

    #if os(macOS) && DEBUG
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
        let root = try await runtime.resolveSwiftType(
            named: module + ".Root",
            in: .path(fixture.libraryURL)
        )
        let string = try await runtime.resolveSwiftType(named: "Swift.String")
        let value = try await root.resolveWritableKeyPath(named: "other", valueType: string)
        let make = try await root.resolve(.initializer("init()", as: (() -> AnyObject).self))
        let object = try unsafe make.unsafeInvoke()
        // An `AnyObject` value cannot apply a key path itself.
        func read<Root>(_ root: Root, through path: AnyKeyPath) -> Any? { root[keyPath: path] }
        try value.withCopy {
            let path = try #require($0 as? AnyKeyPath)
            #expect(read(object, through: path) as? String == "stored")
        }
    }
    #endif

    @Test func unavailableAndMismatchedPropertiesReportFailure() throws {
        let runtime = ABIRuntime()
        let root = try runtime.resolveSwiftTypeAndWait(
            named: "ManagedSwiftFixtures.RuntimeKeyPathRoot"
        )
        let string = try runtime.resolveSwiftTypeAndWait(named: "Swift.String")
        #expect(throws: ABIResolutionError.self) {
            try root.resolveWritableKeyPathAndWait(named: "missing", valueType: string)
        }
        #expect(throws: ABIResolutionError.self) {
            try root.resolveWritableKeyPathAndWait(named: "payload", valueType: string)
        }
        let integer = try runtime.resolveSwiftTypeAndWait(named: "Swift.Int")
        #expect(throws: ABIResolutionError.self) {
            try root.resolveWritableKeyPathAndWait(
                named: "ManagedSwiftFixtures.RuntimeKeyPathStoredRoot.number",
                valueType: integer
            )
        }
    }
}
