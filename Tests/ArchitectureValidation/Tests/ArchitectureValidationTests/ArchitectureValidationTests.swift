import ArchitectureValidation
import Testing

@Test(arguments: ["native", "swift", "ffi", "memory", "replacement", "hooks", "initializers", "native-hooks", "coordinated-hooks", "import-replacement", "import-hooks", "virtual-replacement", "virtual-hooks", "virtual-entries", "virtual-public"])
@MainActor func nativeArchitectureContracts(mode: String) async throws {
    let report = try await runArchitectureValidation(mode: mode)
    #expect(report.mode == mode)
    #expect(!report.checks.isEmpty)
}
