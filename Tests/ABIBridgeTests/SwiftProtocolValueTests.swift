#if DEBUG
@testable import ABIBridge
#else
import ABIBridge
#endif
import Darwin
import Foundation
import ManagedSwiftFixtures
import Synchronization
import Testing

private final class ProtocolTestState: Sendable {
    let messages = Mutex<[String]>([])
    let callerThread = Mutex<UInt32?>(nil)
    let destroyed = Mutex(0)
    let borrowedCalls = Mutex(0)
    let owned = Mutex<ErrorLifetimeToken?>(nil)
}

private final class ProtocolCapture: Sendable {
    let state: ProtocolTestState
    init(_ state: ProtocolTestState) { self.state = state }
    deinit { state.destroyed.withLock { $0 += 1 } }
    func receive(_ value: String) { state.messages.withLock { $0.append(value) } }
}

struct SwiftProtocolValueTests {
    @Test func providerRetainsCastsAndReboxesAfterOriginalWrapperIsReleased() async throws {
        let runtime = ABIRuntime()
        let install = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.installHostDelegate(_:_:)",
                    as: ((AnyObject, NativeSwiftValue) -> Void).self
                )
            )
        )
        let invoke = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.invokeHostDelegate(_:_:)",
                    as: ((AnyObject, String) -> Int).self
                )
            )
        )
        let receiver = makeHostDelegateReceiver()
        let state = ProtocolTestState()
        do {
            let capture = ProtocolCapture(state)
            let value = try await runtime.makeSwiftProtocolValue(
                "ManagedSwiftFixtures.HostDelegate",
                methods: [
                    try NativeSwiftProtocolMethod("receive(_:)") { (message: String) in
                        #expect(
                            state.callerThread.withLock { $0 }
                                == pthread_mach_thread_np(pthread_self())
                        )
                        capture.receive(message)
                    }
                ]
            )
            try unsafe install.unsafeInvoke(receiver, value)
        }
        #expect(state.destroyed.withLock { $0 } == 0)
        state.callerThread.withLock { $0 = pthread_mach_thread_np(pthread_self()) }
        #expect(try unsafe invoke.unsafeInvoke(receiver, "hello") == 3)
        #expect(state.messages.withLock { $0 } == ["hello", "hello:any", "hello:object"])
        #expect(clearHostDelegate(receiver))
        #expect(state.destroyed.withLock { $0 } == 1)
    }
}

// Calls below are synchronous; only the test and its callback use this receiver.
private final class ProtocolReceiverReference: @unchecked Sendable {
    let value: AnyObject
    init(_ value: AnyObject) { self.value = value }
}

extension SwiftProtocolValueTests {
    @Test func inFlightCallRetainsCapturesAfterProviderDropsItsDelegate() throws {
        let receiver = ProtocolReceiverReference(makeHostDelegateReceiver())
        let runtime = ABIRuntime()
        let install = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.installHostDelegate(_:_:)",
                    as: ((AnyObject, NativeSwiftValue) -> Void).self
                )
            )
        )
        let invoke = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.invokeHostDelegate(_:_:)",
                    as: ((AnyObject, String) -> Int).self
                )
            )
        )
        let state = ProtocolTestState()
        do {
            let capture = ProtocolCapture(state)
            let value = try runtime.makeSwiftProtocolValueAndWait(
                "ManagedSwiftFixtures.HostDelegate",
                methods: [
                    try NativeSwiftProtocolMethod("receive(_:)") { (message: String) in
                        _ = clearHostDelegate(receiver.value)
                        #expect(state.destroyed.withLock { $0 } == 0)
                        capture.receive(message)
                    }
                ]
            )
            try unsafe install.unsafeInvoke(receiver.value, value)
        }
        #expect(try unsafe invoke.unsafeInvoke(receiver.value, "active") == 3)
        #expect(state.messages.withLock { $0.count } == 3)
        #expect(clearHostDelegate(receiver.value))
        #expect(state.destroyed.withLock { $0 } == 1)
    }

    @Test func borrowedAndConsumedArgumentsKeepTheirNativeOwnership() throws {
        let runtime = ABIRuntime()
        let state = ProtocolTestState()
        let value = try runtime.makeSwiftProtocolValueAndWait(
            "ManagedSwiftFixtures.HostOwnershipDelegate",
            methods: [
                try NativeSwiftProtocolMethod("borrow(_:)") {
                    (input: NativeSwiftBorrowing<ErrorLifetimeToken>) in
                    #expect(state.destroyed.withLock { $0 } == 0)
                    withExtendedLifetime(input.value) {}
                    state.borrowedCalls.withLock { $0 += 1 }
                },
                try NativeSwiftProtocolMethod("consume(_:)") {
                    (input: NativeSwiftConsuming<ErrorLifetimeToken>) in
                    state.owned.withLock { $0 = input.value }
                },
            ]
        )
        let invoke = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.exerciseHostOwnership(_:_:)",
                    as: ((NativeSwiftValue, NativeSwiftConsuming<ErrorLifetimeToken>) -> Void).self
                )
            )
        )
        do {
            let token = ErrorLifetimeToken { state.destroyed.withLock { $0 += 1 } }
            try unsafe invoke.unsafeInvoke(value, NativeSwiftConsuming(token))
        }
        #expect(state.borrowedCalls.withLock { $0 } == 1)
        #expect(state.destroyed.withLock { $0 } == 0)
        state.owned.withLock { $0 = nil }
        #expect(state.destroyed.withLock { $0 } == 1)
    }

    @Test func invalidPreparationsReleaseCapturesAndDoNotPublishAValue() throws {
        let runtime = ABIRuntime()
        let state = ProtocolTestState()
        do {
            let capture = ProtocolCapture(state)
            let method = try NativeSwiftProtocolMethod("receive(_:)") { (value: String) in
                capture.receive(value)
            }
            #expect(throws: ABIResolutionError.self) {
                _ = try runtime.makeSwiftProtocolValueAndWait(
                    "ManagedSwiftFixtures.HostDelegate",
                    methods: []
                )
            }
            #expect(throws: ABIResolutionError.self) {
                _ = try runtime.makeSwiftProtocolValueAndWait(
                    "ManagedSwiftFixtures.HostDelegate",
                    methods: [try NativeSwiftProtocolMethod("receive(_:)") { (_: Int64) in }]
                )
            }
            #expect(throws: ABIResolutionError.self) {
                _ = try runtime.makeSwiftProtocolValueAndWait(
                    "ManagedSwiftFixtures.HostDelegate",
                    methods: [method, method]
                )
            }
            #expect(throws: ABIResolutionError.self) {
                _ = try runtime.makeSwiftProtocolValueAndWait(
                    "ManagedSwiftFixtures.HostDelegate",
                    methods: [method, try NativeSwiftProtocolMethod("unexpected()") {}]
                )
            }
            for name in ["HostAssociatedDelegate", "HostReturningDelegate"] {
                #expect(throws: ABIResolutionError.self) {
                    _ = try runtime.makeSwiftProtocolValueAndWait(
                        "ManagedSwiftFixtures." + name,
                        methods: [method]
                    )
                }
            }
        }
        #expect(state.messages.withLock { $0.isEmpty })
        #expect(state.destroyed.withLock { $0 } == 1)
    }
}

extension SwiftProtocolValueTests {
    @Test func weakPropertyUsesIndependentCopyAndRuntimeOnlyCallbackArgument() throws {
        let runtime = ABIRuntime()
        let receiver = makeHostDelegateReceiver()
        let object = runtime.object(receiver)
        let setter = try object.resolveAndWait(
            .swift(
                .setter(
                    "observedDelegate",
                    as: ((NativeSwiftValue?) -> Void).self
                )
            )
        )
        let getter = try object.resolveAndWait(
            .swift(
                .getter(
                    "observedDelegate",
                    as: (() -> NativeSwiftValue?).self
                )
            )
        )
        let state = ProtocolTestState()
        do {
            let capture = ProtocolCapture(state)
            let value = try runtime.makeSwiftProtocolValueAndWait(
                "ManagedSwiftFixtures.HostDelegate",
                methods: [
                    try NativeSwiftProtocolMethod("receive(_:)") {
                        (input: NativeSwiftBorrowedValue) in
                        do {
                            let message = try input.copy().withCopy { try #require($0 as? String) }
                            capture.receive(message)
                        } catch { Issue.record(error) }
                    }
                ]
            )
            try unsafe setter.unsafeInvoke(try value.copy())
            #expect(!value.isConsumed)
            let received = try #require(try unsafe getter.unsafeInvoke())
            let originalObject = try value.copyUnderlyingValue()
            let receivedObject = try received.copyUnderlyingValue()
            #expect(originalObject.type == receivedObject.type)
            let identities = try [value, originalObject, receivedObject].map { value in
                try value.withCopy { ObjectIdentifier($0 as AnyObject) }
            }
            #expect(Set(identities).count == 1)
            let forward = try receivedObject.type.resolveAndWait(
                .swift(
                    .method(
                        "ManagedSwiftFixtures.HostDelegate.receive(_:)",
                        as: ((String) -> Void).self
                    )
                )
            )
            try unsafe forward.unsafeInvoke(on: receivedObject, "forwarded")
            #expect(invokeWeakHostDelegate(receiver, "weak"))
            #expect(state.messages.withLock { $0 } == ["forwarded", "weak"])
        }
        #expect(try unsafe getter.unsafeInvoke() == nil)
        #expect(!invokeWeakHostDelegate(receiver, "released"))
        #expect(state.destroyed.withLock { $0 } == 1)
    }
}

extension SwiftProtocolValueTests {
    enum ThrowingRequirementCase: CaseIterable {
        case untyped, typed, widened
    }

    @Test(arguments: ThrowingRequirementCase.allCases)
    func throwingRequirementPreservesNativeErrorsAndTheirLifetime(
        scenario: ThrowingRequirementCase
    ) throws {
        let nativeTyped = scenario == .typed
        let bodyTyped = scenario != .untyped
        let runtime = ABIRuntime()
        let captureState = ProtocolTestState()
        let errorState = ProtocolTestState()
        let invoke: (NativeSwiftValue, Bool) throws -> Void
        if nativeTyped {
            let native = try runtime.resolveAndWait(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.invokeHostTypedThrowingDelegate(_:_:)",
                        as: ((NativeSwiftValue, Bool) throws(ManagedFailure) -> Void).self
                    )
                )
            )
            invoke = { value, fail in try unsafe native.unsafeInvoke(value, fail) }
        } else {
            let native = try runtime.resolveAndWait(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.invokeHostThrowingDelegate(_:_:)",
                        as: ((NativeSwiftValue, Bool) throws -> Void).self
                    )
                )
            )
            invoke = { value, fail in try unsafe native.unsafeInvoke(value, fail) }
        }
        var retainedError: NativeSwiftError?
        do {
            let capture = ProtocolCapture(captureState)
            let body: @Sendable (Bool) throws(ManagedFailure) -> Void = {
                fail throws(ManagedFailure) in
                capture.receive(fail ? "failure" : "success")
                if fail {
                    throw ManagedFailure(
                        ErrorLifetimeToken { errorState.destroyed.withLock { $0 += 1 } },
                        42
                    )
                }
            }
            let method: NativeSwiftProtocolMethod
            if bodyTyped {
                method = try NativeSwiftProtocolMethod("receive(_:)", body)
            } else {
                method = try NativeSwiftProtocolMethod("receive(_:)") { (fail: Bool) throws in
                    try body(fail)
                }
            }
            let value = try runtime.makeSwiftProtocolValueAndWait(
                "ManagedSwiftFixtures."
                    + (nativeTyped ? "HostTypedThrowingDelegate" : "HostThrowingDelegate"),
                methods: [method]
            )
            try invoke(value, false)
            do {
                try invoke(value, true)
                Issue.record("The native throwing requirement returned without its error")
            } catch let error as NativeSwiftError {
                error.withUnderlyingError { #expect(($0 as? ManagedFailure)?.code == 42) }
                retainedError = error
            }
        }
        #expect(captureState.messages.withLock { $0 } == ["success", "failure"])
        #expect(captureState.destroyed.withLock { $0 } == 1)
        #expect(errorState.destroyed.withLock { $0 } == 0)
        #expect(retainedError != nil)
        retainedError = nil
        #expect(errorState.destroyed.withLock { $0 } == 1)
    }

    @Test(arguments: [false, true])
    func nonthrowingImplementationSatisfiesThrowingRequirement(typed: Bool) throws {
        let runtime = ABIRuntime()
        let state = ProtocolTestState()
        let value = try runtime.makeSwiftProtocolValueAndWait(
            "ManagedSwiftFixtures."
                + (typed ? "HostTypedThrowingDelegate" : "HostThrowingDelegate"),
            methods: [
                try NativeSwiftProtocolMethod("receive(_:)") { (flag: Bool) in
                    state.messages.withLock { $0.append(flag ? "true" : "false") }
                }
            ]
        )
        if typed {
            let native = try runtime.resolveAndWait(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.invokeHostTypedThrowingDelegate(_:_:)",
                        as: ((NativeSwiftValue, Bool) throws(ManagedFailure) -> Void).self
                    )
                )
            )
            try unsafe native.unsafeInvoke(value, true)
        } else {
            let native = try runtime.resolveAndWait(
                .swift(
                    .function(
                        "ManagedSwiftFixtures.invokeHostThrowingDelegate(_:_:)",
                        as: ((NativeSwiftValue, Bool) throws -> Void).self
                    )
                )
            )
            try unsafe native.unsafeInvoke(value, true)
        }
        #expect(state.messages.withLock { $0 } == ["true"])
    }

    @Test func selfArgumentKeepsTheConcreteConformerIdentity() throws {
        let runtime = ABIRuntime()
        let state = ProtocolIdentityState()
        let value = try runtime.makeSwiftProtocolValueAndWait(
            "ManagedSwiftFixtures.HostSelfDelegate",
            methods: [
                try NativeSwiftProtocolMethod("accept(_:)") {
                    (other: NativeSwiftBorrowedValue) in
                    do {
                        let identity = try other.copy().withCopy {
                            ObjectIdentifier($0 as AnyObject)
                        }
                        state.values.withLock { $0.append(identity) }
                    } catch { Issue.record(error) }
                },
                try NativeSwiftProtocolMethod("acceptOptional(_:)") {
                    (other: NativeSwiftBorrowedValue?) in
                    do {
                        let other = try #require(other)
                        let identity = try other.copy().withCopy {
                            ObjectIdentifier($0 as AnyObject)
                        }
                        state.values.withLock { $0.append(identity) }
                    } catch { Issue.record(error) }
                },
                try NativeSwiftProtocolMethod("acceptMany(_:)") { (others: [NativeSwiftValue]) in
                    do {
                        let identities = try others.map { other in
                            try other.withCopy { ObjectIdentifier($0 as AnyObject) }
                        }
                        state.values.withLock { $0.append(contentsOf: identities) }
                    } catch { Issue.record(error) }
                },
            ]
        )
        let identity = try value.withCopy { ObjectIdentifier($0 as AnyObject) }
        let invoke = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.invokeHostSelfDelegate(_:)",
                    as: ((NativeSwiftValue) -> Void).self
                )
            )
        )
        try unsafe invoke.unsafeInvoke(value)
        #expect(state.values.withLock { $0 } == [identity, identity, identity])
    }
}

private final class ProtocolIdentityState: Sendable {
    let values = Mutex<[ObjectIdentifier]>([])
}

#if DEBUG
extension SwiftProtocolValueTests {
    @Test func registeredConformanceDoesNotRetainTheCreatingResolver() throws {
        let receiver = makeHostDelegateReceiver()
        let state = ProtocolTestState()
        weak var observedResolver: SymbolResolver?
        do {
            let runtime = ABIRuntime()
            observedResolver = runtime.resolver
            let capture = ProtocolCapture(state)
            let value = try runtime.makeSwiftProtocolValueAndWait(
                "ManagedSwiftFixtures.HostDelegate",
                methods: [
                    try NativeSwiftProtocolMethod("receive(_:)") { (message: String) in
                        capture.receive(message)
                    }
                ]
            )
            try value.withCopy { erased in
                installHostDelegate(receiver, try #require(erased as? any HostDelegate))
            }
        }
        #expect(observedResolver == nil)
        #expect(invokeHostDelegate(receiver, "retained") == 3)
        #expect(state.messages.withLock { $0 } == ["retained", "retained:any", "retained:object"])
        #expect(state.destroyed.withLock { $0 } == 0)
        #expect(clearHostDelegate(receiver))
        #expect(state.destroyed.withLock { $0 } == 1)
    }
}
#endif

extension SwiftProtocolValueTests {
    @Test(arguments: [false, true])
    func consumingReceiverReleasesCapturesOnReturnAndThrow(fail: Bool) throws {
        let runtime = ABIRuntime()
        let state = ProtocolTestState()
        let finish = try runtime.resolveAndWait(
            .swift(
                .function(
                    "ManagedSwiftFixtures.finishHostDelegate(_:_:)",
                    as: ((NativeSwiftConsuming<NativeSwiftValue>, Bool) throws -> Void).self
                )
            )
        )
        do {
            let capture = ProtocolCapture(state)
            let value = try runtime.makeSwiftProtocolValueAndWait(
                "ManagedSwiftFixtures.HostConsumingDelegate",
                methods: [
                    try NativeSwiftProtocolMethod("finish(_:)", receiver: .consuming) {
                        (fail: Bool) throws in
                        capture.receive("finish")
                        if fail { throw URLError(.cancelled) }
                    }
                ]
            )
            do {
                try unsafe finish.unsafeInvoke(NativeSwiftConsuming(value), fail)
                #expect(!fail)
            } catch let error as NativeSwiftError {
                #expect(fail)
                error.withUnderlyingError { #expect(($0 as? URLError)?.code == .cancelled) }
            }
            #expect(value.isConsumed)
        }
        #expect(state.messages.withLock { $0 } == ["finish"])
        #expect(state.destroyed.withLock { $0 } == 1)
    }
}

#if os(macOS)
import ABIBridgeTestSupport

extension SwiftProtocolValueTests {
    @Test func nonresilientProtocolRequirementCanInvokeProjectedProxy() throws {
        let module =
            "ProjectedProtocol_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let fixture = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public protocol Delegate: AnyObject { func receive(_ value: String) }
                public final class CompiledDelegate: Delegate {
                    public init() {}
                    public func receive(_ value: String) {}
                }
                public final class OtherCompiledDelegate: Delegate {
                    public init() {}
                    public func receive(_ value: String) {}
                }
                """,
            linkArguments: ["-swift-version", "6"]
        )
        defer { fixture.cleanup() }
        let runtime = ABIRuntime()
        let state = ProtocolTestState()
        let value = try runtime.makeSwiftProtocolValueAndWait(
            module + ".Delegate",
            methods: [
                try NativeSwiftProtocolMethod("receive(_:)") { (value: String) in
                    state.messages.withLock { $0.append(value) }
                }
            ],
            in: .path(fixture.libraryURL)
        )
        let concrete = try value.copyUnderlyingValue()
        let method = try concrete.type.resolveAndWait(
            .swift(
                .method(
                    module + ".Delegate.receive(_:)",
                    as: ((String) -> Void).self
                )
            )
        )
        try unsafe method.unsafeInvoke(on: concrete, "forwarded")
        #expect(state.messages.withLock { $0 } == ["forwarded"])
    }
}
#endif
