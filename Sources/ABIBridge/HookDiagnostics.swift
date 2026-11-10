import ABIBridgeCore
import ABIBridgeRuntime
import Foundation

/// A hook continuation or callback was used outside the invocation that provided it.
///
/// C, C++, Objective-C, and Swift hooks report these cases from `proceed` and to `onFailure`.
public enum NativeHookInvocationError: Error, Sendable, Equatable {
    /// The callback that provided the continuation has returned.
    case expiredInvocation
    /// A synchronous continuation or MainActor callback was entered from another thread.
    case wrongThread
    /// An asynchronous Swift continuation was used by another task.
    case wrongTask
}

/// A hook registration's logical state combined with a non-atomic observation of its pointer slot.
public enum NativeHookSlotStatus: Sendable, Equatable {
    /// This callback is inactive, regardless of the physical pointer contents.
    case invalidated
    /// The callback is active and the observed pointer selects its dispatcher.
    case active
    /// Another writer changed the pointer while this callback remains registered.
    case displaced
    /// The registered pointer could not be read for this observation.
    case unreadable
}

/// The result of publishing, restoring, or repairing one pointer slot.
///
/// Fields that the operation did not reach remain zero; interpret them together with ``outcome``.
public struct NativePointerSlotMutation: Sendable {
    /// How far a pointer-slot operation progressed.
    public enum Outcome: Sendable, Equatable {
        /// The operation finished and restored the page protections it changed.
        case complete
        /// The slot address is null or misaligned.
        case invalidStorage
        /// The slot's VM region could not be queried.
        case queryFailed
        /// The slot's current pointer could not be read.
        case readFailed
        /// The slot lies in executable storage, which is never written.
        case executableStorage
        /// The slot held a pointer other than the expected one, so nothing was written.
        case displaced
        /// The page could not be made writable.
        case protectFailed
        /// The original page protections could not be restored.
        case restoreFailed

        init(_ status: Int32) {
            switch status {
            case Int32(ABIPointerSlotComplete): self = .complete
            case Int32(ABIPointerSlotInvalidStorage): self = .invalidStorage
            case Int32(ABIPointerSlotQueryFailed): self = .queryFailed
            case Int32(ABIPointerSlotReadFailed): self = .readFailed
            case Int32(ABIPointerSlotExecutableStorage): self = .executableStorage
            case Int32(ABIPointerSlotDisplaced): self = .displaced
            case Int32(ABIPointerSlotProtectFailed): self = .protectFailed
            case Int32(ABIPointerSlotRestoreFailed): self = .restoreFailed
            default: preconditionFailure("Unknown pointer-slot status \(status).")
            }
        }
    }

    /// How far the operation progressed.
    public let outcome: Outcome
    /// Whether the pointer was written, including when a later protection change failed.
    public let didWrite: Bool
    /// The pointer bits observed before the comparison, when the read succeeded.
    public let observed: UInt
    /// The original Mach failure code, or zero.
    public let systemErrorCode: Int32
    /// The failure restoring the region's current page protection, or zero.
    public let restoreProtectionError: Int32
    /// The failure restoring the region's maximum page protection, or zero.
    public let restoreMaximumError: Int32
    /// The current page protection from the original region query.
    public let protectionBefore: Int32
    /// The maximum page protection from the original region query.
    public let maximumBefore: Int32
    /// The VM region flags from the original region query.
    public let regionFlags: UInt32

    init(_ value: ABIPointerSlotResult) {
        outcome = Outcome(value.status)
        didWrite = value.didWrite
        observed = value.observed
        systemErrorCode = value.systemErrorCode
        restoreProtectionError = value.restoreProtectionError
        restoreMaximumError = value.restoreMaximumError
        protectionBefore = value.protectionBefore
        maximumBefore = value.maximumBefore
        regionFlags = value.regionFlags
    }
}

// Prepared once. Formatting an invocation must not touch its native frame or
// dereference arguments/receivers (including their custom descriptions).
func hookDescription(
    declaration: NativeDeclaration?,
    signature: Any.Type,
    unnamed: String
) -> String {
    let name: String
    if let declaration {
        if declaration.nameForm == .source {
            name = declaration.name
        } else {
            let raw = declaration.nameForm == .linker ? "_" + declaration.name : declaration.name
            name =
                DeclarationKey.demangle(raw, language: declaration.language.runtimeValue)
                ?? declaration.name
        }
    } else {
        name = unnamed
    }
    return name + " [" + String(reflecting: signature) + "]"
}
