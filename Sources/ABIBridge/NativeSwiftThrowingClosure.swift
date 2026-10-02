import ABIBridgeCore

final class SwiftThrowingClosureBody {
    let codeOwner: SwiftClosureCodeOwner?
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool
    init(retainingCode codeOwner: Any? = nil, codeLifetime: SwiftValueCodeLifetime? = nil,
         _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool) {
        self.codeOwner = codeOwner.map { SwiftClosureCodeOwner($0, codeLifetime: codeLifetime) }
        self.invoke = invoke
    }
}
func throwingClosureOwner(_ interface: SwiftCallInterface, body: SwiftThrowingClosureBody) throws -> SwiftClosureCallbackOwner {
    var functions = ABISwiftThrowingClosureCallbackFunctions()
    functions.invoke = { context, arguments, result, error in
        Unmanaged<SwiftThrowingClosureBody>.fromOpaque(context!).takeUnretainedValue().invoke(arguments, result!, error)
    }
    functions.releaseContext = { Unmanaged<SwiftThrowingClosureBody>.fromOpaque($0!).release() }
    functions.copyCodeOwner = { context in
        let owner = Unmanaged<SwiftThrowingClosureBody>.fromOpaque(context!).takeUnretainedValue().codeOwner
        return owner.map { Unmanaged.passRetained($0).toOpaque() }
    }
    let context = Unmanaged.passRetained(body)
    var failure: OpaquePointer?
    guard let handle = ABICreateSwiftThrowingClosureCallback(interface.handle, functions, context.toOpaque(), &failure) else {
        context.release()
        throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
    }
    return SwiftClosureCallbackOwner(handle: handle)
}
