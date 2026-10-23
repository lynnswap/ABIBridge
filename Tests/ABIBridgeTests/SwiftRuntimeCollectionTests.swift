import ABIBridge
import Foundation
import ManagedSwiftFixtures
import Testing

@Suite
struct SwiftRuntimeCollectionTests {
    private func count(_ value: NativeSwiftValue) throws -> Int64? {
        try value.withCopy { ($0 as? CollectionRuntimeRecord)?.count }
    }

    @Test func arraysOfRuntimeValuesPassAsArraysOfHandles() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionRecords(_:)", as: ((Int64) -> [NativeSwiftValue]).self)
        let describe = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionRecords(_:)", as: (([NativeSwiftValue]) -> String).self)
        let records = try unsafe make.unsafeInvoke(3)
        #expect(try records.map(count) == [0, 1, 2])
        #expect(try unsafe describe.unsafeInvoke(records.reversed()) == "r2#2,r1#1,r0#0")
        #expect(try unsafe describe.unsafeInvoke([]) == "")
        // Passing copies the elements; the handles keep their values.
        #expect(records.allSatisfy { !$0.isConsumed })

        // Optional elements, and elements of the wrong type, which fail before the call.
        let describeOptional = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeOptionalCollectionRecords(_:)",
            as: (([NativeSwiftValue?]) -> String).self)
        #expect(try unsafe describeOptional.unsafeInvoke([records[1], nil]) == "r1#1,nil")
        let nodes = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeBridgedCollectionNodes()", as: (() -> [NativeSwiftValue]).self)
        let node = try unsafe nodes.unsafeInvoke()[0]
        #expect(throws: ABIInvocationError.self) { try unsafe describe.unsafeInvoke([records[0], node]) }
    }

    @Test func objectElementsKeepTheirClassesAndCocoaStorageIsRead() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeBridgedCollectionNodes()", as: (() -> [NativeSwiftValue]).self)
        let describe = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionNodes(_:)", as: (([NativeSwiftValue]) -> String).self)
        let nodes = try unsafe make.unsafeInvoke()
        #expect(nodes.count == 2)
        // A subclass instance passes for its declared superclass.
        #expect(try unsafe describe.unsafeInvoke(nodes) == "a:node,b:leaf")
        let byName = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeBridgedCollectionNodesByName()", as: (() -> [String: NativeSwiftValue]).self)
        let named = try unsafe byName.unsafeInvoke()
        #expect(Set(named.keys) == ["a", "b"])
        #expect(try unsafe describe.unsafeInvoke([try #require(named["b"])]) == "b:leaf")
    }

    @Test func setsAndDictionariesOfRuntimeValues() async throws {
        let runtime = ABIRuntime.shared
        let makeRecords = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionRecords(_:)", as: ((Int64) -> [NativeSwiftValue]).self)
        let records = try unsafe makeRecords.unsafeInvoke(2)

        // A Set's members arrive as an array, and passing collapses equal members.
        let makeSet = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionRecordSet(_:)", as: ((Int64) -> [NativeSwiftValue]).self)
        #expect(try Set(unsafe makeSet.unsafeInvoke(3).map(count)) == [0, 1, 2])
        let describeSet = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionRecordSet(_:)", as: (([NativeSwiftValue]) -> String).self)
        #expect(try unsafe describeSet.unsafeInvoke([records[0], try records[0].copy(), records[1]]) == "r0#0,r1#1")

        // A host key type keeps a Swift Dictionary.
        let makeByName = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionRecordsByName(_:)", as: ((Int64) -> [String: NativeSwiftValue]).self)
        let byName = try unsafe makeByName.unsafeInvoke(2)
        #expect(try byName.mapValues(count) == ["r0": 0, "r1": 1])
        let describeByName = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionRecordsByName(_:)",
            as: (([String: NativeSwiftValue]) -> String).self)
        #expect(try unsafe describeByName.unsafeInvoke(["x": records[1]]) == "x=r1#1")

        // A runtime-only key uses key-value pairs; a later pair's value replaces an equal key's.
        let makeCounts = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionRecordCounts(_:)",
            as: ((Int64) -> [(key: NativeSwiftValue, value: Int64)]).self)
        let counts = try unsafe makeCounts.unsafeInvoke(2)
        #expect(try Set(counts.map { "\(try count($0.key)!)=\($0.value)" }) == ["0=0", "1=10"])
        let describeCounts = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionRecordCounts(_:)",
            as: (([(key: NativeSwiftValue, value: Int64)]) -> String).self)
        let pairs: [(key: NativeSwiftValue, value: Int64)] = [(records[0], 1), (records[1], 2), (records[0], 3)]
        #expect(try unsafe describeCounts.unsafeInvoke(pairs) == "r0#0=3,r1#1=2")

        // Like Set(_:) and Dictionary(_:uniquingKeysWith:), the first of equal
        // members or keys stays, with the last pair's value.
        let makeTagged = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionTaggedRecords()", as: (() -> [NativeSwiftValue]).self)
        let tagged = try unsafe makeTagged.unsafeInvoke()
        let describeTaggedSet = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionTaggedSet(_:)", as: (([NativeSwiftValue]) -> String).self)
        #expect(try unsafe describeTaggedSet.unsafeInvoke(tagged) == "1/first,2/other")
        let describeTaggedCounts = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.describeCollectionTaggedCounts(_:)",
            as: (([(key: NativeSwiftValue, value: Int64)]) -> String).self)
        let taggedPairs: [(key: NativeSwiftValue, value: Int64)] = [(tagged[0], 1), (tagged[1], 2)]
        #expect(try unsafe describeTaggedCounts.unsafeInvoke(taggedPairs) == "1/first=2")
    }

    @Test func conversionsReleaseEveryElementTheyCopy() async throws {
        let runtime = ABIRuntime.shared
        let make = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionProbes(_:)", as: ((Int) -> [NativeSwiftValue]).self)
        let count = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.countCollectionProbes(_:)", as: (([NativeSwiftValue]) -> Int).self)
        let makeTable = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionProbeTable(_:)",
            as: ((Int) -> [(key: NativeSwiftValue, value: NativeSwiftValue)]).self)
        let countTable = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.countCollectionProbeTable(_:)",
            as: (([(key: NativeSwiftValue, value: NativeSwiftValue)]) -> Int).self)
        // A host Dictionary whose key type is the native one.
        let makeKeyed = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.makeCollectionProbeTable(_:)",
            as: ((Int) -> [CollectionRuntimeProbe: NativeSwiftValue]).self)
        let countKeyed = try await runtime.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.countCollectionProbeTable(_:)",
            as: (([CollectionRuntimeProbe: NativeSwiftValue]) -> Int).self)
        do {
            let probes = try unsafe make.unsafeInvoke(3)
            #expect(try unsafe count.unsafeInvoke(probes + probes) == 3)
            let table = try unsafe makeTable.unsafeInvoke(2)
            #expect(try unsafe countTable.unsafeInvoke(table + table) == 2)
            let keyed = try unsafe makeKeyed.unsafeInvoke(2)
            #expect(try unsafe countKeyed.unsafeInvoke(keyed) == 2)
            withExtendedLifetime((probes, table, keyed)) {
                #expect(CollectionRuntimeProbe.liveCount == 11)
            }
        }
        #expect(CollectionRuntimeProbe.liveCount == 0)
    }

    @Test func callbacksExchangeRuntimeCollections() async throws {
        let visit = try await ABIRuntime.shared.resolveSwiftFunction(
            named: "ManagedSwiftFixtures.visitCollectionRecords(_:)",
            as: ((NativeSwiftClosure<([NativeSwiftValue]) throws -> [NativeSwiftValue]>) throws -> String).self)
        let reversed = try NativeSwiftClosure<([NativeSwiftValue]) throws -> [NativeSwiftValue]> { $0.reversed() }
        #expect(try unsafe visit.unsafeInvoke(reversed) == "r1#1,r0#0")
        let doubled = try NativeSwiftClosure<([NativeSwiftValue]) throws -> [NativeSwiftValue]> { $0 + $0 }
        #expect(try unsafe visit.unsafeInvoke(doubled) == "r0#0,r1#1,r0#0,r1#1")
    }

    @Test func collectionHandlesNeedACollectionDeclaration() async throws {
        let runtime = ABIRuntime.shared
        // Not a collection, a key type other than the native one, and inout.
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.describeOptionalRuntimeRecord(_:)", as: (([NativeSwiftValue]) -> String).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            _ = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.makeCollectionRecordsByName(_:)",
                as: ((Int64) -> [Int: NativeSwiftValue]).self)
        }
        await #expect(throws: ABIResolutionError.self) {
            let append = try await runtime.resolveSwiftFunction(
                named: "ManagedSwiftFixtures.appendCollectionRecord(_:)",
                as: ((NativeSwiftInout<[NativeSwiftValue]>) -> Void).self)
            try unsafe append.unsafeInvoke(NativeSwiftInout<[NativeSwiftValue]>([]))
        }
    }
}
