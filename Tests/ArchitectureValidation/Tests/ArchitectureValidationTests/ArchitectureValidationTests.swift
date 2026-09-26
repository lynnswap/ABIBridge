import ArchitectureValidation
import Testing

@Test(arguments: ["native", "swift", "ffi", "memory"])
@MainActor func nativeArchitectureContracts(mode: String) async throws {
    let report = try await runArchitectureValidation(mode: mode)
    #expect(report.mode == mode)
    #expect(!report.checks.isEmpty)
}
