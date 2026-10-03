import ABIBridgeCore
import Foundation

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
// The entry contains only ABI/code preparation. Native ARC owns each body's
// context separately, so caching or evicting an entry cannot retain captures.
final class SwiftClosureContext {
    let entry: SwiftClosureCallbackOwner
    let body: SwiftThrowingClosureBody
    var function: ABIUnmanagedFunction { entry.function }
    init(interface: SwiftCallInterface, body: SwiftThrowingClosureBody) throws {
        entry = try interface.closureEntry()
        self.body = body
    }

    func value(discriminator: UInt16) -> ABISwiftClosureValue {
        ABISwiftClosureValue(function: ABISignSwiftClosureFunction(function, discriminator),
            context: Unmanaged.passUnretained(self).toOpaque())
    }

    func storage(discriminator: UInt16, codeLifetime: SwiftValueCodeLifetime? = nil) throws -> SwiftClosureStorage {
        let value = value(discriminator: discriminator)
        ABIRetainSwiftClosureContext(value.context)
        return try SwiftClosureStorage(adopting: value, discriminator: discriminator, retaining: nil,
            codeLifetime: codeLifetime, implementation: entry.implementation)
    }
}

extension SwiftClosureCallbackOwner {
    convenience init(interface: SwiftCallInterface) throws {
        var functions = ABISwiftThrowingClosureCallbackFunctions()
        functions.usesNativeContext = true
        functions.invoke = { context, arguments, result, error in
            Unmanaged<SwiftClosureContext>.fromOpaque(context!).takeUnretainedValue().body.invoke(arguments, result!, error)
        }
        functions.copyCodeOwner = { context in
            let owner = Unmanaged<SwiftClosureContext>.fromOpaque(context!).takeUnretainedValue().body.codeOwner
            return owner.map { Unmanaged.passRetained($0).toOpaque() }
        }
        functions.copyBodyOwner = { context in
            let factory = Unmanaged<SwiftClosureContext>.fromOpaque(context!).takeUnretainedValue().body.callbackFactory
            return factory.map { Unmanaged.passRetained($0).toOpaque() }
        }
        var failure: OpaquePointer?
        guard let handle = ABICreateSwiftThrowingClosureCallback(interface.handle, functions, nil, &failure) else {
            throw consumeNativeCallFailure(failure, domain: "ABIBridge.SwiftClosure")
        }
        try self.init(handle: handle)
    }
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


// A host body can bind directly to a native declaration. Its canonical native
// value is prepared only when used, and never owns this holder through its body.
final class SwiftClosureHost {
    let factory: SwiftClosureBodyFactory
    let codeLifetime: SwiftValueCodeLifetime
    private let lock = NSLock()
    private let prepare: () throws -> SwiftClosureCall
    private var native: SwiftClosureCall?

    init(factory: SwiftClosureBodyFactory, codeLifetime: SwiftValueCodeLifetime,
         prepare: @escaping () throws -> SwiftClosureCall) {
        self.factory = factory; self.codeLifetime = codeLifetime; self.prepare = prepare
    }

    func resolved() throws -> SwiftClosureCall {
        lock.lock(); defer { lock.unlock() }
        if let native { return native }
        let value = try prepare()
        native = value
        return value
    }
}

extension SwiftClosureBodyFactory {
    func encode(plan: SwiftGenericClosurePlan, retainingCode owner: Any?,
                codeLifetime: SwiftValueCodeLifetime?) throws -> NativeValueStorage {
        try plan.validateCallbackConversion()
        switch plan.transport {
        case .synchronous(let interface):
            let context = try SwiftClosureContext(interface: interface,
                body: synchronous(plan: plan, retainingCode: owner))
            return SwiftClosureStorage.copy(context.value(discriminator: plan.discriminator),
                retaining: context, codeLifetime: codeLifetime)
        case .asynchronous(let interface, _):
            let context = try SwiftAsyncClosureContext(interface: interface,
                body: asynchronous(plan: plan, retainingCode: owner))
            return SwiftClosureStorage.copy(context.value(discriminator: plan.discriminator),
                retaining: context, codeLifetime: codeLifetime)
        }
    }
}
