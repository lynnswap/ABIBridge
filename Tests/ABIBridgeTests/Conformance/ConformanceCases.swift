import ABIBridge
import Foundation

#if os(macOS)
// Cases name provider declarations with a `cm`/`CM` prefix so that all cases
// share one provider module per variant. Oracles call the same declarations
// natively and format results exactly as the ABIBridge calls do.

private func describe(_ value: some Any) -> String { String(describing: value) }

extension ConformanceCase {
    static let all: [ConformanceCase] = functions + values + inferredValues + classes + protocols

    /// Without library evolution, protocol requirements have no dispatch thunks.
    static let witnessDispatch: @Sendable (ConformanceVariant) -> String? = {
        $0.libraryEvolution
            ? nil : "Requirements without dispatch thunks need witness tables (#407)"
    }

    /// Class methods exported only as dispatch thunks are not selected yet.
    static let functions: [ConformanceCase] = [
        ConformanceCase(
            id: "function.scalar",
            provider:
                "@inline(never) public func cmScalar(_ a: Int64, _ b: Double) -> Double { Double(a) * b }",
            oracle: "return String(cmScalar(4, 2.5))"
        ) { f in
            let call = try await f.function("cmScalar(_:_:)", as: ((Int64, Double) -> Double).self)
            return String(try unsafe call.unsafeInvoke(4, 2.5))
        },
        ConformanceCase(
            id: "function.string",
            provider:
                "@inline(never) public func cmString(_ s: String) -> String { s + \"!\" + String(s.count) }",
            oracle: "return cmString(String(repeating: \"long\", count: 20))"
        ) { f in
            let call = try await f.function("cmString(_:)", as: ((String) -> String).self)
            return try unsafe call.unsafeInvoke(String(repeating: "long", count: 20))
        },
        ConformanceCase(
            id: "function.array",
            provider:
                "@inline(never) public func cmArray(_ v: [Int64]) -> [Int64] { v.reversed() + [Int64(v.count)] }",
            oracle: "return String(describing: cmArray([1, 2, 3]))"
        ) { f in
            let call = try await f.function("cmArray(_:)", as: (([Int64]) -> [Int64]).self)
            return describe(try unsafe call.unsafeInvoke([1, 2, 3]))
        },
        ConformanceCase(
            id: "function.dictionary",
            provider: """
                @inline(never) public func cmDictionary(_ d: [String: Int64]) -> [String: Int64] {
                    d.merging(["z": 26]) { $1 }
                }
                """,
            oracle:
                "return cmDictionary([\"a\": 1]).sorted { $0.key < $1.key }.map { \"\\($0.key)=\\($0.value)\" }.joined(separator: \",\")",
            invoke: { f in
                let call = try await f.function(
                    "cmDictionary(_:)",
                    as: (([String: Int64]) -> [String: Int64]).self
                )
                return try unsafe call.unsafeInvoke(["a": 1]).sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            }
        ),
        ConformanceCase(
            id: "function.set",
            provider:
                "@inline(never) public func cmSet(_ s: Set<Int64>) -> Set<Int64> { s.union([9]) }",
            oracle: "return String(describing: cmSet([1, 2]).sorted())",
            invoke: { f in
                let call = try await f.function("cmSet(_:)", as: ((Set<Int64>) -> Set<Int64>).self)
                return describe(try unsafe call.unsafeInvoke([1, 2]).sorted())
            }
        ),
        ConformanceCase(
            id: "function.optionalScalar",
            provider:
                "@inline(never) public func cmOptionalScalar(_ v: Int64?) -> Int64? { v.map { $0 * 2 } }",
            oracle:
                "return \"\\(String(describing: cmOptionalScalar(nil)))|\\(String(describing: cmOptionalScalar(21)))\"",
            invoke: { f in
                let call = try await f.function(
                    "cmOptionalScalar(_:)",
                    as: ((Int64?) -> Int64?).self
                )
                return
                    "\(describe(try unsafe call.unsafeInvoke(nil)))|\(describe(try unsafe call.unsafeInvoke(21)))"
            }
        ),
        ConformanceCase(
            id: "function.optionalString",
            provider:
                "@inline(never) public func cmOptionalString(_ v: String?) -> String? { v.map { $0 + \"?\" } }",
            oracle:
                "return \"\\(String(describing: cmOptionalString(nil)))|\\(String(describing: cmOptionalString(\"a\")))\""
        ) { f in
            let call = try await f.function("cmOptionalString(_:)", as: ((String?) -> String?).self)
            return
                "\(describe(try unsafe call.unsafeInvoke(nil)))|\(describe(try unsafe call.unsafeInvoke("a")))"
        },
        ConformanceCase(
            id: "function.tuple",
            provider:
                "@inline(never) public func cmTuple(_ v: (Int64, String)) -> (String, Int64) { (v.1, v.0 + 1) }",
            oracle: "return String(describing: cmTuple((41, \"x\")))"
        ) { f in
            let call = try await f.function(
                "cmTuple(_:)",
                as: (((Int64, String)) -> (String, Int64)).self
            )
            return describe(try unsafe call.unsafeInvoke((41, "x")))
        },
        ConformanceCase(
            id: "function.closure",
            provider:
                "@inline(never) public func cmApply(_ f: (Int64) -> Int64, _ x: Int64) -> Int64 { f(x) + 1 }",
            oracle: "return String(cmApply({ $0 * 3 }, 5))"
        ) { f in
            let call = try await f.function(
                "cmApply(_:_:)",
                as: ((NativeSwiftClosure<(Int64) -> Int64>, Int64) -> Int64).self
            )
            return String(try unsafe call.unsafeInvoke(try NativeSwiftClosure { $0 * 3 }, 5))
        },
        ConformanceCase(
            id: "function.optionalClosure",
            provider:
                "@inline(never) public func cmMaybeApply(_ f: ((Int64) -> Int64)?, _ x: Int64) -> Int64 { f?(x) ?? -1 }",
            oracle: "return \"\\(cmMaybeApply(nil, 5))|\\(cmMaybeApply({ $0 * 3 }, 5))\"",
            invoke: { f in
                let call = try await f.function(
                    "cmMaybeApply(_:_:)",
                    as: ((NativeSwiftClosure<(Int64) -> Int64>?, Int64) -> Int64).self
                )
                let tripled = try NativeSwiftClosure<(Int64) -> Int64> { $0 * 3 }
                return
                    "\(try unsafe call.unsafeInvoke(nil, 5))|\(try unsafe call.unsafeInvoke(tripled, 5))"
            }
        ),
        ConformanceCase(
            id: "function.returnedClosure",
            provider:
                "@inline(never) public func cmMakeAdder(_ b: Int64) -> (Int64) -> Int64 { { $0 + b } }",
            oracle: "return String(cmMakeAdder(10)(5))"
        ) { f in
            let call = try await f.function(
                "cmMakeAdder(_:)",
                as: ((Int64) -> NativeSwiftClosure<(Int64) -> Int64>).self
            )
            return String(try unsafe call.unsafeInvoke(10).unsafeInvoke(5))
        },
        ConformanceCase(
            id: "function.throwing",
            provider: """
                public struct CMFailure: Error { public let code: Int }
                @inline(never) public func cmThrowing(_ fail: Bool) throws -> Int64 {
                    if fail { throw CMFailure(code: 7) }
                    return 42
                }
                """,
            oracle: """
                func run(_ fail: Bool) -> String {
                    do { return String(try cmThrowing(fail)) } catch { return "error: \\(error)" }
                }
                return run(false) + "|" + run(true)
                """
        ) { f in
            let call = try await f.function("cmThrowing(_:)", as: ((Bool) throws -> Int64).self)
            func run(_ fail: Bool) -> String {
                do { return String(try unsafe call.unsafeInvoke(fail)) } catch {
                    return "error: \(error)"
                }
            }
            return run(false) + "|" + run(true)
        },
        ConformanceCase(
            id: "function.async",
            provider:
                "@inline(never) public func cmAsync(_ x: Int64) async -> Int64 { await Task.yield(); return x + 1 }",
            oracle: "return String(runBlocking { await cmAsync(41) })"
        ) { f in
            let call = try await f.function(
                "cmAsync(_:)",
                as: (@concurrent (Int64) async -> Int64).self
            )
            return String(try await unsafe call.unsafeInvoke(41))
        },
        ConformanceCase(
            id: "function.opaque",
            provider: "@inline(never) public func cmOpaque() -> some Equatable { Int64(17) }",
            oracle: "return String(describing: cmOpaque())"
        ) { f in
            let call = try await f.function("cmOpaque()", as: (() -> NativeSwiftValue).self)
            return try unsafe call.unsafeInvoke().withCopy { describe($0) }
        },
    ]

    static let values: [ConformanceCase] = [
        ConformanceCase(
            id: "value.frozenStruct",
            provider: """
                @frozen public struct CMPoint {
                    public var x: Double
                    public var y: Double
                    public init(x: Double, y: Double) { self.x = x; self.y = y }
                }
                @inline(never) public func cmMakePoint() -> CMPoint { CMPoint(x: 1, y: 2) }
                @inline(never) public func cmMove(_ p: CMPoint, _ dx: Double) -> CMPoint { CMPoint(x: p.x + dx, y: p.y) }
                @inline(never) public func cmDescribePoint(_ p: CMPoint) -> String { "\\(p.x),\\(p.y)" }
                """,
            oracle: "return cmDescribePoint(cmMove(cmMakePoint(), 3))"
        ) { f in
            let point = try await f.type("CMPoint")
            let abis: [NativeSwiftType: NativeType] = [
                point: try .structure(named: "CMPoint", fields: [.double, .double])
            ]
            let make = try await f.function(
                "cmMakePoint() -> " + point.name,
                as: (() -> NativeSwiftValue).self,
                valueABIs: abis
            )
            let move = try await f.function(
                "cmMove(\(point.name), Swift.Double) -> \(point.name)",
                as: ((NativeSwiftValue, Double) -> NativeSwiftValue).self,
                valueABIs: abis
            )
            let text = try await f.function(
                "cmDescribePoint(\(point.name)) -> Swift.String",
                as: ((NativeSwiftValue) -> String).self,
                valueABIs: abis
            )
            return try unsafe text.unsafeInvoke(move.unsafeInvoke(make.unsafeInvoke(), 3))
        },
        ConformanceCase(
            id: "value.frozenStruct.inferred",
            provider: "",
            oracle: "return cmDescribePoint(cmMove(cmMakePoint(), 3))",
            invoke: { f in
                let make = try await f.function("cmMakePoint()", as: (() -> NativeSwiftValue).self)
                let move = try await f.function(
                    "cmMove(_:_:)",
                    as: ((NativeSwiftValue, Double) -> NativeSwiftValue).self
                )
                let text = try await f.function(
                    "cmDescribePoint(_:)",
                    as: ((NativeSwiftValue) -> String).self
                )
                return try unsafe text.unsafeInvoke(move.unsafeInvoke(make.unsafeInvoke(), 3))
            }
        ),
        ConformanceCase(
            id: "value.resilientStruct",
            provider: """
                public struct CMRecord {
                    public var name: String
                    public var count: Int64
                    public init(name: String, count: Int64) { self.name = name; self.count = count }
                }
                @inline(never) public func cmMakeRecord() -> CMRecord { CMRecord(name: "record", count: 1) }
                @inline(never) public func cmBump(_ r: CMRecord) -> CMRecord { CMRecord(name: r.name, count: r.count + 1) }
                @inline(never) public func cmDescribeRecord(_ r: CMRecord) -> String { "\\(r.name)#\\(r.count)" }
                """,
            oracle: "return cmDescribeRecord(cmBump(cmMakeRecord()))"
        ) { f in
            let record = try await f.type("CMRecord")
            let abi: NativeType =
                f.variant.libraryEvolution
                ? try .opaque(named: record.name)
                : try .structure(named: "CMRecord", fields: [.uint64, .uint64, .int64])
            let abis = [record: abi]
            let make = try await f.function(
                "cmMakeRecord() -> " + record.name,
                as: (() -> NativeSwiftValue).self,
                valueABIs: abis
            )
            let bump = try await f.function(
                "cmBump(\(record.name)) -> \(record.name)",
                as: ((NativeSwiftValue) -> NativeSwiftValue).self,
                valueABIs: abis
            )
            let text = try await f.function(
                "cmDescribeRecord(\(record.name)) -> Swift.String",
                as: ((NativeSwiftValue) -> String).self,
                valueABIs: abis
            )
            return try unsafe text.unsafeInvoke(bump.unsafeInvoke(make.unsafeInvoke()))
        },
        ConformanceCase(
            id: "value.payloadEnum",
            provider: """
                public enum CMShape { case circle(Double), square(Double), none }
                @inline(never) public func cmMakeShape(_ kind: Int64) -> CMShape {
                    kind == 0 ? .circle(1.5) : kind == 1 ? .square(2) : .none
                }
                @inline(never) public func cmDescribeShape(_ s: CMShape) -> String { "\\(s)" }
                """,
            oracle:
                "return (0..<3).map { cmDescribeShape(cmMakeShape($0)) }.joined(separator: \"|\")"
        ) { f in
            let shape = try await f.type("CMShape")
            let abi: NativeType =
                f.variant.libraryEvolution
                ? try .opaque(named: shape.name)
                : try .structure(named: "CMShape", fields: [.uint64, .uint8])
            let abis = [shape: abi]
            let make = try await f.function(
                "cmMakeShape(Swift.Int64) -> " + shape.name,
                as: ((Int64) -> NativeSwiftValue).self,
                valueABIs: abis
            )
            let text = try await f.function(
                "cmDescribeShape(\(shape.name)) -> Swift.String",
                as: ((NativeSwiftValue) -> String).self,
                valueABIs: abis
            )
            return try (0..<3).map { try unsafe text.unsafeInvoke(make.unsafeInvoke(Int64($0))) }
                .joined(separator: "|")
        },
    ]

    static let classes: [ConformanceCase] = [
        ConformanceCase(
            id: "class.method",
            provider: """
                open class CMCounter {
                    open var value: Int64
                    public init(start: Int64) { value = start }
                    @inline(never) open func add(_ x: Int64) -> Int64 { value += x; return value }
                    @inline(never) open func describe() -> String { "counter(\\(value))" }
                    @inline(never) open func asyncValue() async -> Int64 { value }
                    @inline(never) open func opaqueValue() -> some Equatable { value }
                    @inline(never) public final func finalValue() -> Int64 { value }
                    @inline(never) public static func staticValue() -> Int64 { 5 }
                    @inline(never) open class func className() -> String { "CMCounter" }
                }
                open class CMDerivedCounter: CMCounter {
                    @inline(never) public override func add(_ x: Int64) -> Int64 { value += 2 * x; return value }
                }
                extension CMCounter {
                    @inline(never) public func doubled() -> Int64 { value * 2 }
                }
                @inline(never) public func cmMakeCounter() -> CMCounter { CMCounter(start: 1) }
                @inline(never) public func cmMakeDerived() -> CMCounter { CMDerivedCounter(start: 1) }
                @inline(never) public func cmMakeDerivedTyped() -> CMDerivedCounter { CMDerivedCounter(start: 4) }
                """,
            oracle: "return String(cmMakeCounter().add(1))",
            invoke: { f in
                let add = try await f.type("CMCounter").resolveMethod(
                    named: "add(_:)",
                    as: ((Int64) -> Int64).self
                )
                return String(
                    try unsafe add.unsafeInvoke(
                        on: f.make("cmMakeCounter", returning: "CMCounter"),
                        1
                    )
                )
            }
        ),
        ConformanceCase(
            id: "class.accessors",
            provider: "",
            oracle: "let c = cmMakeCounter(); c.value = 9; return String(c.value)",
            invoke: { f in
                let type = try await f.type("CMCounter")
                let counter = try f.make("cmMakeCounter", returning: "CMCounter")
                try unsafe await type.resolveSetter(named: "value", as: Int64.self).unsafeInvoke(
                    on: counter,
                    9
                )
                return String(
                    try unsafe await type.resolveGetter(named: "value", as: (() -> Int64).self)
                        .unsafeInvoke(on: counter)
                )
            }
        ),
        ConformanceCase(
            id: "class.override",
            provider: "",
            oracle: "return String(cmMakeDerived().add(1))",
            invoke: { f in
                let add = try await f.type("CMDerivedCounter").resolveMethod(
                    named: "add(_:)",
                    as: ((Int64) -> Int64).self
                )
                return String(
                    try unsafe add.unsafeInvoke(
                        on: f.make("cmMakeDerived", returning: "CMCounter"),
                        1
                    )
                )
            }
        ),
        ConformanceCase(
            id: "class.capturedBase",
            provider: "",
            // A base-type handle keeps the base implementation for a subclass receiver.
            oracle: "return String(CMCounter(start: 1).add(1))",
            invoke: { f in
                let add = try await f.type("CMCounter").resolveMethod(
                    named: "add(_:)",
                    as: ((Int64) -> Int64).self
                )
                return String(
                    try unsafe add.unsafeInvoke(
                        on: f.make("cmMakeDerived", returning: "CMCounter"),
                        1
                    )
                )
            }
        ),
        ConformanceCase(
            id: "class.boundObject",
            provider: "",
            oracle: "return String(cmMakeDerived().add(1))",
            invoke: { f in
                let derived = try f.make("cmMakeDerived", returning: "CMCounter")
                let add = try await f.runtime.object(derived).resolveMethod(
                    named: "add(_:)",
                    as: ((Int64) -> Int64).self
                )
                return String(try unsafe add.unsafeInvoke(1))
            }
        ),
        ConformanceCase(
            id: "class.final",
            provider: "",
            oracle: "return String(cmMakeCounter().finalValue())"
        ) { f in
            let call = try await f.type("CMCounter").resolveMethod(
                named: "finalValue()",
                as: (() -> Int64).self
            )
            return String(
                try unsafe call.unsafeInvoke(on: f.make("cmMakeCounter", returning: "CMCounter"))
            )
        },
        ConformanceCase(
            id: "class.extension",
            provider: "",
            oracle: "return String(cmMakeCounter().doubled())"
        ) { f in
            let call = try await f.type("CMCounter").resolveMethod(
                named: "doubled()",
                as: (() -> Int64).self
            )
            return String(
                try unsafe call.unsafeInvoke(on: f.make("cmMakeCounter", returning: "CMCounter"))
            )
        },
        ConformanceCase(
            id: "class.static",
            provider: "",
            oracle: "return String(CMCounter.staticValue())"
        ) { f in
            let call = try await f.type("CMCounter").resolveStaticMethod(
                named: "staticValue()",
                as: (() -> Int64).self
            )
            return String(try unsafe call.unsafeInvoke())
        },
        ConformanceCase(
            id: "class.classMethod",
            provider: "",
            oracle: "return CMCounter.className()",
            invoke: { f in
                let call = try await f.type("CMCounter").resolveStaticMethod(
                    named: "className()",
                    as: (() -> String).self
                )
                return try unsafe call.unsafeInvoke()
            }
        ),
        ConformanceCase(
            id: "class.async",
            provider: "",
            oracle: "return String(runBlocking { await cmMakeCounter().asyncValue() })",
            invoke: { f in
                let call = try await f.type("CMCounter").resolveMethod(
                    named: "asyncValue()",
                    as: (@concurrent () async -> Int64).self
                )
                return String(
                    try await unsafe call.unsafeInvoke(
                        on: f.make("cmMakeCounter", returning: "CMCounter")
                    )
                )
            }
        ),
        ConformanceCase(
            id: "class.opaque",
            provider: "",
            oracle: "return String(describing: cmMakeCounter().opaqueValue())",
            invoke: { f in
                let call = try await f.type("CMCounter").resolveMethod(
                    named: "opaqueValue()",
                    as: (() -> NativeSwiftValue).self
                )
                return try unsafe call.unsafeInvoke(
                    on: f.make("cmMakeCounter", returning: "CMCounter")
                ).withCopy { describe($0) }
            }
        ),
        ConformanceCase(
            id: "class.initializer",
            provider: "",
            oracle: "return CMCounter(start: 3).describe()",
            invoke: { f in
                let type = try await f.type("CMCounter")
                let make = try await type.resolveInitializer(
                    named: "init(start:)",
                    as: ((Int64) -> AnyObject).self
                )
                let text = try await type.resolveMethod(
                    named: "describe()",
                    as: (() -> String).self
                )
                return try unsafe text.unsafeInvoke(on: make.unsafeInvoke(3))
            }
        ),
        ConformanceCase(
            id: "class.supertypeResult",
            provider: "",
            oracle: "return cmMakeDerivedTyped().describe()",
            invoke: { f in
                let make = try await f.function("cmMakeDerivedTyped()", as: (() -> AnyObject).self)
                let text = try await f.type("CMCounter").resolveMethod(
                    named: "describe()",
                    as: (() -> String).self
                )
                return try unsafe text.unsafeInvoke(on: make.unsafeInvoke())
            }
        ),
    ]

    static let protocols: [ConformanceCase] = [
        ConformanceCase(
            id: "protocol.method",
            provider: """
                public protocol CMArea {
                    func area() -> Double
                    var label: String { get set }
                }
                public final class CMSquare: CMArea {
                    public var side: Double
                    public var label: String
                    public init(side: Double) { self.side = side; label = "square" }
                    @inline(never) public func area() -> Double { side * side }
                }
                extension CMArea {
                    @inline(never) public func summary() -> String { "\\(label)=\\(area())" }
                }
                @inline(never) public func cmMakeSquare() -> CMSquare { CMSquare(side: 3) }
                """,
            oracle: "return String(cmMakeSquare().area())",
            invoke: { f in
                let square = try await f.type("CMSquare")
                let area = try await square.resolveMethod(
                    named: f.module + ".CMArea.area() -> Swift.Double",
                    as: (() -> Double).self
                )
                return String(
                    try unsafe area.unsafeInvoke(on: f.make("cmMakeSquare", returning: "CMSquare"))
                )
            },
            knownIssue: witnessDispatch
        ),
        ConformanceCase(
            id: "protocol.getter",
            provider: "",
            oracle: "return cmMakeSquare().label",
            invoke: { f in
                let square = try await f.type("CMSquare")
                let label = try await square.resolveGetter(
                    named: f.module + ".CMArea.label.getter : Swift.String",
                    as: (() -> String).self
                )
                return try unsafe label.unsafeInvoke(
                    on: f.make("cmMakeSquare", returning: "CMSquare")
                )
            },
            knownIssue: witnessDispatch
        ),
        ConformanceCase(
            id: "protocol.setter",
            provider: "",
            oracle: "var s: any CMArea = cmMakeSquare(); s.label = \"renamed\"; return s.label",
            invoke: { f in
                let square = try await f.type("CMSquare")
                var object = try f.make("cmMakeSquare", returning: "CMSquare")
                let set = try await square.resolveSetter(
                    named: f.module + ".CMArea.label.setter : Swift.String",
                    as: String.self
                )
                // The requirement's setter is mutating: CMArea is not class-bound.
                try unsafe set.unsafeInvoke(on: &object, "renamed")
                let get = try await square.resolveGetter(named: "label", as: (() -> String).self)
                return try unsafe get.unsafeInvoke(on: object)
            },
            knownIssue: witnessDispatch
        ),
        ConformanceCase(
            id: "protocol.extension",
            provider: "",
            oracle: "return cmMakeSquare().summary()"
        ) { f in
            let square = try await f.type("CMSquare")
            let summary = try await square.resolveMethod(
                named: "(extension in \(f.module)):\(f.module).CMArea.summary() -> Swift.String",
                as: (() -> String).self
            )
            return try unsafe summary.unsafeInvoke(
                on: f.make("cmMakeSquare", returning: "CMSquare")
            )
        },
    ]
}
#endif
