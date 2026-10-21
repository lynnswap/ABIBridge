import ABIBridge
import Foundation

#if os(macOS)
// Runtime-only values of provider structs and enums that have no explicit ABI.
// ABIBridge infers their conventions from metadata and export evidence; where
// library evolution hides whether a type is frozen, the call must fail and
// name the missing evidence.

private func describe(_ value: some Any) -> String { String(describing: value) }

/// Passes the runtime-only result of `make` to `describe`.
private func describeMade(
    _ f: ConformanceFixture,
    _ make: String,
    _ describe: String
) async throws -> String {
    let make = try await f.function(make, as: (() -> NativeSwiftValue).self)
    let text = try await f.function(describe, as: ((NativeSwiftValue) -> String).self)
    return try unsafe text.unsafeInvoke(make.unsafeInvoke())
}

/// Passes the runtime-only result of `make` through `transform`, a function
/// from the value and an Int64 to another value, and then to `describe`.
private func describeTransformed(
    _ f: ConformanceFixture,
    _ make: String,
    _ transform: String,
    _ describe: String
) async throws -> String {
    let make = try await f.function(make, as: (() -> NativeSwiftValue).self)
    let transform = try await f.function(
        transform,
        as: ((NativeSwiftValue, Int64) -> NativeSwiftValue).self
    )
    let text = try await f.function(describe, as: ((NativeSwiftValue) -> String).self)
    return try unsafe text.unsafeInvoke(transform.unsafeInvoke(make.unsafeInvoke(), 3))
}

/// Describes the results of `make` for each kind, joined with `|`.
private func describeKinds(
    _ f: ConformanceFixture,
    _ make: String,
    _ describe: String,
    kinds: [Int64]
) async throws -> String {
    let make = try await f.function(make, as: ((Int64) -> NativeSwiftValue).self)
    let text = try await f.function(describe, as: ((NativeSwiftValue) -> String).self)
    return try kinds.map { try unsafe text.unsafeInvoke(make.unsafeInvoke($0)) }
        .joined(separator: "|")
}

extension ConformanceCase {
    /// The evolution variants do not record whether these types are frozen.
    static func undecidedWithLibraryEvolution(
        _ evidence: String
    )
        -> @Sendable (
            ConformanceVariant
        ) -> String?
    {
        { $0.libraryEvolution ? evidence : nil }
    }

    static let inferredValues: [ConformanceCase] = [
        ConformanceCase(
            id: "value.openStruct.inferred",
            provider: """
                public struct CMOpenPoint {
                    public var x: Double
                    public var y: Double
                    public init(x: Double, y: Double) { self.x = x; self.y = y }
                }
                @inline(never) public func cmMakeOpenPoint() -> CMOpenPoint { CMOpenPoint(x: 1, y: 2) }
                @inline(never) public func cmMoveOpenPoint(_ p: CMOpenPoint, _ dx: Int64) -> CMOpenPoint {
                    CMOpenPoint(x: p.x + Double(dx), y: p.y)
                }
                @inline(never) public func cmDescribeOpenPoint(_ p: CMOpenPoint) -> String { "\\(p.x),\\(p.y)" }
                """,
            oracle: "return cmDescribeOpenPoint(cmMoveOpenPoint(cmMakeOpenPoint(), 3))"
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeOpenPoint()",
                "cmMoveOpenPoint(_:_:)",
                "cmDescribeOpenPoint(_:)"
            )
        },
        ConformanceCase(
            id: "value.resilientStruct.inferred",
            provider: "",
            oracle: "return cmDescribeRecord(cmBump(cmMakeRecord()))",
            invoke: { f in
                let make = try await f.function("cmMakeRecord()", as: (() -> NativeSwiftValue).self)
                let bump = try await f.function(
                    "cmBump(_:)",
                    as: ((NativeSwiftValue) -> NativeSwiftValue).self
                )
                let text = try await f.function(
                    "cmDescribeRecord(_:)",
                    as: ((NativeSwiftValue) -> String).self
                )
                return try unsafe text.unsafeInvoke(bump.unsafeInvoke(make.unsafeInvoke()))
            },
            expectedError: undecidedWithLibraryEvolution("its field `name: Swift.String` explains")
        ),
        ConformanceCase(
            id: "value.frozenStringStruct.inferred",
            provider: """
                @frozen public struct CMLabel {
                    public var text: String
                    public var count: Int64
                    public init(text: String, count: Int64) { self.text = text; self.count = count }
                }
                @inline(never) public func cmMakeLabel() -> CMLabel { CMLabel(text: "label", count: 1) }
                @inline(never) public func cmGrowLabel(_ l: CMLabel, _ n: Int64) -> CMLabel {
                    CMLabel(text: l.text + "+", count: l.count + n)
                }
                @inline(never) public func cmDescribeLabel(_ l: CMLabel) -> String { "\\(l.text)#\\(l.count)" }
                """,
            oracle: "return cmDescribeLabel(cmGrowLabel(cmMakeLabel(), 3))",
            invoke: { f in
                try await describeTransformed(
                    f,
                    "cmMakeLabel()",
                    "cmGrowLabel(_:_:)",
                    "cmDescribeLabel(_:)"
                )
            },
            expectedError: undecidedWithLibraryEvolution("its field `text: Swift.String` explains")
        ),
        ConformanceCase(
            id: "value.payloadEnum.inferred",
            provider: "",
            oracle:
                "return (0..<3).map { cmDescribeShape(cmMakeShape($0)) }.joined(separator: \"|\")"
        ) { f in
            try await describeKinds(f, "cmMakeShape(_:)", "cmDescribeShape(_:)", kinds: [0, 1, 2])
        },
        ConformanceCase(
            id: "value.frozenEnum.inferred",
            provider: """
                @frozen public enum CMOnly { case only(Double) }
                @frozen public enum CMOnlyPair { case pair(Double, Float) }
                @frozen public enum CMMixed { case real(Double), whole(Int64), none }
                @frozen public enum CMPlain { case a, b, c }
                @inline(never) public func cmMakeOnly(_ k: Int64) -> CMOnly { .only(Double(k) + 0.5) }
                @inline(never) public func cmDescribeOnly(_ v: CMOnly) -> String { "\\(v)" }
                @inline(never) public func cmMakeOnlyPair(_ k: Int64) -> CMOnlyPair { .pair(Double(k), Float(k) / 2) }
                @inline(never) public func cmDescribeOnlyPair(_ v: CMOnlyPair) -> String { "\\(v)" }
                @inline(never) public func cmMakeMixed(_ k: Int64) -> CMMixed {
                    k == 0 ? .real(1.5) : k == 1 ? .whole(7) : .none
                }
                @inline(never) public func cmDescribeMixed(_ v: CMMixed) -> String { "\\(v)" }
                @inline(never) public func cmMakePlain(_ k: Int64) -> CMPlain { k == 0 ? .a : k == 1 ? .b : .c }
                @inline(never) public func cmDescribePlain(_ v: CMPlain) -> String { "\\(v)" }
                """,
            oracle: """
                let kinds: [Int64] = [0, 1, 2]
                return [
                    kinds.map { cmDescribeOnly(cmMakeOnly($0)) },
                    kinds.map { cmDescribeOnlyPair(cmMakeOnlyPair($0)) },
                    kinds.map { cmDescribeMixed(cmMakeMixed($0)) },
                    kinds.map { cmDescribePlain(cmMakePlain($0)) },
                ].map { $0.joined(separator: "|") }.joined(separator: ";")
                """
        ) { f in
            var parts: [String] = []
            for (make, text) in [
                ("cmMakeOnly(_:)", "cmDescribeOnly(_:)"),
                ("cmMakeOnlyPair(_:)", "cmDescribeOnlyPair(_:)"),
                ("cmMakeMixed(_:)", "cmDescribeMixed(_:)"),
                ("cmMakePlain(_:)", "cmDescribePlain(_:)"),
            ] {
                parts.append(try await describeKinds(f, make, text, kinds: [0, 1, 2]))
            }
            return parts.joined(separator: ";")
        },
        ConformanceCase(
            id: "value.nestedFrozen.inferred",
            provider: """
                @frozen public struct CMInner {
                    public var a: Int64
                    public var b: UInt8
                    public init(a: Int64, b: UInt8) { self.a = a; self.b = b }
                }
                @frozen public struct CMPacked {
                    public var inner: CMInner
                    public var c: UInt8
                    public init(inner: CMInner, c: UInt8) { self.inner = inner; self.c = c }
                }
                public final class CMBox: Sendable {
                    public let value: Int64
                    public init(_ value: Int64) { self.value = value }
                }
                @frozen public struct CMRefPair {
                    public var box: CMBox
                    public var n: Int64
                    public init(box: CMBox, n: Int64) { self.box = box; self.n = n }
                }
                @frozen public struct CMHolder {
                    public var box: CMBox
                    public var apply: (Int64) -> Int64
                    public var kind: Int64.Type
                    public var point: CMPoint?
                    public init(box: CMBox, apply: @escaping (Int64) -> Int64, point: CMPoint?) {
                        self.box = box; self.apply = apply; kind = Int64.self; self.point = point
                    }
                }
                @inline(never) public func cmMakePacked() -> CMPacked { CMPacked(inner: CMInner(a: 7, b: 8), c: 9) }
                @inline(never) public func cmBumpPacked(_ p: CMPacked, _ n: Int64) -> CMPacked {
                    CMPacked(inner: CMInner(a: p.inner.a + n, b: p.inner.b + 1), c: p.c + 2)
                }
                @inline(never) public func cmDescribePacked(_ p: CMPacked) -> String { "\\(p.inner.a),\\(p.inner.b),\\(p.c)" }
                @inline(never) public func cmMakeRefPair() -> CMRefPair { CMRefPair(box: CMBox(21), n: 1) }
                @inline(never) public func cmBumpRefPair(_ p: CMRefPair, _ n: Int64) -> CMRefPair {
                    CMRefPair(box: CMBox(p.box.value + n), n: p.n + 1)
                }
                @inline(never) public func cmDescribeRefPair(_ p: CMRefPair) -> String { "\\(p.box.value),\\(p.n)" }
                @inline(never) public func cmMakeHolder() -> CMHolder {
                    CMHolder(box: CMBox(4), apply: { $0 * 10 }, point: CMPoint(x: 1, y: 2))
                }
                @inline(never) public func cmBumpHolder(_ h: CMHolder, _ n: Int64) -> CMHolder {
                    CMHolder(box: CMBox(h.box.value + n), apply: h.apply, point: nil)
                }
                @inline(never) public func cmDescribeHolder(_ h: CMHolder) -> String {
                    "\\(h.apply(h.box.value)),\\(h.kind),\\(h.point.map { "\\($0.x)" } ?? "nil")"
                }
                """,
            oracle: """
                return [
                    cmDescribePacked(cmBumpPacked(cmMakePacked(), 3)),
                    cmDescribeRefPair(cmBumpRefPair(cmMakeRefPair(), 3)),
                    cmDescribeHolder(cmMakeHolder()),
                    cmDescribeHolder(cmBumpHolder(cmMakeHolder(), 3)),
                ].joined(separator: "|")
                """
        ) { f in
            [
                try await describeTransformed(
                    f,
                    "cmMakePacked()",
                    "cmBumpPacked(_:_:)",
                    "cmDescribePacked(_:)"
                ),
                try await describeTransformed(
                    f,
                    "cmMakeRefPair()",
                    "cmBumpRefPair(_:_:)",
                    "cmDescribeRefPair(_:)"
                ),
                try await describeMade(f, "cmMakeHolder()", "cmDescribeHolder(_:)"),
                try await describeTransformed(
                    f,
                    "cmMakeHolder()",
                    "cmBumpHolder(_:_:)",
                    "cmDescribeHolder(_:)"
                ),
            ].joined(separator: "|")
        },
        ConformanceCase(
            id: "value.frozenHoldsOpen.inferred",
            provider: """
                @frozen public struct CMHoldsOpen {
                    public var point: CMOpenPoint
                    public var n: Int64
                    public init(point: CMOpenPoint, n: Int64) { self.point = point; self.n = n }
                }
                @inline(never) public func cmMakeHoldsOpen() -> CMHoldsOpen { CMHoldsOpen(point: CMOpenPoint(x: 1, y: 2), n: 3) }
                @inline(never) public func cmBumpHoldsOpen(_ h: CMHoldsOpen, _ n: Int64) -> CMHoldsOpen {
                    CMHoldsOpen(point: h.point, n: h.n + n)
                }
                @inline(never) public func cmDescribeHoldsOpen(_ h: CMHoldsOpen) -> String { "\\(h.point.x),\\(h.n)" }
                """,
            oracle: "return cmDescribeHoldsOpen(cmBumpHoldsOpen(cmMakeHoldsOpen(), 3))"
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeHoldsOpen()",
                "cmBumpHoldsOpen(_:_:)",
                "cmDescribeHoldsOpen(_:)"
            )
        },
        ConformanceCase(
            id: "value.frozenHoldsForeignResilient.inferred",
            provider: """
                import Foundation
                @frozen public struct CMDated {
                    public var date: Date
                    public var n: Int64
                    public init(date: Date, n: Int64) { self.date = date; self.n = n }
                }
                @inline(never) public func cmMakeDated() -> CMDated { CMDated(date: Date(timeIntervalSince1970: 86400), n: 3) }
                @inline(never) public func cmBumpDated(_ d: CMDated, _ n: Int64) -> CMDated {
                    CMDated(date: d.date.addingTimeInterval(Double(n)), n: d.n + n)
                }
                @inline(never) public func cmDescribeDated(_ d: CMDated) -> String { "\\(d.date.timeIntervalSince1970),\\(d.n)" }
                """,
            oracle: "return cmDescribeDated(cmBumpDated(cmMakeDated(), 3))"
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeDated()",
                "cmBumpDated(_:_:)",
                "cmDescribeDated(_:)"
            )
        },
        ConformanceCase(
            id: "value.largeFrozen.inferred",
            provider: """
                @frozen public struct CMWide5 {
                    public var a: Int64, b: Int64, c: Int64, d: Int64, e: Int64
                    public init(_ v: Int64) { a = v; b = v + 1; c = v + 2; d = v + 3; e = v + 4 }
                }
                @inline(never) public func cmMakeWide5() -> CMWide5 { CMWide5(1) }
                @inline(never) public func cmBumpWide5(_ w: CMWide5, _ n: Int64) -> CMWide5 { CMWide5(w.e + n) }
                @inline(never) public func cmDescribeWide5(_ w: CMWide5) -> String { "\\(w.a)...\\(w.e)" }
                """,
            oracle: "return cmDescribeWide5(cmBumpWide5(cmMakeWide5(), 3))"
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeWide5()",
                "cmBumpWide5(_:_:)",
                "cmDescribeWide5(_:)"
            )
        },
        ConformanceCase(
            id: "value.addressOnlyField.inferred",
            provider: """
                public let cmSharedBox = CMBox(11)
                @frozen public struct CMWeakHolder {
                    public weak var box: CMBox?
                    public var n: Int64
                    public init(box: CMBox?, n: Int64) { self.box = box; self.n = n }
                }
                public protocol CMValued { func value() -> Int64 }
                extension Int64: CMValued { public func value() -> Int64 { self } }
                @frozen public struct CMAnyHolder {
                    public var item: any CMValued
                    public var n: Int64
                    public init(item: any CMValued, n: Int64) { self.item = item; self.n = n }
                }
                @inline(never) public func cmMakeWeakHolder() -> CMWeakHolder { CMWeakHolder(box: cmSharedBox, n: 5) }
                @inline(never) public func cmBumpWeakHolder(_ h: CMWeakHolder, _ n: Int64) -> CMWeakHolder {
                    CMWeakHolder(box: h.box, n: h.n + n)
                }
                @inline(never) public func cmDescribeWeakHolder(_ h: CMWeakHolder) -> String { "\\(h.box?.value ?? -1),\\(h.n)" }
                @inline(never) public func cmMakeAnyHolder() -> CMAnyHolder { CMAnyHolder(item: Int64(4), n: 6) }
                @inline(never) public func cmBumpAnyHolder(_ h: CMAnyHolder, _ n: Int64) -> CMAnyHolder {
                    CMAnyHolder(item: h.item.value() + n, n: h.n)
                }
                @inline(never) public func cmDescribeAnyHolder(_ h: CMAnyHolder) -> String { "\\(h.item.value()),\\(h.n)" }
                """,
            oracle: """
                return cmDescribeWeakHolder(cmBumpWeakHolder(cmMakeWeakHolder(), 3)) + "|"
                    + cmDescribeAnyHolder(cmBumpAnyHolder(cmMakeAnyHolder(), 3))
                """
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeWeakHolder()",
                "cmBumpWeakHolder(_:_:)",
                "cmDescribeWeakHolder(_:)"
            ) + "|"
                + describeTransformed(
                    f,
                    "cmMakeAnyHolder()",
                    "cmBumpAnyHolder(_:_:)",
                    "cmDescribeAnyHolder(_:)"
                )
        },
        ConformanceCase(
            id: "value.optional.inferred",
            provider: """
                @frozen public struct CMFloats5 {
                    public var a: Float, b: Float, c: Float, d: Float, e: Float
                    public init(_ v: Float) { a = v; b = v; c = v; d = v; e = v + 1 }
                }
                @inline(never) public func cmMaybePoint(_ k: Int64) -> CMPoint? { k == 0 ? nil : CMPoint(x: Double(k), y: 2) }
                @inline(never) public func cmDescribeMaybePoint(_ p: CMPoint?) -> String { p.map { "\\($0.x),\\($0.y)" } ?? "nil" }
                @inline(never) public func cmMaybeOpenPoint(_ k: Int64) -> CMOpenPoint? { k == 0 ? nil : CMOpenPoint(x: Double(k), y: 3) }
                @inline(never) public func cmDescribeMaybeOpenPoint(_ p: CMOpenPoint?) -> String { p.map { "\\($0.x),\\($0.y)" } ?? "nil" }
                @inline(never) public func cmMaybeFloats(_ k: Int64) -> CMFloats5? { k == 0 ? nil : CMFloats5(Float(k)) }
                @inline(never) public func cmDescribeMaybeFloats(_ f: CMFloats5?) -> String { f.map { "\\($0.a),\\($0.e)" } ?? "nil" }
                """,
            oracle: """
                let kinds: [Int64] = [0, 3]
                return [
                    kinds.map { cmDescribeMaybePoint(cmMaybePoint($0)) },
                    kinds.map { cmDescribeMaybeOpenPoint(cmMaybeOpenPoint($0)) },
                    kinds.map { cmDescribeMaybeFloats(cmMaybeFloats($0)) },
                ].map { $0.joined(separator: "|") }.joined(separator: ";")
                """
        ) { f in
            var parts: [String] = []
            for (make, text) in [
                ("cmMaybePoint(_:)", "cmDescribeMaybePoint(_:)"),
                ("cmMaybeOpenPoint(_:)", "cmDescribeMaybeOpenPoint(_:)"),
                ("cmMaybeFloats(_:)", "cmDescribeMaybeFloats(_:)"),
            ] {
                parts.append(try await describeKinds(f, make, text, kinds: [0, 3]))
            }
            return parts.joined(separator: ";")
        },
        ConformanceCase(
            id: "value.receiver.inferred",
            provider: """
                extension CMPoint {
                    @inline(never) public func cmSum() -> Double { x + y }
                    @inline(never) public mutating func cmScale(_ k: Double) { x *= k; y *= k }
                }
                extension CMOpenPoint {
                    @inline(never) public func cmSum() -> Double { x + y }
                }
                extension CMWide5 {
                    @inline(never) public func cmSum() -> Int64 { a + b + c + d + e }
                }
                """,
            oracle: """
                var point = cmMakePoint()
                point.cmScale(3)
                return "\\(point.cmSum())|\\(cmDescribePoint(point))|\\(cmMakeOpenPoint().cmSum())|\\(cmMakeWide5().cmSum())"
                """
        ) { f in
            let point = try await f.type("CMPoint")
            let sum = try await point.resolveMethod(named: "cmSum()", as: (() -> Double).self)
            let scale = try await point.resolveMethod(
                named: "cmScale(_:)",
                as: ((Double) -> Void).self,
                mutating: true
            )
            let openSum = try await f.type("CMOpenPoint").resolveMethod(
                named: "cmSum()",
                as: (() -> Double).self
            )
            let wideSum = try await f.type("CMWide5").resolveMethod(
                named: "cmSum()",
                as: (() -> Int64).self
            )
            let make = try await f.function("cmMakePoint()", as: (() -> NativeSwiftValue).self)
            let text = try await f.function(
                "cmDescribePoint(_:)",
                as: ((NativeSwiftValue) -> String).self
            )
            let openPoint = try await f.function(
                "cmMakeOpenPoint()",
                as: (() -> NativeSwiftValue).self
            )
            let wide = try await f.function("cmMakeWide5()", as: (() -> NativeSwiftValue).self)
            let value = try unsafe make.unsafeInvoke()
            try unsafe scale.unsafeInvoke(on: value, 3)
            return try unsafe [
                describe(sum.unsafeInvoke(on: value)),
                text.unsafeInvoke(value),
                describe(openSum.unsafeInvoke(on: openPoint.unsafeInvoke())),
                describe(wideSum.unsafeInvoke(on: wide.unsafeInvoke())),
            ].joined(separator: "|")
        },
        ConformanceCase(
            id: "value.closure.inferred",
            provider: """
                @inline(never) public func cmApplyPoint(_ f: (CMPoint) -> Double, _ p: CMPoint) -> Double { f(p) + 1 }
                @inline(never) public func cmApplyOpenPoint(_ f: (CMOpenPoint) -> Double, _ p: CMOpenPoint) -> Double { f(p) + 1 }
                @inline(never) public func cmPointReader(_ scale: Double) -> (CMPoint) -> Double { { $0.x * scale + $0.y } }
                @inline(never) public func cmOpenPointReader(_ scale: Double) -> (CMOpenPoint) -> Double { { $0.x * scale + $0.y } }
                """,
            oracle: """
                return [
                    cmApplyPoint({ $0.x * 10 }, cmMakePoint()),
                    cmApplyOpenPoint({ $0.x * 10 }, cmMakeOpenPoint()),
                    cmPointReader(10)(cmMakePoint()),
                    cmOpenPointReader(10)(cmMakeOpenPoint()),
                ].map { String($0) }.joined(separator: "|")
                """
        ) { f in
            typealias Reader = NativeSwiftClosure<(NativeSwiftValue) -> Double>
            // The first stored property of both point types is x.
            let tenfold = try Reader { value in
                let x = try? value.withCopy {
                    Mirror(reflecting: $0).children.first?.value as? Double
                }
                return (x ?? nil).map { $0 * 10 } ?? -1
            }
            var results: [Double] = []
            for (apply, reader, make) in [
                ("cmApplyPoint(_:_:)", "cmPointReader(_:)", "cmMakePoint()"),
                ("cmApplyOpenPoint(_:_:)", "cmOpenPointReader(_:)", "cmMakeOpenPoint()"),
            ] {
                let apply = try await f.function(
                    apply,
                    as: ((Reader, NativeSwiftValue) -> Double).self
                )
                let make = try await f.function(make, as: (() -> NativeSwiftValue).self)
                results.append(try unsafe apply.unsafeInvoke(tenfold, make.unsafeInvoke()))
                let reader = try await f.function(reader, as: ((Double) -> Reader).self)
                results.append(try unsafe reader.unsafeInvoke(10).unsafeInvoke(make.unsafeInvoke()))
            }
            return [results[0], results[2], results[1], results[3]].map { String($0) }
                .joined(separator: "|")
        },
        ConformanceCase(
            id: "value.genericFrozen.inferred",
            provider: """
                @frozen public struct CMPair<T> {
                    public var a: T
                    public var b: T
                    public init(a: T, b: T) { self.a = a; self.b = b }
                }
                @inline(never) public func cmMakeDoublePair() -> CMPair<Double> { CMPair(a: 1.5, b: 2.5) }
                @inline(never) public func cmDescribeDoublePair(_ p: CMPair<Double>) -> String { "\\(p.a)+\\(p.b)" }
                @inline(never) public func cmMakeOpenPair() -> CMPair<CMOpenPoint> {
                    CMPair(a: CMOpenPoint(x: 1, y: 2), b: CMOpenPoint(x: 3, y: 4))
                }
                @inline(never) public func cmDescribeOpenPair(_ p: CMPair<CMOpenPoint>) -> String { "\\(p.a.x),\\(p.b.y)" }
                """,
            oracle: "return cmDescribeDoublePair(cmMakeDoublePair())",
            invoke: { f in
                try await describeMade(f, "cmMakeDoublePair()", "cmDescribeDoublePair(_:)")
            },
            expectedError: undecidedWithLibraryEvolution("has runtime-built metadata")
        ),
        ConformanceCase(
            id: "value.genericHoldsOpen.inferred",
            provider: "",
            oracle: "return cmDescribeOpenPair(cmMakeOpenPair())"
        ) { f in
            try await describeMade(f, "cmMakeOpenPair()", "cmDescribeOpenPair(_:)")
        },
        ConformanceCase(
            id: "value.largeUndecided.inferred",
            provider: """
                public struct CMWide {
                    public var name: String
                    public var a: Int64
                    public var b: Int64
                    public var c: Int64
                    public init(name: String, a: Int64) { self.name = name; self.a = a; b = a + 1; c = a + 2 }
                }
                @inline(never) public func cmMakeWide() -> CMWide { CMWide(name: "wide", a: 1) }
                @inline(never) public func cmBumpWide(_ w: CMWide, _ n: Int64) -> CMWide { CMWide(name: w.name + "!", a: w.c + n) }
                @inline(never) public func cmDescribeWide(_ w: CMWide) -> String { "\\(w.name):\\(w.a),\\(w.b),\\(w.c)" }
                """,
            oracle: "return cmDescribeWide(cmBumpWide(cmMakeWide(), 3))"
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeWide()",
                "cmBumpWide(_:_:)",
                "cmDescribeWide(_:)"
            )
        },
        ConformanceCase(
            id: "value.functionFields.inferred",
            provider: """
                @frozen public struct CMCFunction {
                    public var call: @convention(c) (Int64) -> Int64
                    public var n: Int64
                    public init(call: @escaping @convention(c) (Int64) -> Int64, n: Int64) { self.call = call; self.n = n }
                }
                @frozen public struct CMBlockFunction {
                    public var call: @convention(block) (Int64) -> Int64
                    public var n: Int64
                    public init(call: @escaping @convention(block) (Int64) -> Int64, n: Int64) { self.call = call; self.n = n }
                }
                @frozen public struct CMSwiftFunction {
                    public var call: (Int64) -> Int64
                    public var n: Int64
                    public init(call: @escaping (Int64) -> Int64, n: Int64) { self.call = call; self.n = n }
                }
                @inline(never) public func cmMakeCFunction() -> CMCFunction { CMCFunction(call: { $0 + 1 }, n: 2) }
                @inline(never) public func cmDescribeCFunction(_ v: CMCFunction) -> String { "\\(v.call(v.n))" }
                @inline(never) public func cmMakeBlockFunction() -> CMBlockFunction { CMBlockFunction(call: { $0 * 3 }, n: 4) }
                @inline(never) public func cmDescribeBlockFunction(_ v: CMBlockFunction) -> String { "\\(v.call(v.n))" }
                @inline(never) public func cmMakeSwiftFunction(_ k: Int64) -> CMSwiftFunction {
                    CMSwiftFunction(call: { $0 + k }, n: 6)
                }
                @inline(never) public func cmDescribeSwiftFunction(_ v: CMSwiftFunction) -> String { "\\(v.call(v.n))" }
                """,
            oracle: """
                return [
                    cmDescribeCFunction(cmMakeCFunction()),
                    cmDescribeBlockFunction(cmMakeBlockFunction()),
                    cmDescribeSwiftFunction(cmMakeSwiftFunction(7)),
                ].joined(separator: "|")
                """
        ) { f in
            [
                try await describeMade(f, "cmMakeCFunction()", "cmDescribeCFunction(_:)"),
                try await describeMade(f, "cmMakeBlockFunction()", "cmDescribeBlockFunction(_:)"),
                try await describeKinds(
                    f,
                    "cmMakeSwiftFunction(_:)",
                    "cmDescribeSwiftFunction(_:)",
                    kinds: [7]
                ),
            ].joined(separator: "|")
        },
        ConformanceCase(
            id: "value.metatypeFields.inferred",
            provider: """
                @frozen public struct CMThinType {
                    public var type: Int64.Type
                    public var n: Int64
                    public init(n: Int64) { type = Int64.self; self.n = n }
                }
                @frozen public struct CMThickType {
                    public var type: CMBox.Type
                    public var n: Int64
                    public init(n: Int64) { type = CMBox.self; self.n = n }
                }
                @inline(never) public func cmMakeThinType() -> CMThinType { CMThinType(n: 3) }
                @inline(never) public func cmDescribeThinType(_ v: CMThinType) -> String { "\\(v.type),\\(v.n)" }
                @inline(never) public func cmMakeThickType() -> CMThickType { CMThickType(n: 4) }
                @inline(never) public func cmDescribeThickType(_ v: CMThickType) -> String { "\\(v.type),\\(v.n)" }
                """,
            oracle:
                "return cmDescribeThinType(cmMakeThinType()) + \"|\" + cmDescribeThickType(cmMakeThickType())"
        ) { f in
            try await describeMade(f, "cmMakeThinType()", "cmDescribeThinType(_:)") + "|"
                + describeMade(f, "cmMakeThickType()", "cmDescribeThickType(_:)")
        },
        ConformanceCase(
            id: "value.genericMetatypeField.inferred",
            provider: """
                @frozen public struct CMGenericType<T> {
                    public var type: T.Type
                    public var n: Int64
                    public init(n: Int64) { type = T.self; self.n = n }
                }
                @inline(never) public func cmMakeGenericType() -> CMGenericType<Int64> { CMGenericType(n: 5) }
                @inline(never) public func cmDescribeGenericType(_ v: CMGenericType<Int64>) -> String { "\\(v.type),\\(v.n)" }
                """,
            oracle: "return cmDescribeGenericType(cmMakeGenericType())",
            invoke: { f in
                try await describeMade(f, "cmMakeGenericType()", "cmDescribeGenericType(_:)")
            },
            expectedError: undecidedWithLibraryEvolution("has runtime-built metadata")
        ),
        ConformanceCase(
            id: "value.tupleFields.inferred",
            provider: """
                @frozen public struct CMTupled {
                    public var pair: (Int64, Double)
                    public var flag: UInt8
                    public init(pair: (Int64, Double), flag: UInt8) { self.pair = pair; self.flag = flag }
                }
                @inline(never) public func cmMakeTupled() -> CMTupled { CMTupled(pair: (1, 2.5), flag: 3) }
                @inline(never) public func cmBumpTupled(_ t: CMTupled, _ n: Int64) -> CMTupled {
                    CMTupled(pair: (t.pair.0 + n, t.pair.1 * 2), flag: t.flag + 1)
                }
                @inline(never) public func cmDescribeTupled(_ t: CMTupled) -> String { "\\(t.pair.0),\\(t.pair.1),\\(t.flag)" }
                """,
            oracle: "return cmDescribeTupled(cmBumpTupled(cmMakeTupled(), 3))"
        ) { f in
            try await describeTransformed(
                f,
                "cmMakeTupled()",
                "cmBumpTupled(_:_:)",
                "cmDescribeTupled(_:)"
            )
        },
    ]
}
#endif
