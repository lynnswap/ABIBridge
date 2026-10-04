import ABIBridgeCore

package final class RuntimeImplementation: @unchecked Sendable {
    package let handle: OpaquePointer
    package let owner: (any Sendable)?
    package let image: RuntimeImage?
    package var function: ABIUnmanagedFunction { ABIVirtualCallTargetFunction(handle)! }
    package var generation: UInt64 { ABIVirtualCallTargetGeneration(handle) }

    package init?(
        bits: UInt,
        storage: UnsafeRawPointer,
        authentication: RuntimePointerAuthentication,
        retaining owner: (any Sendable)?
    ) throws {
        var error: OpaquePointer?
        guard
            let handle = ABICopyFunctionSlotTarget(
                bits,
                storage,
                authentication.keyCode,
                authentication.discriminator,
                authentication.addressDiversity,
                &error
            )
        else {
            if let error { throw consumeRuntimeCallFailure(error) }
            return nil
        }
        self.handle = handle
        self.owner = owner
        do {
            image = try RuntimeImage.retaining(generation: ABIVirtualCallTargetGeneration(handle))
        } catch { ABIReleaseVirtualCallTarget(handle); throw error }
    }
    package init(function: ABIUnmanagedFunction, retaining owner: (any Sendable)?) throws {
        var error: OpaquePointer?
        guard let handle = ABICopyFunctionTarget(function, &error) else {
            throw consumeRuntimeCallFailure(error)
        }
        self.handle = handle
        self.owner = owner
        do {
            image = try RuntimeImage.retaining(generation: ABIVirtualCallTargetGeneration(handle))
        } catch { ABIReleaseVirtualCallTarget(handle); throw error }
    }
    deinit { ABIReleaseVirtualCallTarget(handle) }
}
