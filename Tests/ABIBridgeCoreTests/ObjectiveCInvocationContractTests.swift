import ABIBridgeCore
import ABIBridgeObjCXX
import ABIBridgeRuntime
import CoreGraphics
import Foundation
import ObjectiveCFixtures
import Testing

struct ObjectiveCInvocationContractTests {
    @Test(arguments: [false, true])
    func aggregateCallsMatchCompiledDispatch(_ capturedImplementation: Bool) throws {
        let receiver = ABIReplacementFixture()
        let selector = NSSelectorFromString("translate:")
        var error: NSError?
        let handle: OpaquePointer?
        if capturedImplementation {
            handle = ABICopyObjCImplementation(
                ABIReplacementFixture.self,
                selector,
                false,
                -1,
                -1,
                nil,
                0,
                &error
            )
        } else {
            handle = ABICopyObjCInvocation(receiver, selector, -1, -1, nil, 0, &error)
        }
        let plan = try #require(handle)
        defer { ABIReleaseObjCInvocation(plan) }
        #expect(error == nil)
        let input = CGRect(x: 1, y: 2, width: 3, height: 4)
        let expected = receiver.translate(input)
        var output = CGRect.zero
        let scalar = try RuntimeValueType(scalar: ABIValueDouble)
        let pair = try RuntimeValueType(fields: [scalar, scalar])
        let rectangle = try RuntimeValueType(fields: [pair, pair])
        let pointer = try RuntimeValueType(scalar: ABIValuePointer)
        let interface = try RuntimeCCallInterface(
            result: rectangle,
            parameters: [pointer, pointer, rectangle]
        )
        let succeeded = withUnsafePointer(to: input) { address in
            let arguments = [UnsafeRawPointer(address)]
            return arguments.withUnsafeBufferPointer {
                if capturedImplementation {
                    return ABIInvokeObjCImplementation(
                        plan,
                        interface.handle,
                        receiver,
                        &output,
                        $0.baseAddress,
                        &error
                    )
                }
                return ABIInvokeObjCInvocation(plan, &output, $0.baseAddress, &error)
            }
        }
        #expect(succeeded)
        #expect(error == nil)
        #expect(output == expected)
    }

    @Test(arguments: ["object", "copyObject"])
    func objectResultsTransferOneOwnedReference(_ name: String) throws {
        let receiver = ABIReplacementFixture()
        var error: NSError?
        let plan = try #require(
            ABICopyObjCInvocation(receiver, NSSelectorFromString(name), -1, -1, nil, 0, &error)
        )
        defer { ABIReleaseObjCInvocation(plan) }
        #expect(ABIObjCInvocationReturnsRetained(plan) == (name == "copyObject"))
        weak var observed: AnyObject?
        try autoreleasepool {
            var result: UnsafeMutableRawPointer?
            #expect(ABIInvokeObjCInvocation(plan, &result, nil, &error))
            #expect(error == nil)
            let value = Unmanaged<AnyObject>.fromOpaque(try #require(result)).takeRetainedValue()
            observed = value
            withExtendedLifetime(value) { #expect(receiver.liveResults == 1) }
        }
        #expect(observed == nil)
        #expect(receiver.liveResults == 0)
    }
}
