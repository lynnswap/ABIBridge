import ManagedSwiftFixtures

// The C boundary borrows initialized input and initializes fresh output.
// Only the compiler translates the actual Swift argument and result ABI.
@_cdecl("ABIManagedRecordTransform")
public func managedRecordTransform(_ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer) {
    output.bindMemory(to: ManagedRecord.self, capacity: 1)
        .initialize(to: transformManaged(input.load(as: ManagedRecord.self)))
}

@_cdecl("ABIOptionalValueTransform")
public func optionalValueTransform(_ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer) {
    output.bindMemory(to: Int64?.self, capacity: 1)
        .initialize(to: transformOptional(input.load(as: Int64?.self)))
}

@_cdecl("ABIResilientRecordTransform")
public func resilientRecordTransform(_ input: UnsafeRawPointer, _ output: UnsafeMutableRawPointer) {
    output.bindMemory(to: ResilientRecord.self, capacity: 1)
        .initialize(to: transformResilient(input.load(as: ResilientRecord.self)))
}

// Unspecialized operations exercise metadata/value witnesses without inventing
// a Swift by-value call signature from the storage extent.
@inline(never) public func copyValue<Value>(
    _ type: Value.Type, from input: UnsafeRawPointer, to output: UnsafeMutableRawPointer
) {
    output.bindMemory(to: Value.self, capacity: 1).initialize(to: input.load(as: Value.self))
}

@inline(never) public func moveValue<Value>(
    _ type: Value.Type, from input: UnsafeMutableRawPointer, to output: UnsafeMutableRawPointer
) {
    output.bindMemory(to: Value.self, capacity: 1)
        .moveInitialize(from: input.assumingMemoryBound(to: Value.self), count: 1)
}

@inline(never) public func destroyValue<Value>(_ type: Value.Type, at address: UnsafeMutableRawPointer) {
    address.assumingMemoryBound(to: Value.self).deinitialize(count: 1)
}

// A caller without an importable Swift type sees owned opaque handles.
// The counter's allocation belongs to the fixture caller and outlives all handles.
@_cdecl("ABIResilientRecordCreate")
public func resilientRecordCreate(_ number: Int64, _ destroyed: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer {
    let storage = UnsafeMutablePointer<ResilientRecord>.allocate(capacity: 1)
    storage.initialize(to: ResilientRecord(
        token: LifetimeToken { destroyed.pointee += 1 }, number: number
    ))
    return UnsafeMutableRawPointer(storage)
}

@_cdecl("ABIResilientRecordCopy")
public func resilientRecordCopy(_ input: UnsafeRawPointer) -> UnsafeMutableRawPointer {
    let storage = UnsafeMutablePointer<ResilientRecord>.allocate(capacity: 1)
    storage.initialize(to: input.load(as: ResilientRecord.self))
    return UnsafeMutableRawPointer(storage)
}

@_cdecl("ABIResilientRecordNumber")
public func resilientRecordNumber(_ input: UnsafeRawPointer) -> Int64 {
    input.load(as: ResilientRecord.self).number
}

@_cdecl("ABIResilientRecordDestroy")
public func resilientRecordDestroy(_ address: UnsafeMutableRawPointer) {
    let storage = address.assumingMemoryBound(to: ResilientRecord.self)
    storage.deinitialize(count: 1)
    storage.deallocate()
}
