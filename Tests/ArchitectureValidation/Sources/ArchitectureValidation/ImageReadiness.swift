import ABIBridge
import ABIBridgeCore
import ArchitectureFixtures
import Foundation
import Synchronization

/// Uses the signed, initially unloaded caller control embedded by the device host.
@MainActor public func runImageReadinessValidation() async throws -> ArchitectureReport {
    let runtime = ABIRuntime()
    let binary = Bundle.main.bundleURL.appendingPathComponent("Frameworks/SwiftImportCallerControl.framework/SwiftImportCallerControl")
    let scope = ImageSelector.path(binary)
    var checks: [String] = []
    func check(_ value: Bool, _ message: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    try check(try await runtime.images(matching: scope).isEmpty, "Readiness fixture starts unloaded")
    let baseline = ABIImportedUIDCall()
    let installed = Mutex(false)
    let failures = Mutex<[String]>([])
    let monitor = try await unsafe runtime.monitorImportedFunction(.init(name: "getuid", language: .c), as: (() -> UInt32).self,
        in: scope, onFailure: { error in failures.withLock { $0.append(String(describing: error)) } },
        onImageUpdate: { update in
            switch update.state {
            case .installed: installed.withLock { $0 = true }
            case .failed(let error): failures.withLock { $0.append(String(describing: error)) }
            default: break
            }
        }) { call in try call.proceed() + 7 }
    defer { monitor.invalidate() }
    let call = try await runtime.cFunction(named: "ABIReadinessUID", as: (() -> UInt32).self, in: scope)
    let count = try await runtime.cFunction(named: "ABIReadinessInitializationCount", as: (() -> Int32).self, in: scope)
    let deadline = ContinuousClock.now + .seconds(10)
    while !installed.withLock({ $0 }) && failures.withLock({ $0.isEmpty }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try check(failures.withLock { $0.isEmpty }, "Initializing image produces no permanent monitor installation failure: \(failures.withLock { $0 })")
    try check(installed.withLock { $0 }, "Monitor installs after the initially loading image becomes acquirable")
    try check(try unsafe count.unsafeInvoke() == 1, "The delayed constructor completed exactly once")
    try check(try unsafe call.unsafeInvoke() == baseline + 7, "Post-initialization calls reach the monitored import")

    let alias = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dylib.alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: binary)
    let outcome: Result<Void, any Error>
    do {
        let aliased = try await runtime.cFunction(named: "ABIReadinessUID", as: (() -> UInt32).self,
            in: .path(alias), loading: .loadedOnly)
        try check(aliased.symbol.image.identity == call.symbol.image.identity, "Loaded-only suffix alias resolves to the same ready image")
        try check(try unsafe aliased.unsafeInvoke() == baseline + 7, "Loaded-only alias remains callable through monitored imports")
        try check(try unsafe count.unsafeInvoke() == 1, "Alias lookup does not rerun initialization")
        outcome = .success(())
    } catch { outcome = .failure(error) }
    do { try FileManager.default.removeItem(at: alias) }
    catch {
        if case .failure(let original) = outcome {
            throw ArchitectureValidationFailure(description: "\(original); alias cleanup: \(error)")
        }
        throw error
    }
    try outcome.get()
    monitor.invalidate()
    try check(try unsafe call.unsafeInvoke() == baseline, "Monitor invalidation preserves ordinary imported dispatch")
    return ArchitectureReport(mode: "image-readiness", cpuType: ABIValidationCPUType(), cpuSubtype: ABIValidationCPUSubtype(),
        pacCompiled: ABIValidationPACCompiled(), checks: checks, allocationTag: nil)
}
