public struct RuntimeParameterizedGetter<Body: Sendable>: Sendable {
    public enum Structure: Sendable {
        case body(makeBody: @MainActor () -> Body)
    }

    public let structure: Structure

    public init(_ body: Body) {
        structure = .body(makeBody: { body })
    }

    public var makeStructure: @MainActor () -> Structure {
        let value = structure
        return { value }
    }
}

@inline(never) public func makeRuntimeParameterizedGetter(_ value: Int64) -> some Any {
    RuntimeParameterizedGetter(value)
}
