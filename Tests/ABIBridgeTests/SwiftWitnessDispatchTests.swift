#if DEBUG && os(macOS)
@testable import ABIBridge
import Testing

@Suite(.serialized)
struct SwiftWitnessDispatchTests {
    @Test(arguments: [false, true])
    func hooksUseConformanceSlotsAndStableDeclarationEvidence(evolution: Bool) async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            writable: false,
            libraryEvolution: evolution
        )
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".WitnessValue",
            in: fixture.providerScope
        )
        let name = fixture.module + ".Witnessed.read(_:)"
        let method = try await type.resolve(.method(name, as: ((Int64) -> Int64).self))
        let oracle = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessRead(_:_:_:)",
                as: ((Int64, Int64, Int64) -> Int64).self
            ),
            in: fixture.callerScope
        )
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 42)
        let first = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in try call.proceed(value + 1) + 100
        }
        defer { first.invalidate() }
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 143)
        #expect(try unsafe oracle.unsafeInvoke(1, 40, 2) == 43)
        // Lookup after publication must use immutable identity and join the
        // existing physical slot, even when no Tq symbol exists.
        let again = try await type.resolve(.method(name, as: ((Int64) -> Int64).self))
        let second = try await unsafe again.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in try call.proceed(value * 2) + 1000
        }
        defer { second.invalidate() }
        #expect(first.address == second.address)
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 1145)
        first.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 1044)
        second.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 42)
    }

    @Test(arguments: [false, true])
    func compiledWitnessReplacementCapturesPredecessor(evolution: Bool) async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            writable: false,
            libraryEvolution: evolution
        )
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".WitnessValue",
            in: fixture.providerScope
        )
        let method = try await type.resolve(
            .method(fixture.module + ".Witnessed.read(_:)", as: ((Int64) -> Int64).self)
        )
        let other = try await type.resolve(
            .method(fixture.module + ".Witnessed.replacement(_:)", as: ((Int64) -> Int64).self)
        )
        let make = try await type.resolve(
            .initializer("init(seed:)", as: ((Int64) -> NativeSwiftValue).self)
        )
        let object = try unsafe make.unsafeInvoke(40)
        let oracle = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessRead(_:_:_:)",
                as: ((Int64, Int64, Int64) -> Int64).self
            ),
            in: fixture.callerScope
        )
        let first = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in try call.proceed(value) + 10
        }
        defer { first.invalidate() }
        let plan = try await unsafe method.prepareVirtualReplacement(with: other)
        #expect(try unsafe plan.original.unsafeInvoke(on: object, 2) == 52)
        try unsafe plan.install()
        defer { try? plan.restore() }
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 142)
        #expect(try unsafe plan.original.unsafeInvoke(on: object, 2) == 52)
        try plan.restore()
        #expect(try unsafe oracle.unsafeInvoke(0, 40, 2) == 52)
    }
    @Test(arguments: [false, true])
    func accessorsStaticInitializerAndAsyncUseRequirementConventions(evolution: Bool) async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            writable: false,
            libraryEvolution: evolution
        )
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".WitnessValue",
            in: fixture.providerScope
        )
        let protocolName = fixture.module + ".Witnessed."
        let getter = try await type.resolve(.getter(protocolName + "value", as: (() -> Int64).self))
        let setter = try await type.resolve(
            .setter(protocolName + "value", as: ((Int64) -> Void).self)
        )
        let get = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessGet(_:_:)",
                as: ((Int64, Int64) -> Int64).self
            ),
            in: fixture.callerScope
        )
        let set = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessSet(_:_:_:)",
                as: ((Int64, Int64, Int64) -> Int64).self
            ),
            in: fixture.callerScope
        )
        let getHook = try await unsafe getter.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call in try call.proceed() + 10
        }
        defer { getHook.invalidate() }
        let setHook = try await unsafe setter.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in try call.proceed(value + 100)
        }
        defer { setHook.invalidate() }
        #expect(try unsafe get.unsafeInvoke(0, 40) == 50)
        #expect(try unsafe set.unsafeInvoke(0, 40, 2) == 112)
        #expect(try unsafe set.unsafeInvoke(1, 40, 2) == 2)
        getHook.invalidate(); setHook.invalidate()

        let kind = try await type.resolve(
            .staticMethod(protocolName + "kind(_:)", as: ((Int64) -> Int64).self)
        )
        let patched = try await type.resolve(
            .staticMethod(protocolName + "patchedKind(_:)", as: ((Int64) -> Int64).self)
        )
        let kindOracle = try await fixture.runtime.resolve(
            .function(fixture.callerModule + ".witnessKind(_:)", as: ((Int64) -> Int64).self),
            in: fixture.callerScope
        )
        let replacement = try await unsafe kind.prepareVirtualReplacement(with: patched)
        #expect(try unsafe replacement.original.unsafeInvoke(2) == 12)
        try unsafe replacement.install()
        defer { try? replacement.restore() }
        #expect(try unsafe kindOracle.unsafeInvoke(2) == 112)
        try replacement.restore()

        let construct = try await type.resolve(
            .initializer(protocolName + "init(seed:)", as: ((Int64) -> NativeSwiftValue).self)
        )
        let initOracle = try await fixture.runtime.resolve(
            .function(fixture.callerModule + ".witnessInit(_:)", as: ((Int64) -> Int64).self),
            in: fixture.callerScope
        )
        let initHook = try await unsafe construct.hookVirtualCalls(onFailure: { Issue.record($0) })
        {
            call,
            value in try call.proceed(value + 200)
        }
        defer { initHook.invalidate() }
        #expect(try unsafe initOracle.unsafeInvoke(2) == 202)
        initHook.invalidate()

        let method = try await type.resolve(
            .method(protocolName + "asyncRead(_:)", as: ((Int64) async -> Int64).self)
        )
        let asyncOracle = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessAsync(_:_:_:)",
                as: ((Int64, Int64, Int64) async -> Int64).self
            ),
            in: fixture.callerScope
        )
        let asyncHook = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in
            await Task.yield()
            return try await call.proceed(value + 1) + 300
        }
        defer { asyncHook.invalidate() }
        #expect(try await unsafe asyncOracle.unsafeInvoke(0, 40, 2) == 363)
        #expect(try await unsafe asyncOracle.unsafeInvoke(1, 40, 2) == 63)
        asyncHook.invalidate()
        #expect(try await unsafe asyncOracle.unsafeInvoke(0, 40, 2) == 62)
    }

    @Test(arguments: [false, true])
    func genericAndConditionalBindingsSelectHandlers(evolution: Bool) async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            writable: false,
            libraryEvolution: evolution
        )
        defer { fixture.cleanup() }
        let oracle = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessRead(_:_:_:)",
                as: ((Int64, Int64, Int64) -> Int64).self
            ),
            in: fixture.callerScope
        )
        for (base, which) in [("WitnessBox", Int64(2)), ("WitnessConditional", Int64(4))] {
            let int = try await fixture.runtime.resolveSwiftType(
                named: fixture.module + "." + base,
                in: fixture.providerScope,
                genericArguments: [.type(Int64.self)]
            )
            let string = try await fixture.runtime.resolveSwiftType(
                named: fixture.module + "." + base,
                in: fixture.providerScope,
                genericArguments: [.type(String.self)]
            )
            let name = fixture.module + ".Witnessed.read(_:)"
            let first = try await int.resolve(.method(name, as: ((Int64) -> Int64).self))
            let second = try await string.resolve(.method(name, as: ((Int64) -> Int64).self))
            let firstHook = try await unsafe first.hookVirtualCalls(onFailure: { Issue.record($0) })
            {
                call,
                value in try call.proceed(value) + 100
            }
            defer { firstHook.invalidate() }
            let secondHook = try await unsafe second.hookVirtualCalls(onFailure: {
                Issue.record($0)
            }) {
                call,
                value in try call.proceed(value) + 1000
            }
            defer { secondHook.invalidate() }
            let offset: Int64 = which == 2 ? 2 : 3
            #expect(try unsafe oracle.unsafeInvoke(which, 40, 2) == 142 + offset)
            #expect(try unsafe oracle.unsafeInvoke(which + 1, 40, 2) == 1042 + offset)
            firstHook.invalidate()
            #expect(try unsafe oracle.unsafeInvoke(which, 40, 2) == 42 + offset)
            #expect(try unsafe oracle.unsafeInvoke(which + 1, 40, 2) == 1042 + offset)
            secondHook.invalidate()
        }
    }

    @Test(arguments: [false, true])
    func sharedPhysicalTableFiltersIncomingSelf(evolution: Bool) async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            writable: false,
            libraryEvolution: evolution
        )
        defer { fixture.cleanup() }
        let int = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".WitnessShared",
            in: fixture.providerScope,
            genericArguments: [.type(Int64.self)]
        )
        let string = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".WitnessShared",
            in: fixture.providerScope,
            genericArguments: [.type(String.self)]
        )
        let name = fixture.module + ".SharedWitnessed.read(_:)"
        let method = try await int.resolve(.method(name, as: ((Int64) -> Int64).self))
        let other = try await string.resolve(.method(name, as: ((Int64) -> Int64).self))
        let oracle = try await fixture.runtime.resolve(
            .function(
                fixture.callerModule + ".witnessShared(_:_:_:)",
                as: ((Bool, Int64, Int64) -> Int64).self
            ),
            in: fixture.callerScope
        )
        let first = try await unsafe method.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in try call.proceed(value) + 100
        }
        defer { first.invalidate() }
        let second = try await unsafe other.hookVirtualCalls(onFailure: { Issue.record($0) }) {
            call,
            value in try call.proceed(value) + 1000
        }
        defer { second.invalidate() }
        try #require(first.address == second.address)
        #expect(try unsafe oracle.unsafeInvoke(false, 40, 2) == 142)
        #expect(try unsafe oracle.unsafeInvoke(true, 40, 2) == 1042)
        first.invalidate()
        #expect(try unsafe oracle.unsafeInvoke(false, 40, 2) == 42)
        #expect(try unsafe oracle.unsafeInvoke(true, 40, 2) == 1042)
        second.invalidate()
    }

    @Test func foldedWitnessesWithoutDescriptorsDoNotGuessASlot() async throws {
        let fixture = try CompiledSwiftReplacementFixture(
            writable: false,
            providerExtra: """
                public protocol FoldedWitness { func first() -> Int64; func second() -> Int64 }
                public struct FoldedValue: FoldedWitness {
                    public init() {}
                    @inline(never) public func first() -> Int64 { 42 }
                    @inline(never) public func second() -> Int64 { 42 }
                }
                """
        )
        defer { fixture.cleanup() }
        let type = try await fixture.runtime.resolveSwiftType(
            named: fixture.module + ".FoldedValue",
            in: fixture.providerScope
        )
        let first = try await type.resolve(
            .method(fixture.module + ".FoldedWitness.first()", as: (() -> Int64).self)
        )
        let second = try await type.resolve(
            .method(fixture.module + ".FoldedWitness.second()", as: (() -> Int64).self)
        )
        // Establish that optimized code really erased the declaration distinction.
        try #require(first.symbol.address == second.symbol.address)
        #expect {
            _ = try first.virtualDispatch()
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("folded across requirements")
        }
    }

}
#endif
