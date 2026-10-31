#if DEBUG
@testable import ABIBridge
@testable import ABIBridgeRuntime
#else
import ABIBridge
import ABIBridgeRuntime
#endif
import ABIBridgeTestSupport
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private func runtimeProjectionChoice(
    _ kind: Int64,
    token: ErrorLifetimeToken = ErrorLifetimeToken()
) async throws -> NativeSwiftValue {
    let make = try await ABIRuntime.shared.resolve(
        .swift(
            .function(
                "ManagedSwiftFixtures.makeRuntimeProjectionChoice(_:_:)",
                as: ((Int64, ErrorLifetimeToken) -> NativeSwiftValue).self
            )
        )
    )
    return try unsafe make.unsafeInvoke(kind, token)
}

private func invokeProjectionPreparation(_ body: RuntimeProjectionPreparationSignature) -> Int64 {
    body(
        Int64(35),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0)
    )
}

private func invokeProjectionPreparation(
    _ body: NativeSwiftClosure<RuntimeProjectionPreparationSignature>
) throws -> Int64 {
    try unsafe body.unsafeInvoke(
        Int64(35),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0),
        Int64(0)
    )
}

#if DEBUG
private enum ProjectionPreparationFailure: Error { case timedOut }
private final class ProjectionPreparationGate: Sendable {
    let release = DispatchSemaphore(value: 0)
    let entered = Mutex(false)
    let observations = Mutex<[Bool]>([])
    func observe() throws {
        observations.withLock { $0.append(Thread.isMainThread) }
        entered.withLock { $0 = true }
        guard release.wait(timeout: .now() + 5) == .success else {
            throw ProjectionPreparationFailure.timedOut
        }
    }
}
#endif

@Suite(.serialized)
struct SwiftRuntimeValueProjectionTests {
    @MainActor @Test
    func createsNamedEmptyEnumCasesForNativeCalls() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeEmptyCaseMode"))
        )
        let copy = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(type)]
                )
            )
        )
        for (name, expected) in [("default", RuntimeEmptyCaseMode.default), ("static", .static)] {
            let value = try type.makeEnumCase(named: name)
            let result = try unsafe copy.unsafeInvoke(value)
            #expect(try result.take(as: RuntimeEmptyCaseMode.self) == expected)
            #expect(try value.take(as: RuntimeEmptyCaseMode.self) == expected)
        }
        MainActor.assertIsolated()
    }

    @Test func createsZeroSizedEnumCases() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeEmptyCaseSingleton"))
        )
        let value = try type.makeEnumCase(named: "only")
        #expect(try value.take(as: RuntimeEmptyCaseSingleton.self) == .only)
    }

    @Test func emptyCasesInNontrivialEnumsCanBeCopiedAndDestroyed() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionChoice"))
        )
        var value: NativeSwiftValue? = try type.makeEnumCase(named: "empty")
        let copied = try #require(value).copy()
        value = nil
        guard case .empty = try copied.take(as: RuntimeProjectionChoice.self) else {
            Issue.record("The constructed enum did not contain the empty case")
            return
        }
        let optional = try await ABIRuntime.shared.resolve(
            .swift(.type("Swift.Optional", genericArguments: [.type(ErrorLifetimeToken.self)]))
        )
        let none = try optional.makeEnumCase(named: "none")
        #expect(try none.copy().take(as: ErrorLifetimeToken?.self) == nil)
    }

    @Test func createsEmptyCasesInNoncopyableEnums() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionMoveOnly"))
        )
        let value = try type.makeEnumCase(named: "empty")
        #expect(!value.isCopyable)
        let moved = try value.take(as: RuntimeProjectionMoveOnly.self)
        guard case .empty = consume moved else {
            Issue.record("The constructed noncopyable enum did not contain the empty case")
            return
        }
        #expect(value.isConsumed)
    }

    @Test func enumConstructionReportsUnsupportedCases() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionChoice"))
        )
        #expect(throws: NativeSwiftValueError.enumCaseNotFound(name: "missing")) {
            try type.makeEnumCase(named: "missing")
        }
        #expect(throws: NativeSwiftValueError.enumCaseRequiresPayload(name: "text")) {
            try type.makeEnumCase(named: "text")
        }
        #expect(throws: NativeSwiftValueError.ambiguousEnumCase(name: "repeated")) {
            try type.makeEnumCase(named: "repeated")
        }
        let structure = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionLarge"))
        )
        #expect(throws: ABIResolutionError.self) {
            try structure.makeEnumCase(named: "empty")
        }
    }

    @Test func enumCaseSelectionPreservesNilAndLookupFailures() async throws {
        let value = try await runtimeProjectionChoice(1)
        let payload = try #require(try await value.copyEnumPayload(forCase: "text"))
        #expect(try payload.take(as: String.self) == "payload")
        #expect(try await value.copyEnumPayload(forCase: "empty") == nil)
        #expect(throws: NativeSwiftValueError.enumCaseNotFound(name: "missing")) {
            try value.copyEnumPayloadAndWait(forCase: "missing")
        }
        #expect(!value.isConsumed)
        guard case .text(let text) = try value.take(as: RuntimeProjectionChoice.self) else {
            Issue.record("The original enum case changed after payload projection")
            return
        }
        #expect(text == "payload")
        let empty = try await runtimeProjectionChoice(0)
        #expect(try await empty.copyEnumPayload(forCase: "empty") == nil)
        #expect(try await empty.copyEnumPayload(forCase: "text") == nil)
        let overloaded = try await runtimeProjectionChoice(7)
        #expect(throws: NativeSwiftValueError.ambiguousEnumCase(name: "repeated")) {
            try overloaded.copyEnumPayloadAndWait(forCase: "repeated")
        }
        #expect(!overloaded.isConsumed)
    }

    @MainActor @Test
    func payloadConstructionPreservesTheInputAndPassesNativeCalls() async throws {
        let original = try await runtimeProjectionChoice(1)
        let payload = try #require(try await original.copyEnumPayload(forCase: "text"))
        let value = try await original.type.makeEnumCase(named: "text", payload: payload)
        let copy = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                    genericArguments: [.type(original.type)]
                )
            )
        )
        let result = try unsafe copy.unsafeInvoke(value)
        guard case .text(let text) = try result.take(as: RuntimeProjectionChoice.self) else {
            Issue.record("Native code did not receive the constructed payload case")
            return
        }
        #expect(text == "payload")
        #expect(!payload.isConsumed && !value.isConsumed)
        #expect(throws: NativeSwiftValueError.enumCaseNotFound(name: "missing")) {
            try original.type.makeEnumCaseAndWait(named: "missing", payload: payload)
        }
        #expect(throws: NativeSwiftValueError.ambiguousEnumCase(name: "repeated")) {
            try original.type.makeEnumCaseAndWait(named: "repeated", payload: payload)
        }
        #expect(throws: ABIResolutionError.self) {
            try original.type.makeEnumCaseAndWait(named: "empty", payload: payload)
        }
        #expect(throws: ABIInvocationError.self) {
            try original.type.makeEnumCaseAndWait(named: "large", payload: payload)
        }
        #expect(try payload.take(as: String.self) == "payload")
        #expect(throws: NativeSwiftValueError.consumedValue) {
            try original.type.makeEnumCaseAndWait(named: "text", payload: payload)
        }
        MainActor.assertIsolated()
    }

    @Test(arguments: [false, true])
    func constructedPayloadsOutliveTheirInputs(indirect: Bool) async throws {
        let counts = ArgumentCounts()
        var constructed: NativeSwiftValue?
        do {
            let source = try await runtimeProjectionChoice(
                5,
                token: ErrorLifetimeToken { counts.destroyed() }
            )
            let payload =
                indirect
                ? source
                : try #require(
                    try await source.copyEnumPayload(forCase: "large")
                )
            constructed = try source.type.makeEnumCaseAndWait(
                named: indirect ? "indirect" : "large",
                payload: payload
            )
            #expect(!source.isConsumed && !payload.isConsumed)
        }
        #expect(counts.destructions == 0)
        do {
            let result = try #require(constructed).take(as: RuntimeProjectionChoice.self)
            let payload: RuntimeProjectionChoice
            if indirect, case .indirect(let nested) = result {
                payload = nested
            } else {
                payload = result
            }
            guard case .large(let large) = payload else {
                Issue.record("The constructed enum did not preserve its owned payload")
                return
            }
            #expect(large.first + large.second + large.third + large.fourth == 100)
            #expect(large.text == String(repeating: "owned payload ", count: 80))
        }
        constructed = nil
        #expect(counts.destructions == 1)
    }

    @Test func copyablePayloadsCanInitializeNoncopyableEnums() async throws {
        let type = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionMoveOnly"))
        )
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let payload = try unsafe make.unsafeInvoke(42)
        let constructed = try await type.makeEnumCase(named: "number", payload: payload)
        #expect(!constructed.isCopyable && !payload.isConsumed)
        let moved = try constructed.take(as: RuntimeProjectionMoveOnly.self)
        guard case .number(let number) = consume moved else {
            Issue.record("The noncopyable enum did not contain its copyable payload")
            return
        }
        #expect(number == 42)
        #expect(try payload.take(as: Int64.self) == 42)
        let ticket = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let noncopyable = try unsafe ticket.unsafeInvoke(ErrorLifetimeToken())
        #expect(throws: NativeSwiftValueError.noncopyableType) {
            try type.makeEnumCaseAndWait(named: "ticket", payload: noncopyable)
        }
        #expect(!noncopyable.isConsumed)
    }

    @Test(arguments: [Int64(2), 3])
    func tuplePayloadsKeepTheRuntimeShape(_ kind: Int64) async throws {
        let value = try await runtimeProjectionChoice(kind)
        let payload = try #require(
            try await value.copyEnumPayload(forCase: kind == 2 ? "tuple" : "values")
        )
        let constructed = try await value.type.makeEnumCase(
            named: kind == 2 ? "tuple" : "values",
            payload: payload
        )
        switch try constructed.take(as: RuntimeProjectionChoice.self) {
        case .tuple(let tuple): #expect(kind == 2 && tuple.0 + tuple.1 == 42)
        case .values(let first, let second): #expect(kind == 3 && first + second == 42)
        default: Issue.record("The constructed case did not preserve its tuple payload")
        }
        let first = try payload.copyTupleElement(at: 0)
        let second = try payload.copyTupleElement(at: 1)
        #expect(try first.take(as: Int64.self) == 40)
        #expect(try second.take(as: Int64.self) == 2)
        #expect(throws: NativeSwiftValueError.tupleElementIndexOutOfBounds(index: 2, count: 2)) {
            try payload.copyTupleElement(at: 2)
        }
        #expect(!value.isConsumed && !payload.isConsumed)
        let tuple = try payload.take(as: (Int64, Int64).self)
        #expect(tuple.0 + tuple.1 == 42)
    }

    @Test func associatedValuesBuildTheCasePayloadFromSeparateValues() async throws {
        let runtime = ABIRuntime.shared
        let type = try await runtime.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionChoice"))
        )
        let makeIdentifier = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionIdentifier(_:_:)",
                    as: ((UInt64, ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let readSend = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.readRuntimeProjectionSend(_:)",
                    as: ((NativeSwiftValue) -> String?).self,
                    valueABIs: [type: .opaque(named: type.name)]
                )
            )
        )
        let report = Data((0..<32).map { UInt8($0) })
        let counts = ArgumentCounts()
        var constructed: NativeSwiftValue?
        do {
            let identifier = try unsafe makeIdentifier.unsafeInvoke(
                42,
                ErrorLifetimeToken { counts.destroyed() }
            )
            #expect(throws: ABIInvocationError.self) {
                try type.makeEnumCaseAndWait(named: "send", associatedValues: identifier, report)
            }
            constructed = try await type.makeEnumCase(
                named: "send",
                associatedValues: report,
                identifier
            )
            #expect(!identifier.isConsumed)
        }
        #expect(counts.destructions == 0)
        #expect(try unsafe readSend.unsafeInvoke(#require(constructed)) == "\(Array(report)) 42")
        constructed = nil
        #expect(counts.destructions == 1)

        let labeled = try type.makeEnumCaseAndWait(
            named: "labeled",
            associatedValues: (Int64(7), "single")
        )
        guard case .labeled(let value) = try labeled.take(as: RuntimeProjectionChoice.self) else {
            Issue.record("The single labeled value did not initialize its one-element tuple")
            return
        }
        #expect(value.0 == 7 && value.1 == "single")
    }

    @Test func existentialAssociatedValuesKeepTheirContainers() async throws {
        let optional = try await ABIRuntime.shared.resolve(
            .swift(.type("Swift.Optional", genericArguments: [.type(Any.self)]))
        )
        let pair = try await ABIRuntime.shared.resolve(
            .swift(.type("Swift.Optional", genericArguments: [.type((Any, any Error).self)]))
        )
        let counts = ArgumentCounts()
        var constructed: [NativeSwiftValue] = []
        do {
            // Swift 6 opens an existential passed as the first value.
            let token: Any = ErrorLifetimeToken { counts.destroyed() }
            constructed.append(
                try optional.makeEnumCaseAndWait(named: "some", associatedValues: token)
            )
            constructed.append(
                try await pair.makeEnumCase(
                    named: "some",
                    associatedValues: token,
                    ScalarFailure(7)
                )
            )
        }
        do {
            #expect(try constructed[0].copy().take(as: Any?.self) is ErrorLifetimeToken)
            let element = try #require(try constructed[1].copy().take(as: (Any, any Error)?.self))
            #expect(element.0 is ErrorLifetimeToken && (element.1 as? ScalarFailure)?.code == 7)
        }
        #expect(counts.destructions == 0)
        constructed = []
        #expect(counts.destructions == 1)
    }

    @Test func voidPayloadsAreDistinctFromHiddenNoncopyableMetadata() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionUnit()",
                    as: (() -> NativeSwiftValue).self
                )
            )
        )
        let payload = try unsafe make.unsafeInvoke()
        let direct = try await ABIRuntime.shared.resolve(
            .swift(.type("ManagedSwiftFixtures.RuntimeProjectionMoveOnly"))
        )
        let value = try await direct.makeEnumCase(named: "nothing", payload: payload)
        let moved = try value.take(as: RuntimeProjectionMoveOnly.self)
        guard case .nothing = consume moved else {
            Issue.record("A genuine Void payload was not constructed")
            return
        }
        #expect {
            _ = try direct.makeEnumCaseAndWait(named: "ticket", payload: payload)
        } throws: { error in
            if case ABIResolutionError.metadataUnavailable = error { return true }
            if case ABIInvocationError.incompatibleValue(let expected, let actual) = error {
                return expected == String(reflecting: RuntimeTicket.self)
                    && actual == String(reflecting: Void.self)
            }
            return false
        }
        #expect(!payload.isConsumed)
        let generic = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.RuntimeProjectionGeneric",
                    genericArguments: [.type(Void.self)]
                )
            )
        )
        let genericValue = try await generic.makeEnumCase(named: "value", payload: payload)
        guard case .value = try genericValue.take(as: RuntimeProjectionGeneric<Void>.self) else {
            return
        }
        let associated = try await ABIRuntime.shared.resolve(
            .swift(
                .type(
                    "ManagedSwiftFixtures.RuntimeProjectionAssociated",
                    genericArguments: [.type(RuntimeProjectionUnit.self)]
                )
            )
        )
        let associatedValue = try await associated.makeEnumCase(named: "value", payload: payload)
        let associatedMoved = try associatedValue.take(
            as: RuntimeProjectionAssociated<RuntimeProjectionUnit>.self
        )
        guard case .value = consume associatedMoved else {
            Issue.record("An associated type's genuine Void payload was not constructed")
            return
        }
        #expect(!payload.isConsumed)
    }

    @Test func labeledSingleValuesKeepTheirOuterTuple() async throws {
        let value = try await runtimeProjectionChoice(4)
        let payload = try #require(try await value.copyEnumPayload(forCase: "labeled"))
        let nested = try payload.copyTupleElement(at: 0)
        #expect(throws: NativeSwiftValueError.tupleElementIndexOutOfBounds(index: 1, count: 1)) {
            try payload.copyTupleElement(at: 1)
        }
        let text = try nested.copyTupleElement(at: 1)
        #expect(try text.take(as: String.self) == "nested")
        let original = try nested.take(as: (Int64, String).self)
        #expect(original.0 == 42 && original.1 == "nested")
        #expect(!payload.isConsumed && !value.isConsumed)
    }

    @Test(arguments: [false, true])
    func projectedLargePayloadsOwnTheirStorageAfterTheEnumDies(indirect: Bool) async throws {
        let counts = ArgumentCounts()
        var copied: NativeSwiftValue?
        do {
            let value = try await runtimeProjectionChoice(
                indirect ? 6 : 5,
                token: ErrorLifetimeToken { counts.destroyed() }
            )
            let container: NativeSwiftValue
            if indirect {
                container = try #require(try await value.copyEnumPayload(forCase: "indirect"))
                #expect(container.type.name == value.type.name)
            } else {
                container = value
            }
            copied = try #require(try await container.copyEnumPayload(forCase: "large"))
            #expect(!value.isConsumed && !container.isConsumed)
        }
        #expect(counts.destructions == 0)
        do {
            let payload = try #require(copied).take(as: RuntimeProjectionLarge.self)
            #expect(payload.first + payload.second + payload.third + payload.fourth == 100)
            #expect(payload.text == String(repeating: "owned payload ", count: 80))
        }
        copied = nil
        #expect(counts.destructions == 1)
    }

    @Test func genericAndOptionalPayloadTypesComeFromTheirInstantiatedMetadata() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionGeneric(_:)",
                    as: ((String) -> NativeSwiftValue).self,
                    genericArguments: [.type(String.self)]
                )
            )
        )
        let value = try unsafe make.unsafeInvoke("generic payload")
        let payload = try #require(try await value.copyEnumPayload(forCase: "value"))
        #expect(try payload.take(as: String.self) == "generic payload")
        #expect(!value.isConsumed)
        let optional = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionOptional(_:)",
                    as: ((Bool) -> NativeSwiftValue).self
                )
            )
        )
        let some = try unsafe optional.unsafeInvoke(true)
        #expect(
            try #require(try await some.copyEnumPayload(forCase: "some")).take(as: Int64.self)
                == 42
        )
        let none = try unsafe optional.unsafeInvoke(false)
        #expect(try await none.copyEnumPayload(forCase: "none") == nil)
        #expect(try await none.copyEnumPayload(forCase: "some") == nil)
    }

    @Test func projectedGenericValuesResolveTheirUninstantiatedGetterOwner() async throws {
        typealias Box = ExplicitBox<Int64>
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionGeneric(_:)",
                    as: ((Box) -> NativeSwiftValue).self,
                    genericArguments: [.type(Box.self)]
                )
            )
        )
        let container = try unsafe make.unsafeInvoke(Box(42))
        let payload = try #require(try await container.copyEnumPayload(forCase: "value"))
        #expect(payload.type.name == String(reflecting: Box.self))
        let getter = try await payload.type.resolve(
            .swift(
                .getter(
                    "value",
                    as: (() -> Int64).self,
                    receiverABI: .opaque(named: payload.type.name)
                )
            )
        )
        #expect(try unsafe getter.unsafeInvoke(on: payload) == 42)
        #expect(!container.isConsumed && !payload.isConsumed)
    }

    @Test func projectionErrorsLeaveTheSourceOwned() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(42)
        #expect(throws: ABIResolutionError.self) {
            try value.copyEnumPayloadAndWait(forCase: "some")
        }
        #expect(throws: ABIResolutionError.self) { try value.copyTupleElement(at: 0) }
        #expect(throws: ABIResolutionError.self) { try value.copyUnderlyingValue() }
        #expect(throws: ABIResolutionError.self) {
            try value.copyClosureAndWait(as: (() -> Int64).self)
        }
        #expect(try value.take(as: Int64.self) == 42)
        #expect(throws: NativeSwiftValueError.consumedValue) { try value.copyUnderlyingValue() }
        let counts = ArgumentCounts()
        let move = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionMoveOnly(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let owned = try unsafe move.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        #expect(throws: NativeSwiftValueError.noncopyableType) {
            try owned.copyEnumPayloadAndWait(forCase: "ticket")
        }
        #expect(!owned.isConsumed && counts.destructions == 0)
        do {
            let moved = try owned.take(as: RuntimeProjectionMoveOnly.self)
            withExtendedLifetime(moved) { #expect(owned.isConsumed) }
        }
        #expect(counts.destructions == 1)
    }

    @Test(arguments: [false, true])
    func opaqueExistentialsCopyTheInlineOrBoxedConcreteValue(boxed: Bool) async throws {
        let echo = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoExistential(_:)",
                    as: ((any ExistentialValue) -> NativeSwiftValue).self
                )
            )
        )
        let value: NativeSwiftValue
        if boxed {
            value = try unsafe echo.unsafeInvoke(BoxedExistentialValue(ErrorLifetimeToken(), 42))
        } else {
            value = try unsafe echo.unsafeInvoke(InlineExistentialValue(42))
        }
        let underlying = try value.copyUnderlyingValue()
        #expect(underlying.type.name != value.type.name)
        if boxed {
            #expect(try underlying.take(as: BoxedExistentialValue.self).number == 42)
        } else {
            #expect(try underlying.take(as: InlineExistentialValue.self).number == 42)
        }
        #expect(!value.isConsumed)
        try value.withCopy { #expect(($0 as? any ExistentialValue)?.number == 42) }
    }

    @Test func classAndErrorExistentialsRetainTheConcreteOwner() async throws {
        let runtime = ABIRuntime.shared
        let objectEcho = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoClassExistential(_:)",
                    as: ((any ExistentialObjectValue) -> NativeSwiftValue).self
                )
            )
        )
        let errorEcho = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoErrorExistential(_:)",
                    as: ((any Error) -> NativeSwiftValue).self
                )
            )
        )
        let classErrorEcho = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoRuntimeProjectionClassFailure(_:)",
                    as: ((any RuntimeProjectionClassFailure) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        var object: NativeSwiftValue?
        var error: NativeSwiftValue?
        var classError: NativeSwiftValue?
        weak var observed: ExistentialObject?
        weak var observedError: ReferenceFailure?
        do {
            let original = ExistentialObject(ErrorLifetimeToken { counts.destroyed() }, 42)
            observed = original
            let container = try unsafe objectEcho.unsafeInvoke(original)
            object = try container.copyUnderlyingValue()
            #expect(!container.isConsumed)
            let failure = ReferenceFailure(ErrorLifetimeToken { counts.destroyed() }, 43)
            observedError = failure
            let errorContainer = try unsafe errorEcho.unsafeInvoke(failure)
            error = try errorContainer.copyUnderlyingValue()
            let classContainer = try unsafe classErrorEcho.unsafeInvoke(failure)
            classError = try classContainer.copyUnderlyingValue()
        }
        #expect(observed != nil && observedError != nil && counts.destructions == 0)
        do {
            #expect(try #require(object).take(as: ExistentialObject.self) === observed)
            #expect(try #require(error).take(as: ReferenceFailure.self) === observedError)
            #expect(try #require(classError).take(as: ReferenceFailure.self).code == 43)
        }
        object = nil; error = nil; classError = nil
        #expect(observed == nil && observedError == nil && counts.destructions == 2)
    }

    @Test func bridgedErrorsKeepTheirProjectedObjectAfterTheContainerDies() async throws {
        let echo = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.echoErrorExistential(_:)",
                    as: ((any Error) -> NativeSwiftValue).self
                )
            )
        )
        let original = NSError(domain: "RuntimeProjectionError", code: 42)
        var copied: NativeSwiftValue?
        do {
            let container = try unsafe echo.unsafeInvoke(original)
            copied = try container.copyUnderlyingValue()
            #expect(!container.isConsumed)
        }
        let value = try #require(copied)
        try value.withCopy {
            #expect(ObjectIdentifier(type(of: $0)) == ObjectIdentifier(type(of: original)))
            let error = try #require($0 as? NSError)
            #expect(error === original)
            #expect(error.domain == "RuntimeProjectionError" && error.code == 42)
        }
    }

    @Test(arguments: [Int64(0), 1, 2])
    func unsupportedClassErrorPayloadsLeaveTheOriginalEnumOwned(_ kind: Int64) async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionUnsupportedErrorPayload(_:_:)",
                    as: ((Int64, ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        do {
            let value = try unsafe make.unsafeInvoke(
                kind,
                ErrorLifetimeToken { counts.destroyed() }
            )
            let name = ["direct", "tuple", "optional"][Int(kind)]
            do {
                _ = try value.copyEnumPayloadAndWait(forCase: name)
                Issue.record("A payload with unsupported class-error storage was copied")
            } catch ABIResolutionError.unsupportedDeclaration {}
            #expect(!value.isConsumed && counts.destructions == 0)
            let original = try value.take(as: RuntimeProjectionUnsupportedErrorPayload.self)
            let failure: any Error & AnyObject
            switch original {
            case .direct(let error):
                #expect(kind == 0)
                failure = error
            case .tuple(let pair):
                #expect(kind == 1 && pair.0 == 7)
                failure = pair.1
            case .optional(let error):
                #expect(kind == 2)
                failure = try #require(error)
            case .closure:
                Issue.record("A payload-copy fixture unexpectedly produced a closure")
                return
            }
            #expect(try #require(failure as? ReferenceFailure).code == 42)
            #expect(counts.destructions == 0)
        }
        #expect(counts.destructions == 1)
    }

    @Test func unsupportedStoredClosureResultIsRejectedBeforeInvocation() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionUnsupportedErrorPayload(_:_:)",
                    as: ((Int64, ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        do {
            let value = try unsafe make.unsafeInvoke(3, ErrorLifetimeToken { counts.destroyed() })
            do {
                _ = try await value.copyEnumPayload(forCase: "closure")
                Issue.record("A closure with unsupported class-error result storage was resolved")
            } catch ABIResolutionError.unsupportedDeclaration {}
            #expect(!value.isConsumed && counts.destructions == 0)
            let original = try value.take(as: RuntimeProjectionUnsupportedErrorPayload.self)
            guard case .closure(let native) = original else {
                Issue.record("The original enum case changed after closure resolution failed")
                return
            }
            let failure = native()
            #expect(try #require(failure as? ReferenceFailure).code == 42)
            #expect(counts.destructions == 0)
        }
        #expect(counts.destructions == 1)
    }

    @Test func extendedExistentialsPreserveTheirSpecializedUnderlyingType() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeGenericExtendedCollection(_:)",
                    as: ((Int) -> NativeSwiftValue).self,
                    genericArguments: [.type(Int.self)]
                )
            )
        )
        let container = try unsafe make.unsafeInvoke(42)
        let underlying = try container.copyUnderlyingValue()
        #expect(try underlying.take(as: [Int].self) == [42])
        #expect(!container.isConsumed)
    }

    @MainActor @Test
    func projectedMainActorClosuresRetainCapturesAndEraseTheNativeResult() async throws {
        typealias Signature = @MainActor () -> NativeSwiftValue
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionRoot(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        var closure: NativeSwiftClosure<Signature>?
        var constructed: NativeSwiftValue?
        do {
            let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
            let payload = try #require(try await value.copyEnumPayload(forCase: "preview"))
            let existential = try payload.copyTupleElement(at: 0)
            let source = try existential.copyUnderlyingValue()
            #expect(existential.type.name != source.type.name)
            let previewType = try await ABIRuntime.shared.resolve(
                .swift(.type("ManagedSwiftFixtures.RuntimeProjectionPreview"))
            )
            let body = try await source.type.resolve(
                .swift(
                    .getter(
                        "body",
                        as: (() -> NativeSwiftValue).self,
                        valueABIs: [previewType: NativeType.opaque(named: previewType.name)],
                        receiverABI: NativeType.opaque(named: source.type.name)
                    )
                )
            )
            let preview = try unsafe body.unsafeInvoke(on: source)
            let bodyType = try await ABIRuntime.shared.resolve(
                .swift(.type("ManagedSwiftFixtures.RuntimeProjectionBody"))
            )
            let associated = try #require(
                try await preview.copyEnumPayload(
                    forCase: "singlePreview",
                    valueABIs: [bodyType: .opaque(named: bodyType.name)]
                )
            )
            constructed = try await preview.type.makeEnumCase(
                named: "singlePreview",
                payload: associated,
                valueABIs: [bodyType: .opaque(named: bodyType.name)]
            )
            let function = try associated.copyTupleElement(at: 0)
            closure = try await function.copyClosure(as: Signature.self)
            #expect(!function.isConsumed && !value.isConsumed && !source.isConsumed)
            #expect(throws: ABIResolutionError.self) {
                try function.copyClosureAndWait(as: (() -> NativeSwiftValue).self)
            }
        }
        #expect(counts.destructions == 0)
        do {
            let result = try unsafe #require(closure).unsafeInvoke()
            #expect(result.type.name == String(reflecting: RuntimeProjectionBody.self))
            let body = try result.take(as: RuntimeProjectionBody.self)
            #expect(body.number == 42)
            MainActor.assertIsolated()
        }
        closure = nil
        do {
            let value = try #require(constructed).take(as: RuntimeProjectionPreview.self)
            guard case .singlePreview(let makeBody) = value else { return }
            #expect(makeBody().number == 42)
        }
        constructed = nil
        #expect(counts.destructions == 1)
    }

    @MainActor @Test
    func formalGenericClosureResultsUseTheirBoundTypeWithoutAnABIOverride() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionGenericPreview(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let container = try unsafe make.unsafeInvoke(ErrorLifetimeToken())
        let payload = try #require(try await container.copyEnumPayload(forCase: "singlePreview"))
        let constructed = try container.type.makeEnumCaseAndWait(
            named: "singlePreview",
            payload: payload
        )
        let native = try constructed.take(
            as: RuntimeProjectionGenericPreview<RuntimeProjectionBody>.self
        )
        guard case .singlePreview(let makeBody) = native else { return }
        #expect(makeBody().number == 42)
        let function = try payload.copyTupleElement(at: 0)
        let closure = try await function.copyClosure(
            as: (@MainActor () -> NativeSwiftValue).self
        )
        let result = try unsafe closure.unsafeInvoke()
        #expect(result.type.name == String(reflecting: RuntimeProjectionBody.self))
        #expect(try result.take(as: RuntimeProjectionBody.self).number == 42)
        #expect(!container.isConsumed && !payload.isConsumed && !function.isConsumed)
        MainActor.assertIsolated()
    }

    @MainActor @Test
    func projectedAsyncMainActorClosuresPreserveSuspensionAndTypedFailure() async throws {
        typealias Signature = @MainActor (Bool) async throws(ScalarFailure) -> NativeSwiftValue
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionAsyncClosure(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let value = try unsafe make.unsafeInvoke(ErrorLifetimeToken())
        let closure = try value.copyClosureAndWait(as: Signature.self)
        let result = try unsafe await closure.unsafeInvoke(false)
        #expect(try result.take(as: RuntimeProjectionBody.self).number == 42)
        do {
            _ = try unsafe await closure.unsafeInvoke(true)
            Issue.record("The closure's native typed error did not escape")
        } catch let error as NativeSwiftError {
            #expect(error.withUnderlyingError { ($0 as? ScalarFailure)?.code } == 42)
        }
        #expect(throws: ABIResolutionError.self) {
            try value.copyClosureAndWait(
                as: (@MainActor (Bool) throws(ScalarFailure) -> NativeSwiftValue).self
            )
        }
        #expect(throws: ABIResolutionError.self) {
            try value.copyClosureAndWait(
                as: (@MainActor (Bool) async -> NativeSwiftValue).self
            )
        }
        #expect(!value.isConsumed)
        MainActor.assertIsolated()
    }

    /// An Optional closure in a payload is adapted between the case's
    /// convention and that of owned runtime values, and nil stays nil.
    @Test func optionalClosurePayloadsAdaptTheirFunctions() async throws {
        typealias Increment = (Int64) -> Int64
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionOptionalHandler(_:labeled:)",
                    as: ((Int64?, Bool) -> NativeSwiftValue).self
                )
            )
        )
        for labeled in [false, true] {
            let name = labeled ? "labeled" : "handler"
            let value = try unsafe make.unsafeInvoke(1, labeled)
            let payload = try #require(try await value.copyEnumPayload(forCase: name))
            let body = labeled ? try payload.copyTupleElement(at: 1) : payload
            #expect(try body.withCopy { ($0 as? Increment?)??(41) } == 42, "\(name)")
            let empty = try unsafe make.unsafeInvoke(nil, labeled)
            let none = try #require(try await empty.copyEnumPayload(forCase: name))
            let nilBody = labeled ? try none.copyTupleElement(at: 1) : none
            #expect(try nilBody.withCopy { ($0 as? Increment?).map { $0 == nil } } == true)
            // A case built from the payload holds the case's convention again.
            let rebuilt = try await value.type.makeEnumCase(named: name, payload: payload)
            switch try rebuilt.take(as: RuntimeProjectionOptionalHandler.self) {
            case .handler(let body): #expect(body?(41) == 42)
            case .labeled(_, let body): #expect(body?(41) == 42)
            }
        }
    }

    /// An Optional C function pointer or block in a payload is a plain
    /// pointer, which needs no adaptation and keeps its value.
    @Test func optionalForeignFunctionPayloadsPassUnchanged() async throws {
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionForeignHandler(_:)",
                    as: ((Bool) -> NativeSwiftValue).self
                )
            )
        )
        let function = try unsafe make.unsafeInvoke(false)
        let pointer = try #require(try await function.copyEnumPayload(forCase: "function"))
        #expect(try pointer.withCopy { ($0 as? (@convention(c) (Int64) -> Int64)?)??(41) } == 42)
        let block = try unsafe make.unsafeInvoke(true)
        let body = try #require(try await block.copyEnumPayload(forCase: "block"))
        #expect(try body.withCopy { ($0 as? (@convention(block) (Int64) -> Int64)?)??(40) } == 42)
        let rebuilt = try await block.type.makeEnumCase(named: "block", payload: body)
        guard case .block(let native) = try rebuilt.take(as: RuntimeProjectionForeignHandler.self)
        else {
            Issue.record("The rebuilt case is not the block case")
            return
        }
        #expect(native?(40) == 42)
    }

    @Test func plainSynchronousAndCallerIsolatedAsyncClosuresKeepTheirEffects() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionPlainClosure(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let synchronous = try unsafe make.unsafeInvoke(7)
        let closure = try synchronous.copyClosureAndWait(as: ((Int64) -> Int64).self)
        #expect(try unsafe closure.unsafeInvoke(35) == 42)
        let makeAsync = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionAsyncPlainClosure(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let asynchronous = try unsafe makeAsync.unsafeInvoke(7)
        let asyncClosure = try await asynchronous.copyClosure(
            as: (nonisolated(nonsending) (Int64) async -> Int64).self
        )
        #expect(try unsafe await asyncClosure.unsafeInvoke(35) == 42)
        #expect(throws: ABIResolutionError.self) {
            try synchronous.copyClosureAndWait(as: ((String) -> String).self)
        }
        #expect(throws: ABIResolutionError.self) {
            try asynchronous.copyClosureAndWait(as: ((Int64) -> Int64).self)
        }
        #expect(!synchronous.isConsumed && !asynchronous.isConsumed)
        let native = try synchronous.take(as: ((Int64) -> Int64).self)
        #expect(native(35) == 42)
        #expect(throws: NativeSwiftValueError.consumedValue) {
            try synchronous.copyClosureAndWait(as: ((Int64) -> Int64).self)
        }
        await #expect(throws: NativeSwiftValueError.consumedValue) {
            _ = try await synchronous.copyClosure(as: ((Int64) -> Int64).self)
        }
        #expect(try unsafe closure.unsafeInvoke(35) == 42)
    }

    @MainActor @Test
    func storedClosureOwnershipUsesExplicitWrappersForConsumptionAndMutation() async throws {
        let runtime = ABIRuntime.shared
        let makeTicket = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueRuntimeTicket(_:)",
                    as: ((ErrorLifetimeToken) -> NativeSwiftValue).self
                )
            )
        )
        let counts = ArgumentCounts()
        let ticket = try unsafe makeTicket.unsafeInvoke(ErrorLifetimeToken { counts.destroyed() })
        let makeConsumer = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeConsumer<A where A: ~Swift.Copyable>(A.Type) -> (__owned A) -> Swift.Int64",
                    as: ((RuntimeTicket.Type) -> NativeSwiftValue).self,
                    genericArguments: [.type(ticket.type)]
                )
            )
        )
        let consumerValue = try unsafe makeConsumer.unsafeInvoke(RuntimeTicket.self)
        #expect(throws: ABIResolutionError.self) {
            try consumerValue.copyClosureAndWait(as: ((NativeSwiftValue) -> Int64).self)
        }
        let consume = try consumerValue.copyClosureAndWait(
            as: ((NativeSwiftConsuming<NativeSwiftValue>) -> Int64).self
        )
        #expect(
            try unsafe consume.unsafeInvoke(NativeSwiftConsuming(ticket))
                == MemoryLayout<RuntimeTicket>.size
        )
        #expect(ticket.isConsumed && counts.destructions == 1 && !consumerValue.isConsumed)

        let makeSwap = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeSwap<A where A: ~Swift.Copyable>(A.Type) -> (inout A, inout A) -> ()",
                    as: ((Int64.Type) -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        )
        let swapValue = try unsafe makeSwap.unsafeInvoke(Int64.self)
        let swap = try await swapValue.copyClosure(
            as: ((NativeSwiftInout<NativeSwiftValue>, NativeSwiftInout<NativeSwiftValue>) -> Void)
                .self
        )
        let makeInteger = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeOpaqueInteger(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let first = NativeSwiftInout(try unsafe makeInteger.unsafeInvoke(40))
        let second = NativeSwiftInout(try unsafe makeInteger.unsafeInvoke(2))
        try unsafe swap.unsafeInvoke(first, second)
        #expect(try first.value.take(as: Int64.self) == 2)
        #expect(try second.value.take(as: Int64.self) == 40)
        #expect(!swapValue.isConsumed)
    }

    @MainActor @Test
    func enumClosurePreparationJoinsRequiredWorkAndCanonicalizesBothFieldPatterns() async throws {
        typealias Signature = RuntimeProjectionPreparationSignature
        let make = try await ABIRuntime.shared.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionPreparationClosure(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let container = try unsafe make.unsafeInvoke(7)
        #if DEBUG
        let gate = ProjectionPreparationGate()
        let integer = try RuntimeValueType(
            indirectSwiftSize: MemoryLayout<Int64>.size,
            alignment: MemoryLayout<Int64>.alignment
        )
        let parameters = Array(repeating: integer, count: 17)
        let key = RuntimeCallInterfaceKey(result: integer, parameters: parameters)
        let preparation = Task.detached {
            try await NativePreparation.run {
                try RuntimeSwiftCallInterface.cache.interface(for: key) {
                    try gate.observe()
                    return try RuntimeSwiftCallInterface(result: integer, parameters: parameters)
                }
            }
        }
        defer { gate.release.signal() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !gate.entered.withLock({ $0 }) {
            guard ContinuousClock.now < deadline else {
                throw ProjectionPreparationFailure.timedOut
            }
            await Task.yield()
        }
        let progress = Task { @MainActor in
            defer { gate.release.signal() }
            MainActor.assertIsolated()
            #expect(throws: NativeSwiftValueError.valueInUse) {
                try container.take(as: RuntimeProjectionPreparationContainer.self)
            }
        }
        let result: Result<NativeSwiftValue, any Error>
        do {
            result = .success(try #require(try await container.copyEnumPayload(forCase: "body")))
        } catch {
            result = .failure(error)
        }
        await progress.value
        let prepared = try await preparation.value
        let value = try result.get()
        #else
        let value = try #require(try await container.copyEnumPayload(forCase: "body"))
        #endif
        let closure = try await value.copyClosure(as: Signature.self)
        #if DEBUG
        guard case .synchronous(_, let call) = closure.call else {
            Issue.record("Expected the stored synchronous closure's prepared call interface")
            return
        }
        #expect(call.interface.runtime === prepared)
        let observations = gate.observations.withLock { $0 }
        #expect(!observations.isEmpty && observations.allSatisfy { !$0 })
        #endif
        #expect(try invokeProjectionPreparation(closure) == 42)
        let concreteType = value.type
        try value.withCopy { copied in
            let native = try #require(copied as? Signature)
            #expect(invokeProjectionPreparation(native) == 42)
        }
        let runtime = ABIRuntime.shared
        let export = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.copyRuntimeValue<A>(A) -> A",
                    as: ((NativeSwiftValue) -> Signature).self,
                    genericArguments: [.type(value.type)]
                )
            )
        )
        let exported = try unsafe export.unsafeInvoke(value)
        #expect(invokeProjectionPreparation(exported) == 42)
        let apply = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.applyRuntimeProjectionPreparationClosure(_:)",
                    as: ((NativeSwiftValue) -> Int64).self
                )
            )
        )
        #expect(try unsafe apply.unsafeInvoke(value) == 42)
        #expect(!container.isConsumed && !value.isConsumed)
        #expect(invokeProjectionPreparation(try value.take(as: Signature.self)) == 42)

        let makeGeneric = try await runtime.resolve(
            .swift(
                .function(
                    "ManagedSwiftFixtures.makeRuntimeProjectionGenericPreparationClosure(_:)",
                    as: ((Int64) -> NativeSwiftValue).self
                )
            )
        )
        let generic = try unsafe makeGeneric.unsafeInvoke(7)
        let genericValue = try #require(try generic.copyEnumPayloadAndWait(forCase: "value"))
        #expect(concreteType == genericValue.type)
        let genericClosure = try genericValue.copyClosureAndWait(as: Signature.self)
        #expect(try invokeProjectionPreparation(genericClosure) == 42)
        try genericValue.withCopy { copied in
            let native = try #require(copied as? Signature)
            #expect(invokeProjectionPreparation(native) == 42)
        }
        #expect(!generic.isConsumed && !genericValue.isConsumed)
        #expect(invokeProjectionPreparation(try genericValue.take(as: Signature.self)) == 42)
        MainActor.assertIsolated()
    }

    #if os(macOS)
    @Test func constructedRuntimeOnlyEnumPreservesPayloadOwnershipAfterMutation() async throws {
        let module = "EmptyEnum_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                nonisolated(unsafe) private var destructions: Int64 = 0
                public final class Token {
                    deinit { destructions += 1 }
                }
                public enum Selection {
                    case empty
                    case payload(Token)
                    public func isEmpty() -> Bool {
                        switch self {
                        case .empty: true
                        case .payload: false
                        }
                    }
                    public mutating func fill() { self = .payload(Token()) }
                }
                public func destructionCount() -> Int64 { destructions }
                """,
            linkArguments: ["-swift-version", "6", "-enable-library-evolution"]
        )
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let type = try await runtime.resolve(
            .swift(.type(module + ".Selection")),
            in: .path(fixture.libraryURL)
        )
        let count = try await runtime.resolve(
            .swift(
                .function(
                    module + ".destructionCount()",
                    as: (() -> Int64).self
                )
            ),
            in: .path(fixture.libraryURL)
        )
        let read = try await type.resolve(
            .swift(
                .method(
                    "isEmpty()",
                    as: (() -> Bool).self,
                    receiverABI: .opaque(named: type.name)
                )
            )
        )
        let fill = try await type.resolve(
            .swift(
                .method(
                    "fill()",
                    as: (() -> Void).self,
                    receiverABI: .opaque(named: type.name),
                    receiver: .mutating
                )
            )
        )
        var value: NativeSwiftValue? = try type.makeEnumCase(named: "empty")
        #expect(try unsafe count.unsafeInvoke() == 0)
        #expect(try unsafe read.unsafeInvoke(on: #require(value)))
        try unsafe fill.unsafeInvoke(on: #require(value))
        #expect(try unsafe !read.unsafeInvoke(on: #require(value)))
        var copied: NativeSwiftValue? = try #require(value).copy()
        value = nil
        #expect(try unsafe count.unsafeInvoke() == 0)
        #expect(try unsafe !read.unsafeInvoke(on: #require(copied)))
        copied = nil
        #expect(try unsafe count.unsafeInvoke() == 1)
    }

    @MainActor @Test
    func legacyMainActorFunctionMetadataAcceptsTheSwiftSixSendableSignature() async throws {
        let module =
            "ProjectionLegacy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public func make() -> some Any {
                    let body: @MainActor (Int64) -> Int64 = { $0 + 7 }
                    return body
                }
                """,
            linkArguments: ["-swift-version", "5"]
        )
        defer { fixture.cleanup() }
        let make = try await ABIRuntime().resolve(
            .swift(
                .function(
                    module + ".make()",
                    as: (() -> NativeSwiftValue).self
                )
            ),
            in: .path(fixture.libraryURL)
        )
        let value = try unsafe make.unsafeInvoke()
        let metadata = try value.withCopy { try RuntimeFunctionMetadata(type(of: $0)) }
        #expect(!metadata.isSendable)
        let host = try RuntimeFunctionMetadata((@MainActor (Int64) -> Int64).self)
        #expect(host.isSendable)
        let closure = try await value.copyClosure(as: (@MainActor (Int64) -> Int64).self)
        #expect(try unsafe closure.unsafeInvoke(35) == 42)
        MainActor.assertIsolated()
    }
    #endif
}
