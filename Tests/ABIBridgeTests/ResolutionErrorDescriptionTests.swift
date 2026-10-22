import ABIBridge
import ABIBridgeTestSupport
import Foundation
import Testing

/// A resolution failure describes itself, naming the image or declaration
/// involved and the details its case carries.
@Suite(.serialized)
struct ResolutionErrorDescriptionTests {
    private static let declaration = NativeDeclaration(
        name: "Example.render(Swift.Int) -> Swift.Int",
        language: .swift
    )

    // Each case's description. The explicit type keeps type checking fast.
    private static let descriptions: [(ABIResolutionError, String)] = [
        (
            .imageUnavailable,
            "The image catalog or a registered image is not currently available for lookup."
        ),
        (.imageNotLoaded, "No loaded image matches the requested scope."),
        (
            .imageLoadFailed(target: "/Library/Example.dylib", message: "image not found"),
            "Cannot load /Library/Example.dylib: image not found"
        ),
        (
            .ambiguousImage(candidates: ["/A/Example", "/B/Example"]),
            "More than one image matches the framework name: /A/Example, /B/Example."
                + " Select one by its path."
        ),
        (
            .invalidImageTarget("Example/Sub"),
            "The image target Example/Sub is not a valid framework name, install name, or file URL."
        ),
        (.declarationNotFound(declaration), "Cannot find Example.render(Swift.Int) -> Swift.Int."),
        (
            .ivarNotFound(name: "_missing", className: "NSView"),
            "NSView and its superclasses have no ivar named _missing."
        ),
        (
            .ambiguousDeclaration(
                declaration,
                candidates: ["/A/libExample.dylib", "/B/libExample.dylib"]
            ),
            "More than one definition matches Example.render(Swift.Int) -> Swift.Int:"
                + " /A/libExample.dylib, /B/libExample.dylib."
        ),
        (
            .signatureMismatch(
                .init(
                    declaration: declaration,
                    position: .argument(0),
                    expected: "Swift.Int, passed in registers (8-byte integer at 0)",
                    found: ["Swift.Double, passed in registers (8-byte float at 0)"]
                )
            ),
            "Example.render(Swift.Int) -> Swift.Int does not match the requested signature"
                + " at argument 0: expected Swift.Int, passed in registers (8-byte integer at 0),"
                + " found Swift.Double, passed in registers (8-byte float at 0)."
        ),
        // A standalone check has no declaration, and may find nothing.
        (
            .signatureMismatch(.init(position: .receiver, expected: "A class type", found: [])),
            "The requested signature does not match at self: expected A class type."
        ),
        (
            .unsupportedDeclaration("Lookup cannot lower this value."),
            "Lookup cannot lower this value."
        ),
        (.metadataUnavailable("The metadata is missing."), "The metadata is missing."),
        (
            .imageChanged,
            "The image was unloaded or replaced before a loader reference could be acquired."
        ),
        (
            .invalidAddress,
            "The address of the matching symbol does not hold the requested kind of storage."
        ),
    ]

    @Test(arguments: descriptions)
    func describesEachCase(_ error: ABIResolutionError, as message: String) {
        #expect(error.localizedDescription == message)
        #expect(String(describing: error) == message)
    }

    @Test func loadFailuresReportTheLoaderDiagnosticAsTheReason() {
        let error = ABIResolutionError.imageLoadFailed(
            target: "/Library/Example.dylib",
            message: "image not found"
        )
        #expect((error as NSError).localizedFailureReason == "image not found")
    }

    #if os(macOS)
    /// A host that shows only `localizedDescription` learns which declaration
    /// failed and why. Like the imported C types of a stripped system
    /// framework, the declared enum has no exported descriptor, so the
    /// convention of its host type must come from a valueABIs entry.
    @Test func failedResolutionsNameTheDeclarationAndReason() async throws {
        let header = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".h")
        try """
        #include <stdint.h>
        typedef enum : uint32_t { DescribedTargetMain = 7 } DescribedTarget;
        """.write(to: header, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: header) }
        let module = "Described_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: """
                public final class Screen {
                    public init() {}
                    public var target: DescribedTarget { DescribedTargetMain }
                }
                """,
            stripped: true,
            linkArguments: ["-parse-as-library", "-import-objc-header", header.path]
        )
        defer { library.cleanup() }
        let screen = try await ABIRuntime().resolveSwiftType(
            named: module + ".Screen",
            in: .path(library.libraryURL)
        )
        let getter = "target.getter : __C.DescribedTarget"
        await #expect {
            _ = try await screen.resolveGetter(named: getter, as: (() -> UInt32).self)
        } throws: { error in
            error.localizedDescription.hasPrefix("\(module).Screen.\(getter): Cannot compare")
                && error.localizedDescription.hasSuffix(
                    "state its convention with a valueABIs entry for Swift.UInt32."
                )
        }
    }
    #endif
}
