import Foundation

/// The source language of a native declaration.
public enum NativeLanguage: Sendable, Hashable {
    /// A Swift declaration, including its module qualification.
    case swift
    /// An Objective-C selector, interpreted through the Objective-C runtime.
    case objectiveC
    /// A C linker name, without the leading Mach-O underscore.
    case c
    /// A demangled C++ declaration.
    case cxx
}

/// The storage expected at a native symbol's address.
public enum NativeSymbolKind: Sendable, Hashable {
    /// Code in a section marked as containing instructions.
    case function
    /// Non-instruction storage, excluding thread-local descriptors and templates.
    /// This does not establish a value's layout.
    case data
    /// Constant data holding a C++ virtual table.
    case vtable
}

/// Identifies one load of an image in the current process.
///
/// A generation distinguishes an unloaded image from a later image at the same
/// address. Constructing this value does not acquire a loader reference.
public struct NativeImageIdentity: Sendable, Hashable {
    /// The address of the loaded Mach-O header.
    public let headerAddress: UInt64
    /// The displacement added to the image's unslid virtual addresses.
    public let slide: Int64
    /// The process-local generation assigned when the image was loaded.
    public let loadGeneration: UInt64
    /// The build UUID, when the image contains an LC_UUID command.
    public let uuid: UUID?

    /// Creates an identity from information supplied by a loader.
    ///
    /// - Parameters:
    ///   - headerAddress: The in-process Mach-O header address.
    ///   - slide: The displacement from link-time virtual addresses.
    ///   - loadGeneration: An identifier for this particular load.
    ///   - uuid: The image's optional build UUID.
    public init(headerAddress: UInt64, slide: Int64, loadGeneration: UInt64, uuid: UUID? = nil) {
        self.headerAddress = headerAddress
        self.slide = slide
        self.loadGeneration = loadGeneration
        self.uuid = uuid
    }
}

/// A source-level name and storage requirement for symbol lookup.
///
/// For C++ and Swift, use a complete demangled declaration. Lookup normalizes
/// punctuation spacing while preserving identifier boundaries. A symbol's name
/// alone does not determine its calling convention or ownership.
public struct NativeDeclaration: Sendable, Hashable {
    /// The name or complete declaration to match.
    public let name: String
    /// The language used to interpret the name.
    public let language: NativeLanguage
    /// The required storage kind.
    public let kind: NativeSymbolKind

    /// Describes a symbol to resolve.
    ///
    /// - Parameters:
    ///   - name: A C name, demangled Swift/C++ declaration, or selector.
    ///   - language: The declaration's source language.
    ///   - kind: The storage requirement, defaulting to executable code.
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

/// The ownership contract associated with a native result.
///
/// These labels describe a contract; they do not implement retain, copy, or
/// destruction operations.
public enum NativeOwnership: Sendable, Hashable {
    /// Valid only within a lifetime established by another owner.
    case borrowed
    /// Transfers responsibility for releasing the result to the caller.
    case owned
    /// Does not transfer ownership or extend the result's lifetime.
    case unowned
    /// Requires a caller-supplied ownership implementation.
    case custom
}

/// Describes the basic shape of a native call.
///
/// This model does not resolve a function, verify its ABI, or invoke it.
public struct NativeCallPlan: Sendable, Hashable {
    /// The source language whose ABI is being described.
    public let language: NativeLanguage
    /// The result's ownership contract.
    public let resultOwnership: NativeOwnership
    /// Whether the call requires an instance receiver.
    public let hasReceiver: Bool
    /// Whether the caller supplies storage for an indirect result.
    public let hasIndirectResult: Bool

    /// Records the call shape and result ownership.
    ///
    /// - Parameters:
    ///   - language: The declaration's source language.
    ///   - resultOwnership: Ownership of the returned value.
    ///   - hasReceiver: Whether an instance receiver is required.
    ///   - hasIndirectResult: Whether the result uses caller-provided storage.
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

/// Failures encountered while locating images, declarations, or ABI information.
public enum ABIResolutionError: Error, Sendable, Hashable {
    /// The native image catalog could not be initialized.
    case imageUnavailable
    /// No currently loaded image matches the requested scope.
    case imageNotLoaded
    /// None of the available symbol sources contains the declaration.
    case declarationNotFound(NativeDeclaration)
    /// Multiple distinct definitions match; candidates identify the competing symbols or images.
    case ambiguousDeclaration(NativeDeclaration, candidates: [String])
    /// Available signature information disagrees with the requested signature.
    case signatureMismatch(expected: String, found: [String])
    /// The operation cannot interpret this kind of declaration.
    case unsupportedDeclaration(String)
    /// The required type metadata is unavailable.
    case metadataUnavailable(String)
    /// An image was unloaded or replaced before a loader reference could be acquired.
    case imageChanged
    /// Matching symbol addresses do not satisfy the requested storage kind.
    case invalidAddress
}
