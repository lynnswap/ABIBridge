import ManagedSwiftFixtures

// A metadata pointer must come from a live Swift metatype with a retained image.
// Status 1 means unavailable metadata; 2 means an unsatisfied existing conformance.
// Failure leaves output storage untouched. Success is synchronous and nonthrowing.
private func withGenericMetric(
    _ metadata: UnsafeRawPointer?, _ body: (any GenericMetric.Type) -> Void
) -> Int32 {
    guard let metadata else { return 1 }
    guard let type = unsafeBitCast(metadata, to: Any.Type.self) as? any GenericMetric.Type else { return 2 }
    body(type)
    return 0
}

@_cdecl("ABIGenericRecordMetadata")
public func genericRecordMetadata(
    _ argument: UnsafeRawPointer?, _ output: UnsafeMutablePointer<UnsafeRawPointer?>
) -> Int32 {
    withGenericMetric(argument) { type in
        func specialize<Value: GenericMetric>(_ type: Value.Type) {
            output.pointee = unsafeBitCast(GenericRecord<Value>.self, to: UnsafeRawPointer.self)
        }
        specialize(type)
    }
}

@_cdecl("ABIGenericRecordLayout")
public func genericRecordLayout(
    _ argument: UnsafeRawPointer?, _ stride: UnsafeMutablePointer<Int>, _ alignment: UnsafeMutablePointer<Int>
) -> Int32 {
    withGenericMetric(argument) { type in
        func layout<Value: GenericMetric>(_ type: Value.Type) {
            stride.pointee = MemoryLayout<GenericRecord<Value>>.stride
            alignment.pointee = MemoryLayout<GenericRecord<Value>>.alignment
        }
        layout(type)
    }
}

@_cdecl("ABIGenericRecordInitialize")
public func genericRecordInitialize(
    _ argument: UnsafeRawPointer?, _ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer
) -> Int32 {
    withGenericMetric(argument) { type in
        func initialize<Value: GenericMetric>(_ type: Value.Type) {
            output.bindMemory(to: GenericRecord<Value>.self, capacity: 1)
                .initialize(to: makeGenericRecord(input.load(as: Value.self)))
        }
        initialize(type)
    }
}

@_cdecl("ABIGenericRecordMeasure")
public func genericRecordMeasure(
    _ argument: UnsafeRawPointer?, _ input: UnsafeRawPointer, _ output: UnsafeMutablePointer<Int64>
) -> Int32 {
    withGenericMetric(argument) { type in
        func measure<Value: GenericMetric>(_ type: Value.Type) {
            output.pointee = measureGenericRecord(input.load(as: GenericRecord<Value>.self))
        }
        measure(type)
    }
}

@_cdecl("ABIGenericRecordDestroy")
public func genericRecordDestroy(_ argument: UnsafeRawPointer?, _ storage: UnsafeMutableRawPointer) -> Int32 {
    withGenericMetric(argument) { type in
        func destroy<Value: GenericMetric>(_ type: Value.Type) {
            storage.assumingMemoryBound(to: GenericRecord<Value>.self).deinitialize(count: 1)
        }
        destroy(type)
    }
}
