import ManagedSwiftFixtures

@inline(never) public func probeResilient(
    _ body: (IndirectRecord) -> IndirectRecord, _ value: IndirectRecord
) -> IndirectRecord { body(value) }
@inline(never) public func probeIntegerBox(
    _ body: (ExplicitBox<Int64>) -> ExplicitBox<Int64>, _ value: ExplicitBox<Int64>
) -> ExplicitBox<Int64> { body(value) }
@inline(never) public func probeDoubleBox(
    _ body: (ExplicitBox<Double>) -> ExplicitBox<Double>, _ value: ExplicitBox<Double>
) -> ExplicitBox<Double> { body(value) }
@inline(never) public func probeStringBox(
    _ body: (ExplicitBox<String>) -> ExplicitBox<String>, _ value: ExplicitBox<String>
) -> ExplicitBox<String> { body(value) }
@inline(never) public func probeNested(
    _ body: (BoxNamespace.Container<Int64>) -> BoxNamespace.Container<Int64>, _ value: BoxNamespace.Container<Int64>
) -> BoxNamespace.Container<Int64> { body(value) }
@inline(never) public func probeUnicode(_ body: (箱<Int64>) -> 箱<Int64>, _ value: 箱<Int64>) -> 箱<Int64> { body(value) }
