import ABIBridgeRuntime
import ManagedSwiftFixtures
import Testing

struct RuntimeKeyPathTests {
    @Test func keyValueCodingKeyCannotSilentlyTruncateAtNull() throws {
        let descriptor = try CallSymbols.resolve(
            "property descriptor for ManagedSwiftFixtures.RuntimeKeyPathObservedRoot.text : Swift.String",
            kind: .data
        )
        #expect {
            try RuntimeWritableKeyPathPlan(
                descriptor: descriptor,
                root: RuntimeKeyPathObservedRoot.self,
                value: String.self,
                keyValueCodingKey: "nativeText\0other"
            )
        } throws: { error in
            if case RuntimeResolutionError.unsupportedDeclaration = error { return true }
            return false
        }
    }

    @Test func nonmutatingDescriptorCreatesReferenceWritableKeyPath() throws {
        let descriptor = try CallSymbols.resolve(
            "property descriptor for ManagedSwiftFixtures.RuntimeKeyPathReferenceRoot.text : Swift.String",
            kind: .data
        )
        let plan = try RuntimeWritableKeyPathPlan(
            descriptor: descriptor,
            root: RuntimeKeyPathReferenceRoot.self,
            value: String.self
        )
        let path = try #require(
            plan.instantiate() as? ReferenceWritableKeyPath<RuntimeKeyPathReferenceRoot, String>
        )
        #expect(path == \RuntimeKeyPathReferenceRoot.text)
        let root = RuntimeKeyPathReferenceRoot("original")
        root[keyPath: path] = "updated"
        #expect(root.text == "updated")
    }

    @Test func computedDescriptorPreservesPropertyIdentityAndWriteback() throws {
        let descriptor = try CallSymbols.resolve(
            "property descriptor for ManagedSwiftFixtures.RuntimeKeyPathRoot.payload : ManagedSwiftFixtures.RuntimeKeyPathPayload",
            kind: .data
        )
        let plan = try RuntimeWritableKeyPathPlan(
            descriptor: descriptor,
            root: RuntimeKeyPathRoot.self,
            value: RuntimeKeyPathPayload.self
        )
        let path = try #require(
            plan.instantiate() as? WritableKeyPath<RuntimeKeyPathRoot, RuntimeKeyPathPayload>
        )
        let canonical = runtimePayloadKeyPath()
        #expect(path == canonical)
        #expect(path.hashValue == canonical.hashValue)
        #expect([canonical: "matched"][path] == "matched")

        var root = RuntimeKeyPathRoot("original")
        #expect(root[keyPath: path].text == "original")
        root[keyPath: path] = RuntimeKeyPathPayload("updated")
        #expect(root.payload.text == "updated")
        #expect(root.writes == 1)
    }

    @Test func readOnlyAndTrivialDescriptorsCannotSupplyWritableComponents() throws {
        let readOnly = try CallSymbols.resolve(
            "property descriptor for ManagedSwiftFixtures.RuntimeKeyPathRoot.readOnly : Swift.String",
            kind: .data
        )
        #expect {
            try RuntimeWritableKeyPathPlan(
                descriptor: readOnly,
                root: RuntimeKeyPathRoot.self,
                value: String.self
            )
        } throws: { error in
            if case RuntimeResolutionError.unsupportedDeclaration = error { return true }
            return false
        }

        let trivial = try CallSymbols.resolve(
            "property descriptor for ManagedSwiftFixtures.RuntimeKeyPathStoredRoot.number : Swift.Int",
            kind: .data
        )
        #expect {
            try RuntimeWritableKeyPathPlan(
                descriptor: trivial,
                root: RuntimeKeyPathStoredRoot.self,
                value: Int.self
            )
        } throws: { error in
            if case RuntimeResolutionError.unsupportedDeclaration = error { return true }
            return false
        }
    }
}
