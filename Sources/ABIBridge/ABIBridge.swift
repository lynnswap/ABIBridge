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

/// How a symbol name is represented, independently of its source language.
public enum NativeSymbolNameForm: Int32, Sendable, Hashable {
    /// A source-level declaration, interpreted using its language.
    case source = 0
    /// An exact linker spelling, such as a mangled C++ or Swift name.
    /// Mach-O's leading underscore is added exactly once without inspecting the name.
    case linker = 1
    /// An exact symbol-table spelling, including Mach-O's leading underscore.
    case machO = 2
}

/// A name, representation, language, and storage requirement for symbol lookup.
///
/// Prefer complete source-level declarations for C++ and Swift. Source lookup
/// normalizes punctuation spacing while preserving identifier boundaries.
/// Exact-name initializers bypass that normalization. A name alone does not
/// determine calling convention or ownership. Equality and hashing preserve
/// the name's UTF-8 bytes, even for canonically equivalent Unicode strings.
public struct NativeDeclaration: Sendable, Hashable {
    /// The name or complete declaration to match.
    public let name: String
    /// The language used for source lookup; metadata only for exact spellings.
    public let language: NativeLanguage
    /// The required storage kind.
    public let kind: NativeSymbolKind
    /// Whether the name is a source declaration or an exact native spelling.
    public let nameForm: NativeSymbolNameForm

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
        self.init(name: name, language: language, kind: kind, nameForm: .source)
    }

    /// Describes an exact linker spelling without demangling or normalization.
    ///
    /// Use the source-level initializer for ordinary lookup. This escape hatch
    /// distinguishes ABI variants with identical demangled declarations.
    /// - Parameters:
    ///   - linkerName: The exact linker name; any existing underscore is preserved.
    ///   - language: The declaration's source language, retained as metadata.
    ///   - kind: The required storage kind.
    public init(linkerName: String, language: NativeLanguage, kind: NativeSymbolKind = .function) {
        self.init(name: linkerName, language: language, kind: kind, nameForm: .linker)
    }

    /// Describes the literal spelling stored in a Mach-O symbol table.
    ///
    /// No prefix is added or removed, and no name normalization is performed.
    /// - Parameters:
    ///   - machOName: The complete symbol-table spelling.
    ///   - language: The declaration's source language, retained as metadata.
    ///   - kind: The required storage kind.
    public init(machOName: String, language: NativeLanguage, kind: NativeSymbolKind = .function) {
        self.init(name: machOName, language: language, kind: kind, nameForm: .machO)
    }

    init(name: String, language: NativeLanguage, kind: NativeSymbolKind, nameForm: NativeSymbolNameForm) {
        self.name = name
        self.language = language
        self.kind = kind
        self.nameForm = nameForm
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.language == rhs.language, lhs.kind == rhs.kind, lhs.nameForm == rhs.nameForm else { return false }
        // Canonical string equality can merge distinct native symbol spellings.
        return lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(kind)
        hasher.combine(nameForm)
        hasher.combine(Array(name.utf8))
    }

    /// Describes a C++ vtable using its qualified source-level type name.
    ///
    /// The resolver supplies the descriptive symbol spelling. The resulting
    /// address is the vtable symbol, not an inferred address point or first slot.
    /// - Parameter typeName: A qualified C++ type name, such as `Example::Renderer`.
    public init(vtableFor typeName: String) {
        self.init(name: "vtable for \(typeName)", language: .cxx, kind: .vtable)
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
    /// dyld could not acquire an explicit target. The original loader diagnostic is preserved.
    case imageLoadFailed(target: String, message: String)
    /// More than one image matches a framework name; select a concrete path.
    case ambiguousImage(candidates: [String])
    /// A target cannot be represented as a framework name or executable file URL.
    case invalidImageTarget(String)
    /// None of the available symbol sources contains the declaration.
    case declarationNotFound(NativeDeclaration)
    /// The receiver's Objective-C class hierarchy has no ivar with this name.
    case ivarNotFound(name: String, className: String)
    /// Multiple distinct definitions match; candidates identify the competing symbols or images.
    case ambiguousDeclaration(NativeDeclaration, candidates: [String])
    /// Available signature information disagrees with the requested signature.
    case signatureMismatch(expected: String, found: [String])
    /// The operation cannot interpret this kind of declaration.
    case unsupportedDeclaration(String)
    /// Requested native metadata is unavailable.
    case metadataUnavailable(String)
    /// An image was unloaded or replaced before a loader reference could be acquired.
    case imageChanged
    /// Matching symbol addresses do not satisfy the requested storage kind.
    case invalidAddress
}
