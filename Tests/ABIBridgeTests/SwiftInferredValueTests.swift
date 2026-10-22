#if DEBUG
@testable import ABIBridge
import ABIBridgeCore
#else
import ABIBridge
#endif
import ABIBridgeTestSupport
import Foundation
import Testing

#if os(macOS)
/// A host struct that shares a provider point's layout under another name.
public struct InferredAdapterPoint {
    public var x: Double
    public var y: Double
}

/// Values whose conventions inference cannot establish fail during
/// preparation, naming the type, the missing evidence or unsupported kind, and
/// the explicit ABI that describes them instead.
@Suite(.serialized)
struct SwiftInferredValueTests {
    private let runtime = ABIRuntime()

    private func provider(
        _ source: String,
        arguments: [String] = [],
        modulePrefix: String = "Inferred_"
    ) throws -> (
        library: FixtureLibrary, module: String
    ) {
        let module = modulePrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: source,
            linkArguments: ["-parse-as-library", "-swift-version", "6"] + arguments
        )
        return (library, module)
    }

    private func expectFailure<Signature>(
        _ declaration: String,
        in library: FixtureLibrary,
        as signature: Signature.Type,
        unsupported: Bool = false,
        naming evidence: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await #expect(sourceLocation: sourceLocation) {
            _ = try await runtime.resolveSwiftFunction(
                named: declaration,
                as: signature,
                in: .path(library.libraryURL)
            )
        } throws: { error in
            let message: String
            switch error {
            case ABIResolutionError.unsupportedDeclaration(let text) where unsupported:
                message = text
            case ABIResolutionError.metadataUnavailable(let text) where !unsupported: message = text
            default: return false
            }
            return message.contains(evidence)
                && message.contains("valueABIs or an ABIBridgeSwiftValue conformance")
        }
    }

    /// Passes the result of `make` to `describe`, both taking runtime values.
    private func describeMade(
        _ make: String,
        _ describe: String,
        in library: FixtureLibrary
    ) async throws -> String {
        let make = try await runtime.resolveSwiftFunction(
            named: make,
            as: (() -> NativeSwiftValue).self,
            in: .path(library.libraryURL)
        )
        let describe = try await runtime.resolveSwiftFunction(
            named: describe,
            as: ((NativeSwiftValue) -> String).self,
            in: .path(library.libraryURL)
        )
        return try unsafe describe.unsafeInvoke(make.unsafeInvoke())
    }

    @Test func fieldsWithoutReflectionRecordsAreNotInferred() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct Bare {
                public var x: Double
                public var y: Double
                public init() { x = 1; y = 2 }
            }
            @inline(never) public func makeBare() -> Bare { Bare() }
            """,
            arguments: ["-Xfrontend", "-disable-reflection-metadata"]
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeBare()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "\(module).Bare in module \(module): it has no reflection field descriptor"
        )
    }

    /// Field records omit packing, bitfields, and NSDecimal's leading bytes.
    @Test func importedCStructFieldsAreNotInferred() async throws {
        let header = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".h")
        try """
        #include <stdint.h>
        typedef struct __attribute__((packed)) { uint8_t tag; float value; } PackedTag;
        typedef struct { uint8_t a, b; unsigned bits: 4, more: 4; } BitFlags;
        """.write(to: header, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: header) }
        let (library, module) = try provider(
            """
            import Foundation
            @frozen public struct HoldsPacked { public var packed: PackedTag; public var extra: Int8 }
            @frozen public struct HoldsFlags { public var flags: BitFlags }
            @frozen public struct HoldsDecimal { public var decimal: Decimal }
            @inline(never) public func makePacked() -> HoldsPacked {
                HoldsPacked(packed: PackedTag(tag: 1, value: 2.5), extra: 3)
            }
            @inline(never) public func makeFlags() -> HoldsFlags {
                HoldsFlags(flags: BitFlags(a: 1, b: 2, bits: 3, more: 4))
            }
            @inline(never) public func makeDecimal() -> HoldsDecimal { HoldsDecimal(decimal: Decimal(42)) }
            """,
            arguments: ["-import-objc-header", header.path]
        )
        defer { library.cleanup() }
        for (name, field) in [
            ("makePacked()", "packed: __C.PackedTag"),
            ("makeFlags()", "flags: __C.BitFlags"),
            ("makeDecimal()", "decimal: __C.NSDecimal"),
        ] {
            await expectFailure(
                "\(module).\(name)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                unsupported: true,
                naming:
                    "its field `\(field)` cannot be lowered: imported C structs and unions are not inferred"
            )
        }
    }

    @Test func vectorAndWideScalarFieldsAreNotInferred() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct Vectors {
                public var vector: SIMD4<Float>
                public init() { vector = SIMD4(1, 2, 3, 4) }
            }
            @frozen public struct Halves {
                public var half: Float16
                public init() { half = 1.5 }
            }
            @inline(never) public func makeVectors() -> Vectors { Vectors() }
            @inline(never) public func makeHalves() -> Halves { Halves() }
            """
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeVectors()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            unsupported: true,
            naming: "its field `vector: Swift.SIMD4<Swift.Float>` cannot be lowered"
        )
        await expectFailure(
            module + ".makeHalves()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            unsupported: true,
            naming: "SIMD vectors, Float16, and Int128 are not inferred"
        )
    }

    @Test func noncopyableValuesAreNotInferred() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct Unique: ~Copyable {
                public var value: Int64
                public init() { value = 1 }
            }
            @inline(never) public func makeUnique() -> Unique { Unique() }
            """
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeUnique()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            unsupported: true,
            naming: "noncopyable values are not inferred"
        )
    }

    /// Library evolution also gives unowned, static, and computed properties
    /// trivial descriptors, so they do not show that a module is built
    /// without it. Open's addressable bit then leaves its resilience open.
    @Test func trivialDescriptorsOfOtherPropertiesDoNotProveAFixedLayout() async throws {
        let (library, module) = try provider(
            """
            import Foundation
            public struct UnownedHolder {
                public unowned let owner: NSObject
                public init(owner: NSObject) { self.owner = owner }
            }
            public struct Statics {
                public static let shared = 1
            }
            public struct Open {
                var x: Double
                public var doubled: Double { x * 2 }
                public init() { x = 1 }
            }
            @inline(never) public func makeOpen() -> Open { Open() }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeOpen()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "module `\(module)` does not show whether it is built with library evolution"
        )
    }

    /// Without evidence of how a module is built, the failure does not call
    /// it a library-evolution module.
    @Test func undecidedModulesAreNotCalledLibraryEvolutionModules() async throws {
        let (library, module) = try provider(
            """
            public struct Open {
                var text: String
                var x: Double
                public init() { text = "open"; x = 1 }
            }
            @inline(never) public func makeOpen() -> Open { Open() }
            """
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeOpen()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming:
                "Cannot infer the Swift calling convention of \(module).Open in module \(module): module `\(module)` does not show whether it is built with library evolution, or whether struct `\(module).Open` is @frozen; its field `text: Swift.String` explains"
        )
    }

    /// Key paths reabstract a stored `let` of these types, so library
    /// evolution gives it a trivial descriptor like a computed property.
    @Test(arguments: [
        "public let callback: () -> Void = {}",
        "public let type: Int.Type = Int.self",
        "public let optional: (() -> Int)? = nil",
        "public let pair: (Int, (Int) -> Int) = (1, { $0 })",
    ])
    func trivialDescriptorsOfReabstractedLetsDoNotProveAFixedLayout(
        _ property: String
    ) async throws {
        let (library, module) = try provider(
            """
            public struct Holder {
                \(property)
                public init() {}
            }
            public struct Open {
                var x: Double
                var y: Double
                public init() { x = 1; y = 2 }
            }
            @inline(never) public func makeOpen() -> Open { Open() }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeOpen()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "module `\(module)` does not show whether it is built with library evolution"
        )
    }

    /// Before Swift 6.2, no value witnesses set the addressable bit, so its
    /// absence certifies nothing in a module where no type sets it.
    @Test func modulesThatNeverSetTheAddressableBitAreNotTrusted() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct Point {
                public var x: Double
                public var y: Double
                public init() { x = 1; y = 2 }
            }
            @inline(never) public func makePoint() -> Point { Point() }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makePoint()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming:
                "module `\(module)` never sets the addressable-for-dependencies value-witness bit"
        )
    }

    /// Static metadata places empty fields at offset 0 after other fields.
    @Test func emptyFieldsFollowingOtherFieldsAreInferred() async throws {
        let (library, module) = try provider(
            """
            public struct Empty { public init() {} }
            @frozen public struct WithEmpty {
                public var e: Empty
                public var f: Float
                public var g: Empty
                public var unit: ()
                public var h: Int8
                public init() { e = Empty(); f = 1.5; g = Empty(); unit = (); h = 7 }
            }
            @inline(never) public func makeWithEmpty() -> WithEmpty { WithEmpty() }
            @inline(never) public func describeWithEmpty(_ v: WithEmpty) -> String { "\\(v.f),\\(v.h)" }
            """
        )
        defer { library.cleanup() }
        #expect(
            try await describeMade(
                module + ".makeWithEmpty()",
                module + ".describeWithEmpty(_:)",
                in: library
            ) == "1.5,7"
        )
    }

    /// A module's symbols spell a word that repeats in its name as a
    /// substitution, which its evidence lookup must reproduce.
    @Test(arguments: [false, true])
    func modulesWithRepeatedWordsKeepTheirEvidence(evolution: Bool) async throws {
        let (library, module) = try provider(
            """
            public struct Labeled {
                public var text: String
                public var x: Double
                public init() { text = "label"; x = 1.5 }
            }
            public struct Plain {
                public var x: Double
                public var y: Double
                public init() { x = 2.5; y = 3.5 }
            }
            @inline(never) public func makeLabeled() -> Labeled { Labeled() }
            @inline(never) public func describeLabeled(_ v: Labeled) -> String { "\\(v.text),\\(v.x)" }
            @inline(never) public func makePlain() -> Plain { Plain() }
            @inline(never) public func describePlain(_ v: Plain) -> String { "\\(v.x),\\(v.y)" }
            """,
            arguments: evolution ? ["-enable-library-evolution"] : [],
            modulePrefix: "Inferred_F8F8_"
        )
        defer { library.cleanup() }
        // A library-evolution module does not record whether Labeled is frozen.
        if !evolution {
            #expect(
                try await describeMade(
                    module + ".makeLabeled()",
                    module + ".describeLabeled(_:)",
                    in: library
                ) == "label,1.5"
            )
        }
        #expect(
            try await describeMade(
                module + ".makePlain()",
                module + ".describePlain(_:)",
                in: library
            ) == "2.5,3.5"
        )
    }

    /// `Data` sets the addressable bit for itself, whatever it stores, so
    /// the bit does not show whether it is resilient, and neither it nor a
    /// value that stores it is inferred.
    @Test func selfAddressableTypesStayUndecided() async throws {
        let (library, module) = try provider(
            """
            import Foundation
            @frozen public struct DataBox {
                public var data: Data
                public var n: Int64
                public init(data: Data, n: Int64) { self.data = data; self.n = n }
            }
            @inline(never) public func dataCount(_ d: Data) -> Int { d.count }
            @inline(never) public func makeData(_ n: Int) -> Data { Data(repeating: 1, count: n) }
            @inline(never) public func makeDataBox() -> DataBox { DataBox(data: Data([1, 2, 3]), n: 4) }
            """
        )
        defer { library.cleanup() }
        let evidence = "its own @_addressableForDependencies attribute explains"
        await expectFailure(
            module + ".dataCount(_:)",
            in: library,
            as: ((Data) -> Int).self,
            naming: evidence
        )
        await expectFailure(
            module + ".makeData(_:)",
            in: library,
            as: ((Int) -> Data).self,
            naming: evidence
        )
        await expectFailure(
            module + ".makeDataBox()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: evidence
        )
    }

    /// An Optional or tuple field explains the addressable bit through the
    /// values it holds, which leaves these frozen structs undecided rather
    /// than resilient.
    @Test func optionalAndTupleFieldsExplainTheAddressableBit() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct OptionalText {
                public var text: String?
                public var n: Int64
                public init() { text = "o"; n = 1 }
            }
            @frozen public struct TupleText {
                public var pair: (String, Int64)
                public init() { pair = ("t", 2) }
            }
            @inline(never) public func makeOptionalText() -> OptionalText { OptionalText() }
            @inline(never) public func makeTupleText() -> TupleText { TupleText() }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        for (make, field) in [
            ("makeOptionalText()", "text: Swift.Optional<Swift.String>"),
            ("makeTupleText()", "pair: (Swift.String, Swift.Int64)"),
        ] {
            await expectFailure(
                "\(module).\(make)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming: "its field `\(field)` explains"
            )
        }
    }

    /// A library that exports its public types' descriptors but not a type's
    /// shows that the type is not public, so it is not resilient.
    @Test func unexportedTypesOfLibrariesAreNotResilient() async throws {
        let (library, module) = try provider(
            """
            public struct Visible {
                public var x: Int64
                public init() { x = 1 }
            }
            struct Hidden {
                var text: String
                var n: Int64
            }
            @inline(never) func makeHidden() -> Hidden { Hidden(text: "h", n: 9) }
            @inline(never) func describeHidden(_ h: Hidden) -> String { "\\(h.text),\\(h.n)" }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        #expect(
            try await describeMade(
                module + ".makeHidden()",
                module + ".describeHidden(_:)",
                in: library
            ) == "h,9"
        )
    }

    /// Another module's extension of a library-evolution module's types
    /// exports symbols in that module's context, and a link can hide the
    /// module's own symbols. Neither shows how the module was built or which
    /// of its types are public.
    @Test(arguments: ["extended", "hidden", "hiddenDescriptor"])
    func staticallyLinkedModulesKeepTheirOwnEvidence(link: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Lowercase keeps the module's mangling free of word substitutions.
        let base =
            "inferredbase_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let baseSource = directory.appendingPathComponent("Base.swift")
        // Base shows no library-evolution evidence of its own: it has no
        // public stored property, enum, class, or protocol.
        try """
        public struct Point {
            var x: Double
            var y: Double
            public init(x: Double, y: Double) { self.x = x; self.y = y }
            public var sum: Double { x + y }
        }
        public struct Label {
            var name: String
            var n: Int64
            public init(name: String, n: Int64) { self.name = name; self.n = n }
            public var count: Int64 { Int64(name.count) + n }
        }
        """.write(to: baseSource, atomically: true, encoding: .utf8)
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        try FixtureLibrary.run([
            "--sdk", "macosx", "swiftc", "-module-name", base,
            "-target", "\(architecture)-apple-macosx15.4", "-parse-as-library", "-swift-version",
            "6", "-enable-library-evolution", "-emit-library", "-static", "-emit-module",
            "-emit-module-path", directory.appendingPathComponent(base + ".swiftmodule").path,
            baseSource.path, "-o", directory.appendingPathComponent("lib\(base).a").path,
        ])
        let (extensions, linkArguments): (String, [String]) =
            switch link {
            // A stored property of a struct nested in this extension has a
            // trivial descriptor, which another module would only have
            // without library evolution.
            case "extended":
                (
                    """
                    extension Point {
                        public struct Builder {
                            public var scale: Int
                            public init(scale: Int) { self.scale = scale }
                        }
                    }
                    """,
                    ["-l" + base]
                )
            case "hidden":
                (
                    "extension Label { public var twice: Int64 { count * 2 } }",
                    ["-Xlinker", "-hidden-l" + base]
                )
            // Only a public type sets the bit for itself, so a missing
            // descriptor of such a type does not show that it is internal.
            default:
                (
                    "",
                    [
                        "-l" + base, "-Xlinker", "-unexported_symbol", "-Xlinker",
                        "_$s\(base.utf8.count)\(base)5PointVMn",
                    ]
                )
            }
        let (library, module) = try provider(
            """
            import \(base)
            \(extensions)
            @inline(never) public func makePoint() -> Point { Point(x: 3, y: 4) }
            @inline(never) public func makeLabel() -> Label { Label(name: "abc", n: 4) }
            """,
            arguments: ["-I", directory.path, "-L", directory.path] + linkArguments
        )
        defer { library.cleanup() }
        for make in ["makePoint()", "makeLabel()"] {
            await expectFailure(
                "\(module).\(make)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming: "module `\(base)` does not show whether it is built with library evolution"
            )
        }
    }

    /// A runtime type name omits a constrained extension's generic
    /// signature, which the type's exported symbols spell.
    @Test func typesInConstrainedExtensionsKeepTheirExportEvidence() async throws {
        let (library, module) = try provider(
            """
            public enum Marker { case a, b }
            public struct Box<T> {}
            extension Box where T: Equatable {
                public struct Inner {
                    var x: Double
                    var y: Double
                    public init() { x = 1; y = 2 }
                }
                public enum Kind { case real(Double), whole(Int64), none }
            }
            @inline(never) public func makeInner() -> Box<Int>.Inner { .init() }
            @inline(never) public func makeKind(_ k: Int64) -> Box<Int>.Kind {
                k == 0 ? .real(1.5) : k == 1 ? .whole(7) : .none
            }
            @inline(never) public func kindType() -> Any.Type { Box<Int>.Kind.self }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        // An exported generic struct is not known to be frozen.
        await expectFailure(
            module + ".makeInner()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "has runtime-built metadata"
        )
        #if DEBUG
        // Its enum case symbols make Kind resilient, so it passes by address.
        let kindType = try await runtime.resolveSwiftFunction(
            named: module + ".kindType()",
            as: (() -> Any.Type).self,
            in: .path(library.libraryURL)
        )
        let layout = try SwiftInferredValue.layout(
            of: try unsafe kindType.unsafeInvoke(),
            position: .nested
        )
        try #require(withExtendedLifetime(layout) { ABISwiftValueIsIndirect(layout.handle) })
        let make = try await runtime.resolveSwiftFunction(
            named: module + ".makeKind(_:)",
            as: ((Int64) -> NativeSwiftValue).self,
            in: .path(library.libraryURL)
        )
        let kinds = try [Int64(0), 1, 2].map {
            try unsafe make.unsafeInvoke($0).withCopy { String(describing: $0) }
        }
        #expect(kinds == ["real(1.5)", "whole(7)", "none"])
        #endif
    }

    /// Inference reads the declaration's formal type, not a host type that
    /// merely shares its layout, wherever the host type stands for it.
    @Test func adapterHostTypesNeedAnExplicitABI() async throws {
        let (library, module) = try provider(
            """
            public protocol Summer { func total() -> Double }
            public struct Point: Summer {
                public var x: Double
                public var y: Double
                public init(x: Double, y: Double) { self.x = x; self.y = y }
                @inline(never) public func total() -> Double { x + y }
                @inline(never) public func sum() -> Double { x + y }
            }
            extension Summer {
                @inline(never) public func doubled() -> Double { total() * 2 }
            }
            @inline(never) public func makePoint() -> Point { Point(x: 1, y: 2) }
            @inline(never) public func describe(_ p: Point) -> String { "\\(p.x),\\(p.y)" }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        // Complete names skip the signature check that relative names apply.
        let adapter = "the host type \(String(reflecting: InferredAdapterPoint.self)) is an adapter"
        await expectFailure(
            "\(module).describe(\(module).Point) -> Swift.String",
            in: library,
            as: ((InferredAdapterPoint) -> String).self,
            naming: adapter
        )
        await expectFailure(
            "\(module).makePoint() -> \(module).Point",
            in: library,
            as: (() -> InferredAdapterPoint).self,
            naming: adapter
        )
        let point = try await runtime.resolveSwiftType(
            named: module + ".Point",
            as: InferredAdapterPoint.self,
            in: .path(library.libraryURL)
        )
        for member in [
            "sum()",
            "\(module).Summer.total() -> Swift.Double",
            "(extension in \(module)):\(module).Summer.doubled() -> Swift.Double",
        ] {
            await #expect("\(member)") {
                _ = try await point.resolveMethod(named: member, as: (() -> Double).self)
            } throws: { error in
                guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                    return false
                }
                return message.contains(
                    "its representation \(String(reflecting: InferredAdapterPoint.self)) is an adapter"
                ) && message.contains("receiverABI or an ABIBridgeSwiftValue conformance")
            }
        }
    }

    /// A tuple element's valueABIs layout describes an adapter; an Optional
    /// payload still lowers through the adapter's own type.
    @Test func adapterTupleElementsUseTheirValueABIs() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct Point {
                public var x: Double
                public var y: Double
            }
            @inline(never) public func sum(_ p: (Point, Int64)) -> Double { p.0.x + p.0.y + Double(p.1) }
            @inline(never) public func pair(_ n: Int64) -> (Point, Int64) { (Point(x: 1.5, y: 2.5), n) }
            @inline(never) public func maybe(_ p: Point?) -> Double { p.map { $0.x + $0.y } ?? -1 }
            """
        )
        defer { library.cleanup() }
        let host = try await runtime.resolveSwiftType(named: "ABIBridgeTests.InferredAdapterPoint")
        let valueABIs: [NativeSwiftType: NativeType] = [
            host: try .structure(named: "Pair", fields: [.double, .double])
        ]
        let sum = try await runtime.resolveSwiftFunction(
            named: "\(module).sum((\(module).Point, Swift.Int64)) -> Swift.Double",
            as: (((InferredAdapterPoint, Int64)) -> Double).self,
            valueABIs: valueABIs,
            in: .path(library.libraryURL)
        )
        #expect(try unsafe sum.unsafeInvoke((InferredAdapterPoint(x: 1.5, y: 2.5), 3)) == 7)
        let pair = try await runtime.resolveSwiftFunction(
            named: "\(module).pair(Swift.Int64) -> (\(module).Point, Swift.Int64)",
            as: ((Int64) -> (InferredAdapterPoint, Int64)).self,
            valueABIs: valueABIs,
            in: .path(library.libraryURL)
        )
        let value = try unsafe pair.unsafeInvoke(9)
        #expect(value.0.x == 1.5 && value.0.y == 2.5 && value.1 == 9)
        await #expect {
            _ = try await runtime.resolveSwiftFunction(
                named: "\(module).maybe(\(module).Point?) -> Swift.Double",
                as: ((InferredAdapterPoint?) -> Double).self,
                valueABIs: valueABIs,
                in: .path(library.libraryURL)
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("is an adapter")
        }
    }

    /// valueABIs do not describe self, so a failed inference of self names
    /// receiverABI instead.
    @Test func undecidedSelfNamesReceiverABI() async throws {
        let (library, module) = try provider(
            """
            public struct Label {
                public var text: String
                public var n: Int64
                public init(text: String, n: Int64) { self.text = text; self.n = n }
                @inline(never) public func count() -> Int64 { Int64(text.count) + n }
            }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let label = try await runtime.resolveSwiftType(
            named: module + ".Label",
            in: .path(library.libraryURL)
        )
        await #expect {
            _ = try await label.resolveMethod(named: "count()", as: (() -> Int64).self)
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("its field `text: Swift.String` explains")
                && message.hasSuffix(
                    "Describe self with receiverABI or an ABIBridgeSwiftValue conformance."
                )
        }
    }
}
#endif
