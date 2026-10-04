import ABIBridgeRuntime
import Foundation

func withRuntimeErrors<Value>(_ body: () throws -> Value) throws -> Value {
    do { return try body() } catch let error as RuntimeResolutionError {
        throw ABIResolutionError(error)
    }
}

extension NativeLanguage {
    var runtimeValue: RuntimeLanguage {
        switch self {
        case .swift: .swift;
        case .objectiveC: .objectiveC;
        case .c: .c;
        case .cxx: .cxx
        }
    }
    init(_ value: RuntimeLanguage) {
        self =
            switch value {
            case .swift: .swift;
            case .objectiveC: .objectiveC;
            case .c: .c;
            case .cxx: .cxx
            }
    }
}
extension NativeSymbolKind {
    var runtimeValue: RuntimeSymbolKind {
        switch self {
        case .function: .function;
        case .data: .data;
        case .vtable: .vtable
        }
    }
    init(_ value: RuntimeSymbolKind) {
        self =
            switch value {
            case .function: .function;
            case .data: .data;
            case .vtable: .vtable
            }
    }
}
extension NativeDeclaration {
    var runtimeValue: RuntimeDeclaration {
        .init(
            name: name,
            language: language.runtimeValue,
            kind: kind.runtimeValue,
            nameForm: RuntimeSymbolNameForm(rawValue: nameForm.rawValue)!
        )
    }
    init(_ value: RuntimeDeclaration) {
        self.init(
            name: value.name,
            language: NativeLanguage(value.language),
            kind: NativeSymbolKind(value.kind),
            nameForm: NativeSymbolNameForm(rawValue: value.nameForm.rawValue)!
        )
    }
}
extension NativeImageIdentity {
    var runtimeValue: RuntimeImageIdentity {
        .init(
            headerAddress: headerAddress,
            slide: slide,
            loadGeneration: loadGeneration,
            uuid: uuid
        )
    }
    init(_ value: RuntimeImageIdentity) {
        self.init(
            headerAddress: value.headerAddress,
            slide: value.slide,
            loadGeneration: value.loadGeneration,
            uuid: value.uuid
        )
    }
}
extension ImageSelector {
    var runtimeValue: RuntimeImageSelector {
        switch self {
        case .automatic: .automatic
        case .path(let value): .path(value)
        case .framework(let name): .framework(named: name)
        case .installName(let value): .installName(value)
        }
    }
}
extension ImageLoadingPolicy {
    var runtimeValue: RuntimeImageLoadingPolicy { self == .ifNeeded ? .ifNeeded : .loadedOnly }
}
extension NativeSymbolRequest {
    var runtimeValue: RuntimeSymbolRequest {
        .init(
            declaration.runtimeValue,
            alternatives: alternatives.map(\.runtimeValue),
            fallbacks: fallbacks.map(\.runtimeValue),
            in: imageScopes.map(\.runtimeValue),
            loading: loading.runtimeValue
        )
    }
}
extension NativePointerAuthentication {
    init(_ value: RuntimePointerAuthentication) {
        self =
            switch value {
            case .unsigned: .unsigned
            case .signed(let key, let discriminator, let diversity):
                .signed(
                    key: Key(rawValue: key.rawValue)!,
                    discriminator: discriminator,
                    addressDiversity: diversity
                )
            }
    }
}
extension ABIResolutionError {
    init(_ error: RuntimeResolutionError) {
        self =
            switch error {
            case .imageUnavailable: .imageUnavailable
            case .imageNotLoaded: .imageNotLoaded
            case .imageLoadFailed(let target, let message):
                .imageLoadFailed(target: target, message: message)
            case .ambiguousImage(let candidates): .ambiguousImage(candidates: candidates)
            case .invalidImageTarget(let target): .invalidImageTarget(target)
            case .declarationNotFound(let declaration):
                .declarationNotFound(NativeDeclaration(declaration))
            case .ivarNotFound(let name, let className):
                .ivarNotFound(name: name, className: className)
            case .ambiguousDeclaration(let declaration, let candidates):
                .ambiguousDeclaration(NativeDeclaration(declaration), candidates: candidates)
            case .signatureMismatch(let mismatch): .signatureMismatch(.init(mismatch))
            case .unsupportedDeclaration(let message): .unsupportedDeclaration(message)
            case .metadataUnavailable(let message): .metadataUnavailable(message)
            case .imageChanged: .imageChanged
            case .invalidAddress: .invalidAddress
            }
    }
}
extension ABIResolutionError.SignatureMismatch {
    init(_ value: RuntimeResolutionError.SignatureMismatch) {
        let position: Position =
            switch value.position {
            case .signature: .signature
            case .argument(let index): .argument(index)
            case .result: .result
            case .argumentCount: .argumentCount
            }
        self.init(
            declaration: value.declaration.map(NativeDeclaration.init),
            position: position,
            expected: value.expected,
            found: value.found
        )
    }
}
