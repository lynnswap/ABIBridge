import ABIBridgeCore
import Foundation

package func consumeRuntimeCallFailure(
    _ failure: OpaquePointer?,
    domain: String = "ABIBridge.CInvocation"
) -> any Error {
    guard let failure else {
        return RuntimeResolutionError.metadataUnavailable(
            "The native call interface returned no failure details."
        )
    }
    defer { ABIReleaseResolutionFailure(failure) }
    return NSError(
        domain: domain,
        code: Int(ABIResolutionFailureCode(failure)),
        userInfo: [NSLocalizedDescriptionKey: String(cString: ABIResolutionFailureMessage(failure))]
    )
}
