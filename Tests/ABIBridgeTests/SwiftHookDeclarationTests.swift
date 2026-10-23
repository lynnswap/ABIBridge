#if os(macOS) && DEBUG
@testable import ABIBridge
import ABIBridgeTestSupport
import Foundation
import Synchronization
import Testing

/// A library-evolution provider whose clients call class members and
/// protocol requirements through dispatch thunks, and a client that does.
private final class DispatchedHookFixture {
    let module = "Dispatched_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let provider: FixtureLibrary
    let caller: FixtureLibrary
    let runtime = ABIRuntime()
    var providerScope: ImageSelector { .path(provider.libraryURL) }
    var callerScope: ImageSelector { .path(caller.libraryURL) }
    var callerModule: String { module + "Caller" }

    /// - Parameter stripped: Whether the provider keeps only its exports, so
    ///   that a class member's code is reachable only through its dispatch
    ///   thunk and its class's virtual table.
    init(stripped: Bool) throws {
        provider = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: """
                open class Dispatched {
                    public init() {}
                    @inline(never) open func value(_ x: Int64) -> Int64 { x + 1 }
                    @inline(never) open func patched(_ x: Int64) -> Int64 { x + 100 }
                }
                public final class DispatchedChild: Dispatched {
                    public override init() {}
                    @inline(never) public override func value(_ x: Int64) -> Int64 { x + 2 }
                }
                @inline(never) public func makeDispatched(_ child: Bool) -> Dispatched {
                    child ? DispatchedChild() : Dispatched()
                }
                public protocol Valued { func value() -> Int64 }
                public struct FirstValued: Valued {
                    public init() {}
                    @inline(never) public func value() -> Int64 { 1 }
                }
                public struct SecondValued: Valued {
                    public init() {}
                    @inline(never) public func value() -> Int64 { 2 }
                }
                @inline(never) public func makeValued(_ second: Bool) -> any Valued {
                    second ? SecondValued() : FirstValued()
                }
                """,
            stripped: stripped,
            linkArguments: [
                "-O", "-swift-version", "6", "-emit-module", "-parse-as-library",
                "-enable-library-evolution",
            ]
        )
        caller = try FixtureLibrary(
            load: false,
            swiftModule: module + "Caller",
            swiftSource: """
                import \(module)
                @inline(never) public func callValue(_ child: Bool, _ x: Int64) -> Int64 {
                    makeDispatched(child).value(x)
                }
                @inline(never) func callRequirement(_ value: any Valued) -> Int64 { value.value() }
                @inline(never) public func callValued(_ second: Bool) -> Int64 {
                    callRequirement(makeValued(second))
                }
                """,
            linkArguments: [
                "-O", "-swift-version", "6", "-parse-as-library", "-I", provider.directory.path,
                provider.libraryURL.path,
            ]
        )
        try provider.load(); try caller.load()
    }

    func cleanup() { caller.cleanup(); provider.cleanup() }

    func callerFunction<Signature>(
        _ declaration: String,
        as signature: Signature.Type
    ) async throws -> NativeSwiftFunction<Signature> {
        try await runtime.resolveSwiftFunction(
            named: callerModule + "." + declaration,
            as: signature,
            in: callerScope
        )
    }
}

/// Hooks and replacements follow the declarations, dispatch, and lowering
/// that lookup selected for calls.
@Suite(.serialized)
struct SwiftHookDeclarationTests {
    /// Other images call a library-evolution class member through its
    /// dispatch thunk, whether lookup selects the member's own code or, when
    /// the image keeps only its exports, the class's virtual-table entry.
    /// Hooks and replacements of imports select references to that thunk,
    /// which dispatches on the receiver's class.
    @Test(arguments: [false, true])
    func classMembersAreInterceptedAtTheirDispatchThunkImports(stripped: Bool) async throws {
        let fixture = try DispatchedHookFixture(stripped: stripped)
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".Dispatched",
            in: fixture.providerScope
        )
        let value = try await type.resolveMethod(named: "value(_:)", as: ((Int64) -> Int64).self)
        #expect((value.entry.dispatch != nil) == stripped)
        let call = try await fixture.callerFunction(
            "callValue(_:_:)",
            as: ((Bool, Int64) -> Int64).self
        )
        #expect(try unsafe call.unsafeInvoke(false, 40) == 41)
        #expect(try unsafe call.unsafeInvoke(true, 40) == 42)
        let hook = try await unsafe value.hookImportedCalls(
            in: fixture.callerScope,
            using: fixture.runtime,
            onFailure: { Issue.record($0) }
        ) { call, x in try call.proceed(x) * 10 }
        #expect(try unsafe call.unsafeInvoke(false, 40) == 410)
        // The thunk runs the receiver's override.
        #expect(try unsafe call.unsafeInvoke(true, 40) == 420)
        hook.invalidate()
        #expect(try unsafe call.unsafeInvoke(false, 40) == 41)

        let patched = try await type.resolveMethod(
            named: "patched(_:)",
            as: ((Int64) -> Int64).self
        )
        let plan = try await unsafe value.prepareImportedReplacement(
            with: patched,
            in: fixture.callerScope,
            using: fixture.runtime
        )
        try unsafe plan.install()
        defer { try? plan.restore() }
        #expect(try unsafe call.unsafeInvoke(false, 40) == 140)
        // The captured thunk still dispatches on its receiver.
        let original = try #require(plan.slots.first?.original)
        let child = try await fixture.runtime.resolveSwiftFunction(
            named: fixture.module + ".makeDispatched(_:)",
            as: ((Bool) -> AnyObject).self,
            in: fixture.providerScope
        )
        #expect(try unsafe original.unsafeInvoke(on: child.unsafeInvoke(true), 40) == 42)
        try plan.restore()
        #expect(try unsafe call.unsafeInvoke(false, 40) == 41)
    }

    /// Other images call a library-evolution protocol requirement through
    /// its dispatch thunk, which a hook of the requirement selects. The hook
    /// receives the calls of its type's conformance; calls of other
    /// conformances continue to their witnesses.
    @Test func protocolRequirementsAreInterceptedAtTheirDispatchThunkImports() async throws {
        let fixture = try DispatchedHookFixture(stripped: false)
        defer { fixture.cleanup() }
        let first = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".FirstValued",
            in: fixture.providerScope
        )
        let requirement = try await first.resolveMethod(
            named: fixture.module + ".Valued.value()",
            as: (() -> Int64).self
        )
        let call = try await fixture.callerFunction("callValued(_:)", as: ((Bool) -> Int64).self)
        #expect(try unsafe call.unsafeInvoke(false) == 1)
        #expect(try unsafe call.unsafeInvoke(true) == 2)
        let hook = try await unsafe requirement.hookImportedCalls(
            in: fixture.callerScope,
            using: fixture.runtime,
            onFailure: { Issue.record($0) }
        ) { call in try call.proceed() + 10 }
        defer { hook.invalidate() }
        #expect(try unsafe call.unsafeInvoke(false) == 11)
        #expect(try unsafe call.unsafeInvoke(true) == 2)
        hook.invalidate()
        #expect(try unsafe call.unsafeInvoke(false) == 1)
    }

    /// A replacement's code receives the calls of the declaration it
    /// replaces, so its declaration must pass every value as that one does,
    /// whatever host types the two handles share.
    @Test func replacementsMustPassValuesAsTheirTargets() async throws {
        let module =
            "ReplacementLowering_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public struct SmallRecord { public var value: Int64 }
                public struct LargeRecord { public var a, b, c, d, e: Int64 }
                @inline(never) public func readSmall(_ record: SmallRecord) -> Int64 { record.value }
                @inline(never) public func readLarge(_ record: LargeRecord) -> Int64 { record.a }
                @inline(never) public func makeSmall() -> SmallRecord { SmallRecord(value: 1) }
                @inline(never) public func makeLarge() -> LargeRecord {
                    LargeRecord(a: 1, b: 2, c: 3, d: 4, e: 5)
                }
                open class LoweringRenderer {
                    public init() {}
                    @inline(never) open func generic<T>(_ value: T) -> Int64 { 1 }
                    @inline(never) open func plain(_ value: Int64) -> Int64 { value }
                }
                """,
            linkArguments: ["-O", "-swift-version", "6", "-parse-as-library"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(library.libraryURL)
        let small = try await runtime.resolveSwiftType(named: module + ".SmallRecord", in: scope)
        let large = try await runtime.resolveSwiftType(named: module + ".LargeRecord", in: scope)
        let valueABIs: [NativeSwiftType: NativeType] = [
            small: try .structure(named: "SmallRecord", fields: [.int64]),
            large: try .structure(named: "LargeRecord", fields: Array(repeating: .int64, count: 5)),
        ]
        func function<Signature>(
            _ name: String,
            as signature: Signature.Type
        ) async throws
            -> NativeSwiftFunction<Signature>
        {
            try await runtime.resolveSwiftFunction(
                named: module + "." + name,
                as: signature,
                valueABIs: valueABIs,
                in: scope
            )
        }
        func expectMismatch(
            at position: ABIResolutionError.SignatureMismatch.Position,
            _ body: () throws -> Void
        ) {
            #expect {
                try body()
            } throws: { error in
                guard case ABIResolutionError.signatureMismatch(let mismatch) = error else {
                    return false
                }
                return mismatch.position == position
            }
        }
        // A small record passes in a register, a large one by address.
        let readSmall = try await function("readSmall(_:)", as: ((NativeSwiftValue) -> Int64).self)
        let readLarge = try await function("readLarge(_:)", as: ((NativeSwiftValue) -> Int64).self)
        expectMismatch(at: .argument(0)) {
            _ = try unsafe readSmall.prepareImportedReplacementAndWait(with: readLarge, in: scope)
        }
        let makeSmall = try await function("makeSmall()", as: (() -> NativeSwiftValue).self)
        let makeLarge = try await function("makeLarge()", as: (() -> NativeSwiftValue).self)
        expectMismatch(at: .result) {
            _ = try unsafe makeLarge.prepareImportedReplacementAndWait(with: makeSmall, in: scope)
        }
        // A generic method passes its value by address, with its metadata.
        let renderer = try await runtime.resolveSwiftType(
            named: module + ".LoweringRenderer",
            in: scope
        )
        let generic = try await renderer.resolveMethod(
            named: "generic(_:)",
            as: ((Int64) -> Int64).self,
            genericArguments: [.type(Int64.self)]
        )
        let plain = try await renderer.resolveMethod(
            named: "plain(_:)",
            as: ((Int64) -> Int64).self
        )
        expectMismatch(at: .argument(0)) {
            _ = try unsafe generic.prepareVirtualReplacementAndWait(with: plain)
        }
        expectMismatch(at: .argument(0)) {
            _ = try unsafe plain.prepareImportedReplacementAndWait(with: generic, in: scope)
        }
    }

    /// A class's static member and a protocol's member receive a metatype as
    /// `self`, as their call plans say; a struct's or an enum's static member
    /// receives its thin metatype, which passes nothing. A replacement may
    /// take a metatype only where callers of the original pass one.
    @Test func staticReplacementsReceiveAMetatypeOnlyWhereCallersPassOne() async throws {
        let module =
            "StaticReplacement_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let provider = try FixtureLibrary(
            load: false,
            swiftModule: module,
            swiftSource: """
                @inline(never) public func identity(_ value: Int64) -> Int64 { value }
                public struct ScaledValue {
                    @inline(never) public static func scaled(_ value: Int64) -> Int64 { value * 3 }
                }
                public enum ScaledChoice {
                    case only
                    @inline(never) public static func scaled(_ value: Int64) -> Int64 { value * 4 }
                }
                open class ScaledClass {
                    public init() {}
                    @inline(never) open class func scaled(_ value: Int64) -> Int64 { value * 2 }
                }
                """,
            linkArguments: ["-O", "-swift-version", "6", "-emit-module", "-parse-as-library"]
        )
        let caller = try FixtureLibrary(
            load: false,
            swiftModule: module + "Caller",
            swiftSource: """
                import \(module)
                @inline(never) public func callIdentity(_ value: Int64) -> Int64 { identity(value) }
                """,
            linkArguments: [
                "-O", "-swift-version", "6", "-parse-as-library", "-I", provider.directory.path,
                provider.libraryURL.path,
            ]
        )
        try provider.load(); try caller.load()
        defer { caller.cleanup(); provider.cleanup() }
        let runtime = ABIRuntime()
        let scope = ImageSelector.path(provider.libraryURL)
        let callerScope = ImageSelector.path(caller.libraryURL)
        let identity = try await runtime.resolveSwiftFunction(
            named: module + ".identity(_:)",
            as: ((Int64) -> Int64).self,
            in: scope
        )
        let call = try await runtime.resolveSwiftFunction(
            named: module + "Caller.callIdentity(_:)",
            as: ((Int64) -> Int64).self,
            in: callerScope
        )
        func scaled(_ type: String) async throws -> NativeSwiftFunction<(Int64) -> Int64> {
            try await runtime.resolveSwiftType(named: module + "." + type, in: scope)
                .resolveStaticMethod(named: "scaled(_:)", as: ((Int64) -> Int64).self)
        }
        for (type, factor) in [("ScaledValue", Int64(3)), ("ScaledChoice", 4)] {
            let plan = try unsafe identity.prepareImportedReplacementAndWait(
                with: try await scaled(type),
                in: callerScope,
                using: runtime
            )
            try unsafe plan.install()
            #expect(try unsafe call.unsafeInvoke(20) == 20 * factor, "\(type)")
            try plan.restore()
            #expect(try unsafe call.unsafeInvoke(20) == 20, "\(type)")
        }
        let classScaled = try await scaled("ScaledClass")
        #expect {
            _ = try unsafe identity.prepareImportedReplacementAndWait(
                with: classScaled,
                in: callerScope,
                using: runtime
            )
        } throws: { error in
            guard case ABIResolutionError.signatureMismatch(let mismatch) = error else {
                return false
            }
            return mismatch.position == .receiver
        }
        // A free function ignores the metatype that callers of a class
        // method pass; the provider imports no reference to it.
        #expect(throws: ABIResolutionError.declarationNotFound(classScaled.declaration)) {
            _ = try unsafe classScaled.prepareImportedReplacementAndWait(with: identity, in: scope)
        }
    }
}
#endif
