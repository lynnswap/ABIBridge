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
