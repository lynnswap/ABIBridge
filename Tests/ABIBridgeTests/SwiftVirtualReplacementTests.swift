#if DEBUG && os(macOS)
@testable import ABIBridge
import Foundation
import Testing

@Suite(.serialized)
struct SwiftVirtualReplacementTests {
    @Test func sourceSelectedSlotsPreserveInheritanceOverridesAndCapturedEntries() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false)
        defer { fixture.cleanup() }
        let baseName = fixture.module + ".ReplacementRenderer"
        let base = try await fixture.runtime.swiftType(named: baseName, in: fixture.providerScope)
        let inherited = try await fixture.runtime.swiftType(named: fixture.module + ".InheritedRenderer", in: fixture.providerScope)
        let overridden = try await fixture.runtime.swiftType(named: fixture.module + ".OverridingRenderer", in: fixture.providerScope)
        let replacement = try await base.method(named: "replacementScalar(_:)", as: ((Int64) -> Int64).self)
        let call = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classScalar(\(baseName), Swift.Int64) -> Swift.Int64",
            as: ((AnyObject, Int64) -> Int64).self, in: fixture.callerScope)
        var objects: [AnyObject] = []
        for name in ["makeRenderer", "makeInheritedRenderer", "makeOverridingRenderer"] {
            let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".\(name)() -> \(baseName)",
                as: (() -> AnyObject).self, in: fixture.providerScope)
            objects.append(try unsafe make.unsafeInvoke())
        }
        for (index, type) in [base, inherited, overridden].enumerated() {
            let method = try await type.method(named: "scalar(_:)", as: ((Int64) -> Int64).self)
            let plan = try unsafe method.prepareVirtualReplacement(with: replacement)
            let original = plan.original
            #expect(plan.status == .prepared)
            #expect(try unsafe original.unsafeInvoke(on: objects[index], 40) == (index == 2 ? 44 : 42))
            try unsafe plan.install()
            defer { try? plan.restore() }
            #expect(plan.status == .installed)
            for (other, object) in objects.enumerated() {
                #expect(try unsafe call.unsafeInvoke(object, 40) == (other == index ? 240 : (other == 2 ? 44 : 42)))
            }
            // A second preparation selects the immutable declaration metadata,
            // while its original captures the implementation installed above.
            let second = try unsafe method.prepareVirtualReplacement(with: replacement)
            #expect(second.address == plan.address)
            #expect(try unsafe second.original.unsafeInvoke(on: objects[index], 40) == 240)
            let directResult = try unsafe method.unsafeInvoke(on: objects[index], 40)
            #expect(directResult == (index == 2 ? 44 : 42))
            try plan.restore()
            #expect(plan.status == .restored)
            #expect(try unsafe original.unsafeInvoke(on: objects[index], 40) == (index == 2 ? 44 : 42))
        }
        let final = try await base.method(named: "finalScalar(_:)", as: ((Int64) -> Int64).self)
        #expect(throws: ABIResolutionError.self) { try unsafe final.prepareVirtualReplacement(with: replacement) }
    }

    @Test func heapBackedArgumentsAndReturnsUseTheOriginalSwiftABI() async throws {
        let fixture = try CompiledSwiftReplacementFixture(writable: false)
        defer { fixture.cleanup() }
        let name = fixture.module + ".ReplacementRenderer"
        let type = try await fixture.runtime.swiftType(named: name, in: fixture.providerScope)
        let make = try await fixture.runtime.swiftFunction(named: fixture.module + ".makeRenderer() -> " + name,
            as: (() -> AnyObject).self, in: fixture.providerScope)
        let object = try unsafe make.unsafeInvoke()
        let method = try await type.method(named: "text(_:)", as: ((String) -> String).self)
        let replacement = try await type.method(named: "replacementText(_:)", as: ((String) -> String).self)
        let plan = try unsafe method.prepareVirtualReplacement(with: replacement)
        let oracle = try await fixture.runtime.swiftFunction(named: fixture.callerModule + ".classText(\(name), Swift.String) -> Swift.String",
            as: ((AnyObject, String) -> String).self, in: fixture.callerScope)
        let input = String(repeating: "swift class", count: 100)
        try unsafe plan.install()
        defer { try? plan.restore() }
        for _ in 0..<20 {
            #expect(try unsafe oracle.unsafeInvoke(object, input) == "replacement-method:" + input)
            #expect(try unsafe plan.original.unsafeInvoke(on: object, input) == "method:" + input)
        }
        try plan.restore()
        #expect(try unsafe oracle.unsafeInvoke(object, input) == "method:" + input)
    }

    @Test func resilientSuperclassOffsetsAndIndirectOverrideDescriptors() async throws {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let parentModule = "ResilientBase_" + suffix, childModule = "ResilientChild_" + suffix
        let parent = try FixtureLibrary(swiftModule: parentModule, swiftSource: """
        open class Parent {
            public init() {}
            @inline(never) open func value(_ input: Int64) -> Int64 { input + 1 }
            @inline(never) public func replacement(_ input: Int64) -> Int64 { input + 100 }
        }
        @inline(never) public func invoke(_ object: Parent, _ value: Int64) -> Int64 { object.value(value) }
        """, linkArguments: ["-O", "-emit-module", "-enable-library-evolution"])
        defer { parent.cleanup() }
        let child = try FixtureLibrary(swiftModule: childModule, swiftSource: """
        import \(parentModule)
        open class Child: Parent {
            @inline(never) public override func value(_ input: Int64) -> Int64 { input + 2 }
            @inline(never) public func extra(_ input: Int64) -> Int64 { input + 3 }
        }
        @inline(never) public func make() -> Child { Child() }
        @inline(never) public func invokeExtra(_ object: Child, _ value: Int64) -> Int64 { object.extra(value) }
        """, linkArguments: ["-O", "-emit-module", "-enable-library-evolution", "-I", parent.directory.path, parent.libraryURL.path])
        defer { child.cleanup() }
        let runtime = ABIRuntime(), childName = childModule + ".Child"
        let type = try await runtime.swiftType(named: childName, in: .path(child.libraryURL))
        let parentType = try await runtime.swiftType(named: parentModule + ".Parent", in: .path(parent.libraryURL))
        let replacement = try await parentType.method(named: "replacement(_:)", as: ((Int64) -> Int64).self)
        let make = try await runtime.swiftFunction(named: childModule + ".make() -> " + childName,
            as: (() -> AnyObject).self, in: .path(child.libraryURL))
        let object = try unsafe make.unsafeInvoke()
        for (methodName, oracleName, scope, expected) in [
            ("value", parentModule + ".invoke(\(parentModule).Parent, Swift.Int64) -> Swift.Int64", parent.libraryURL, Int64(42)),
            ("extra", childModule + ".invokeExtra(\(childName), Swift.Int64) -> Swift.Int64", child.libraryURL, Int64(43))
        ] {
            let method = try await type.method(named: methodName + "(_:)", as: ((Int64) -> Int64).self)
            let oracle = try await runtime.swiftFunction(named: oracleName, as: ((AnyObject, Int64) -> Int64).self, in: .path(scope))
            let plan = try unsafe method.prepareVirtualReplacement(with: replacement)
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == expected)
            try unsafe plan.install()
            defer { try? plan.restore() }
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == 140)
            #expect(try unsafe plan.original.unsafeInvoke(on: object, 40) == expected)
            try plan.restore()
            #expect(try unsafe oracle.unsafeInvoke(object, 40) == expected)
        }
    }
}
#endif
