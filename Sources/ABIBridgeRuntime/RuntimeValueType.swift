import ABIBridgeCore

package final class RuntimeValueType: @unchecked Sendable {
    package let handle: OpaquePointer
    package let size: Int
    package let alignment: Int

    package init(adopting handle: OpaquePointer) {
        self.handle = handle
        size = ABIValueTypeSize(handle)
        alignment = ABIValueTypeAlignment(handle)
    }

    package init(scalar: Int) throws {
        var failure: OpaquePointer?
        guard let handle = ABICreateScalarType(Int32(scalar), &failure) else {
            throw consumeRuntimeCallFailure(failure)
        }
        self.handle = handle
        size = ABIValueTypeSize(handle)
        alignment = ABIValueTypeAlignment(handle)
    }

    package init(fields: [RuntimeValueType]) throws {
        let handles: [OpaquePointer?] = fields.map(\.handle)
        var failure: OpaquePointer?
        // Keep the owners alive until the aggregate retains each native field type.
        let handle = withExtendedLifetime(fields) {
            handles.withUnsafeBufferPointer {
                ABICreateStructType($0.baseAddress, $0.count, &failure)
            }
        }
        guard let handle else { throw consumeRuntimeCallFailure(failure) }
        self.handle = handle
        size = ABIValueTypeSize(handle)
        alignment = ABIValueTypeAlignment(handle)
    }

    package init(indirectSwiftSize size: Int, alignment: Int) throws {
        var failure: OpaquePointer?
        guard let handle = ABICreateSwiftIndirectStorageType(size, alignment, &failure) else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
        }
        self.handle = handle
        self.size = size
        self.alignment = alignment
    }

    package init(
        swiftTuple fields: [RuntimeValueType],
        offsets: [Int],
        size: Int,
        alignment: Int,
        isPack: Bool = false
    ) throws {
        let handles: [OpaquePointer?] = fields.map(\.handle)
        var failure: OpaquePointer?
        let handle = withExtendedLifetime(fields) {
            handles.withUnsafeBufferPointer { handles in
                offsets.withUnsafeBufferPointer { offsets in
                    if isPack {
                        ABICreateSwiftPackStorageType(
                            handles.baseAddress,
                            offsets.baseAddress,
                            fields.count,
                            size,
                            alignment,
                            &failure
                        )
                    } else {
                        ABICreateSwiftTupleStorageType(
                            handles.baseAddress,
                            offsets.baseAddress,
                            fields.count,
                            size,
                            alignment,
                            &failure
                        )
                    }
                }
            }
        }
        guard let handle else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
        }
        self.handle = handle
        self.size = size
        self.alignment = alignment
    }

    package init(swiftOptionalSingleton: Void) {
        handle = ABICreateSwiftOptionalSingletonType()!
        size = MemoryLayout<UInt>.size
        alignment = MemoryLayout<UInt>.alignment
    }

    package init(swiftComponents components: RuntimeValueType, size: Int, alignment: Int) throws {
        var failure: OpaquePointer?
        let handle = withExtendedLifetime(components) {
            ABICreateSwiftStorageType(components.handle, size, alignment, &failure)
        }
        guard let handle else {
            throw consumeRuntimeCallFailure(failure, domain: "ABIBridge.SwiftInvocation")
        }
        self.handle = handle
        self.size = size
        self.alignment = alignment
    }

    deinit { ABIReleaseValueType(handle) }
}
