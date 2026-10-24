import WitnessProbe

@inline(never) public func callSync<P: Probe>(_ object: P, _ value: Int64) -> Int64 {
    object.sync(value)
}
@inline(never) public func callGet<P: Probe>(_ object: P) -> Int64 { object.value }
@inline(never) public func callSet<P: Probe>(_ object: inout P, _ value: Int64) { object.value = value }
@inline(never) public func callCode<P: Probe>(_ type: P.Type, _ value: Int64) -> Int64 { P.code(value) }
@inline(never) public func callInit<P: Probe>(_ type: P.Type, _ value: Int64) -> P { P(seed: value) }
@inline(never) public func callAsync<P: Probe>(_ object: P, _ value: Int64) async -> Int64 {
    await object.asynchronous(value)
}
@inline(never) public func callEcho<P: Probe>(_ object: P, _ value: P.Output) -> P.Output {
    object.echo(value)
}
@inline(never) public func callExistential(_ object: any Probe, _ value: Int64) -> Int64 {
    object.sync(value)
}
@inline(never) public func getConditionalTable<P: Equatable>(_ type: P.Type) -> any Probe {
    Conditional<P>(seed: 7)
}
