import ABIBridgeCore
import Foundation
import Darwin

enum FunctionCallbackFrameError: Error { case expiredInvocation, wrongThread }

final class FunctionCallbackFrame {
    let lock = NSLock()
    let thread = pthread_self()
    var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func use<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        guard let pointer else { lock.unlock(); throw FunctionCallbackFrameError.expiredInvocation }
        guard pthread_equal(thread, pthread_self()) != 0 else { lock.unlock(); throw FunctionCallbackFrameError.wrongThread }
        lock.unlock()
        return try body(pointer)
    }
    func expire() { lock.lock(); pointer = nil; lock.unlock() }
}

struct FunctionCallbackSignature<Result, each Argument>: Sendable {
    let result: CValueCodec<Result>
    let arguments: (repeat CValueCodec<each Argument>)
    init() throws { result = try CValueCodec(); arguments = (repeat try CValueCodec<each Argument>()) }
    func proceed(_ pointer: OpaquePointer, prefix: [NativeValueStorage] = [], _ values: repeat each Argument) throws -> Result {
        var storage = prefix
        for (codec, value) in repeat (each arguments, each values) { storage.append(try codec.encode(value)) }
        let addresses: [UnsafeMutableRawPointer?] = storage.map(\.address)
        var error: OpaquePointer?
        let ok = withExtendedLifetime(storage) { addresses.withUnsafeBufferPointer { ABIImportedProceed(pointer,$0.baseAddress,$0.count,&error) } }
        guard ok else { throw consumeNativeCallFailure(error) }
        let output = NativeValueStorage(size: result.type.size, alignment: result.type.alignment)
        guard ABIImportedCopyResult(pointer,output.address,result.type.size,&error) else { throw consumeNativeCallFailure(error) }
        return try result.decode(output)
    }
    func decodeArguments(_ pointer: OpaquePointer, startingAt offset: Int = 0) throws -> (repeat each Argument) {
        var index = offset
        func decode<T>(_ codec: CValueCodec<T>) throws -> T {
            defer { index += 1 }
            let storage = NativeValueStorage(size: codec.type.size, alignment: codec.type.alignment)
            var error: OpaquePointer?
            guard ABIImportedReadArgument(pointer,index,storage.address,codec.type.size,&error) else { throw consumeNativeCallFailure(error) }
            return try codec.decode(storage)
        }
        return (repeat try decode(each arguments))
    }
}

final class FunctionCallbackBox {
    let result: CValueType
    let parameters: [CValueType]
    let invoke: (OpaquePointer) throws -> Void
    let failure: @Sendable (any Error) -> Void
    init(result: CValueType, parameters: [CValueType], invoke: @escaping (OpaquePointer) throws -> Void,
         failure: @escaping @Sendable (any Error) -> Void) {
        self.result=result; self.parameters=parameters; self.invoke=invoke; self.failure=failure
    }
}

func invokeFunctionCallback(_ box: FunctionCallbackBox, _ call: OpaquePointer) -> Bool {
    do { try box.invoke(call) }
    catch { box.failure(error) }
    // A failure without an assigned result uses native fallback or the latest
    // completed continuation, while preserving the original Swift error above.
    return true
}
