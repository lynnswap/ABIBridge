import ABIBridge
import Foundation
import Testing

#if os(macOS)
/// Compares each ABIBridge call with a natively compiled call of the same
/// declaration, for every provider build variant.
///
/// A cell that does not pass yet records the issue expected to fix it. When a
/// change makes such a cell pass, the unrecorded known issue fails the test
/// until its expectation is removed. A cell whose convention the variant's
/// binary evidence cannot decide expects a failure that names the evidence.
@Suite(.serialized)
struct ConformanceMatrixTests {
    @Test(arguments: ConformanceCase.all, ConformanceVariant.selected)
    func nativeCallsMatchCompiledCallers(
        _ item: ConformanceCase,
        _ variant: ConformanceVariant
    ) async throws {
        let fixture = try await ConformanceFixtures.shared.fixture(for: variant)
        let expected = fixture.expected(item.id)
        try #require(expected != "unknown case")
        if let evidence = item.expectedError(variant) {
            await #expect {
                _ = try await item.invoke(fixture)
            } throws: { error in
                guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                    return false
                }
                return message.contains(evidence)
            }
        } else if let reason = item.knownIssue(variant) {
            await withKnownIssue(Comment(rawValue: reason)) {
                do { #expect(try await item.invoke(fixture) == expected) } catch {
                    Issue.record(error)
                }
            }
        } else {
            #expect(try await item.invoke(fixture) == expected)
        }
    }
}
#endif
