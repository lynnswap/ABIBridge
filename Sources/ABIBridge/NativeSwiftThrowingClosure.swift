import ABIBridgeCore

final class SwiftThrowingClosureBody {
    let codeOwner: SwiftClosureCodeOwner?
    let callbackFactory: SwiftClosureBodyFactory?
    let invoke: (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool
    init(retainingCode codeOwner: Any? = nil, codeLifetime: SwiftValueCodeLifetime? = nil, callbackFactory: SwiftClosureBodyFactory? = nil,
         _ invoke: @escaping (UnsafePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool) {
        self.callbackFactory = callbackFactory
        self.codeOwner = SwiftClosureCodeOwner(codeOwner, codeLifetime: codeLifetime)
        self.invoke = { arguments, result, error in
            SwiftValueCodeLifetime.withCurrent(codeLifetime) { invoke(arguments, result, error) }
        }
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
    functions.copyBodyOwner = { context in
        let factory = Unmanaged<SwiftThrowingClosureBody>.fromOpaque(context!).takeUnretainedValue().callbackFactory
        return factory.map { Unmanaged.passRetained($0).toOpaque() }
    }
    let context = Unmanaged.passRetained(body)
    var failure: OpaquePointer?
    guard let handle = ABICreateSwiftThrowingClosureCallback(interface.handle, functions, context.toOpaque(), &failure) else {
        context.release()
        throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
    }
    return SwiftClosureCallbackOwner(handle: handle)
}

// The body is prepared once for each native declaration. Nested closures use
// that declaration's value plans directly, without an intermediate host ABI call.
final class SwiftClosureBodyFactory {
    enum Preparation {
        case synchronous((SwiftGenericClosurePlan?, SwiftClosureBodyFactory, Any?) throws -> SwiftThrowingClosureBody)
        case asynchronous((SwiftGenericClosurePlan?, SwiftClosureBodyFactory, Any?) throws -> SwiftAsyncClosureBody)
    }
    let signature: Any.Type
    private let preparation: Preparation
    init(signature: Any.Type, synchronous: @escaping (SwiftGenericClosurePlan?, SwiftClosureBodyFactory, Any?) throws -> SwiftThrowingClosureBody) {
        self.signature = signature
        preparation = .synchronous(synchronous)
    }
    init(signature: Any.Type, asynchronous: @escaping (SwiftGenericClosurePlan?, SwiftClosureBodyFactory, Any?) throws -> SwiftAsyncClosureBody) {
        self.signature = signature
        preparation = .asynchronous(asynchronous)
    }
    func synchronous(plan: SwiftGenericClosurePlan?, retainingCode owner: Any?) throws -> SwiftThrowingClosureBody {
        guard case .synchronous(let prepare) = preparation else { preconditionFailure("The callback's effects agree with its native plan.") }
        return try prepare(plan, self, owner)
    }
    func asynchronous(plan: SwiftGenericClosurePlan?, retainingCode owner: Any?) throws -> SwiftAsyncClosureBody {
        guard case .asynchronous(let prepare) = preparation else { preconditionFailure("The callback's effects agree with its native plan.") }
        return try prepare(plan, self, owner)
    }
}
