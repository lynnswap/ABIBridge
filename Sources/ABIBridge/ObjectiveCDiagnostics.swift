import ABIBridgeCore
import ABIBridgeObjCXX
import Foundation

func objcMethodDeclaration(on type: AnyClass, selector: String, classMethod: Bool) -> NativeDeclaration {
    .init(name: "\(classMethod ? "+" : "-")[\(NSStringFromClass(type)) \(selector)]", language: .objectiveC)
}

// Translate only this boundary's known failures. Other NSError domains and
// future codes retain their native identity instead of becoming lookup absence.
func objcResolutionError(_ error: NSError?, declaration: NativeDeclaration) -> any Error {
    guard let error else {
        return ABIResolutionError.metadataUnavailable("No native lookup diagnostic for " + declaration.name)
    }
    guard error.domain == ABIObjCInvocationErrorDomain else { return error }
    switch error.code {
    case Int(ABIFailureImageUnavailable): return ABIResolutionError.imageUnavailable
    case Int(ABIFailureImageNotLoaded): return ABIResolutionError.imageNotLoaded
    case Int(ABIFailureDeclarationNotFound): return ABIResolutionError.declarationNotFound(declaration)
    case Int(ABIFailureSignatureMismatch):
        return ABIResolutionError.signatureMismatch(.init(
            declaration: declaration, expected: "A compatible Objective-C signature",
            found: [error.localizedDescription]
        ))
    case Int(ABIFailureUnsupportedDeclaration), Int(ABIFailureInvalidRequest):
        return ABIResolutionError.unsupportedDeclaration(error.localizedDescription)
    case Int(ABIFailureMetadataUnavailable):
        return ABIResolutionError.metadataUnavailable(error.localizedDescription)
    case Int(ABIFailureImageChanged): return ABIResolutionError.imageChanged
    case Int(ABIFailureInvalidAddress): return ABIResolutionError.invalidAddress
    default: return error
    }
}
