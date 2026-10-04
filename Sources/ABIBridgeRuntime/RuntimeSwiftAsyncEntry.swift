import ABIBridgeCore

@_silgen_name("ABIInvokeSwiftAsync")
nonisolated(nonsending) package func invokeSwiftAsync(_ invocation: OpaquePointer) async

package final class RuntimeSwiftAsyncEntry: @unchecked Sendable {
    package let handle: OpaquePointer
    package var function: ABIUnmanagedFunction { ABISwiftAsyncDescriptorFunction(handle)! }
    package var contextSize: UInt32 { ABISwiftAsyncDescriptorContextSize(handle) }
    package init(descriptor: UnsafeRawPointer) throws {
        var failure: OpaquePointer?
        guard let handle = ABICopySwiftAsyncDescriptor(descriptor, &failure) else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftAsyncInvocation")
        }
        self.handle = handle
    }
    deinit { ABIReleaseSwiftAsyncDescriptor(handle) }
}
// Used only while a native call already owns the authenticated descriptor.
package func runtimeAsyncDescriptorComponents(
    _ descriptor: UnsafeRawPointer
) -> (function: ABIUnmanagedFunction?, contextSize: UInt32) {
    let offset = descriptor.load(as: Int32.self)
    return (
        ABIUnsafeFunctionAtAddress(descriptor.advanced(by: Int(offset))),
        descriptor.load(fromByteOffset: 4, as: UInt32.self)
    )
}
