import Foundation

/// The declaration language used by a native image.
public enum NativeLanguage: Sendable, Hashable {
    case swift
    case objectiveC
    case c
    case cxx
}

/// The storage kind expected at a resolved address.
public enum NativeSymbolKind: Sendable, Hashable {
    case function
    case data
    case vtable
}

/// The identity of a loaded image at one point in the process lifetime.
public struct NativeImageIdentity: Sendable, Hashable {
    public let headerAddress: UInt64
    public let slide: Int64
    public let loadGeneration: UInt64

    public init(headerAddress: UInt64, slide: Int64, loadGeneration: UInt64) {
        self.headerAddress = headerAddress
        self.slide = slide
        self.loadGeneration = loadGeneration
    }
}

/// A source-level declaration to resolve in a native image.
public struct NativeDeclaration: Sendable, Hashable {
    public let name: String
    public let language: NativeLanguage
    public let kind: NativeSymbolKind

    public init(
        name: String,
        language: NativeLanguage,
        kind: NativeSymbolKind = .function
    ) {
        self.name = name
        self.language = language
        self.kind = kind
    }
}

/// Ownership of a value returned by a native operation.
public enum NativeOwnership: Sendable, Hashable {
    case borrowed
    case owned
    case unowned
    case custom
}

/// The common ABI call-plan information shared by all language frontends.
public struct NativeCallPlan: Sendable, Hashable {
    public let language: NativeLanguage
    public let resultOwnership: NativeOwnership
    public let hasReceiver: Bool
    public let hasIndirectResult: Bool

    public init(
        language: NativeLanguage,
        resultOwnership: NativeOwnership = .borrowed,
        hasReceiver: Bool = false,
        hasIndirectResult: Bool = false
    ) {
        self.language = language
        self.resultOwnership = resultOwnership
        self.hasReceiver = hasReceiver
        self.hasIndirectResult = hasIndirectResult
    }
}

/// Failures shared by image, declaration, and call-plan resolution.
public enum ABIResolutionError: Error, Sendable, Hashable {
    case imageUnavailable
    case imageNotLoaded
    case declarationNotFound(NativeDeclaration)
    case ambiguousDeclaration(NativeDeclaration, candidates: [String])
    case signatureMismatch(expected: String, found: [String])
    case unsupportedDeclaration(String)
    case metadataUnavailable(String)
    case imageChanged
    case invalidAddress
}
