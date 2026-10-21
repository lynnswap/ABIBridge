import ABIBridgeObjCXX
import Foundation

/// An Objective-C exception raised by an invoked method.
///
/// ABIBridge catches the exception at the native boundary instead of letting it unwind through Swift frames. Arguments already transferred to the method are not reclaimed, and the method's side effects remain.
public struct NativeObjCException: Error, Sendable, CustomStringConvertible {
    /// The exception's name, such as `NSInvalidArgumentException`.
    public let name: String
    /// The exception's reason, when it has one.
    public let reason: String?
    /// The call stack where the exception was raised.
    public let callStackSymbols: [String]

    public var description: String { name + ": " + (reason ?? "(no reason)") }

    init(_ error: NSError) {
        name = error.userInfo[ABIObjCExceptionNameKey] as? String ?? ""
        reason = error.userInfo[ABIObjCExceptionReasonKey] as? String
        callStackSymbols = error.userInfo[ABIObjCExceptionCallStackKey] as? [String] ?? []
    }
}

/// An Objective-C method reported failure through its result without providing an `NSError`.
public struct NativeObjCUnreportedFailure: Error, Sendable {
    /// The method that failed.
    public let declaration: NativeDeclaration
}

/// The call contract of a prepared Objective-C message.
///
/// A method declared with a Swift `throws` signature has a trailing `NSError **` parameter that the caller does not supply. It fails when it returns `NO`, for a `Void` Swift result, or `nil`, for an object result, and the error it stores is thrown.
struct ObjCCallSignature<Result, each Argument>: Sendable {
    private let direct: ObjCMethodSignature<Result, repeat each Argument>?
    private let nilResult: ObjCMethodSignature<Result?, repeat each Argument>?
    private let falseResult: ObjCMethodSignature<Bool, repeat each Argument>?
    private let declaration: NativeDeclaration

    init(
        handle: OpaquePointer,
        declaration: NativeDeclaration,
        variadicFrom: Int? = nil,
        reportsErrors: Bool = false
    ) throws {
        self.declaration = declaration
        guard reportsErrors else {
            direct = try ObjCMethodSignature(
                handle: handle,
                declaration: declaration,
                variadicFrom: variadicFrom
            )
            nilResult = nil
            falseResult = nil
            return
        }
        guard variadicFrom == nil else {
            throw ABIResolutionError.unsupportedDeclaration(
                "A variadic Objective-C method cannot report errors through a trailing parameter."
            )
        }
        let count = ABIObjCInvocationParameterCount(handle)
        guard count > 0,
            Self.unqualified(ABIObjCInvocationParameterType(handle, count - 1)) == "^@"
        else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    declaration: declaration,
                    position: .signature,
                    expected: "A trailing NSError ** parameter",
                    found: [count > 0 ? String(cString: ABIObjCInvocationParameterType(handle, count - 1)) : "no parameters"]
                )
            )
        }
        direct = nil
        if Result.self == Void.self {
            falseResult = try ObjCMethodSignature(
                handle: handle,
                declaration: declaration,
                errorSlot: true
            )
            nilResult = nil
        } else {
            guard Self.unqualified(ABIObjCInvocationResultType(handle)).hasPrefix("@"),
                !(Result.self is any NativeOptionalValue.Type)
            else {
                throw ABIResolutionError.signatureMismatch(
                    .init(
                        declaration: declaration,
                        position: .result,
                        expected: "Void for a BOOL result, or a nonoptional object",
                        found: [String(cString: ABIObjCInvocationResultType(handle))]
                    )
                )
            }
            nilResult = try ObjCMethodSignature(
                handle: handle,
                declaration: declaration,
                errorSlot: true
            )
            falseResult = nil
        }
    }

    var variadicInterface: CCallInterface? { direct?.variadicInterface }

    func callInterface() throws -> CCallInterface {
        if let direct { return try direct.callInterface() }
        if let nilResult { return try nilResult.callInterface() }
        return try falseResult!.callInterface()
    }

    func invoke(
        _ values: repeat each Argument,
        using body: (UnsafeBufferPointer<UnsafeRawPointer>, UnsafeMutableRawPointer) throws -> Void
    ) throws -> Result {
        if let direct { return try direct.invoke(repeat each values, using: body) }
        // The method autoreleases its error; read it before this pool drains.
        return try autoreleasepool {
            let slot = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
            slot.initialize(to: nil)
            defer { slot.deallocate() }
            let failed: Bool
            var value: Result?
            if let nilResult {
                value = try nilResult.invoke(
                    repeat each values,
                    errorSlot: UnsafeMutableRawPointer(slot),
                    using: body
                )
                failed = value == nil
            } else {
                failed = try !falseResult!.invoke(
                    repeat each values,
                    errorSlot: UnsafeMutableRawPointer(slot),
                    using: body
                )
                value = (() as! Result)
            }
            guard failed else { return value! }
            let error = slot.withMemoryRebound(to: NSError?.self, capacity: 1) {
                AutoreleasingUnsafeMutablePointer<NSError?>($0).pointee
            }
            throw error ?? NativeObjCUnreportedFailure(declaration: declaration)
        }
    }

    private static func unqualified(_ encoding: UnsafePointer<CChar>) -> String {
        String(String(cString: encoding).drop { "rnNoORV".contains($0) })
    }
}
