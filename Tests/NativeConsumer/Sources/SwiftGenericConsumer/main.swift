import ABIBridge
import Darwin
import Foundation

private enum GenericConsumerFailure: Error { case load(String), initialize(Int32) }

@MainActor
func prepare(_ path: String, destroyed: UnsafeMutablePointer<Int32>) async throws -> (
    NativeValue, NativeFunction<Int32, UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<Int64>>, UnsafeRawPointer
) {
    guard let original = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
        throw GenericConsumerFailure.load(String(cString: dlerror()))
    }
    defer { dlclose(original) }
    let runtime = ABIRuntime()
    let scope = ImageSelector.path(URL(fileURLWithPath: path))
    let argumentType = try await runtime.cFunction(named: "ABIGenericResilientArgument", as: (() -> UnsafeRawPointer).self)
    let argument = try unsafe argumentType.unsafeInvoke()
    let metadata = try await runtime.cFunction(
        named: "ABIGenericRecordMetadata", as: ((UnsafeRawPointer?, UnsafeMutablePointer<UnsafeRawPointer?>) -> Int32).self, in: scope
    )
    var first: UnsafeRawPointer?, repeated: UnsafeRawPointer?
    let firstStatus = try withUnsafeMutablePointer(to: &first) { try unsafe metadata.unsafeInvoke(argument, $0) }
    let repeatedStatus = try withUnsafeMutablePointer(to: &repeated) { try unsafe metadata.unsafeInvoke(argument, $0) }
    precondition(firstStatus == 0 && repeatedStatus == 0 && first != nil && first == repeated)
    let layout = try await runtime.cFunction(
        named: "ABIGenericRecordLayout",
        as: ((UnsafeRawPointer?, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Int32).self, in: scope
    )
    var stride = 0, alignment = 0
    let layoutStatus = try withUnsafeMutablePointer(to: &stride) { stride in
        try withUnsafeMutablePointer(to: &alignment) { try unsafe layout.unsafeInvoke(argument, stride, $0) }
    }
    precondition(layoutStatus == 0)
    let create = try await runtime.cFunction(
        named: "ABIResilientRecordCreate", as: ((Int64, UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer).self, in: scope
    )
    let destroyInput = try await runtime.cFunction(named: "ABIResilientRecordDestroy", as: ((UnsafeMutableRawPointer) -> Void).self, in: scope)
    let initialize = try await runtime.cFunction(
        named: "ABIGenericRecordInitialize",
        as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutableRawPointer) -> Int32).self, in: scope
    )
    let destroy = try await runtime.cFunction(
        named: "ABIGenericRecordDestroy", as: ((UnsafeRawPointer?, UnsafeMutableRawPointer) -> Int32).self, in: scope
    )
    let measure = try await runtime.cFunction(
        named: "ABIGenericRecordMeasure",
        as: ((UnsafeRawPointer?, UnsafeRawPointer, UnsafeMutablePointer<Int64>) -> Int32).self, in: scope
    )
    let input = unsafe NativeValue(adopting: try create.unsafeInvoke(42, destroyed),
                                  as: try .opaque(named: "ResilientRecord"), retaining: destroyInput, release: { address in
        do { try unsafe destroyInput.unsafeInvoke(address) }
        catch { fatalError("Input destruction failed: \(error)") }
    })
    let value = try NativeValue(type: .opaque(named: "GenericRecord", size: stride, alignment: alignment),
                               retaining: (initialize, destroy, argumentType), destroy: { address in
        do {
            let status = try unsafe destroy.unsafeInvoke(argument, address)
            precondition(status == 0)
        } catch { fatalError("Generic destruction failed: \(error)") }
    }) { output in
        let status = try unsafe input.withUnsafeBytes {
            try unsafe initialize.unsafeInvoke(argument, $0.baseAddress!, output.baseAddress!)
        }
        guard status == 0 else { throw GenericConsumerFailure.initialize(status) }
    }
    await runtime.removeCachedResults()
    return (value, measure, argument)
}

let destroyed = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
destroyed.initialize(to: 0)
defer { destroyed.deinitialize(count: 1); destroyed.deallocate() }
var value: NativeValue?
do {
    let prepared = try await prepare(CommandLine.arguments[1], destroyed: destroyed)
    value = prepared.0
    precondition(destroyed.pointee == 0)
    var actual: Int64 = -1
    let status = try unsafe prepared.0.withUnsafeBytes { input in
        try withUnsafeMutablePointer(to: &actual) {
            try unsafe prepared.1.unsafeInvoke(prepared.2, input.baseAddress!, $0)
        }
    }
    precondition(status == 0 && actual == 42)
}
// Only the value's destructor and retained owners remain; all lookup handles
// outside the value, the runtime, and the original loader reference have ended.
withExtendedLifetime(value) { precondition(destroyed.pointee == 0) }
value = nil
precondition(destroyed.pointee == 1)
print("Generic Swift consumer passed")
