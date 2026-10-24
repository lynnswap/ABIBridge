import ABIBridge
import Foundation
import Synchronization

/// The provider/caller frameworks are compiled separately for the device's
/// actual ABI. Their protocol calls must read conformance tables at runtime.
@MainActor func validateSwiftWitnessHooks() async throws -> [String] {
    let runtime = ABIRuntime()
    let root = Bundle.main.bundleURL.appendingPathComponent("Frameworks")
    let provider = ImageSelector.path(
        root.appendingPathComponent("SwiftImportProvider.framework/SwiftImportProvider")
    )
    let caller = ImageSelector.path(
        root.appendingPathComponent("SwiftImportCallerControl.framework/SwiftImportCallerControl")
    )
    let type = try await runtime.resolve(
        .swift(.type("SwiftImportProvider.WitnessValue")),
        in: provider
    )
    let prefix = "SwiftImportProvider.Witnessed."
    let failures = Mutex<[String]>([])
    let failure: @Sendable (any Error) -> Void = { error in
        failures.withLock { $0.append(String(describing: error)) }
    }
    var checks: [String] = []
    func check(_ result: Bool, _ message: String) throws {
        guard result else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let oracle = try await runtime.resolve(
        .swift(
            .function(
                "SwiftImportCallerControl.witnessRead(_:_:_:)",
                as: ((Int64, Int64, Int64) -> Int64).self
            )
        ),
        in: caller
    )
    let method = try await type.resolve(
        .swift(.method(prefix + "read(_:)", as: ((Int64) -> Int64).self))
    )
    let hook = try await unsafe method.hookVirtualCalls(onFailure: failure) {
        call,
        value in try call.proceed(value + 1) + 100
    }
    defer { hook.invalidate() }
    try check(
        try unsafe oracle.unsafeInvoke(0, 40, 2) == 143,
        "Witness method uses actual conformance slot"
    )
    try check(
        try unsafe oracle.unsafeInvoke(1, 40, 2) == 43,
        "Witness hook preserves another conformance"
    )
    let again = try await type.resolve(
        .swift(.method(prefix + "read(_:)", as: ((Int64) -> Int64).self))
    )
    let second = try await unsafe again.hookVirtualCalls(onFailure: failure) {
        call,
        value in try call.proceed(value * 2) + 1000
    }
    defer { second.invalidate() }
    try check(
        hook.address == second.address && (try unsafe oracle.unsafeInvoke(0, 40, 2)) == 1145,
        "Re-resolved witness slot joins its existing chain"
    )
    second.invalidate()
    let replacement = try await type.resolve(
        .swift(.method(prefix + "replacement(_:)", as: ((Int64) -> Int64).self))
    )
    let plan = try await unsafe method.prepareVirtualReplacement(with: replacement)
    let construct = try await type.resolve(
        .swift(.initializer("init(seed:)", as: ((Int64) -> NativeSwiftValue).self))
    )
    let value = try unsafe construct.unsafeInvoke(40)
    try check(
        try unsafe plan.original.unsafeInvoke(on: value, 2) == 143,
        "Witness replacement captures its predecessor chain"
    )
    try unsafe plan.install()
    defer { try? plan.restore() }
    try check(
        try unsafe oracle.unsafeInvoke(0, 40, 2) == 142,
        "Compiled witness replacement receives native requirement context"
    )
    try plan.restore()
    hook.invalidate()

    let getter = try await type.resolve(.swift(.getter(prefix + "value", as: (() -> Int64).self)))
    let setter = try await type.resolve(
        .swift(.setter(prefix + "value", as: ((Int64) -> Void).self))
    )
    let getHook = try await unsafe getter.hookVirtualCalls(onFailure: failure) { call in
        try call.proceed() + 10
    }
    defer { getHook.invalidate() }
    let setHook = try await unsafe setter.hookVirtualCalls(onFailure: failure) { call, value in
        try call.proceed(value + 100)
    }
    defer { setHook.invalidate() }
    let set = try await runtime.resolve(
        .swift(
            .function(
                "SwiftImportCallerControl.witnessSet(_:_:_:)",
                as: ((Int64, Int64, Int64) -> Int64).self
            )
        ),
        in: caller
    )
    try check(
        try unsafe set.unsafeInvoke(0, 40, 2) == 112,
        "Witness getter/setter preserve inout Self"
    )
    getHook.invalidate(); setHook.invalidate()

    let kind = try await type.resolve(
        .swift(.staticMethod(prefix + "kind(_:)", as: ((Int64) -> Int64).self))
    )
    let kindHook = try await unsafe kind.hookVirtualCalls(onFailure: failure) { call, value in
        try call.proceed(value) + 200
    }
    defer { kindHook.invalidate() }
    let kindOracle = try await runtime.resolve(
        .swift(.function("SwiftImportCallerControl.witnessKind(_:)", as: ((Int64) -> Int64).self)),
        in: caller
    )
    try check(
        try unsafe kindOracle.unsafeInvoke(2) == 212,
        "Static requirement preserves metatype and conformance context"
    )
    let initializer = try await type.resolve(
        .swift(.initializer(prefix + "init(seed:)", as: ((Int64) -> NativeSwiftValue).self))
    )
    let initHook = try await unsafe initializer.hookVirtualCalls(onFailure: failure) {
        call,
        value in try call.proceed(value + 300)
    }
    defer { initHook.invalidate() }
    let initOracle = try await runtime.resolve(
        .swift(.function("SwiftImportCallerControl.witnessInit(_:)", as: ((Int64) -> Int64).self)),
        in: caller
    )
    try check(
        try unsafe initOracle.unsafeInvoke(2) == 302,
        "Initializer requirement returns owned runtime value through witness slot"
    )
    initHook.invalidate()

    let asynchronous = try await type.resolve(
        .swift(
            .method(
                prefix + "asyncRead(_:)",
                as: (nonisolated(nonsending) (Int64) async -> Int64).self
            )
        )
    )
    let asyncHook = try await unsafe asynchronous.hookVirtualCalls(onFailure: failure) {
        call,
        value in
        await Task.yield()
        return try await call.proceed(value + 1) + 400
    }
    defer { asyncHook.invalidate() }
    let asyncOracle = try await runtime.resolve(
        .swift(
            .function(
                "SwiftImportCallerControl.witnessAsync(_:_:_:)",
                as: (nonisolated(nonsending) (Int64, Int64, Int64) async -> Int64).self
            )
        ),
        in: caller
    )
    try check(
        try await unsafe asyncOracle.unsafeInvoke(0, 40, 2) == 463,
        "Async witness authenticates descriptor and preserves suspension"
    )
    asyncHook.invalidate()
    try check(
        try await unsafe asyncOracle.unsafeInvoke(0, 40, 2) == 62,
        "Invalidated async witness retains callable descriptor"
    )

    for (name, which) in [("WitnessBox", Int64(2)), ("WitnessConditional", Int64(4))] {
        let bound = try await runtime.resolve(
            .swift(.type("SwiftImportProvider." + name, genericArguments: [.type(Int64.self)])),
            in: provider
        )
        let boundMethod = try await bound.resolve(
            .swift(.method(prefix + "read(_:)", as: ((Int64) -> Int64).self))
        )
        let boundHook = try await unsafe boundMethod.hookVirtualCalls(onFailure: failure) {
            call,
            value in try call.proceed(value) + 500
        }
        defer { boundHook.invalidate() }
        let offset: Int64 = which == 2 ? 2 : 3
        try check(
            try unsafe oracle.unsafeInvoke(which, 40, 2) == 542 + offset,
            "\(name) hooks instantiated conformance table"
        )
        try check(
            try unsafe oracle.unsafeInvoke(which + 1, 40, 2) == 42 + offset,
            "\(name) handler filters incoming Self binding"
        )
        boundHook.invalidate()
    }
    let sharedInt = try await runtime.resolve(
        .swift(.type("SwiftImportProvider.WitnessShared", genericArguments: [.type(Int64.self)])),
        in: provider
    )
    let sharedString = try await runtime.resolve(
        .swift(.type("SwiftImportProvider.WitnessShared", genericArguments: [.type(String.self)])),
        in: provider
    )
    let sharedName = "SwiftImportProvider.SharedWitnessed.read(_:)"
    let sharedMethod = try await sharedInt.resolve(
        .swift(.method(sharedName, as: ((Int64) -> Int64).self))
    )
    let sharedOther = try await sharedString.resolve(
        .swift(.method(sharedName, as: ((Int64) -> Int64).self))
    )
    let sharedHook = try await unsafe sharedMethod.hookVirtualCalls(onFailure: failure) {
        call,
        value in try call.proceed(value) + 600
    }
    defer { sharedHook.invalidate() }
    let sharedOtherHook = try await unsafe sharedOther.hookVirtualCalls(onFailure: failure) {
        call,
        value in try call.proceed(value) + 700
    }
    defer { sharedOtherHook.invalidate() }
    let sharedOracle = try await runtime.resolve(
        .swift(
            .function(
                "SwiftImportCallerControl.witnessShared(_:_:_:)",
                as: ((Bool, Int64, Int64) -> Int64).self
            )
        ),
        in: caller
    )
    try check(
        sharedHook.address == sharedOtherHook.address,
        "Generic bindings share the actual physical conformance slot"
    )
    try check(
        try unsafe sharedOracle.unsafeInvoke(false, 40, 2) == 642,
        "Shared table selects Int64 Self handler"
    )
    try check(
        try unsafe sharedOracle.unsafeInvoke(true, 40, 2) == 742,
        "Shared table selects String Self handler"
    )
    sharedHook.invalidate(); sharedOtherHook.invalidate()
    try check(
        failures.withLock { $0.isEmpty },
        "Witness callbacks preserve native ABI without conversion failures"
    )
    return checks
}
