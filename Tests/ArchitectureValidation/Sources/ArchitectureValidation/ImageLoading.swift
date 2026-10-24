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
