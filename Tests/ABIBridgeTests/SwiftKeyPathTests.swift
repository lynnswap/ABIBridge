import ABIBridge
import ManagedSwiftFixtures
import Testing

struct SwiftKeyPathTests {
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
