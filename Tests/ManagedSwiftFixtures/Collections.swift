@inline(never) public func appendStrings(_ value: [String], _ suffix: String) -> [String] {
    value + [suffix]
}

@inline(never) public func optionalStrings(_ value: [String]?) -> [String]? { value }

@inline(never) public func decorateOptionalString(_ value: String?) -> String? {
    value.map { $0 + "!" }
}

@inline(never) public func copyManagedRecords(_ value: [ManagedRecord]) -> [ManagedRecord] { value }

@inline(never) public func recordsWithSuffix(_ value: [ManagedRecord], _ suffix: Int64) -> [ManagedRecord] {
    value.map { ManagedRecord(token: $0.token, number: $0.number + suffix) }
}

@inline(never) public func applyArrayClosure(_ body: ([String]) -> [String], _ value: [String]) -> [String] {
    body(value)
}

@inline(never) public func applyOptionalArrayClosure(
    _ body: ([String]?) -> [String]?, _ value: [String]?
) -> [String]? { body(value) }

@inline(never) public func applyOptionalStringClosure(_ body: (String?) -> String?, _ value: String?) -> String? {
    body(value)
}

@inline(never) public func makeArrayClosure(_ suffix: String) -> ([String]) -> [String] {
    { $0 + [suffix] }
}

@inline(never) public func makeOptionalStringClosure(_ suffix: String) -> (String?) -> String? {
    { $0.map { $0 + suffix } }
}

public final class CollectionStore {
    public var values: [String]
    public var title: String?
    private var callback: (([String]) -> [String])?

    public init(_ values: [String], _ title: String?) {
        self.values = values
        self.title = title
    }
    @inline(never) public func append(_ value: String) -> [String] {
        values.append(value)
        return values
    }
    public func retainCallback(_ callback: @escaping ([String]) -> [String]) { self.callback = callback }
    public func invoke(_ value: [String]) -> [String] { callback?(value) ?? value }
    public func clear() { callback = nil }
}
