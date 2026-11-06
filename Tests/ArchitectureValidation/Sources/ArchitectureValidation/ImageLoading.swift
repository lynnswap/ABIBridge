import ABIBridge
import ArchitectureFixtures
import Foundation

/// Runs in a fresh host process that embeds, but does not link, the fixture framework.
@MainActor public func runImageLoadingValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let framework = "ABIBridgeLoadingFixture"
    let relative = "Frameworks/\(framework).framework/\(framework)"
    let binary = Bundle.main.bundleURL.appendingPathComponent(relative)
    var checks: [String] = []
    func check(_ value: Bool, _ name: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: name) }
        checks.append(name)
    }
    try check(
        try runtime.resolveImagesAndWait(matching: .path(binary)).isEmpty,
        "Fixture starts unloaded"
    )
    do {
        _ = try runtime.resolveAndWait(
            .c(.function("ABIImageLoadingFixtureValue", as: (() -> Int32).self)),
            in: .path(binary),
            loading: .loadedOnly
        )
        throw ArchitectureValidationFailure(
            description: "Inspection unexpectedly loaded the fixture"
        )
    } catch ABIResolutionError.imageNotLoaded {
        checks.append("Loaded-only lookup leaves the fixture unloaded")
    }
    let value = try runtime.resolveAndWait(
        .c(.function("ABIImageLoadingFixtureValue", as: (() -> Int32).self)),
        in: .framework(named: framework)
    )
    try check(
        try unsafe value.unsafeInvoke() == 42,
        "Framework acquisition runs the constructor before invocation"
    )
    let pathRequest = NativeRequest.c(.symbol("ABIImageLoadingFixtureValue"))
    let expectedAddress = unsafe value.symbol.withUnsafeAddress { UInt(bitPattern: $0) }
    _ = try runtime.resolveAndWait(pathRequest, in: .path(binary))
    let pathStart = ContinuousClock.now
    for _ in 0..<10000 {
        let symbol = try runtime.resolveAndWait(pathRequest, in: .path(binary))
        let actualAddress = unsafe symbol.withUnsafeAddress { UInt(bitPattern: $0) }
        guard actualAddress == expectedAddress else {
            throw ArchitectureValidationFailure(
                description: "Warmed path changed the symbol address"
            )
        }
    }
    let pathDuration = pathStart.duration(to: .now).components
    let pathMicroseconds =
        (Double(pathDuration.seconds) + Double(pathDuration.attoseconds) / 1e18) * 1e6 / 10000
    checks.append("10,000 warmed path lookups preserved the address: \(pathMicroseconds) us mean")
    for target in [
        ImageSelector.path(binary), .installName("@rpath/\(framework).framework/\(framework)"),
        .installName("@executable_path/\(relative)"), .installName("@loader_path/\(relative)"),
    ] {
        let count = try runtime.resolveAndWait(
            .c(.function("ABIImageLoadingFixtureConstructorCount", as: (() -> Int32).self)),
            in: target
        )
        try check(
            count.symbol.image.identity == value.symbol.image.identity,
            "Path/install-name identity: \(target)"
        )
        try check(
            try unsafe count.unsafeInvoke() == 1,
            "Repeated acquisition does not rerun the constructor"
        )
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let alias = directory.appendingPathComponent("library")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: binary)
    _ = try runtime.resolveAndWait(pathRequest, in: .path(alias))
    guard let executable = Bundle.main.executableURL else {
        throw ArchitectureValidationFailure(description: "Host executable URL is unavailable")
    }
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
    runtime.removeCachedResults()
    let add = try runtime.resolveAndWait(
        .c(.function("ABIValidationAdd", as: ((Int32, Int32) -> Int32).self)),
        in: .path(alias)
    )
    try check(
        try unsafe add.unsafeInvoke(20, 22) == 42,
        "Explicit invalidation resolves the changed symbolic-link target"
    )
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: binary)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var notified = false
    while ContinuousClock.now < deadline {
        do {
            _ = try runtime.resolveAndWait(pathRequest, in: .path(alias))
            notified = true
            break
        } catch ABIResolutionError.declarationNotFound {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    try check(
        notified,
        "File notification resolves the changed target without explicit invalidation"
    )
    runtime.removeCachedResults()
    try check(
        try unsafe value.unsafeInvoke() == 42,
        "Function remains callable after cache removal"
    )
    return ArchitectureReport(
        mode: "loading",
        cpuType: ABIValidationCPUType(),
        cpuSubtype: ABIValidationCPUSubtype(),
        pacCompiled: ABIValidationPACCompiled(),
        checks: checks,
        allocationTag: nil
    )
}
