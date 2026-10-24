#if DEBUG
@testable import ABIBridge
import ABIBridgeCore
#else
import ABIBridge
#endif
import ABIBridgeTestSupport
import CoreFoundation
import Foundation
import Testing

#if os(macOS)
/// A host struct that shares a provider point's layout under another name.
public struct InferredAdapterPoint {
    public var x: Double
    public var y: Double
}

/// A host record whose String field leaves its inferred convention
/// undecided, so only a valueABIs entry describes it.
public struct InferredAdapterRecord {
    public var name: String
    public var count: Int64
}

/// Imported C types whose passing a test states: an enum and an option set,
/// which the importer makes a struct.
extension CFComparisonResult: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .int }
}
extension CFStringCompareFlags: ABIBridgeSwiftValue {
    public static var swiftABIType: NativeType { .uint }
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
        modulePrefix: String = "Inferred_",
        stripped: Bool = false
    ) throws -> (
        library: FixtureLibrary, module: String
    ) {
        let module = modulePrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let library = try FixtureLibrary(
            swiftModule: module,
            swiftSource: source,
            stripped: stripped,
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
            _ = try await runtime.resolve(
                .function(
                    declaration,
                    as: signature
                ),
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
        let make = try await runtime.resolve(
            .function(
                make,
                as: (() -> NativeSwiftValue).self
            ),
            in: .path(library.libraryURL)
        )
        let describe = try await runtime.resolve(
            .function(
                describe,
                as: ((NativeSwiftValue) -> String).self
            ),
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

    /// Library evolution gives unowned, static, and computed properties
    /// trivial descriptors, so this module exports no symbols that show it.
    /// Open's addressable bit, which no field explains, then stays undecided.
    @Test func modulesWithoutLibraryEvolutionSymbolsLeaveUnexplainedBitsUndecided() async throws {
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
            naming:
                "none of the fields of struct `\(module).Open` explains its addressable-for-dependencies value-witness bit, and module `\(module)` exports no symbols that only library evolution emits"
        )
    }

    /// Without evidence of how a module is built, the failure does not call
    /// it a library-evolution module. Open has no property descriptors, and
    /// neither has any other type of the module.
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
                "Cannot infer the Swift calling convention of \(module).Open in module \(module): its field `text: Swift.String` explains its addressable-for-dependencies value-witness bit, so the bit does not show whether struct `\(module).Open` is resilient; no trivial property descriptor of a stored `var` in its image shows that module `\(module)` is built without library evolution."
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
            public enum Marker { case only }
            // Its String field sets the addressable bit, so the module's
            // clear bits certify its other types.
            public struct Label {
                public var text = "label"
                public init() {}
            }
            @frozen public struct WithEmpty {
                public var e: Empty
                public var f: Float
                public var g: Empty
                public var unit: ()
                public var h: Int8
                public var m: Marker
                public init() { e = Empty(); f = 1.5; g = Empty(); unit = (); h = 7; m = .only }
            }
            @inline(never) public func makeWithEmpty() -> WithEmpty { WithEmpty() }
            @inline(never) public func describeWithEmpty(_ v: WithEmpty) -> String { "\\(v.f),\\(v.h),\\(v.m)" }
            @inline(never) public func makeMarker() -> Marker { .only }
            @inline(never) public func describeMarker(_ m: Marker) -> String { "\\(m)" }
            """
        )
        defer { library.cleanup() }
        #expect(
            try await describeMade(
                module + ".makeWithEmpty()",
                module + ".describeWithEmpty(_:)",
                in: library
            ) == "1.5,7,only"
        )
        // An enum without bytes passes nothing, alone or as a field.
        #expect(
            try await describeMade(module + ".makeMarker()", module + ".describeMarker(_:)", in: library) == "only"
        )
    }

    /// A module's symbols spell a word that repeats in its name as a
    /// substitution, which its evidence lookup must reproduce: only the
    /// library-evolution symbols under that spelling show that Plain is
    /// resilient.
    @Test func modulesWithRepeatedWordsKeepTheirEvidence() async throws {
        let (library, module) = try provider(
            """
            public struct Plain {
                public var x: Double
                public var y: Double
                public init() { x = 2.5; y = 3.5 }
            }
            @inline(never) public func makePlain() -> Plain { Plain() }
            @inline(never) public func describePlain(_ v: Plain) -> String { "\\(v.x),\\(v.y)" }
            """,
            arguments: ["-enable-library-evolution"],
            modulePrefix: "Inferred_F8F8_"
        )
        defer { library.cleanup() }
        #expect(
            try await describeMade(
                module + ".makePlain()",
                module + ".describePlain(_:)",
                in: library
            ) == "2.5,3.5"
        )
    }

    /// `Data` sets the addressable bit for itself, whatever it stores, so the
    /// bit does not show whether it is resilient, and nothing in Foundation
    /// shows how it was built. Whether a static value that stores it is
    /// decided depends on the OS's Foundation, so the test does not check it;
    /// ``staticParentsDecideFrozenTypesOfOtherModules(link:)`` covers the rule.
    @Test func selfAddressableTypesStayUndecided() async throws {
        let (library, module) = try provider(
            """
            import Foundation
            @inline(never) public func dataCount(_ d: Data) -> Int { d.count }
            @inline(never) public func makeData(_ n: Int) -> Data { Data(repeating: 1, count: n) }
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

    /// Only exported enum case symbols show that an enum is resilient, and a
    /// link can hide them. Their absence leaves the enum undecided.
    @Test func enumsWithoutExportedCaseSymbolsAreUndecided() async throws {
        let (library, module) = try provider(
            """
            public enum Tagged { case text(String), none }
            public enum Choice<T> { case one(T), none }
            @inline(never) public func makeTagged() -> Tagged { .text("t") }
            @inline(never) public func makeChoice() -> Choice<Int64> { .one(41) }
            """,
            arguments: [
                "-enable-library-evolution", "-Xlinker", "-unexported_symbol", "-Xlinker", "_$s*WC",
            ]
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeTagged()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "its field `text: Swift.String` explains"
        )
        await expectFailure(
            module + ".makeChoice()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "has runtime-built metadata"
        )
    }

    /// A @sensitive struct is address-only, and only its value witnesses,
    /// which are not POD although its fields are, show it.
    @Test func sensitiveStructsAreUndecided() async throws {
        let (library, module) = try provider(
            """
            @sensitive public struct Secret {
                public var a: Int64
                public var b: Int64
                public init() { a = 1; b = 2 }
            }
            public struct HoldsSecret {
                public var secret = Secret()
                public var n: Int64 = 3
                public init() {}
            }
            // Its String field sets the addressable bit, so the module's
            // clear bits certify its other types.
            public struct Label {
                public var text = "label"
                public init() {}
            }
            @inline(never) public func makeSecret() -> Secret { Secret() }
            @inline(never) public func makeHoldsSecret() -> HoldsSecret { HoldsSecret() }
            """,
            arguments: ["-enable-experimental-feature", "Sensitive"]
        )
        defer { library.cleanup() }
        for (make, name) in [("makeSecret()", "Secret"), ("makeHoldsSecret()", "HoldsSecret")] {
            await expectFailure(
                "\(module).\(make)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming: "the value witnesses of struct `\(module).\(name)` are not POD"
            )
        }
    }

    /// A @sensitive struct is address-only. Swift sets the addressable-for-
    /// dependencies bit for a value whenever a value it stores sets it, but
    /// not for a @sensitive struct, so a struct whose value witnesses leave
    /// the bit clear although it stores a String is undecided, and so is a
    /// value that stores one, whether or not the module's other types set the
    /// bit. A @sensitive struct whose fields do not set the bit, such as one
    /// that stores a class reference, has no such record.
    @Test(arguments: [false, true])
    func sensitiveStructsThatStoreAddressableValuesAreUndecided(addressableModule: Bool) async throws {
        let (library, module) = try provider(
            """
            // A value that stores it fits in four registers.
            @sensitive public struct SecretText {
                public var text: String
                public init() { text = "s" }
            }
            public struct HoldsSecretText {
                public var secret = SecretText()
                public var n: Int64 = 2
                public init() {}
            }
            public struct MaybeSecretText {
                public var secret: SecretText? = SecretText()
                public var n: Int64 = 3
                public init() {}
            }
            public struct LabeledSecret {
                public var secret = SecretText()
                public var label = "l"
                public init() {}
            }
            @inline(never) public func makeSecretText() -> SecretText { SecretText() }
            @inline(never) public func makeHoldsSecretText() -> HoldsSecretText { HoldsSecretText() }
            @inline(never) public func makeMaybeSecretText() -> MaybeSecretText { MaybeSecretText() }
            @inline(never) public func makeLabeledSecret() -> LabeledSecret { LabeledSecret() }
            """ + (addressableModule ? "\npublic struct Label { public var text = \"label\"; public init() {} }" : ""),
            arguments: ["-enable-experimental-feature", "Sensitive"]
        )
        defer { library.cleanup() }
        let masked = "leave the addressable-for-dependencies bit clear although"
        await expectFailure(
            module + ".makeSecretText()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "struct `\(module).SecretText` \(masked) its field `text: Swift.String` sets it"
        )
        let stores = "stores a value whose value witnesses \(masked) a value it stores sets it"
        await expectFailure(
            module + ".makeHoldsSecretText()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "its field `secret: \(module).SecretText` \(stores)"
        )
        await expectFailure(
            module + ".makeMaybeSecretText()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "its field `secret: Swift.Optional<\(module).SecretText>` \(stores)"
        )
        await expectFailure(
            module + ".makeLabeledSecret()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "its field `secret: \(module).SecretText` \(stores)"
        )
    }

    /// A field record describes a stored property of an opaque type by its
    /// underlying type, but signatures lower the property as an opaque
    /// archetype: address-only unless it is class-bound. Only one that is not
    /// class-bound sets the addressable bit, so a clear bit certifies a struct
    /// with a class-bound one. Without library-evolution symbols, a bit that
    /// no field explains leaves the others undecided.
    @Test func opaqueStoredPropertiesAreDecidedByTheAddressableBit() async throws {
        let (library, module) = try provider(
            """
            public protocol Shape { var sides: Int64 { get } }
            public protocol Owned: AnyObject { var sides: Int64 { get } }
            public struct Square: Shape { public var sides: Int64 { 4 } }
            public final class Owner: Shape, Owned { public var sides: Int64 { 3 } }
            public struct OwnerBox {
                public var owner: some Owned = Owner()
                public var n: Double = 1.5
                public init() {}
            }
            public struct Shaped {
                public var shape: some Shape = Square()
                public var n: Int64 = 2
                public init() {}
            }
            public struct ClassShaped {
                public var shape: some Shape = Owner()
                public var n: Double = 1.5
                public init() {}
            }
            public struct HoldsShaped {
                public var shaped = Shaped()
                public var z: Int64 = 3
                public init() {}
            }
            @inline(never) public func makeOwnerBox() -> OwnerBox { OwnerBox() }
            @inline(never) public func describeOwnerBox(_ v: OwnerBox) -> String { "\\(v.owner.sides),\\(v.n)" }
            @inline(never) public func makeShaped() -> Shaped { Shaped() }
            @inline(never) public func makeClassShaped() -> ClassShaped { ClassShaped() }
            @inline(never) public func makeHoldsShaped() -> HoldsShaped { HoldsShaped() }
            """
        )
        defer { library.cleanup() }
        #expect(
            try await describeMade(
                module + ".makeOwnerBox()",
                module + ".describeOwnerBox(_:)",
                in: library
            ) == "3,1.5"
        )
        for name in ["Shaped", "ClassShaped"] {
            await expectFailure(
                "\(module).make\(name)()",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming:
                    "none of the fields of struct `\(module).\(name)` explains its addressable-for-dependencies value-witness bit, and module `\(module)` exports no symbols that only library evolution emits"
            )
        }
        await expectFailure(
            module + ".makeHoldsShaped()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "its field `shaped: \(module).Shaped` explains"
        )
    }

    /// A generic instance's value witnesses come from its pattern, which
    /// treats an unowned reference to a type parameter as non-native, so its
    /// referent decides: a Swift class that uses native reference counting
    /// is a loadable reference, while an Objective-C class and a class-bound
    /// existential without a superclass are address-only. Nothing decides an
    /// existential with a superclass, which a type parameter cannot be bound
    /// to but another field can store. A nongeneric value that stores the
    /// instance has static value witnesses for the concrete referent, which
    /// decide both.
    @Test func unownedReferentsDecideGenericInstances() async throws {
        let (library, module) = try provider(
            """
            import Foundation
            public final class Native { public let n: Int64; public init(_ n: Int64) { self.n = n } }
            public final class Bridged: NSObject {
                public let n: Int64
                public init(_ n: Int64) { self.n = n }
            }
            // Unowned references need their referents alive.
            nonisolated(unsafe) public var referents: [AnyObject] = []
            public struct Holder<T: AnyObject> {
                public unowned var t: T
                public var x: Int64
                public init(t: T, x: Int64) { referents.append(t); self.t = t; self.x = x }
            }
            public struct Outer {
                public var h: Holder<Native>
                public var f: Float
                public init(h: Holder<Native>, f: Float) { self.h = h; self.f = f }
            }
            public struct BridgedOuter {
                public var h: Holder<Bridged>
                public var f: Float
                public init(h: Holder<Bridged>, f: Float) { self.h = h; self.f = f }
            }
            // Its String field sets the addressable bit, so the module's
            // clear bits certify its other types.
            public struct Label {
                public var text = "label"
                public init() {}
            }
            public protocol Marked: AnyObject {}
            public class Shape { public let n: Int64; public init(_ n: Int64) { self.n = n } }
            public final class Square: Shape, Marked {}
            public struct Marking<T> {
                public unowned var shape: Shape & Marked
                public var t: T
                public init(shape: Shape & Marked, t: T) { referents.append(shape); self.shape = shape; self.t = t }
            }
            @inline(never) public func makeNativeHolder() -> Holder<Native> { Holder(t: Native(5), x: 3) }
            @inline(never) public func describeNativeHolder(_ h: Holder<Native>) -> String { "\\(h.t.n),\\(h.x)" }
            @inline(never) public func makeBridgedHolder() -> Holder<Bridged> { Holder(t: Bridged(6), x: 4) }
            @inline(never) public func describeBridgedHolder(_ h: Holder<Bridged>) -> String { "\\(h.t.n),\\(h.x)" }
            @inline(never) public func makeAnyHolder() -> Holder<AnyObject> { Holder(t: Native(7), x: 5) }
            @inline(never) public func describeAnyHolder(_ h: Holder<AnyObject>) -> String {
                "\\((h.t as! Native).n),\\(h.x)"
            }
            @inline(never) public func makeMarking() -> Marking<Int64> { Marking(shape: Square(8), t: 6) }
            @inline(never) public func makeOuter() -> Outer { Outer(h: Holder(t: Native(8), x: 2), f: 1.5) }
            @inline(never) public func describeOuter(_ o: Outer) -> String { "\\(o.h.t.n),\\(o.h.x),\\(o.f)" }
            @inline(never) public func makeBridgedOuter() -> BridgedOuter {
                BridgedOuter(h: Holder(t: Bridged(9), x: 3), f: 2.5)
            }
            @inline(never) public func describeBridgedOuter(_ o: BridgedOuter) -> String {
                "\\(o.h.t.n),\\(o.h.x),\\(o.f)"
            }
            """
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeMarking()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming: "nothing shows how its field `shape: \(module).Shape & \(module).Marked` counts references to its referent"
        )
        for (name, expected) in [
            ("NativeHolder", "5,3"), ("BridgedHolder", "6,4"), ("AnyHolder", "7,5"),
            ("Outer", "8,2,1.5"), ("BridgedOuter", "9,3,2.5"),
        ] {
            #expect(
                try await describeMade(
                    "\(module).make\(name)()",
                    "\(module).describe\(name)(_:)",
                    in: library
                ) == expected,
                "\(name)"
            )
        }
    }

    /// Another module's extension of a library-evolution module's types
    /// exports symbols in that module's context, and a link can hide the
    /// module's own symbols. Neither shows how the module was built or which
    /// of its types are public.
    @Test(arguments: [
        "extended", "hidden", "hiddenWithNestedType", "hiddenPointDescriptor",
        "hiddenLabelDescriptor",
    ])
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
        try FixtureLibrary.run([
            "--sdk", "macosx", "swiftc", "-module-name", base,
            "-target", "arm64-apple-macosx15.4", "-parse-as-library", "-swift-version",
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
            // The nested type's descriptor is in the hidden module's context.
            case "hiddenWithNestedType":
                (
                    """
                    extension Point {
                        public struct Builder {
                            public var scale: Int
                            public init(scale: Int) { self.scale = scale }
                        }
                    }
                    """,
                    ["-Xlinker", "-hidden-l" + base]
                )
            // A missing descriptor of a type does not show that it is
            // internal, whatever explains its addressable bit.
            default:
                (
                    "",
                    [
                        "-l" + base, "-Xlinker", "-unexported_symbol", "-Xlinker",
                        "_$s\(base.utf8.count)\(base)\(link == "hiddenPointDescriptor" ? "5Point" : "5Label")VMn",
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
        for (make, evidence) in [
            ("makePoint()", "module `\(base)` exports no symbols that only library evolution emits"),
            ("makeLabel()", "its field `name: Swift.String` explains"),
        ] {
            await expectFailure(
                "\(module).\(make)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming: evidence
            )
        }
    }

    /// A type declared in an extension of another module's type keeps its
    /// own module's evidence, although its runtime name starts with the
    /// extended type: the module's clear addressable bits without library
    /// evolution, and its library-evolution symbols with it.
    @Test(arguments: [false, true])
    func typesInExtensionsOfOtherModulesKeepTheirModuleEvidence(evolution: Bool) async throws {
        // Lookup of a type in an extension of Int searches every image, and
        // the fixture of the other argument stays loaded.
        let name = evolution ? "EvolvedVisible" : "FixedVisible"
        let (library, module) = try provider(
            """
            public struct Top {
                public var a: Int64
                public var text: String
                public init() { a = 1; text = "top" }
            }
            extension Int {
                public struct \(name) {
                    public var a: Int64
                    public var b: Int64
                    public init() { a = 1; b = 2 }
                }
            }
            @inline(never) public func makeVisible() -> Int.\(name) { .init() }
            @inline(never) public func describeVisible(_ v: Int.\(name)) -> String { "\\(v.a),\\(v.b)" }
            """,
            arguments: evolution ? ["-enable-library-evolution"] : []
        )
        defer { library.cleanup() }
        // Relative names do not find these declarations.
        let visible = "(extension in \(module)):Swift.Int.\(name)"
        #expect(
            try await describeMade(
                "\(module).makeVisible() -> \(visible)",
                "\(module).describeVisible(\(visible)) -> Swift.String",
                in: library
            ) == "1,2"
        )
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
        let kindType = try await runtime.resolve(
            .function(
                module + ".kindType()",
                as: (() -> Any.Type).self
            ),
            in: .path(library.libraryURL)
        )
        let layout = try SwiftInferredValue.layout(
            of: try unsafe kindType.unsafeInvoke(),
            position: .nested
        )
        try #require(withExtendedLifetime(layout) { ABISwiftValueIsIndirect(layout.handle) })
        let make = try await runtime.resolve(
            .function(
                module + ".makeKind(_:)",
                as: ((Int64) -> NativeSwiftValue).self
            ),
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
        // Complete names accept a host type with another name, but not one
        // that inference would lower.
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
                _ = try await point.resolve(.method(member, as: (() -> Double).self))
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
        let sum = try await runtime.resolve(
            .function(
                "\(module).sum((\(module).Point, Swift.Int64)) -> Swift.Double",
                as: (((InferredAdapterPoint, Int64)) -> Double).self,
                valueABIs: valueABIs
            ),
            in: .path(library.libraryURL)
        )
        #expect(try unsafe sum.unsafeInvoke((InferredAdapterPoint(x: 1.5, y: 2.5), 3)) == 7)
        let pair = try await runtime.resolve(
            .function(
                "\(module).pair(Swift.Int64) -> (\(module).Point, Swift.Int64)",
                as: ((Int64) -> (InferredAdapterPoint, Int64)).self,
                valueABIs: valueABIs
            ),
            in: .path(library.libraryURL)
        )
        let value = try unsafe pair.unsafeInvoke(9)
        #expect(value.0.x == 1.5 && value.0.y == 2.5 && value.1 == 9)
        await #expect {
            _ = try await runtime.resolve(
                .function(
                    "\(module).maybe(\(module).Point?) -> Swift.Double",
                    as: ((InferredAdapterPoint?) -> Double).self,
                    valueABIs: valueABIs
                ),
                in: .path(library.libraryURL)
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("is an adapter")
        }
    }

    /// The schema of a closed tuple that the caller's types do not include
    /// takes its elements' layouts from the lookup's valueABIs, as the
    /// tuple's codec does, instead of inferring an undecided element.
    @Test func undecidedAdapterTupleElementsUseTheirValueABIs() async throws {
        let (library, module) = try provider(
            """
            public struct Record {
                public var name: String
                public var count: Int64
            }
            @inline(never) public func pair(_ n: Int64) -> (Record, Int64) {
                (Record(name: "record", count: n), n * 2)
            }
            """
        )
        defer { library.cleanup() }
        let native = try await runtime.resolveSwiftType(
            named: module + ".Record",
            in: .path(library.libraryURL)
        )
        let host = try await runtime.resolveSwiftType(named: "ABIBridgeTests.InferredAdapterRecord")
        let abi = try NativeType.structure(named: "Record", fields: [.uint64, .uint64, .int64])
        let pair = try await runtime.resolve(
            .function(
                "\(module).pair(Swift.Int64) -> (\(module).Record, Swift.Int64)",
                as: ((Int64) -> (InferredAdapterRecord, Int64)).self,
                valueABIs: [native: abi, host: abi]
            ),
            in: .path(library.libraryURL)
        )
        let value = try unsafe pair.unsafeInvoke(21)
        #expect(value.0.name == "record" && value.0.count == 21 && value.1 == 42)
    }

    /// A complete declaration compares a host type with the declared type
    /// once a convention for the declared type is established. Without one,
    /// the lookup states the host type's convention itself. Nothing shows
    /// that this library-evolution module's Point is frozen.
    @Test func adaptersNeedAnEstablishedDeclaredConvention() async throws {
        let (library, module) = try provider(
            """
            @frozen public struct Point {
                public var x: Double
                public var y: Double
            }
            @inline(never) public func sum(_ p: Point) -> Double { p.x + p.y }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        let name = "\(module).sum(\(module).Point) -> Swift.Double"
        await #expect {
            _ = try await runtime.resolve(
                .function(
                    name,
                    as: ((CGPoint) -> Double).self
                ),
                in: .path(library.libraryURL)
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("Cannot infer the Swift calling convention of \(module).Point")
                && message.contains("valueABIs entry for \(String(reflecting: CGPoint.self))")
        }
        let point = try await runtime.resolveSwiftType(
            named: module + ".Point",
            in: .path(library.libraryURL)
        )
        let sum = try await runtime.resolve(
            .function(
                name,
                as: ((CGPoint) -> Double).self,
                valueABIs: [point: try .structure(named: "Point", fields: [.double, .double])]
            ),
            in: .path(library.libraryURL)
        )
        #expect(try unsafe sum.unsafeInvoke(CGPoint(x: 1.5, y: 2.5)) == 4)
        do {
            _ = try await runtime.resolve(
                .function(
                    name,
                    as: ((CGPoint) -> Double).self,
                    valueABIs: [point: try .structure(named: "Point", fields: [.int64, .int64])]
                ),
                in: .path(library.libraryURL)
            )
            Issue.record("CGPoint was accepted for integer fields")
        } catch let ABIResolutionError.signatureMismatch(mismatch) {
            #expect(mismatch.position == .argument(0))
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
            _ = try await label.resolve(.method("count()", as: (() -> Int64).self))
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
    // MARK: Modules built without library evolution

    /// Without library evolution, every stored property with a descriptor
    /// has a trivial one, which shows how the module is built, and the
    /// symbols of a struct's stored properties spell their declared types.
    /// A field record holds an opaque property's underlying type, so only
    /// those symbols show that a property is opaque. Stripping removes the
    /// local accessors that spell an internal property without an initial
    /// value, and a link can hide a property's exported symbols.
    @Test(arguments: ["unstripped", "stripped", "hiddenDescriptor"])
    func modulesWithoutLibraryEvolutionDecideTheirValuesFromRecords(link: String) async throws {
        // Lookup of a type in an extension of Int searches every image, and
        // the fixtures of the other arguments stay loaded.
        let nestedName = "Nested_" + link
        let (library, module) = try provider(
            """
            public protocol P {}
            extension Int: P {}
            public struct Label {
                public var text: String
                public var n: Int64
                public init(text: String, n: Int64) { self.text = text; self.n = n }
            }
            public struct Mixed {
                public var text: String = "m"
                var count: Int64 = 2
                public init() {}
                public var total: Int64 { count }
            }
            public struct Unspelled {
                public var text: String
                var count: Int64
                public init() { text = "u"; count = 3 }
                public var total: Int64 { count }
            }
            public struct PrivateField {
                public var text: String = "p"
                private var count: Int64 = 5
                public init() {}
                public var total: Int64 { count }
            }
            public enum Tagged { case text(String), none }
            extension Int {
                public struct \(nestedName) {
                    public var text: String
                    public var n: Int64
                    public init(text: String, n: Int64) { self.text = text; self.n = n }
                }
            }
            @_addressableForDependencies public struct SelfAddressable {
                public var a: Int64
                public var b: Int64
                public init(a: Int64, b: Int64) { self.a = a; self.b = b }
            }
            public struct OpaqueLabel { public var text: String = "o"; public var x: some P = 7; public init() {} }
            public struct StructuralOpaque { public var text: String = "s"; public var x: (some P)? = 7; public init() {} }
            public struct HiddenOpaque { public var text: String = "h"; var x: some P = 7; public init() {} }
            @inline(never) public func makeLabel() -> Label { Label(text: "label", n: 4) }
            @inline(never) public func describeLabel(_ v: Label) -> String { "\\(v.text),\\(v.n)" }
            @inline(never) public func makeMixed() -> Mixed { Mixed() }
            @inline(never) public func describeMixed(_ v: Mixed) -> String { "\\(v.text),\\(v.total)" }
            @inline(never) public func makeUnspelled() -> Unspelled { Unspelled() }
            @inline(never) public func describeUnspelled(_ v: Unspelled) -> String { "\\(v.text),\\(v.total)" }
            @inline(never) public func makePrivateField() -> PrivateField { PrivateField() }
            @inline(never) public func describePrivateField(_ v: PrivateField) -> String { "\\(v.text),\\(v.total)" }
            @inline(never) public func makeTagged() -> Tagged { .text("tagged") }
            @inline(never) public func describeTagged(_ v: Tagged) -> String { "\\(v)" }
            @inline(never) public func makeNested() -> Int.\(nestedName) { .init(text: "nested", n: 5) }
            @inline(never) public func describeNested(_ v: Int.\(nestedName)) -> String { "\\(v.text),\\(v.n)" }
            @inline(never) public func makeSelfAddressable() -> SelfAddressable { .init(a: 6, b: 7) }
            @inline(never) public func describeSelfAddressable(_ v: SelfAddressable) -> String { "\\(v.a),\\(v.b)" }
            @inline(never) public func makeOpaqueLabel() -> OpaqueLabel { OpaqueLabel() }
            @inline(never) public func makeStructuralOpaque() -> StructuralOpaque { StructuralOpaque() }
            @inline(never) public func makeHiddenOpaque() -> HiddenOpaque { HiddenOpaque() }
            """,
            arguments: ["-enable-experimental-feature", "AddressableTypes"]
                + (link == "hiddenDescriptor"
                    ? ["-Xlinker", "-unexported_symbol", "-Xlinker", "_$s*5LabelV1ns5Int64V*"] : []),
            stripped: link != "unstripped"
        )
        defer { library.cleanup() }
        var decided = [
            ("makeMixed()", "describeMixed(_:)", "m,2"),
            ("makePrivateField()", "describePrivateField(_:)", "p,5"),
            ("makeTagged()", "describeTagged(_:)", "text(\"tagged\")"),
            ("makeSelfAddressable()", "describeSelfAddressable(_:)", "6,7"),
        ]
        if link != "hiddenDescriptor" { decided.append(("makeLabel()", "describeLabel(_:)", "label,4")) }
        if link == "unstripped" { decided.append(("makeUnspelled()", "describeUnspelled(_:)", "u,3")) }
        for (make, describe, expected) in decided {
            #expect(
                try await describeMade("\(module).\(make)", "\(module).\(describe)", in: library) == expected,
                "\(make)"
            )
        }
        // Relative names do not find these declarations.
        let nested = "(extension in \(module)):Swift.Int.\(nestedName)"
        #expect(
            try await describeMade(
                "\(module).makeNested() -> \(nested)",
                "\(module).describeNested(\(nested)) -> Swift.String",
                in: library
            ) == "nested,5"
        )
        var undecided = [
            ("makeOpaqueLabel()", "its stored property `x` has an opaque (`some`) type"),
            ("makeStructuralOpaque()", "its stored property `x` has an opaque (`some`) type"),
            ("makeHiddenOpaque()", "stored property `x`"),
        ]
        if link == "hiddenDescriptor" {
            undecided.append(
                ("makeLabel()", "no symbol in its image spells the declared type of its stored property `n`")
            )
        }
        if link != "unstripped" {
            undecided.append(
                ("makeUnspelled()", "no symbol in its image spells the declared type of its stored property `count`")
            )
        }
        for (make, evidence) in undecided {
            await expectFailure(
                "\(module).\(make)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming: evidence
            )
        }
    }

    /// Library evolution gives trivial descriptors to stored `let`s of
    /// function, metatype, and unowned types, to static properties, and to
    /// computed properties, but never to a stored `var`. Even a frozen value
    /// of such a module stays undecided.
    @Test func libraryEvolutionModulesShowNoTrivialStoredVariables() async throws {
        let (library, module) = try provider(
            """
            import Foundation
            public struct Kinds {
                public let f: () -> Void
                public let m: Int.Type
                public unowned let u: NSObject
                nonisolated(unsafe) public static var shared: Int64 = 0
                public var computed: Int64 { 1 }
                public init(u: NSObject) { f = {}; m = Int.self; self.u = u }
            }
            public final class Klass { public let l: Int64 = 0; public init() {} }
            @frozen public struct FrozenLabel {
                public var text: String
                public var n: Int64
                public init() { text = "f"; n = 1 }
            }
            @inline(never) public func makeFrozenLabel() -> FrozenLabel { FrozenLabel() }
            """,
            arguments: ["-enable-library-evolution"]
        )
        defer { library.cleanup() }
        await expectFailure(
            module + ".makeFrozenLabel()",
            in: library,
            as: (() -> NativeSwiftValue).self,
            naming:
                "no trivial property descriptor of a stored `var` in its image shows that module `\(module)` is built without library evolution"
        )
    }

    /// A value whose static metadata stores a frozen type of a library-
    /// evolution module shows that the type is not resilient: its compiler
    /// laid the type out. Every struct it stores at any depth still needs
    /// symbols that spell its stored properties, which show an opaque one,
    /// unless its own static value witnesses decide it, as Code's do.
    /// A type of an extension in the client belongs to the client, whose
    /// trivial descriptors therefore say nothing about the base. A subclass
    /// of the base's resilient class exports a class metadata base offset,
    /// which a module built without library evolution also exports, so it
    /// does not make the client's self-addressable type resilient.
    @Test(arguments: ["linked", "hidden", "hiddenStripped"])
    func staticParentsDecideFrozenTypesOfOtherModules(link: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let base =
            "inferredfrozen_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let baseSource = directory.appendingPathComponent("Base.swift")
        try """
        public protocol P {}
        extension Int: P {}
        @frozen public struct FrozenLabel {
            public var text: String
            public init(text: String) { self.text = text }
        }
        public struct OpenLabel {
            public var text: String
            public var n: Int64
            public init() { text = "o"; n = 2 }
        }
        @frozen public struct FrozenOpaque {
            public var text: String = "o"
            public var x: some P = 7
            public init() {}
        }
        @frozen public struct Outer {
            public var inner: FrozenOpaque
            public var m: Int64
            public init() { inner = FrozenOpaque(); m = 1 }
        }
        open class Base { public init() {} }
        @frozen public struct Code {
            public var raw: Int32
            public init(raw: Int32) { self.raw = raw }
        }
        @frozen public struct Coded {
            public var text: String
            public var code: Code
            public init(text: String, code: Code) { self.text = text; self.code = code }
        }
        @inline(never) public func makeFrozenLabel() -> FrozenLabel { FrozenLabel(text: "alone") }
        """.write(to: baseSource, atomically: true, encoding: .utf8)
        try FixtureLibrary.run([
            "--sdk", "macosx", "swiftc", "-module-name", base,
            "-target", "arm64-apple-macosx15.4", "-parse-as-library", "-swift-version",
            "6", "-enable-library-evolution", "-emit-library", "-static", "-emit-module",
            "-emit-module-path", directory.appendingPathComponent(base + ".swiftmodule").path,
            baseSource.path, "-o", directory.appendingPathComponent("lib\(base).a").path,
        ])
        let (library, module) = try provider(
            """
            import \(base)
            public struct HoldsFrozen {
                public var f: FrozenLabel = .init(text: "held")
                public var n: Int64 = 3
                public init() {}
            }
            public enum HoldsFrozenCase { case f(FrozenLabel), none }
            public struct HoldsFrozenOpaque { public var f = FrozenOpaque(); public init() {} }
            public struct HoldsOuter { public var o = Outer(); public init() {} }
            public struct HoldsOpen { public var o = OpenLabel(); public init() {} }
            public struct HoldsCoded {
                public var coded = Coded(text: "coded", code: Code(raw: 7))
                public init() {}
            }
            extension OpenLabel {
                public struct Builder {
                    public var scale: Int = 4
                    public var text: String = "builder"
                    public init() {}
                }
            }
            public final class Sub: Base {}
            @_addressableForDependencies public struct SelfAddressable {
                public var a: Int64
                public var b: Int64
                public init(a: Int64, b: Int64) { self.a = a; self.b = b }
            }
            @inline(never) public func makeHoldsFrozen() -> HoldsFrozen { HoldsFrozen() }
            @inline(never) public func describeHoldsFrozen(_ v: HoldsFrozen) -> String { "\\(v.f.text),\\(v.n)" }
            @inline(never) public func makeHoldsFrozenCase() -> HoldsFrozenCase { .f(FrozenLabel(text: "case")) }
            @inline(never) public func describeHoldsFrozenCase(_ v: HoldsFrozenCase) -> String {
                if case .f(let label) = v { label.text } else { "none" }
            }
            @inline(never) public func makeHoldsOpen() -> HoldsOpen { HoldsOpen() }
            @inline(never) public func makeHoldsCoded() -> HoldsCoded { HoldsCoded() }
            @inline(never) public func describeHoldsCoded(_ v: HoldsCoded) -> String {
                "\\(v.coded.text),\\(v.coded.code.raw)"
            }
            @inline(never) public func describeHoldsOpen(_ v: HoldsOpen) -> String { "\\(v.o.text),\\(v.o.n)" }
            @inline(never) public func makeBuilder() -> OpenLabel.Builder { OpenLabel.Builder() }
            @inline(never) public func describeBuilder(_ v: OpenLabel.Builder) -> String { "\\(v.text),\\(v.scale)" }
            @inline(never) public func makeSelfAddressable() -> SelfAddressable { .init(a: 8, b: 9) }
            @inline(never) public func describeSelfAddressable(_ v: SelfAddressable) -> String { "\\(v.a),\\(v.b)" }
            @inline(never) public func makeHoldsFrozenOpaque() -> HoldsFrozenOpaque { HoldsFrozenOpaque() }
            @inline(never) public func makeHoldsOuter() -> HoldsOuter { HoldsOuter() }
            """,
            arguments: [
                "-I", directory.path, "-L", directory.path,
                "-enable-experimental-feature", "AddressableTypes",
            ] + (link == "linked" ? ["-l" + base] : ["-Xlinker", "-hidden-l" + base]),
            stripped: link == "hiddenStripped"
        )
        defer { library.cleanup() }
        // The client's own types and the base's frozen type in a static
        // parent; HoldsOpen's metadata is initialized at run time.
        var decided = [
            ("makeHoldsOpen()", "describeHoldsOpen(_:)", "o,2"),
            ("makeSelfAddressable()", "describeSelfAddressable(_:)", "8,9"),
        ]
        if link != "hiddenStripped" {
            decided += [
                ("makeHoldsFrozen()", "describeHoldsFrozen(_:)", "held,3"),
                ("makeHoldsFrozenCase()", "describeHoldsFrozenCase(_:)", "case"),
                ("makeHoldsCoded()", "describeHoldsCoded(_:)", "coded,7"),
            ]
        }
        for (make, describe, expected) in decided {
            #expect(
                try await describeMade("\(module).\(make)", "\(module).\(describe)", in: library) == expected,
                "\(make)"
            )
        }
        // Relative names do not find a type of an extension of another
        // module's type.
        let builder = "(extension in \(module)):\(base).OpenLabel.Builder"
        #expect(
            try await describeMade(
                "\(module).makeBuilder() -> \(builder)",
                "\(module).describeBuilder(\(builder)) -> Swift.String",
                in: library
            ) == "builder,4"
        )
        let opaque = "its stored property `x` has an opaque (`some`) type"
        let unspelled = "no symbol in its image spells the declared type of its stored property"
        var undecided = [
            ("makeHoldsFrozenOpaque()", link == "hiddenStripped" ? unspelled : opaque),
            ("makeHoldsOuter()", link == "hiddenStripped" ? unspelled : opaque),
        ]
        if link == "hiddenStripped" {
            undecided += [
                ("makeHoldsFrozen()", unspelled + " `text`"),
                ("makeHoldsFrozenCase()", unspelled + " `text`"),
                ("makeHoldsCoded()", unspelled + " `text`"),
            ]
        }
        for (make, evidence) in undecided {
            await expectFailure(
                "\(module).\(make)",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming: evidence
            )
        }
        // Alone, the base's frozen type is undecided, although the image
        // holds the client's trivial descriptors in the base's context.
        if link == "linked" {
            await expectFailure(
                "\(base).makeFrozenLabel()",
                in: library,
                as: (() -> NativeSwiftValue).self,
                naming:
                    "no trivial property descriptor of a stored `var` in its image shows that module `\(base)` is built without library evolution"
            )
            #if DEBUG
            // Code's static value witnesses leave the addressable bit clear,
            // which decides it alone, while Coded needs HoldsCoded.
            let scope = ImageSelector.path(library.libraryURL)
            let code = try await runtime.resolveSwiftType(named: base + ".Code", in: scope).metadata
            _ = try SwiftInferredValue.layout(of: code, position: .nested)
            let coded = try await runtime.resolveSwiftType(named: base + ".Coded", in: scope).metadata
            #expect(throws: ABIResolutionError.self) {
                _ = try SwiftInferredValue.layout(of: coded, position: .nested)
            }
            #endif
        }
    }

    @Test func scopedClosureResultsPreserveErrorsAndDestruction() async throws {
        let (library, module) = try provider(
            """
            nonisolated(unsafe) private var destroyed = 0
            public enum Failure: Error { case rejected }
            public struct Number: ~Copyable, ~Escapable {
                let value: Int64
                @_lifetime(immortal) init(_ value: Int64) { self.value = value }
                deinit { destroyed += 1 }
            }
            @inline(never) public func read(_ value: borrowing Number) -> Int64 { value.value }
            @inline(never) public func destructions() -> Int64 { Int64(destroyed) }
            @inline(never) public func make(_ fail: Bool) -> () throws -> Number {
                { if fail { throw Failure.rejected }; return Number(42) }
            }
            @inline(never) public func makeAsync() -> nonisolated(nonsending) () async -> Number {
                { await Task.yield(); return Number(43) }
            }
            """, arguments: ["-enable-experimental-feature", "Lifetimes"]
        )
        defer { library.cleanup() }
        let scope = ImageSelector.path(library.libraryURL)
        let number = try await runtime.resolveSwiftType(named: module + ".Number", in: scope)
        let valueABIs: [NativeSwiftType: NativeType] = [
            number: try .structure(named: "Number", fields: [.int64])
        ]
        let read = try await runtime.resolve(
            .function(module + ".read(_:)", as: ((NativeSwiftBorrowedValue) -> Int64).self, valueABIs: valueABIs), in: scope
        )
        let destructions = try await runtime.resolve(
            .function(module + ".destructions()", as: (() -> Int64).self), in: scope
        )
        let make = try await runtime.resolve(
            .function(module + ".make(_:)", as: ((Bool) -> NativeSwiftClosure<() throws -> NativeSwiftBorrowedValue>).self, valueABIs: valueABIs), in: scope
        )
        let closure = try unsafe make.unsafeInvoke(false)
        #expect(try unsafe closure.unsafeInvoke(withResult: { try unsafe read.unsafeInvoke($0) }) == 42)
        #expect(throws: NativeSwiftValueError.valueInUse) {
            try unsafe closure.unsafeInvoke(withResult: { _ in throw NativeSwiftValueError.valueInUse })
        }
        let failure = try unsafe make.unsafeInvoke(true)
        #expect(throws: NativeSwiftError.self) { try unsafe failure.unsafeInvoke(withResult: { _ in () }) }
        #expect(try unsafe destructions.unsafeInvoke() == 2)
        let makeAsync = try await runtime.resolve(
            .function(module + ".makeAsync()", as: (() -> NativeSwiftClosure<nonisolated(nonsending) () async -> NativeSwiftBorrowedValue>).self, valueABIs: valueABIs), in: scope
        )
        let asynchronous = try unsafe makeAsync.unsafeInvoke()
        #expect(try unsafe await asynchronous.unsafeInvoke(withResult: { value in
            await Task.yield()
            return try unsafe read.unsafeInvoke(value)
        }) == 43)
        #expect(try unsafe destructions.unsafeInvoke() == 3)
    }

    #if compiler(>=6.4)
    @available(macOS 26.0, *)
    @Test func declaredClosureLifetimesKeepTheirInputStorage() async throws {
        // Swift 6.4 crashes while lowering a borrowed tuple's projections.
        // The first body returns the exact incoming tuple address. Its String
        // remains valid only if invocation and reabstraction preserve that storage.
        let shim = try FixtureLibrary(cxxSource: """
            #include <stdint.h>
            #include <string.h>
            extern "C" __attribute__((swiftcall)) const void *ABILifetimeTupleAddress(const void *pair) { return pair; }
            using Stored = __attribute__((swiftcall)) void (*)(__attribute__((swift_indirect_result)) int64_t *, const int64_t *, __attribute__((swift_context)) void *);
            extern "C" __attribute__((swiftcall)) int64_t ABILifetimeFunctionTuple(const void *pair) {
                Stored function; void *context;
                memcpy(&function, static_cast<const char *>(pair) + 16, sizeof(function));
                memcpy(&context, static_cast<const char *>(pair) + 24, sizeof(context));
                const int64_t argument = 35;
                int64_t result;
                function(&result, &argument, context);
                return result;
            }
            """)
        defer { shim.cleanup() }
        let (library, module) = try provider(
            """
            @available(macOS 26.0, *)
            public struct View: ~Escapable {
                let bytes: Span<UInt8>
                @_lifetime(copy bytes) init(_ bytes: Span<UInt8>) { self.bytes = bytes }
            }
            public struct TupleView: ~Escapable { let text: UnsafePointer<String> }
            public struct Number: ~Escapable {
                let value: Int64
                @_lifetime(immortal) init(_ value: Int64) { self.value = value }
            }
            @inline(never) public func readNumber(_ value: borrowing Number) -> Int64 { value.value }
            @inline(never) public func makeResultTuple() -> () -> (Number, Int64) { { (Number(44), 7) } }
            public struct Evidence { public var text: String = "evidence" }
            @available(macOS 26.0, *)
            @_lifetime(borrow text) @inline(never) public func first(_ text: String, _ other: String) -> View { View(text.utf8Span.span) }
            @available(macOS 26.0, *)
            @_lifetime(borrow text) @inline(never) public nonisolated(nonsending) func asyncBody(_ text: String) async -> View {
                await Task.yield()
                return View(text.utf8Span.span)
            }
            @available(macOS 26.0, *)
            @inline(never) public func make() -> @_lifetime(borrow text) (_ text: String, _ other: String) -> View {
                first
            }
            @available(macOS 26.0, *)
            @inline(never) public func makeComposite() -> (Int64, (@_lifetime(borrow text) (_ text: String, _ other: String) -> View)?) {
                (7, first)
            }
            @_silgen_name("ABILifetimeTupleAddress")
            @_lifetime(borrow pair) public func tupleBody(_ pair: (String, Int64)) -> TupleView
            @available(macOS 26.0, *)
            @inline(never) public func makeTuple() -> @_lifetime(borrow pair) (_ pair: (String, Int64)) -> TupleView { tupleBody }
            @available(macOS 26.0, *)
            @inline(never) public func makeAsync() -> nonisolated(nonsending) @_lifetime(borrow text) (_ text: String) async -> View {
                asyncBody
            }
            @available(macOS 26.0, *)
            @inline(never) public func read(_ view: borrowing View) -> Int64 {
                var number: Int64 = 0
                for i in view.bytes.indices { number = number * 10 + (Int64(view.bytes[i]) - 48) }
                return number
            }

            @inline(never) public func readTuple(_ view: borrowing TupleView) -> Int64 {
                var number: Int64 = 0
                for byte in view.text.pointee.utf8 { number = number * 10 + Int64(byte) - 48 }
                return number
            }

            @_silgen_name("ABILifetimeFunctionTuple")
            @_lifetime(borrow pair) public func functionTupleBody(_ pair: (String, (Int64) -> Int64)) -> Number
            @inline(never) public func makeFunctionTuple() -> @_lifetime(borrow pair) (_ pair: (String, (Int64) -> Int64)) -> Number { functionTupleBody }
            """,
            arguments: ["-enable-experimental-feature", "Lifetimes", shim.libraryURL.path]
        )
        defer { library.cleanup() }
        let scope = ImageSelector.path(library.libraryURL)
        let read = try await runtime.resolve(
            .function(module + ".read(_:)", as: ((NativeSwiftBorrowedValue) -> Int64).self), in: scope
        )
        typealias Borrower = NativeSwiftClosure<(String, String) -> NativeSwiftBorrowedValue>
        let make = try await runtime.resolve(
            .function(
                module + ".make()", as: (() -> Borrower).self,
                declaredAs: "() -> @_lifetime(borrow text) (_ text: Swift.String, _ other: Swift.String) -> \(module).View"
            ), in: scope
        )
        let closure = try unsafe make.unsafeInvoke()
        var expired: NativeSwiftBorrowedValue?
        #expect(try unsafe closure.unsafeInvoke("123", "456", withResult: { value in
            expired = value
            return try unsafe read.unsafeInvoke(value)
        }) == 123)
        #expect(throws: NativeSwiftBorrowError.expiredBorrow) { try unsafe read.unsafeInvoke(expired!) }
        await #expect(throws: ABIResolutionError.self) {
            try await runtime.resolve(.function(module + ".make()", as: (() -> Borrower).self), in: scope)
        }
        let makeComposite = try await runtime.resolve(
            .function(module + ".makeComposite()", as: (() -> (Int64, Borrower?)).self,
                declaredAs: "() -> (Swift.Int64, (@_lifetime(borrow text) (_ text: Swift.String, _ other: Swift.String) -> \(module).View)?)"), in: scope
        )
        let composite = try unsafe makeComposite.unsafeInvoke()
        let nested = try #require(composite.1)
        #expect(try unsafe nested.unsafeInvoke("456", "123", withResult: { try unsafe read.unsafeInvoke($0) }) == 456)
        let readTuple = try await runtime.resolve(
            .function(module + ".readTuple(_:)", as: ((NativeSwiftBorrowedValue) -> Int64).self), in: scope
        )
        typealias TupleBorrower = NativeSwiftClosure<((String, Int64)) -> NativeSwiftBorrowedValue>
        let tupleDeclaration = "() -> @_lifetime(borrow pair) (_ pair: (Swift.String, Swift.Int64)) -> \(module).TupleView"
        let makeTuple = try await runtime.resolve(
            .function(module + ".makeTuple()", as: (() -> TupleBorrower).self, declaredAs: tupleDeclaration), in: scope
        )
        let tuple = try unsafe makeTuple.unsafeInvoke()
        #expect(try unsafe tuple.unsafeInvoke(("456", 7), withResult: { try unsafe readTuple.unsafeInvoke($0) }) == 456)
        // Erasing the function value changes its ABI to indirect value storage;
        // the adapter must forward the tuple address that owns these small-string bytes.
        let erase = try await runtime.resolve(
            .function(module + ".makeTuple()", as: (() -> NativeSwiftValue).self, declaredAs: tupleDeclaration), in: scope
        )
        let erased = try unsafe erase.unsafeInvoke()
        let stored = try await erased.resolveClosure(as: (((String, Int64)) -> NativeSwiftBorrowedValue).self)
        #if DEBUG
        // Compare addresses before reading the borrowed String, so a copying
        // adapter fails without dereferencing its already-destroyed temporary.
        guard case .synchronous(let storage, let prepared) = try stored.call.resolved() else {
            Issue.record("Expected a synchronous stored closure")
            return
        }
        let input = NativeValueStorage(size: MemoryLayout<(String, Int64)>.stride,
                                       alignment: MemoryLayout<(String, Int64)>.alignment)
        input.initialize(("789", Int64(7)))
        let output = NativeValueStorage(size: MemoryLayout<UnsafeRawPointer>.stride,
                                        alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        var error: OpaquePointer?
        let invoked = withExtendedLifetime((stored, storage)) {
            [Optional(input.address)].withUnsafeBufferPointer { arguments in
                unsafe ABIUnsafeInvokeSwiftCallInterface(prepared.interface.handle,
                    storage.implementation.function, output.address, arguments.baseAddress,
                    storage.value.context.map { UnsafeRawPointer($0) }, &error)
            }
        }
        guard invoked else { throw consumeNativeCallFailure(error, domain: "ABIBridge.ClosureTest") }
        try #require(output.address.load(as: UnsafeMutableRawPointer.self) == input.address)
        #endif
        #expect(try unsafe stored.unsafeInvoke(("789", 7), withResult: { try unsafe readTuple.unsafeInvoke($0) }) == 789)
        let readNumber = try await runtime.resolve(
            .function(module + ".readNumber(_:)", as: ((NativeSwiftBorrowedValue) -> Int64).self), in: scope
        )
        typealias FunctionTupleBorrower = NativeSwiftClosure<((String, NativeSwiftClosure<(Int64) -> Int64>)) -> NativeSwiftBorrowedValue>
        let makeFunctionTuple = try await runtime.resolve(
            .function(module + ".makeFunctionTuple()", as: (() -> FunctionTupleBorrower).self,
                declaredAs: "() -> @_lifetime(borrow pair) (_ pair: (Swift.String, (Swift.Int64) -> Swift.Int64)) -> \(module).Number"), in: scope
        )
        let functionTuple = try unsafe makeFunctionTuple.unsafeInvoke()
        let transform = try NativeSwiftClosure<(Int64) -> Int64> { $0 + 7 }
        #expect(try unsafe functionTuple.unsafeInvoke(("123", transform), withResult: { try unsafe readNumber.unsafeInvoke($0) }) == 42)
        let makeResultTuple = try await runtime.resolve(
            .function(module + ".makeResultTuple()", as: (() -> NativeSwiftValue).self), in: scope
        )
        let erasedResultTuple = try unsafe makeResultTuple.unsafeInvoke()
        let resultTuple = try await erasedResultTuple.resolveClosure(as: (() -> NativeSwiftBorrowedValue).self)
        try unsafe resultTuple.unsafeInvoke(withResult: { value in
            #expect(value.type.name.contains(module + ".Number"))
            #expect(throws: ABIResolutionError.self) { try value.copy() }
        })
        let makeAsync = try await runtime.resolve(
            .function(
                module + ".makeAsync()",
                as: (() -> NativeSwiftClosure<nonisolated(nonsending) (String) async -> NativeSwiftBorrowedValue>).self,
                declaredAs: "() -> nonisolated(nonsending) @_lifetime(borrow text) (_ text: Swift.String) async -> \(module).View"
            ), in: scope
        )
        let asynchronous = try unsafe makeAsync.unsafeInvoke()
        #expect(try unsafe await asynchronous.unsafeInvoke("123", withResult: { value in
            await Task.yield()
            return try unsafe read.unsafeInvoke(value)
        }) == 123)
    }
    #endif

    @available(macOS 26.0, *)
    @Test func declaredLifetimeInputsSelectTheirNativeStorage() async throws {
        let (library, module) = try provider(
            """
            @available(macOS 26.0, *)
            public struct View: ~Escapable {
                let bytes: Span<UInt8>
                @_lifetime(copy bytes) init(_ bytes: Span<UInt8>) { self.bytes = bytes }
                @_lifetime(borrow text) public init(text: borrowing String) { self.bytes = text.utf8Span.span }
            }
            @available(macOS 26.0, *)
            @_lifetime(borrow a) @inline(never) public func first(_ a: String, _ b: String) -> View { View(a.utf8Span.span) }
            @available(macOS 26.0, *)
            @_lifetime(borrow b) @inline(never) public func second(_ a: String, _ b: String) -> View { View(b.utf8Span.span) }
            @available(macOS 26.0, *)
            @_lifetime(borrow text) @inline(never) public nonisolated(nonsending) func asyncText(_ text: String) async -> View {
                await Task.yield()
                return View(text.utf8Span.span)
            }
            @available(macOS 26.0, *)
            @_lifetime(copy view) @inline(never) public func copied(_ text: String, _ view: View) -> View { view }
            @available(macOS 26.0, *)
            @_lifetime(borrow pair) @inline(never) public func tuple(_ pair: (String, Int64)) -> Number { Number(Int64(pair.0.utf8.count) + pair.1) }
            // Copyable stored vars expose both this module's AFD support and
            // its lack of library evolution; nonescapable accessors do not.
            public struct LifetimeEvidence { public var text: String = "evidence" }
            public struct Number: ~Escapable {
                let value: Int64
                @_lifetime(immortal) init(_ value: Int64) { self.value = value }
            }
            @_lifetime(borrow pair) @inline(never) public func genericTuple<T>(_ pair: (T, Int64)) -> Number { Number(pair.1) }
            public final class ClassBoundOwner { public init() {} }
            @inline(never) public func classBoundOwner() -> ClassBoundOwner { ClassBoundOwner() }
            @_lifetime(borrow pair) @inline(never) public func classBoundTuple<T: AnyObject>(_ pair: (T, Int64)) -> Number { Number(pair.1) }
            @inline(never) public func readNumber(_ number: borrowing Number) -> Int64 { number.value }
            @_lifetime(borrow text) @inline(never) public func projected<T: ~Escapable>(_ text: String, _ value: consuming T?) -> T? {
                unsafe _overrideLifetime(value, borrowing: text)
            }
            @_lifetime(borrow text) @inline(never) public func opaqueProjected<T: ~Escapable>(_ text: String, _ value: consuming T) -> some ~Escapable {
                unsafe _overrideLifetime(value, borrowing: text)
            }
            extension String {
                @available(macOS 26.0, *)
                @_lifetime(borrow self) @inline(never) public func declaredScoped<T>(_ value: T) -> View { View(utf8Span.span) }
                @_lifetime(borrow self) @inline(never) public func declaredProjected<T: ~Escapable>(_ value: consuming T) -> T {
                    unsafe _overrideLifetime(value, borrowing: self)
                }
            }
            extension Optional where Wrapped == String {
                @_lifetime(borrow self) @inline(never) public func declaredSize<T>(_ value: T) -> Number {
                    Number(Int64(MemoryLayout<T>.size))
                }
            }
            @available(macOS 26.0, *)
            @inline(never) public func read(_ view: borrowing View) -> Int64 {
                var number: Int64 = 0
                for i in view.bytes.indices { number = number * 10 + (Int64(view.bytes[i]) - 48) }
                return number
            }
            """,
            arguments: ["-enable-experimental-feature", "Lifetimes"]
        )
        defer { library.cleanup() }
        let scope = ImageSelector.path(library.libraryURL)
        let read = try await runtime.resolve(
            .function(
                module + ".read(_:)",
                as: ((NativeSwiftBorrowedValue) -> Int64).self
            ),
            in: scope
        )
        for (name, source, expected) in [("first", "a", Int64(123)), ("second", "b", Int64(456))] {
            let borrow = try await runtime.resolve(
                .function(
                    module + "." + name + "(_:_:)",
                    as: ((String, String) -> NativeSwiftBorrowedValue).self,
                    declaredAs:
                        "@_lifetime(borrow \(source)) (_ a: Swift.String, _ b: Swift.String) -> \(module).View"
                ),
                in: scope
            )
            #expect(
                try unsafe borrow.unsafeInvoke(
                    "123",
                    "456",
                    withResult: { view in
                        // The result reads small-string bytes in the very input storage
                        // passed to native code, until this body finishes.
                        try unsafe read.unsafeInvoke(view)
                    }
                ) == expected
            )
        }
        let asyncText = try await runtime.resolve(
            .function(
                module + ".asyncText(_:)",
                as: (nonisolated(nonsending) (String) async -> NativeSwiftBorrowedValue).self,
                declaredAs:
                    "nonisolated(nonsending) @_lifetime(borrow text) (_ text: Swift.String) async -> \(module).View"
            ),
            in: scope
        )
        #expect(
            try unsafe await asyncText.unsafeInvoke(
                "123",
                withResult: { value in
                    await Task.yield()
                    return try unsafe read.unsafeInvoke(value)
                }
            ) == 123
        )
        let tuple = try await runtime.resolve(
            .function(
                module + ".tuple(_:)",
                as: (((String, Int64)) -> NativeSwiftBorrowedValue).self,
                declaredAs:
                    "@_lifetime(borrow pair) (_ pair: (Swift.String, Swift.Int64)) -> \(module).Number"
            ),
            in: scope
        )
        let generic = try await runtime.resolve(
            .function(
                module + ".genericTuple(_:)",
                as: (((Int64, Int64)) -> NativeSwiftBorrowedValue).self,
                genericArguments: [.type(Int64.self)],
                declaredAs:
                    "<A> @_lifetime(borrow pair) (_ pair: (A, Swift.Int64)) -> \(module).Number"
            ),
            in: scope
        )
        let readNumber = try await runtime.resolve(
            .function(
                module + ".readNumber(_:)",
                as: ((NativeSwiftBorrowedValue) -> Int64).self
            ),
            in: scope
        )
        let owner = try await runtime.resolve(
            .function(module + ".classBoundOwner()", as: (() -> NativeSwiftValue).self),
            in: scope
        )
        let ownerType = try await runtime.resolveSwiftType(
            named: module + ".ClassBoundOwner",
            in: scope
        )
        let classBound = try await runtime.resolve(
            .function(
                module + ".classBoundTuple(_:)",
                as: (((NativeSwiftValue, Int64)) -> NativeSwiftBorrowedValue).self,
                genericArguments: [.type(ownerType)]
            ),
            in: scope
        )
        #expect(
            try unsafe classBound.unsafeInvoke(
                (owner.unsafeInvoke(), Int64(42)),
                withResult: { try unsafe readNumber.unsafeInvoke($0) }
            ) == 42
        )
        #expect(
            try unsafe tuple.unsafeInvoke(
                ("123", Int64(7)),
                withResult: { try unsafe readNumber.unsafeInvoke($0) }
            ) == 10
        )
        await #expect {
            _ = try await runtime.resolve(
                .function(
                    module + ".projected(_:_:)",
                    as: ((String, NativeSwiftConsuming<Int64?>) -> Int64?).self,
                    genericArguments: [.type(Int64.self)]
                ),
                in: scope
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains(
                "Cannot decide how Swift passes argument 0 of type Swift.String"
            )
        }
        let projected = try await runtime.resolve(
            .function(
                module + ".projected(_:_:)",
                as: ((String, NativeSwiftConsuming<Int64?>) -> Int64?).self,
                genericArguments: [.type(Int64.self)],
                declaredAs:
                    "<A where A: ~Escapable> @_lifetime(borrow text) (_ text: Swift.String, _ value: consuming A?) -> A?"
            ),
            in: scope
        )
        #expect(
            try unsafe projected.unsafeInvoke("123", NativeSwiftConsuming(Optional(Int64(789))))
                == 789
        )
        await #expect {
            _ = try await runtime.resolve(
                .function(
                    module + ".opaqueProjected(_:_:)",
                    as: ((String, NativeSwiftConsuming<Int64>) -> NativeSwiftValue).self,
                    genericArguments: [.type(Int64.self)]
                ),
                in: scope
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains(
                "Cannot decide how Swift passes argument 0 of type Swift.String"
            )
        }
        let opaqueProjected = try await runtime.resolve(
            .function(
                module + ".opaqueProjected(_:_:)",
                as: ((String, NativeSwiftConsuming<Int64>) -> NativeSwiftValue).self,
                genericArguments: [.type(Int64.self)],
                declaredAs:
                    "<A where A: ~Escapable> @_lifetime(borrow text) (_ text: Swift.String, _ value: consuming A) -> some"
            ),
            in: scope
        )
        #expect(
            try unsafe opaqueProjected.unsafeInvoke("123", NativeSwiftConsuming(Int64(987)))
                .take(as: Int64.self) == 987
        )
        #expect(
            try unsafe generic.unsafeInvoke(
                (Int64(7), Int64(456)),
                withResult: { try unsafe readNumber.unsafeInvoke($0) }
            ) == 456
        )
        let viewType = try await runtime.resolveSwiftType(named: module + ".View", in: scope)
        let makeView = try await viewType.resolve(
            .initializer(
                "init(text:)",
                as: ((NativeSwiftBorrowing<String>) -> NativeSwiftBorrowedValue).self,
                declaredAs:
                    "@_lifetime(borrow text) (text: borrowing Swift.String) -> \(module).View"
            )
        )
        #expect(
            try unsafe makeView.unsafeInvoke(
                NativeSwiftBorrowing("123"),
                withResult: { try unsafe read.unsafeInvoke($0) }
            ) == 123
        )
        let string = try await runtime.resolveSwiftType(named: "Swift.String")
        let method = try await string.resolve(
            .method(
                "declaredScoped(_:)",
                as: ((Int64) -> NativeSwiftBorrowedValue).self,
                genericArguments: [.type(Int64.self)],
                declaredAs: "<A> @_lifetime(borrow self) (_ value: A) -> \(module).View"
            )
        )
        #expect(
            try unsafe method.unsafeInvoke(
                on: "789",
                Int64(7),
                withResult: { try unsafe read.unsafeInvoke($0) }
            ) == 789
        )
        let optionalString = try await runtime.resolveSwiftType(
            named: "Swift.Optional",
            genericArguments: [.type(String.self)]
        )
        let optionalABI = try NativeType.structure(
            named: "OptionalString",
            fields: [.uint64, .uint64]
        )
        for receiverABI in [nil, optionalABI] as [NativeType?] {
            let size = try await optionalString.resolve(
                .method(
                    "declaredSize(_:)",
                    as: ((Int64) -> NativeSwiftBorrowedValue).self,
                    genericArguments: [.type(Int64.self)],
                    declaredAs:
                        "<A, A1 where A == Swift.String> @_lifetime(borrow self) (_ value: A1) -> \(module).Number",
                    receiverABI: receiverABI
                )
            )
            #expect(
                try unsafe size.unsafeInvoke(
                    on: Optional("789"),
                    Int64(7),
                    withResult: { try unsafe readNumber.unsafeInvoke($0) }
                ) == Int64(MemoryLayout<Int64>.size)
            )
        }
        await #expect {
            _ = try await string.resolve(
                .method(
                    "declaredProjected(_:)",
                    as: ((NativeSwiftConsuming<Int64>) -> Int64).self,
                    genericArguments: [.type(Int64.self)]
                )
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("Cannot decide how Swift passes self of type Swift.String")
        }
        let projectedMethod = try await string.resolve(
            .method(
                "declaredProjected(_:)",
                as: ((NativeSwiftConsuming<Int64>) -> Int64).self,
                genericArguments: [.type(Int64.self)],
                declaredAs:
                    "<A where A: ~Escapable> @_lifetime(borrow self) (_ value: consuming A) -> A"
            )
        )
        #expect(
            try unsafe projectedMethod.unsafeInvoke(on: "123", NativeSwiftConsuming(Int64(456)))
                == 456
        )
        let copied = try await runtime.resolve(
            .function(
                module + ".copied(_:_:)",
                as: ((String, NativeSwiftBorrowedValue) -> NativeSwiftBorrowedValue).self,
                declaredAs:
                    "@_lifetime(copy view) (_ text: Swift.String, _ view: \(module).View) -> \(module).View"
            ),
            in: scope
        )
        let first = try await runtime.resolve(
            .function(
                module + ".first(_:_:)",
                as: ((String, String) -> NativeSwiftBorrowedValue).self,
                declaredAs:
                    "@_lifetime(borrow a) (_ a: Swift.String, _ b: Swift.String) -> \(module).View"
            ),
            in: scope
        )
        #expect(
            try unsafe first.unsafeInvoke(
                "123",
                "456",
                withResult: { view in
                    try unsafe copied.unsafeInvoke(
                        "456",
                        view,
                        withResult: { try unsafe read.unsafeInvoke($0) }
                    )
                }
            ) == 123
        )
    }

    /// Swift passes an input that a result borrows from by address when its
    /// type sets the addressable-for-dependencies bit, a tuple as one
    /// address instead of its elements, and no symbol or metadata records
    /// which inputs a result borrows from. In a call with a scoped result, a
    /// borrowed parameter or `self` that ABIBridge passes directly is
    /// therefore undecided when its type sets the bit, whether inference, a
    /// built-in representation, or an explicit ABI describes it, and when
    /// nothing shows the bit, as for a generic instance. A type that leaves
    /// the bit clear, a value that passes by address anyway, and consuming
    /// and inout inputs keep their conventions.
    @Test func resultsThatBorrowFromInputsLeaveAddressableInputsUndecided() async throws {
        let (library, module) = try provider(
            """
            import CoreFoundation
            public struct View: ~Escapable {
                let n: Int64
                @_lifetime(immortal) public init(_ n: Int64) { self.n = n }
            }
            public struct Label {
                public var text: String
                public var n: Int64
                public init(text: String, n: Int64) { self.text = text; self.n = n }
            }
            public struct Plain {
                public var x: Int64
                public var y: Int64
                public init(x: Int64, y: Int64) { self.x = x; self.y = y }
            }
            extension Label {
                @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(n) }
            }
            extension Plain {
                @_lifetime(borrow self) @inline(never) public func scoped() -> View { View(x * 10 + y) }
            }
            extension String {
                @_lifetime(borrow self) @inline(never) public func scopedCount() -> View { View(Int64(utf8.count)) }
            }
            @_lifetime(borrow v) @inline(never) public func borrowLabel(_ v: Label) -> View { View(v.n) }
            @_lifetime(borrow v) @inline(never) public func borrowPlain(_ v: Plain) -> View { View(v.x * 10 + v.y) }
            @_lifetime(borrow s) @inline(never) public func borrowString(_ s: String) -> View { View(Int64(s.utf8.count)) }
            @_lifetime(borrow v) @inline(never) public func borrowPlainConsuming(_ v: Plain, _ s: consuming String) -> View {
                View(v.x * 100 + Int64(s.utf8.count))
            }
            @_lifetime(borrow v) @inline(never) public func borrowComparison(_ v: CFComparisonResult) -> View {
                View(Int64(v.rawValue))
            }
            @_lifetime(borrow v) @inline(never) public func borrowCompareFlags(_ v: CFStringCompareFlags) -> View {
                View(Int64(v.rawValue))
            }
            @_lifetime(borrow v) @inline(never) public func borrowPack<each T>(_ v: repeat (each T, Int64)) -> View {
                var sum: Int64 = 0
                for element in repeat each v { sum += element.1 }
                return View(sum)
            }
            @_lifetime(&s) @inline(never) public func mutateString(_ s: inout String) -> View {
                s += "!"
                return View(Int64(s.utf8.count))
            }
            #if compiler(>=6.4)
            @inline(never) public func makeBorrower() -> @_lifetime(borrow s) (_ s: String) -> View {
                { s in View(Int64(s.utf8.count)) }
            }
            #endif
            public struct Wide {
                public var text: String
                public var a: Int64
                public var b: Int64
                public var c: Int64
                public init() { text = "wide"; a = 5; b = 6; c = 7 }
            }
            @_lifetime(borrow t) @inline(never) public func borrowTriple(_ t: (Label, Int64, Int64)) -> View { View(t.1) }
            public struct Pair<T> {
                public var a: T
                public var b: T
                public init(a: T, b: T) { self.a = a; self.b = b }
            }
            @_lifetime(borrow p) @inline(never) public func borrowPair(_ p: Pair<Int64>) -> View { View(p.a) }
            @inline(never) public func makePair() -> Pair<Int64> { Pair(a: 1, b: 2) }
            @inline(never) public func describePair(_ p: Pair<Int64>) -> String { "\\(p.a),\\(p.b)" }
            @_lifetime(borrow w) @inline(never) public func borrowWide(_ w: Wide) -> View { View(w.a * 10 + w.c) }
            @inline(never) public func makeWide() -> Wide { Wide() }
            @inline(never) public func makeLabel() -> Label { Label(text: "label", n: 4) }
            @inline(never) public func describeLabel(_ v: Label) -> String { "\\(v.text),\\(v.n)" }
            @inline(never) public func makePlain() -> Plain { Plain(x: 2, y: 3) }
            @inline(never) public func read(_ v: borrowing View) -> Int64 { v.n }
            """,
            arguments: ["-enable-experimental-feature", "Lifetimes"]
        )
        defer { library.cleanup() }
        let scope = ImageSelector.path(library.libraryURL)
        func expectUndecided(
            _ input: String,
            naming evidence: String,
            sourceLocation: SourceLocation = #_sourceLocation,
            _ resolve: () async throws -> Void
        ) async {
            await #expect(sourceLocation: sourceLocation) {
                try await resolve()
            } throws: { error in
                guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                    return false
                }
                return message.contains(
                    "Cannot decide how Swift passes \(input), because the call's result can borrow from it."
                )
                    && message.contains(evidence)
                    && message.contains(
                        "No symbol or metadata records which inputs a result borrows from."
                    )
            }
        }
        // Label is loadable where nothing borrows from it.
        #expect(
            try await describeMade(module + ".makeLabel()", module + ".describeLabel(_:)", in: library)
                == "label,4"
        )
        let label = try await runtime.resolveSwiftType(named: module + ".Label", in: scope)
        let labelSets = "the static value witnesses of `\(module).Label` set it"
        await expectUndecided("argument 0 of type \(module).Label", naming: labelSets) {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowLabel(_:)",
                    as: ((NativeSwiftValue) -> NativeSwiftBorrowedValue).self
                ),
                in: scope
            )
        }
        // Its elements would pass separately, the tuple as one address.
        await expectUndecided(
            "argument 0 of type (\(module).Label, Swift.Int64, Swift.Int64)",
            naming: "even a tuple, whose elements ABIBridge passes separately, and " + labelSets
        ) {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowTriple(_:)",
                    as: (((NativeSwiftValue, Int64, Int64)) -> NativeSwiftBorrowedValue).self
                ),
                in: scope
            )
        }
        #expect(
            try await describeMade(module + ".makePair()", module + ".describePair(_:)", in: library) == "1,2"
        )
        await expectUndecided(
            "argument 0 of type \(module).Pair<Swift.Int64>",
            naming:
                "nothing shows whether it does: `\(module).Pair<Swift.Int64>` is a generic instance"
        ) {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowPair(_:)",
                    as: ((NativeSwiftValue) -> NativeSwiftBorrowedValue).self
                ),
                in: scope
            )
        }
        // A stated dependency supplies the position, not the missing AFD evidence.
        await #expect {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowPair(_:)",
                    as: ((NativeSwiftValue) -> NativeSwiftBorrowedValue).self,
                    declaredAs:
                        "@_lifetime(borrow p) (_ p: \(module).Pair<Swift.Int64>) -> \(module).View"
                ),
                in: scope
            )
        } throws: { error in
            guard case ABIResolutionError.metadataUnavailable(let message) = error else {
                return false
            }
            return message.contains("The declared result borrows argument 0")
                && message.contains("generic instance")
        }
        await expectUndecided("self of type \(module).Label", naming: labelSets) {
            _ = try await label.resolve(
                .method("scoped()", as: (() -> NativeSwiftBorrowedValue).self)
            )
        }
        // A built-in representation or an explicit ABI describes how a value
        // passes without a scoped result, and nothing records whether it
        // has one.
        let stringSets = "`Swift.String` sets it"
        await expectUndecided("argument 0 of type Swift.String", naming: stringSets) {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowString(_:)",
                    as: ((String) -> NativeSwiftBorrowedValue).self
                ),
                in: scope
            )
        }
        await expectUndecided("self of type Swift.String", naming: stringSets) {
            _ = try await runtime.resolveSwiftType(named: "Swift.String")
                .resolve(.method("scopedCount()", as: (() -> NativeSwiftBorrowedValue).self))
        }
        let labelABI = try NativeType.structure(
            named: "Label",
            fields: [.uint64, .pointer, .int64]
        )
        await expectUndecided("self of type \(module).Label", naming: labelSets) {
            _ = try await label.resolve(
                .method(
                    "scoped()",
                    as: (() -> NativeSwiftBorrowedValue).self,
                    receiverABI: labelABI
                )
            )
        }
        await expectUndecided("argument 0 of type \(module).Label", naming: labelSets) {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowLabel(_:)",
                    as: ((NativeSwiftValue) -> NativeSwiftBorrowedValue).self,
                    valueABIs: [label: labelABI]
                ),
                in: scope
            )
        }
        #if compiler(>=6.4)
        // A closure's function type does not record its lifetime
        // dependencies either.
        await expectUndecided("argument 0 of type Swift.String", naming: stringSets) {
            _ = try await runtime.resolve(
                .function(
                    module + ".makeBorrower()",
                    as: (() -> NativeSwiftClosure<(String) -> NativeSwiftBorrowedValue>).self
                ),
                in: scope
            )
        }
        #endif
        // Plain's static value witnesses decide it and leave the bit clear.
        let make = try await runtime.resolve(
            .function(
                module + ".makePlain()",
                as: (() -> NativeSwiftValue).self
            ),
            in: scope
        )
        let read = try await runtime.resolve(
            .function(
                module + ".read(_:)",
                as: ((NativeSwiftBorrowedValue) -> Int64).self
            ),
            in: scope
        )
        let borrow = try await runtime.resolve(
            .function(
                module + ".borrowPlain(_:)",
                as: ((NativeSwiftValue) -> NativeSwiftBorrowedValue).self
            ),
            in: scope
        )
        let plain = try unsafe make.unsafeInvoke()
        #expect(try unsafe borrow.unsafeInvoke(plain, withResult: { try unsafe read.unsafeInvoke($0) }) == 23)
        // Wide passes by address by size, as a borrowed value does.
        let makeWide = try await runtime.resolve(
            .function(
                module + ".makeWide()",
                as: (() -> NativeSwiftValue).self
            ),
            in: scope
        )
        let borrowWide = try await runtime.resolve(
            .function(
                module + ".borrowWide(_:)",
                as: ((NativeSwiftValue) -> NativeSwiftBorrowedValue).self
            ),
            in: scope
        )
        #expect(
            try unsafe borrowWide.unsafeInvoke(makeWide.unsafeInvoke(), withResult: { try unsafe read.unsafeInvoke($0) })
                == 57
        )
        let scoped = try await runtime.resolveSwiftType(named: module + ".Plain", in: scope)
            .resolve(.method("scoped()", as: (() -> NativeSwiftBorrowedValue).self))
        #expect(try unsafe scoped.unsafeInvoke(on: plain, withResult: { try unsafe read.unsafeInvoke($0) }) == 23)
        // Swift rejects a borrow dependency on a consuming String, and passes
        // an inout String by address either way.
        let consuming = try await runtime.resolve(
            .function(
                module + ".borrowPlainConsuming(_:_:)",
                as: ((NativeSwiftValue, NativeSwiftConsuming<String>) -> NativeSwiftBorrowedValue)
                    .self
            ),
            in: scope
        )
        let counted = try unsafe consuming.unsafeInvoke(
            plain,
            NativeSwiftConsuming("four"),
            withResult: { try unsafe read.unsafeInvoke($0) }
        )
        #expect(counted == 204)
        let mutate = try await runtime.resolve(
            .function(
                module + ".mutateString(_:)",
                as: ((NativeSwiftInout<String>) -> NativeSwiftBorrowedValue).self
            ),
            in: scope
        )
        let text = NativeSwiftInout("text")
        let mutated = try unsafe mutate.unsafeInvoke(
            text,
            withResult: { try unsafe read.unsafeInvoke($0) }
        )
        #expect(mutated == 5)
        #expect(text.value == "text!")
        // An imported C enum never sets the bit, whatever describes its
        // passing. The importer makes an option set a struct, which a C
        // struct or union also is, so its clear bit shows nothing.
        let comparison = try await runtime.resolve(
            .function(
                module + ".borrowComparison(_:)",
                as: ((CFComparisonResult) -> NativeSwiftBorrowedValue).self
            ),
            in: scope
        )
        let compared = try unsafe comparison.unsafeInvoke(
            CFComparisonResult.compareGreaterThan,
            withResult: { try unsafe read.unsafeInvoke($0) }
        )
        #expect(compared == 1)
        await expectUndecided(
            "argument 0 of type __C.CFStringCompareFlags",
            naming: "do not show whether it imports a C struct or union"
        ) {
            _ = try await runtime.resolve(
                .function(
                    module + ".borrowCompareFlags(_:)",
                    as: ((CFStringCompareFlags) -> NativeSwiftBorrowedValue).self
                ),
                in: scope
            )
        }
        // A pack passes its elements' addresses through one buffer, whether
        // or not the result borrows from them.
        let pack = try await runtime.resolve(
            .function(
                module + ".borrowPack(_:)",
                as: (((String, Int64)) -> NativeSwiftBorrowedValue).self,
                genericArguments: [.pack([.type(String.self)])]
            ),
            in: scope
        )
        let summed = try unsafe pack.unsafeInvoke(
            ("seven", 7),
            withResult: { try unsafe read.unsafeInvoke($0) }
        )
        #expect(summed == 7)
    }
}
#endif
