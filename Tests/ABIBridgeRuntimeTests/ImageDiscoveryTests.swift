import ABIBridgeRuntime
import Foundation
import Testing

struct ImageDiscoveryTests {
    @Test func frameworkDiscoveryPreservesAmbiguousCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "Framework_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let roots = [
            directory.appendingPathComponent("one"), directory.appendingPathComponent("two"),
        ]
        for root in roots {
            let framework = root.appendingPathComponent(name + ".framework")
            try FileManager.default.createDirectory(
                at: framework,
                withIntermediateDirectories: true
            )
            try Data().write(to: framework.appendingPathComponent(name))
        }
        #expect(FrameworkImages.candidates(named: name, bundleDirectories: roots).count == 2)
    }

}
