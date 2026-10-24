import ABIBridge
import ABIBridgeTestSupport
import Foundation
import ManagedSwiftFixtures
import Testing

/// A value whose setter does not mutate it.
@frozen public struct SwiftRequestToggle: BitwiseCopyable {
    public nonisolated(unsafe) static var stored: Int64 = 0
    public var offset: Int64
    public init(offset: Int64) { self.offset = offset }
    public var value: Int64 {
        get { Self.stored + offset }
        nonmutating set { Self.stored = newValue - offset }
    }
    public var adjusted: Int64 {
        get { offset }
        set { offset = newValue }
    }
}

extension SwiftRequestToggle: ABIBridgeValue {
    public static let abiType = NativeType.int64
    public init(nativeValue: NativeValue) throws {
        self = try unsafe nativeValue.read(as: Self.self)
    }
    public static func nativeValue(from value: Self) throws -> NativeValue {
        try .init(copying: value, as: abiType)
    }
}

/// A class with a generic subscript.
public final class SwiftRequestTable {
    public var values: [String: Int64] = ["7": 70]
    public init() {}
    public subscript<Key: CustomStringConvertible>(described key: Key) -> Int64 {
        values[key.description] ?? -1
    }
}

/// Requests resolve on a type or on a bound object with the same options.
@Suite(.serialized)
struct ResolutionRequestTests {
    @MainActor @Test func oneRequestResolvesOnATypeAndOnAnObject() async throws {
        let runtime = ABIRuntime()
        let renderer = SwiftMemberRenderer(text: "four")
        let type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberRenderer")
        let object = runtime.object(renderer)
        let render = NativeSwiftInstanceMemberRequest.method("render(_:)", as: ((Int) -> Int).self)
        let text = NativeSwiftInstanceMemberRequest.getter("text", as: (() -> String).self)
        let setText = NativeSwiftInstanceMemberRequest.setter(
            "text",
            as: ((String) -> Void).self
        )

        let unboundRender = try type.resolveAndWait(render)
        let boundRender = try await object.resolve(render)
        #expect(try unsafe unboundRender.unsafeInvoke(on: renderer, 1) == 5)
        #expect(try unsafe boundRender.unsafeInvoke(1) == 5)

        let unboundSet = try await type.resolve(setText)
        try unsafe unboundSet.unsafeInvoke(on: renderer, "seven")
        let boundText = try object.resolveAndWait(text)
        #expect(try unsafe boundText.unsafeInvoke() == "seven")
        let boundSet = try object.resolveAndWait(setText)
        try unsafe boundSet.unsafeInvoke("six")
        #expect(try unsafe type.resolveAndWait(text).unsafeInvoke(on: renderer) == "six")
    }

    @MainActor @Test func boundObjectsResolveTheirTypesMembers() async throws {
        let runtime = ABIRuntime()
        let object = runtime.object(SwiftMemberRenderer(text: "base"))
        let decorate = try object.resolveAndWait(
            .staticMethod("decorate(_:)", as: ((String) -> String).self)
        )
        #expect(try unsafe decorate.unsafeInvoke("ready") == "ready!")
        let standard = try await object.resolve(
            .staticGetter("standard", as: (() -> String).self)
        )
        #expect(try unsafe standard.unsafeInvoke() == "standard")
        let make = try await object.resolve(
            .initializer("init(text:)", as: ((String) -> SwiftMemberRenderer).self)
        )
        let made = try unsafe make.unsafeInvoke("made")
        #expect(made.text == "made")
        // The object's class is the lookup type, as it is for instance members.
        let derived = runtime.object(SwiftMemberDerived(text: "derived"))
        let derivedMake = try derived.resolveAndWait(
            .initializer("init(text:)", as: ((String) -> SwiftMemberRenderer).self)
        )
        #expect(try unsafe derivedMake.unsafeInvoke("again") is SwiftMemberDerived)
    }

    #if os(macOS)
    /// Like an imported C type in a stripped system framework, the enum has no
    /// exported descriptor, so only a valueABIs entry states its convention.
    @MainActor @Test func boundMembersAcceptValueABIs() async throws {
        let header = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".h")
        try """
        #include <stdint.h>
        typedef enum : uint32_t { RequestTargetMain = 7 } RequestTarget;
        """.write(to: header, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: header) }
        let module = "Requests_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public final class Screen {
                    public init() {}
                    public var target: RequestTarget { RequestTargetMain }
                }
                """,
            stripped: true,
            linkArguments: ["-parse-as-library", "-import-objc-header", header.path]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let screen = try await runtime.resolveSwiftType(
            named: module + ".Screen",
            in: .path(library.libraryURL)
        )
        let uint32 = try await runtime.resolveSwiftType(named: "Swift.UInt32")
        let make = try await screen.resolve(.initializer("init()", as: (() -> AnyObject).self))
        let object = runtime.object(try unsafe make.unsafeInvoke())
        let getter = "target.getter : __C.RequestTarget"
        await #expect(throws: ABIResolutionError.self) {
            _ = try await object.resolve(.getter(getter, as: (() -> UInt32).self))
        }
        let target = try await object.resolve(
            .getter(getter, as: (() -> UInt32).self, valueABIs: [uint32: .uint32])
        )
        #expect(try unsafe target.unsafeInvoke() == 7)
    }
    #endif

    @MainActor @Test func subscriptAccessorsResolveByTheirMemberName() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.makeGenericIdentifiedLookup(_:)",
                as: ((String) -> NativeSwiftValue).self
            )
        )
        let makeKey = try await runtime.resolve(
            .function(
                "ManagedSwiftFixtures.makeGenericLookupKey(_:)",
                as: ((String) -> NativeSwiftValue).self
            )
        )
        let source = try unsafe make.unsafeInvoke("a")
        let key = try unsafe makeKey.unsafeInvoke("a")
        let abis = [key.type: try NativeType.opaque(named: key.type.name)]
        let get = try await source.type.resolve(
            .getter(
                "subscript",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: abis,
                receiverABI: .opaque(named: source.type.name)
            )
        )
        let original = try unsafe get.unsafeInvoke(on: source, key)
        #expect(try original.take(as: GenericIdentifiedRecord?.self)?.value == 41)
        // A value's setter receives it inout unless a convention says otherwise.
        let set = try await source.type.resolve(
            .setter(
                "subscript",
                as: ((GenericIdentifiedRecord?, String) -> Void).self,
                valueABIs: abis,
                receiverABI: .opaque(named: source.type.name)
            )
        )
        try unsafe set.unsafeInvoke(on: source, GenericIdentifiedRecord(id: "a", value: 42), "a")
        let updated = try unsafe get.unsafeInvoke(on: source, key)
        #expect(try updated.take(as: GenericIdentifiedRecord?.self)?.value == 42)

        // A generic subscript binds its own parameters.
        let table = runtime.object(SwiftRequestTable())
        let described = try await table.resolve(
            .getter(
                "subscript",
                as: ((Int) -> Int64).self,
                genericArguments: [.type(Int.self)]
            )
        )
        #expect(try unsafe described.unsafeInvoke(7) == 70)

        // The index and value types select among Array's subscripts.
        let array = try await runtime.resolveSwiftType(
            named: "Swift.Array",
            genericArguments: [.type(Int.self)]
        )
        let element = try await array.resolve(.getter("subscript", as: ((Int) -> Int).self))
        #expect(try unsafe element.unsafeInvoke(on: [10, 20, 30], 1) == 20)
        // A complete accessor declaration qualified by the type selects it too.
        let declared = try await array.resolve(
            .getter("Swift.Array.subscript.getter : (Swift.Int) -> A", as: ((Int) -> Int).self)
        )
        #expect(try unsafe declared.unsafeInvoke(on: [10, 20, 30], 2) == 30)
    }

    @MainActor @Test func typesNestedInExtensionsResolveTheirMembers() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.resolveSwiftType(
            named: "(extension in ManagedSwiftFixtures):Swift.Int.RuntimeNestedCounter"
        )
        let make = try await type.resolve(
            .initializer("init()", as: (() -> Int.RuntimeNestedCounter).self)
        )
        let value = try await type.resolve(.method("value()", as: (() -> Int).self))
        #expect(try unsafe value.unsafeInvoke(on: make.unsafeInvoke()) == 7)
    }

    @MainActor @Test func receiverConventionsSelectHowSelfPasses() async throws {
        let runtime = ABIRuntime()
        let type = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftRequestToggle")
        let toggle = SwiftRequestToggle(offset: 2)
        let nonmutating = try await type.resolve(
            .setter("value", as: ((Int64) -> Void).self, receiver: .borrowing)
        )
        try unsafe nonmutating.unsafeInvoke(on: toggle, 42)
        #expect(SwiftRequestToggle.stored == 40 && toggle.value == 42)

        // A setter's default follows its declaration: a value's is mutating.
        var adjustable = SwiftRequestToggle(offset: 0)
        let adjust = try await type.resolve(.setter("adjusted", as: ((Int64) -> Void).self))
        try unsafe adjust.unsafeInvoke(on: &adjustable, 5)
        #expect(adjustable.offset == 5)

        let pointType = try await runtime.resolveSwiftType(named: "ABIBridgeTests.SwiftMemberPoint")
        let change = try await pointType.resolve(
            .method("change(_:)", as: ((Int64) -> Void).self, receiver: .mutating)
        )
        var point = SwiftMemberPoint(value: 1)
        try unsafe change.unsafeInvoke(on: &point, 9)
        #expect(point.value == 9)
        let consume = try await pointType.resolve(
            .method("consumeValue()", as: (() -> Int64).self, receiver: .consuming)
        )
        #expect(try unsafe consume.unsafeInvoke(on: point) == 9)
        let read = try await pointType.resolve(
            .method("read(_:)", as: ((Int64) -> Int64).self, receiver: .borrowing)
        )
        #expect(try unsafe read.unsafeInvoke(on: point, 1) == 10)
    }
}
