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

@frozen public struct RuntimeAssociatedElement<Source: FreshExistentialClass> {
    public let element: Source.Element
    public init(_ element: Source.Element) { self.element = element }
}

@frozen public struct RuntimeAssociatedGetter<Value: Hashable> {
    public let storage: RuntimeAssociatedElement<FreshCollectionSuperclassValue<[Value]>>
    public init(_ value: Value) { storage = .init(value) }
}
