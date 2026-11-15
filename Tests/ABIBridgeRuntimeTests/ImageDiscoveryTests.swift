import ABIBridgeCore
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

    /// The loader can name an image by the symlink it was loaded through,
    /// whose last component differs from the file's.
    @Test func pathSelectorMatchesAnImageNamedByASymlinkOfAnotherName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.dylib")
        try Data().write(to: file)
        let alias = directory.appendingPathComponent("alias.dylib")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        func image(at url: URL, generation: UInt64) -> RuntimeImageSnapshot {
            url.path.withCString { path in
                var info = ABIImageInfo()
                info.generation = generation
                info.path = path
                return RuntimeImageSnapshot(info)
            }
        }
        let images = [
            image(at: alias, generation: 1),
            image(at: directory.appendingPathComponent("other.dylib"), generation: 2),
        ]
        let matched = try RuntimeImageSnapshot.matching(.path(file), in: images)
        #expect(matched.map(\.identity) == [images[0].identity])
    }
}
