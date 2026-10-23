import Foundation
import Synchronization

// Runtime-only collection elements: tests reach these types only through NativeSwiftValue.
public struct CollectionRuntimeRecord: Hashable {
    public var name: String
    public var count: Int64
    public init(name: String, count: Int64) { self.name = name; self.count = count }
    var summary: String { "\(name)#\(count)" }
}

public class CollectionRuntimeNode: NSObject {
    public let name: String
    public init(name: String) { self.name = name }
}

public final class CollectionRuntimeLeaf: CollectionRuntimeNode {}

@inline(never) public func makeCollectionRecords(_ count: Int64) -> [CollectionRuntimeRecord] {
    (0..<count).map { CollectionRuntimeRecord(name: "r\($0)", count: $0) }
}

@inline(never) public func describeCollectionRecords(_ records: [CollectionRuntimeRecord]) -> String {
    records.map(\.summary).joined(separator: ",")
}

@inline(never) public func describeOptionalCollectionRecords(_ records: [CollectionRuntimeRecord?]) -> String {
    records.map { $0?.summary ?? "nil" }.joined(separator: ",")
}

@inline(never) public func countOptionalCollectionRecords(_ records: [CollectionRuntimeRecord]?) -> Int64 {
    records.map { Int64($0.count) } ?? -1
}

@inline(never) public func makeOptionalCollectionRecords(_ count: Int64) -> [CollectionRuntimeRecord]? {
    makeCollectionRecords(count)
}

@inline(never) public func countNestedCollectionRecords(_ records: [[CollectionRuntimeRecord]]) -> Int64 {
    Int64(records.joined().count)
}

@inline(never) public func appendCollectionRecord(_ records: inout [CollectionRuntimeRecord]) {
    records.append(CollectionRuntimeRecord(name: "appended", count: 0))
}

@inline(never) public func makeCollectionRecordSet(_ count: Int64) -> Set<CollectionRuntimeRecord> {
    Set(makeCollectionRecords(count))
}

@inline(never) public func describeCollectionRecordSet(_ records: Set<CollectionRuntimeRecord>) -> String {
    records.map(\.summary).sorted().joined(separator: ",")
}

@inline(never) public func makeCollectionRecordsByName(_ count: Int64) -> [String: CollectionRuntimeRecord] {
    Dictionary(uniqueKeysWithValues: makeCollectionRecords(count).map { ($0.name, $0) })
}

@inline(never) public func describeCollectionRecordsByName(_ records: [String: CollectionRuntimeRecord]) -> String {
    records.map { "\($0.key)=\($0.value.summary)" }.sorted().joined(separator: ",")
}

@inline(never) public func makeCollectionRecordCounts(_ count: Int64) -> [CollectionRuntimeRecord: Int64] {
    Dictionary(uniqueKeysWithValues: makeCollectionRecords(count).map { ($0, $0.count * 10) })
}

@inline(never) public func describeCollectionRecordCounts(_ counts: [CollectionRuntimeRecord: Int64]) -> String {
    counts.map { "\($0.key.summary)=\($0.value)" }.sorted().joined(separator: ",")
}

/// Arrays and dictionaries of objects backed by Cocoa storage.
@inline(never) public func makeBridgedCollectionNodes() -> [CollectionRuntimeNode] {
    NSArray(array: [CollectionRuntimeNode(name: "a"), CollectionRuntimeLeaf(name: "b")]) as! [CollectionRuntimeNode]
}

@inline(never) public func makeBridgedCollectionNodesByName() -> [String: CollectionRuntimeNode] {
    NSDictionary(dictionary: ["a": CollectionRuntimeNode(name: "a"), "b": CollectionRuntimeLeaf(name: "b")])
        as! [String: CollectionRuntimeNode]
}

@inline(never) public func describeCollectionNodes(_ nodes: [CollectionRuntimeNode]) -> String {
    nodes.map { "\($0.name):\($0 is CollectionRuntimeLeaf ? "leaf" : "node")" }.joined(separator: ",")
}

@inline(never) public func visitCollectionRecords(
    _ body: ([CollectionRuntimeRecord]) throws -> [CollectionRuntimeRecord]
) rethrows -> String {
    describeCollectionRecords(try body(makeCollectionRecords(2)))
}

/// Counts its live instances, so a test can check that collection
/// conversions release every element they copy.
public final class CollectionRuntimeProbe: Hashable {
    private static let live = Atomic<Int>(0)
    public static var liveCount: Int { live.load(ordering: .sequentiallyConsistent) }
    public let id: Int
    init(id: Int) {
        self.id = id
        Self.live.add(1, ordering: .sequentiallyConsistent)
    }
    deinit { Self.live.subtract(1, ordering: .sequentiallyConsistent) }
    public static func == (lhs: CollectionRuntimeProbe, rhs: CollectionRuntimeProbe) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@inline(never) public func makeCollectionProbes(_ count: Int) -> [CollectionRuntimeProbe] {
    (0..<count).map(CollectionRuntimeProbe.init)
}

@inline(never) public func makeCollectionProbeTable(_ count: Int) -> [CollectionRuntimeProbe: CollectionRuntimeProbe] {
    Dictionary(uniqueKeysWithValues: makeCollectionProbes(count).map { ($0, CollectionRuntimeProbe(id: -$0.id)) })
}

@inline(never) public func countCollectionProbes(_ probes: Set<CollectionRuntimeProbe>) -> Int { probes.count }

@inline(never) public func countCollectionProbeTable(_ table: [CollectionRuntimeProbe: CollectionRuntimeProbe]) -> Int {
    table.count
}

/// Equal by `id` only, so a test can tell which of two equal values a
/// collection kept.
public struct CollectionTaggedRecord: Hashable {
    public let id: Int64
    public let tag: String
    init(id: Int64, tag: String) { self.id = id; self.tag = tag }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var summary: String { "\(id)/\(tag)" }
}

@inline(never) public func makeCollectionTaggedRecords() -> [CollectionTaggedRecord] {
    [CollectionTaggedRecord(id: 1, tag: "first"), CollectionTaggedRecord(id: 1, tag: "last"),
     CollectionTaggedRecord(id: 2, tag: "other")]
}

@inline(never) public func describeCollectionTaggedSet(_ records: Set<CollectionTaggedRecord>) -> String {
    records.sorted { $0.id < $1.id }.map(\.summary).joined(separator: ",")
}

@inline(never) public func describeCollectionTaggedCounts(_ counts: [CollectionTaggedRecord: Int64]) -> String {
    counts.sorted { $0.key.id < $1.key.id }.map { "\($0.key.summary)=\($0.value)" }.joined(separator: ",")
}
