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

public final class RuntimeConditionalSource<Values> {}
extension RuntimeConditionalSource: FreshExistentialClass where Values: Collection {
    public typealias Element = Values.Element
}

@frozen public struct RuntimeConditionalGetter<Values: Collection> {
    public let storage: RuntimeAssociatedElement<RuntimeConditionalSource<Values>>
    public init(_ value: Values.Element) { storage = .init(value) }
}

public protocol RuntimeCollectionSource { associatedtype Values: Collection }
public struct RuntimeCollectionSourceValue: RuntimeCollectionSource {
    public typealias Values = [Int64]
}
public final class RuntimeNestedSource<Source: RuntimeCollectionSource>: FreshExistentialClass {
    public typealias Element = Source.Values.Element
}

@frozen public struct RuntimeNestedGetter<Source: RuntimeCollectionSource> {
    public let storage: RuntimeAssociatedElement<RuntimeNestedSource<Source>>
    public init(_ value: Source.Values.Element) { storage = .init(value) }
}
