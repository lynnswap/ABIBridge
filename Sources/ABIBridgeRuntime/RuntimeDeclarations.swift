import Foundation

package enum RuntimeLanguage: Sendable, Hashable {
    case swift
    case objectiveC
    case c
    case cxx
}

package enum RuntimeSymbolKind: Sendable, Hashable {
    case function
    case data
    case vtable
}

package struct RuntimeImageIdentity: Sendable, Hashable {
    package let headerAddress: UInt64
    package let slide: Int64
    package let loadGeneration: UInt64
    package let uuid: UUID?

    package init(headerAddress: UInt64, slide: Int64, loadGeneration: UInt64, uuid: UUID? = nil) {
        self.headerAddress = headerAddress
        self.slide = slide
        self.loadGeneration = loadGeneration
        self.uuid = uuid
    }
}

package enum RuntimeSymbolNameForm: Int32, Sendable, Hashable {
    case source = 0
    case linker = 1
    case machO = 2
}

package struct RuntimeDeclaration: Sendable, Hashable {
    package let name: String
    package let language: RuntimeLanguage
    package let kind: RuntimeSymbolKind
    package let nameForm: RuntimeSymbolNameForm

    package init(
        name: String,
        language: RuntimeLanguage,
        kind: RuntimeSymbolKind = .function
    ) {
        self.init(name: name, language: language, kind: kind, nameForm: .source)
    }

    package init(linkerName: String, language: RuntimeLanguage, kind: RuntimeSymbolKind = .function)
    {
        self.init(name: linkerName, language: language, kind: kind, nameForm: .linker)
    }

    package init(machOName: String, language: RuntimeLanguage, kind: RuntimeSymbolKind = .function)
    {
        self.init(name: machOName, language: language, kind: kind, nameForm: .machO)
    }

    package init(
        name: String,
        language: RuntimeLanguage,
        kind: RuntimeSymbolKind,
        nameForm: RuntimeSymbolNameForm
    ) {
        self.name = name
        self.language = language
        self.kind = kind
        self.nameForm = nameForm
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.language == rhs.language, lhs.kind == rhs.kind, lhs.nameForm == rhs.nameForm
        else { return false }
        // Canonical string equality can merge distinct native symbol spellings.
        return lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(kind)
        hasher.combine(nameForm)
        hasher.combine(Array(name.utf8))
    }

    package init(vtableFor typeName: String) {
        self.init(name: "vtable for \(typeName)", language: .cxx, kind: .vtable)
    }
}

package enum RuntimeResolutionError: Error, Sendable, Hashable {
    case imageUnavailable
    case imageNotLoaded
    case imageLoadFailed(target: String, message: String)
    case ambiguousImage(candidates: [String])
    case invalidImageTarget(String)
    case declarationNotFound(RuntimeDeclaration)
    case ivarNotFound(name: String, className: String)
    case ambiguousDeclaration(RuntimeDeclaration, candidates: [String])
    case signatureMismatch(SignatureMismatch)

    package struct SignatureMismatch: Sendable, Hashable {
        package enum Position: Sendable, Hashable {
            case signature
            case argument(Int)
            case result
            case argumentCount
            case receiver
        }

        package let declaration: RuntimeDeclaration?
        package let position: Position
        package let expected: String
        package let found: [String]

        package init(
            declaration: RuntimeDeclaration? = nil,
            position: Position = .signature,
            expected: String,
            found: [String]
        ) {
            self.declaration = declaration
            self.position = position
            self.expected = expected
            self.found = found
        }

        package func inContext(_ declaration: RuntimeDeclaration, at position: Position) -> Self {
            .init(declaration: declaration, position: position, expected: expected, found: found)
        }
    }
    case unsupportedDeclaration(String)
    case metadataUnavailable(String)
    case imageChanged
    case invalidAddress
}

// The C interface reports these descriptions as failure messages, and
// ABIResolutionError describes itself with them, so both say the same.
extension RuntimeResolutionError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .imageUnavailable:
            "The image catalog or a registered image is not currently available for lookup."
        case .imageNotLoaded:
            "No loaded image matches the requested scope."
        case .imageLoadFailed(let target, let message):
            "Cannot load \(target): \(message)"
        case .ambiguousImage(let candidates):
            "More than one image matches the framework name: "
                + candidates.joined(separator: ", ") + ". Select one by its path."
        case .invalidImageTarget(let target):
            "The image target \(target) is not a valid framework name, install name, or file URL."
        case .declarationNotFound(let declaration):
            "Cannot find \(declaration.name)."
        case .ivarNotFound(let name, let className):
            "\(className) and its superclasses have no ivar named \(name)."
        case .ambiguousDeclaration(let declaration, let candidates):
            "More than one definition matches \(declaration.name): "
                + candidates.joined(separator: ", ") + "."
        case .signatureMismatch(let mismatch):
            mismatch.description
        case .unsupportedDeclaration(let reason), .metadataUnavailable(let reason):
            reason
        case .imageChanged:
            "The image was unloaded or replaced before a loader reference could be acquired."
        case .invalidAddress:
            "The address of the matching symbol does not hold the requested kind of storage."
        }
    }
}

extension RuntimeResolutionError.SignatureMismatch: CustomStringConvertible {
    package var description: String {
        let subject =
            declaration.map { "\($0.name) does not match the requested signature" }
            ?? "The requested signature does not match"
        let text = subject + position.phrase + ": " + difference
        return text.hasSuffix(".") ? text : text + "."
    }

    /// The mismatch as one entry of a list that compares several
    /// declarations with the request.
    package var summary: String {
        (declaration?.name ?? "The requested signature") + position.phrase + ": " + difference
    }

    private var difference: String {
        found.isEmpty
            ? "expected \(expected)"
            : "expected \(expected), found \(found.joined(separator: "; "))"
    }
}

extension RuntimeResolutionError.SignatureMismatch.Position {
    /// Where the mismatch is, as a phrase that follows the signature.
    fileprivate var phrase: String {
        switch self {
        case .signature: ""
        case .argument(let index): " at argument \(index)"
        case .result: " at the result"
        case .argumentCount: " in the argument count"
        case .receiver: " at self"
        }
    }
}
