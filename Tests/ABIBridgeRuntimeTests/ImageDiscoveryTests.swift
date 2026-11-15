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

    /// The loader names an image by the path it was loaded through, which can
    /// be a symlink of another name or, where the file system ignores case,
    /// another spelling of the file's name.
    @Test func pathSelectorMatchesTheImagesWhosePathsResolveToIt() throws {
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
        let named = image(at: alias, generation: 1)
        let unrelated = image(at: directory.appendingPathComponent("other.dylib"), generation: 2)
        let images = [
            named, unrelated,
            image(at: directory.appendingPathComponent("LIBRARY.DYLIB"), generation: 3),
        ]
        // Whether the other spelling names the file depends on the volume.
        let resolved = file.resolvingSymlinksInPath()
        let resolving = images.filter {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == resolved
        }
        let matched = try RuntimeImageSnapshot.matching(.path(file), in: images)
        #expect(matched.map(\.identity) == resolving.map(\.identity))
        #expect(matched.contains { $0.identity == named.identity })
        #expect(!matched.contains { $0.identity == unrelated.identity })
    }
}
