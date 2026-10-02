import ABIBridgeCore
import Foundation
import Synchronization
import Testing

private final class RuntimeValueDeaths: Sendable {
    let count = Mutex(0)
}
private final class RuntimeValueLife {
    let deaths: RuntimeValueDeaths
    init(_ deaths: RuntimeValueDeaths) { self.deaths = deaths }
    deinit { deaths.count.withLock { $0 += 1 } }
}
private struct RuntimeCopyablePayload {
    let life: RuntimeValueLife
    let text: String
}
private struct RuntimeMoveOnlyPayload: ~Copyable {
    let life: RuntimeValueLife
    let text: String
}

@Suite struct SwiftRuntimeValueTests {
    @Test func witnessesCopyAndDestroyManagedStorage() throws {
        let deaths = RuntimeValueDeaths()
        let metadata = unsafeBitCast(RuntimeCopyablePayload.self, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(metadata)
        #expect(layout.size == MemoryLayout<RuntimeCopyablePayload>.size)
        #expect(layout.stride == MemoryLayout<RuntimeCopyablePayload>.stride)
        #expect(layout.alignment == MemoryLayout<RuntimeCopyablePayload>.alignment)
        #expect(layout.isCopyable)
        let source = UnsafeMutablePointer<RuntimeCopyablePayload>.allocate(capacity: 1)
        source.initialize(to: RuntimeCopyablePayload(life: RuntimeValueLife(deaths), text: String(repeating: "owned", count: 100)))
        let copy = UnsafeMutableRawPointer.allocate(byteCount: layout.stride, alignment: layout.alignment)
        defer { source.deallocate(); copy.deallocate() }
        #expect(ABISwiftCopyValue(metadata, copy, source))
        ABISwiftDestroyValue(metadata, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(copy.load(as: RuntimeCopyablePayload.self).text == String(repeating: "owned", count: 100))
        ABISwiftDestroyValue(metadata, copy)
        #expect(deaths.count.withLock { $0 } == 1)
    }

    @Test func witnessesMoveNoncopyableStorageWithoutCopying() throws {
        let deaths = RuntimeValueDeaths()
        let metadata = unsafeBitCast(RuntimeMoveOnlyPayload.self, to: UnsafeRawPointer.self)
        let layout = ABISwiftGetValueLayout(metadata)
        #expect(layout.size == MemoryLayout<RuntimeMoveOnlyPayload>.size)
        #expect(layout.stride == MemoryLayout<RuntimeMoveOnlyPayload>.stride)
        #expect(layout.alignment == MemoryLayout<RuntimeMoveOnlyPayload>.alignment)
        #expect(!layout.isCopyable)
        let source = UnsafeMutablePointer<RuntimeMoveOnlyPayload>.allocate(capacity: 1)
        source.initialize(to: RuntimeMoveOnlyPayload(life: RuntimeValueLife(deaths), text: String(repeating: "moved", count: 100)))
        let destination = UnsafeMutableRawPointer.allocate(byteCount: layout.stride, alignment: layout.alignment)
        destination.initializeMemory(as: UInt8.self, repeating: 0xa5, count: layout.stride)
        defer { source.deallocate(); destination.deallocate() }
        #expect(!ABISwiftCopyValue(metadata, destination, source))
        #expect(UnsafeRawBufferPointer(start: destination, count: layout.stride).allSatisfy { $0 == 0xa5 })
        #expect(source.pointee.text == String(repeating: "moved", count: 100))
        ABISwiftTakeValue(metadata, destination, source)
        #expect(deaths.count.withLock { $0 } == 0)
        #expect(destination.assumingMemoryBound(to: RuntimeMoveOnlyPayload.self).pointee.text == String(repeating: "moved", count: 100))
        ABISwiftDestroyValue(metadata, destination)
        #expect(deaths.count.withLock { $0 } == 1)
    }
}
