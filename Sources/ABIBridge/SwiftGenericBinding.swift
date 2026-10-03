import ABIBridgeCore
import Darwin
import Foundation
import ObjectiveC
import Synchronization

/// Immutable metadata/witness words. Native calls only borrow this buffer.
final class SwiftGenericArgumentBuffer: @unchecked Sendable {
    private let storage: NativeValueStorage
    let count: Int
    var address: UInt { UInt(bitPattern: storage.address) }
    var addresses: [UnsafeMutableRawPointer?] {
        (0..<count).map { storage.address.advanced(by: $0 * MemoryLayout<UInt>.stride) }
    }
    init(_ words: [UInt]) {
        count = words.count
        storage = NativeValueStorage(size: max(1, words.count) * MemoryLayout<UInt>.stride,
                                     alignment: MemoryLayout<UInt>.alignment)
        for (index, word) in words.enumerated() {
            storage.address.storeBytes(of: word, toByteOffset: index * MemoryLayout<UInt>.stride, as: UInt.self)
        }
    }
}

private final class SwiftBoundTypeStorage: Sendable {
    let metadata = Mutex<[ObjectIdentifier: SwiftGenericTypeMetadata]>([:])
}

struct SwiftGenericBinding: Sendable {
    struct BoundArgument: Sendable {
        let types: [Any.Type]
        let isPack: Bool
    }
    struct Conformance: Sendable {
        let subject: SwiftFormalType
        let name: String
        let descriptor: SwiftProtocolDescriptor?
        var objectiveC: SwiftObjectiveCProtocol? = nil
    }

    let declaration: SwiftGenericDeclaration
    let arguments: [String: BoundArgument]
    let conformances: [Conformance]
    let typeOwners: [NativeSwiftType]
    private let boundTypes = SwiftBoundTypeStorage()
    private let knownTypes: [[UInt8]: Any.Type]
    private let resolver: SymbolResolver
    private var packElementIndex: Int?

    func selectingPackElement(at index: Int) -> Self {
        var binding = self
        binding.packElementIndex = index
        return binding
    }
    enum MetadataSource: Sendable {
        case shape(Set<String>)
        case parameter(String)
        case conformance(Int)
    }
    private var metadataWords: [(source: MetadataSource, value: UInt)] = []
    var metadataArguments: [UInt] { metadataWords.map(\.value) }
    private(set) var images: [NativeImage] = []
    private(set) var packs: [SwiftGenericArgumentBuffer] = []

    init(declaration: SwiftGenericDeclaration, arguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver,
         enclosing context: SwiftGenericTypeContext? = nil, image: NativeImage? = nil) throws {
        guard arguments.count == declaration.parameters.count else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "\(declaration.parameters.count) generic arguments", found: ["\(arguments.count) generic arguments"]))
        }
        self.declaration = declaration
        self.resolver = resolver
        if let image { images.append(image) }
        var bound: [String: BoundArgument] = [:]
        var owners: [NativeSwiftType] = []
        var known: [[UInt8]: Any.Type] = [:]
        func remember(_ type: Any.Type) throws {
            known[try Self.key(swiftNativeTypeName(type))] = type
            if let tuple = SwiftTupleMetadata(type) {
                for element in tuple.elements { try remember(element.type) }
            }
            if let optional = type as? any NativeOptionalValue.Type { try remember(optional.wrappedType) }
            if let metatype = SwiftMetatypeMetadata(type) { try remember(metatype.instance) }
            if let argument = type as? any SwiftConventionArgument.Type { try remember(argument.wrappedType) }
            if let closure = type as? any SwiftClosureValue.Type {
                let function = try SwiftFunctionSignature(closure.swiftFunctionType)
                for type in function.parameters { try remember(type) }
                try remember(function.result)
            }
        }
        for (parameter, argument) in zip(declaration.parameters, arguments) {
            let types: [Any.Type]
            switch argument.storage {
            case .type(let type, let owner):
                guard !parameter.isPack else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "A type pack for " + parameter.name, found: [String(reflecting: type)]))
                }
                types = [type]
                if let owner { owners.append(owner) }
            case .pack(let elements):
                guard parameter.isPack else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "A scalar type for " + parameter.name, found: ["A type pack"]))
                }
                types = try elements.map { element in
                    guard case .type(let type, let owner) = element.storage else {
                        throw ABIResolutionError.signatureMismatch(.init(expected: "Scalar elements in a Swift type pack", found: ["A nested pack"]))
                    }
                    if let owner { owners.append(owner) }
                    return type
                }
            }
            for type in types { try remember(type) }
            bound[parameter.name] = BoundArgument(types: types, isPack: parameter.isPack)
        }
        for type in signature.parameters { try remember(type) }
        try remember(signature.result)
        try remember(signature.failure)
        self.arguments = bound
        typeOwners = owners
        knownTypes = known
        let invertibleProtocols = [
            (name: "Swift.Copyable", mask: UInt16(1), accepts: SwiftCopyability.accepts),
            (name: "Swift.Escapable", mask: UInt16(2), accepts: SwiftEscapability.accepts),
        ]
        var conformances = context?.conformances ?? []
        for requirement in declaration.requirements {
            guard case .conformance(let subject, let name) = requirement else { continue }
            if conformances.contains(where: { $0.subject == subject && $0.name == name }) { continue }
            // Marker protocols have no runtime witness table. Invertible
            // requirements are checked against native metadata below.
            if ["AnyObject", "Swift.AnyObject", "Swift.Sendable", "Swift.Copyable", "Swift.Escapable"].contains(name) {
                conformances.append(Conformance(subject: subject, name: name, descriptor: nil))
                continue
            }
            if let protocolValue = NSProtocolFromString(name.hasPrefix("__C.") ? String(name.dropFirst(4)) : name) {
                conformances.append(Conformance(subject: subject, name: name, descriptor: nil,
                    objectiveC: try SwiftObjectiveCProtocol(protocolValue)))
                continue
            }
            conformances.append(Conformance(subject: subject, name: name, descriptor: try SwiftProtocolDescriptor(resolver.resolve(
                .init(name: "protocol descriptor for " + name, language: .swift, kind: .data),
                in: .automatic, loading: .loadedOnly))))
        }
        self.conformances = conformances
        var witnessesByConformance: [Int: [UInt]] = [:]
        for (index, conformance) in conformances.enumerated() {
            let types = try types(conformance.subject)
            if let descriptor = conformance.descriptor {
                if let image = descriptor.image { images.append(image) }
                var witnesses: [UInt] = []
                for type in types {
                    let pointer = unsafeBitCast(type, to: UnsafeRawPointer.self)
                    let witness = unsafe descriptor.withUnsafeAddress { ABISwiftConformance(pointer, $0) }
                    guard let witness else {
                        throw ABIResolutionError.signatureMismatch(.init(
                            expected: conformance.subject.spelling + ": " + conformance.name,
                            found: [String(reflecting: type)]))
                    }
                    witnesses.append(UInt(bitPattern: witness))
                    if let address = ABISwiftConformanceDescriptor(witness),
                       let image = try swiftImplementationImage(containing: address) { images.append(image) }
                }
                witnessesByConformance[index] = witnesses
            } else if let objectiveC = conformance.objectiveC {
                if let image = objectiveC.image { images.append(image) }
                guard types.allSatisfy(objectiveC.accepts) else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: conformance.name,
                        found: types.map { String(reflecting: $0) }))
                }
            } else if ["AnyObject", "Swift.AnyObject"].contains(conformance.name) {
                guard types.allSatisfy({ SwiftObjectType($0) != nil }) else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "A class type", found: types.map { String(reflecting: $0) }))
                }
            } else if let requirement = invertibleProtocols.first(where: { $0.name == conformance.name }) {
                guard types.allSatisfy(requirement.accepts) else {
                    throw ABIResolutionError.signatureMismatch(.init(
                        expected: conformance.subject.spelling + ": " + requirement.name,
                        found: types.map { String(reflecting: $0) }))
                }
            }
        }
        for requirement in declaration.requirements {
            switch requirement {
            case .sameType(let left, let right):
                let lhs = try types(left), rhs = try types(right)
                guard lhs.count == rhs.count, zip(lhs, rhs).allSatisfy({ $0 == $1 }) else {
                    throw ABIResolutionError.signatureMismatch(.init(
                        expected: try spelling(left), found: [try spelling(right)]))
                }
            case .sameShape(let left, let right):
                guard try types(left).count == types(right).count else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "Equal type pack lengths", found: [left.spelling, right.spelling]))
                }
            case .superclass(let subject, let constraint):
                guard let expected = try types(constraint).first as? AnyClass else {
                    throw ABIResolutionError.metadataUnavailable("The superclass constraint does not identify a class: " + constraint.spelling)
                }
                for type in try types(subject) {
                    guard SwiftObjectType(type)?.isSubclass(of: expected) == true else {
                        throw ABIResolutionError.signatureMismatch(.init(expected: constraint.spelling, found: [String(reflecting: type)]))
                    }
                }
            case .conformance, .invertedProtocols: break
            }
        }
        for parameter in declaration.parameters {
            let subject = SwiftFormalType.named(parameter.name, [])
            let equivalents = try equivalentTypes(of: subject)
            let suppressed = declaration.requirements.reduce(UInt16(0)) {
                if case .invertedProtocols(let type, let mask) = $1, equivalents.contains(type) {
                    return $0 | mask
                }
                return $0
            }
            for requirement in invertibleProtocols where suppressed & requirement.mask == 0 {
                for type in bound[parameter.name]!.types {
                    guard requirement.accepts(type) else {
                        throw ABIResolutionError.signatureMismatch(.init(
                            expected: parameter.name + ": " + requirement.name, found: [String(reflecting: type)]))
                    }
                }
            }
        }
        var shapeClasses: [Set<String>] = []
        for parameter in declaration.parameters where parameter.isPack {
            var shape: Set<String> = [parameter.name]
            for requirement in declaration.requirements {
                guard case .sameShape(let left, let right) = requirement else { continue }
                if left.spelling == parameter.name { shape.insert(right.spelling) }
                if right.spelling == parameter.name { shape.insert(left.spelling) }
            }
            let overlapping = shapeClasses.indices.filter { !shapeClasses[$0].isDisjoint(with: shape) }
            if let first = overlapping.first {
                shapeClasses[first].formUnion(shape)
                for index in overlapping.dropFirst().reversed() {
                    shapeClasses[first].formUnion(shapeClasses.remove(at: index))
                }
            } else { shapeClasses.append(shape) }
        }
        for shape in shapeClasses {
            let parameter = declaration.parameters.first { shape.contains($0.name) }!
            metadataWords.append((.shape(shape), UInt(bound[parameter.name]!.types.count)))
        }
        for (index, parameter) in declaration.parameters.enumerated() {
            if let context, context.parameters.contains(where: { $0.name == parameter.name }),
               !context.keyParameters.contains(parameter.name) { continue }
            let equivalents = try equivalentTypes(of: .named(parameter.name, []))
            if equivalents.contains(where: { !isArchetype($0) }) { continue }
            if declaration.parameters[..<index].contains(where: { equivalents.contains(.named($0.name, [])) }) { continue }
            let argument = bound[parameter.name]!
            let metadata = argument.types.map { unsafeBitCast($0, to: UInt.self) }
            if argument.isPack {
                metadataWords.append((.parameter(parameter.name), appendPack(metadata)))
            } else {
                metadataWords.append((.parameter(parameter.name), metadata[0]))
            }
        }
        for index in try canonicalWitnessIndices() {
            let witnesses = witnessesByConformance[index]!
            if isPack(conformances[index].subject) { metadataWords.append((.conformance(index), appendPack(witnesses))) }
            else { metadataWords.append(contentsOf: witnesses.map { (.conformance(index), $0) }) }
        }
        let fulfilled = try argumentFulfillments()
        func isFulfilled(_ source: MetadataSource) throws -> Bool {
            switch source {
            case .parameter(let name):
                return try equivalentTypes(of: .named(name, [])).contains { fulfilled.types.contains($0) }
            case .shape(let names): return !names.isDisjoint(with: fulfilled.shapes)
            case .conformance(let index):
                let conformance = conformances[index]
                return try equivalentTypes(of: conformance.subject).contains { subject in
                    fulfilled.conformances.contains { $0.0 == subject && $0.1.contains(conformance.name) }
                }
            }
        }
        metadataWords = try metadataWords.filter { try !isFulfilled($0.source) }
    }

    func metadataArguments(fulfilledBy context: SwiftGenericTypeContext) throws -> [UInt] {
        try unfulfilledMetadata(in: context).map(\.value)
    }

    private func unfulfilledMetadata(in context: SwiftGenericTypeContext?) throws -> [(source: MetadataSource, value: UInt)] {
        guard let context else { return metadataWords }
        let parameters = Set(context.parameters.map(\.name))
        return try metadataWords.filter { source, _ in
            switch source {
            case .shape(let names): return !names.isSubset(of: parameters)
            case .parameter(let name): return !parameters.contains(name)
            case .conformance(let index):
                let conformance = conformances[index]
                return try !context.conformances.contains { source in
                    guard try equivalentTypes(of: conformance.subject).contains(where: { try sameFormalType($0, source.subject) }) else {
                        return false
                    }
                    return try source.descriptor?.qualifiedNames().contains(conformance.name) ?? (source.name == conformance.name)
                }
            }
        }
    }

    func validateMetadataArguments(fulfilledBy context: SwiftGenericTypeContext?) throws {
        guard declaration.abiRequirements == nil else { return }
        // A retroactive superclass conformance may or may not have been
        // visible to the provider. Runtime availability cannot recover that
        // import boundary, so it cannot decide whether a witness was omitted.
        for requirement in declaration.requirements {
            guard case .superclass(let subject, let superclass) = requirement else { continue }
            for (source, _) in try unfulfilledMetadata(in: context) {
                guard case .conformance(let index) = source else { continue }
                let conformance = conformances[index]
                guard let descriptor = conformance.descriptor,
                      declaration.implicitRequirements.contains(.conformance(conformance.subject, conformance.name)),
                      try equivalentTypes(of: subject).contains(where: { try sameFormalType($0, conformance.subject) }) else { continue }
                for type in try types(superclass) {
                    if unsafe descriptor.withUnsafeAddress({ ABISwiftConformance(unsafeBitCast(type, to: UnsafeRawPointer.self), $0) }) != nil {
                        throw ABIResolutionError.unsupportedDeclaration(
                            "The superclass conformance " + superclass.spelling + ": " + conformance.name
                            + " may have been omitted from this member's generic ABI. Supply declaredAs: with the provider's complete canonical generic signature, including its <...> clause.")
                    }
                }
            }
        }
    }

    /// Swift's canonical generic signature orders dependent subjects, removes
    /// refined protocols, and then orders protocol declarations by context/name.
    /// See Swift 6.3 GenericSignature.cpp, Requirement.cpp, and TypeDecl::compare.
    private func canonicalWitnessIndices() throws -> [Int] {
        if let requirements = declaration.abiRequirements {
            return try requirements.compactMap { requirement in
                guard case .conformance(let subject, let name) = requirement else { return nil }
                return try conformances.indices.first { index in
                    let conformance = conformances[index]
                    return try conformance.descriptor != nil && conformance.name == name
                        && sameFormalType(conformance.subject, subject)
                }
            }
        }
        func protocolLess(_ left: String, _ right: String) -> Bool {
            let lhs = left.split(separator: "."), rhs = right.split(separator: ".")
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        func subjectLess(_ left: SwiftFormalType, _ right: SwiftFormalType) -> Bool {
            switch (left, right) {
            case (.named(let lhs, []), .named(let rhs, [])):
                return declaration.parameters.firstIndex { $0.name == lhs }! < declaration.parameters.firstIndex { $0.name == rhs }!
            case (.named, .associated): return true
            case (.associated, .named): return false
            case (.associated(let lhs, let leftName, let leftProtocol), .associated(let rhs, let rightName, let rightProtocol)):
                if lhs != rhs { return subjectLess(lhs, rhs) }
                if leftName != rightName { return leftName.utf8.lexicographicallyPrecedes(rightName.utf8) }
                return protocolLess(leftProtocol ?? "", rightProtocol ?? "")
            default: return false
            }
        }
        var sources: [(index: Int, subject: SwiftFormalType, name: String, inherited: Set<String>, path: [String])] = []
        for (index, conformance) in conformances.enumerated() {
            guard let descriptor = conformance.descriptor else { continue }
            let subject = try canonicalType(of: conformance.subject)
            guard isArchetype(subject) else { continue }
            let name = try descriptor.name()
            let representative = try equivalentTypes(of: subject).min(by: subjectLess) ?? subject
            sources.append((index, representative, name, try descriptor.qualifiedNames(), try descriptor.orderingPath()))
        }
        var required = try sources.filter { source in
            try !sources.contains { other in
                guard source.index != other.index,
                      try sameFormalType(source.subject, other.subject),
                      other.inherited.contains(source.name) else { return false }
                return source.name != other.name || other.index < source.index
            }
        }
        required = try required.sorted { left, right in
            if try !sameFormalType(left.subject, right.subject) { return subjectLess(left.subject, right.subject) }
            if left.path.count != right.path.count { return left.path.count < right.path.count }
            return left.path.lexicographicallyPrecedes(right.path) { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        }
        // A same-type alias can receive a conformance through another
        // parameter's associated-type requirements. Derive it only from
        // witnesses that remain, so cycles cannot remove every source.
        for position in required.indices.reversed() {
            let candidate = required[position]
            let others = Set(required.map(\.index)).subtracting([candidate.index])
            let aliases = try equivalentTypes(of: conformances[candidate.index].subject)
            if try aliases.contains(where: { subject in
                try associatedConformances(for: subject, from: others).contains(where: {
                    try $0.descriptor!.qualifiedNames().contains(candidate.name)
                })
            }) { required.remove(at: position) }
        }
        return required.map(\.index)
    }

    private static func key(_ name: String) throws -> [UInt8] {
        DeclarationKey.make(try SwiftFormalType(name).spelling)
    }

    private mutating func appendPack(_ words: [UInt]) -> UInt {
        let buffer = SwiftGenericArgumentBuffer(words)
        packs.append(buffer)
        // An untagged pack is borrowed storage; the plan owns it for every call.
        return buffer.address
    }

    func isPack(_ type: SwiftFormalType) -> Bool {
        switch type {
        case .pack, .packValue: true
        case .named(let name, _): arguments[String(name.prefix { $0 != "." })]?.isPack == true
        case .associated(let base, _, _): isPack(base)
        default: false
        }
    }

    private func sameFormalType(_ left: SwiftFormalType, _ right: SwiftFormalType) throws -> Bool {
        if left == right { return true }
        guard case .associated(let leftBase, let leftMember, let leftProtocol) = left,
              case .associated(let rightBase, let rightMember, let rightProtocol) = right,
              leftMember == rightMember, try sameFormalType(leftBase, rightBase) else { return false }
        if leftProtocol == rightProtocol { return true }
        guard let qualifier = leftProtocol ?? rightProtocol,
              leftProtocol == nil || rightProtocol == nil else { return false }
        var origins: Set<String> = []
        for conformance in try conformances(for: leftBase) {
            for descriptor in try conformance.descriptor!.protocolsDeclaring(leftMember) {
                origins.insert(try descriptor.name())
            }
        }
        return origins == [qualifier]
    }

    func equivalentTypes(of type: SwiftFormalType) throws -> [SwiftFormalType] {
        var types = [type], index = 0
        while index < types.count {
            let current = types[index]
            for requirement in declaration.requirements {
                guard case .sameType(let left, let right) = requirement else { continue }
                let other = try sameFormalType(left, current) ? right : sameFormalType(right, current) ? left : nil
                if let other, !types.contains(other) { types.append(other) }
            }
            index += 1
        }
        return types
    }

    func isArchetype(_ type: SwiftFormalType) -> Bool {
        if case .associated(let base, _, _) = type { return isArchetype(base) }
        guard case .named(let name, let arguments) = type, arguments.isEmpty else { return false }
        return self.arguments[String(name.prefix { $0 != "." })] != nil
    }

    func canonicalType(of type: SwiftFormalType) throws -> SwiftFormalType {
        let type = try equivalentTypes(of: type).first { !isArchetype($0) } ?? type
        guard case .associated(let base, let member, let protocolName) = type else { return type }
        let canonicalBase = try canonicalType(of: base)
        if isArchetype(canonicalBase) { return .associated(canonicalBase, member, protocolName: protocolName) }
        let metadata = try types(canonicalBase)[0]
        let context = try SwiftGenericTypeContext(metadata: metadata)
        let parameters: [SwiftFormalType]
        switch canonicalBase {
        case .reference(_, let arguments), .named(_, let arguments): parameters = arguments
        default: parameters = canonicalBase.nominalDeclaration?.arguments ?? []
        }
        guard context.parameters.count == parameters.count else {
            throw ABIResolutionError.metadataUnavailable("Cannot recover the formal arguments of " + canonicalBase.spelling + ".")
        }
        let substitutions = Dictionary(uniqueKeysWithValues: zip(context.parameters.map(\.name), parameters))
        var matches: [SwiftFormalType] = []
        for candidate in try conformances(for: canonicalBase, qualifiedBy: protocolName) {
            let handle = unsafe candidate.descriptor!.withUnsafeAddress { address in
                member.withCString { ABICopySwiftAssociatedTypeSyntax(unsafeBitCast(metadata, to: UnsafeRawPointer.self), address, $0) }
            }
            if let handle {
                let witness = try SwiftFormalType(SwiftSyntax(adopting: handle).root).substituting(substitutions)
                if !matches.contains(witness) { matches.append(witness) }
            }
        }
        guard matches.count == 1 else {
            throw ABIResolutionError.metadataUnavailable("Cannot recover the formal associated type " + type.spelling + ".")
        }
        return try canonicalType(of: matches[0])
    }

    func isClassBound(_ type: SwiftFormalType) throws -> Bool {
        for type in try equivalentTypes(of: type) {
            if declaration.requirements.contains(where: {
                if case .superclass(let subject, _) = $0 { return subject == type }
                return false
            }) { return true }
            if case .associated(let base, let member, let protocolName) = type {
                for conformance in try conformances(for: base, qualifiedBy: protocolName) {
                    for requirement in try conformance.descriptor!.associatedRequirements(of: member) {
                        if case .superclass = requirement.value { return true }
                        if case .conformance(_, let name) = requirement.value,
                           name == "Swift.AnyObject" || requirement.objectiveC != nil { return true }
                    }
                }
            }
            let candidates = try conformances(for: type)
                + conformances.filter { $0.subject == type && $0.descriptor == nil }
            for conformance in candidates {
                if ["AnyObject", "Swift.AnyObject"].contains(conformance.name) || conformance.objectiveC != nil { return true }
                if let descriptor = conformance.descriptor,
                   unsafe descriptor.withUnsafeAddress({ $0.loadUnaligned(as: UInt32.self) & 0x10000 == 0 }) { return true }
            }
        }
        return false
    }

    private func associatedConformances(for subject: SwiftFormalType, from sources: Set<Int>? = nil) throws -> [Conformance] {
        var result: [Conformance] = []
        if case .associated(let parent, let member, let qualifier) = subject {
            for conformance in try conformances(for: parent, qualifiedBy: qualifier, from: sources) {
                for descriptor in try conformance.descriptor!.associatedConformances(of: member) {
                    result.append(try Conformance(subject: subject, name: descriptor.name(), descriptor: descriptor))
                }
            }
        }
        return result
    }

    private func conformances(for subject: SwiftFormalType, qualifiedBy protocolName: String? = nil,
                              from sources: Set<Int>? = nil) throws -> [Conformance] {
        var result = try conformances.enumerated().filter { index, conformance in
            try (sources?.contains(index) ?? true) && conformance.descriptor != nil && sameFormalType(conformance.subject, subject)
        }.map(\.element) + associatedConformances(for: subject, from: sources)
        if let protocolName {
            result = try result.filter { try $0.descriptor!.qualifiedNames().contains(protocolName) }
            if result.isEmpty && !isArchetype(subject) {
                let descriptor = SwiftProtocolDescriptor(try resolver.resolve(
                    .init(name: "protocol descriptor for " + protocolName, language: .swift, kind: .data),
                    in: .automatic, loading: .loadedOnly))
                result = [.init(subject: subject, name: protocolName, descriptor: descriptor)]
            }
        }
        return result
    }

    func types(_ type: SwiftFormalType, packIndex: Int? = nil) throws -> [Any.Type] {
        let packIndex = packIndex ?? packElementIndex
        if case .objectiveCClass(let name) = type {
            guard let type = NSClassFromString(String(name.dropFirst(4))) else {
                throw ABIResolutionError.metadataUnavailable("The Objective-C class is unavailable: " + name)
            }
            return [type]
        }
        if case .pack(let pattern, let shape) = type {
            return try (0..<packCount(in: shape ?? pattern)).flatMap { try types(pattern, packIndex: $0) }
        }
        if case .packValue(let elements) = type {
            return try elements.flatMap { try types($0, packIndex: packIndex) }
        }
        func elements(of argument: BoundArgument) throws -> [Any.Type] {
            if let packIndex, argument.isPack {
                guard argument.types.indices.contains(packIndex) else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "Equal lengths for the expanded packs", found: []))
                }
                return [argument.types[packIndex]]
            }
            return argument.types
        }
        if case .named(let name, let parameters) = type, parameters.isEmpty {
            if let direct = arguments[name] { return try elements(of: direct) }
            let components = name.split(separator: ".").map(String.init)
            if let root = components.first, arguments[root] != nil, components.count > 1 {
                return try types(components.dropFirst().reduce(.named(root, [])) { .associated($0, $1) }, packIndex: packIndex)
            }
        }
        if case .associated(let base, let member, let protocolName) = type {
            let candidates = try conformances(for: base, qualifiedBy: protocolName)
            return try types(base, packIndex: packIndex).map { metadata in
                var matches: [Any.Type] = []
                for candidate in candidates {
                    let found = unsafe candidate.descriptor!.withUnsafeAddress { protocolAddress in
                        member.withCString { ABISwiftAssociatedType(unsafeBitCast(metadata, to: UnsafeRawPointer.self), protocolAddress, $0) }
                    }
                    if let found {
                        let type = unsafeBitCast(found, to: Any.Type.self)
                        if !matches.contains(where: { $0 == type }) { matches.append(type) }
                    }
                }
                guard matches.count == 1 else {
                    throw ABIResolutionError.metadataUnavailable("Cannot resolve associated type " + type.spelling + ".")
                }
                return matches[0]
            }
        }
        switch type {
        case .metatype(let instance), .existentialMetatype(let instance):
            let metadata = unsafeBitCast(try types(instance, packIndex: packIndex)[0], to: UnsafeRawPointer.self)
            let result: UnsafeRawPointer?
            if case .existentialMetatype = type { result = ABISwiftExistentialMetatypeMetadata(metadata) }
            else { result = ABISwiftMetatypeMetadata(metadata) }
            guard let result else {
                throw ABIResolutionError.metadataUnavailable("An existential metatype requires an existential instance type.")
            }
            return [unsafeBitCast(result, to: Any.Type.self)]
        default: break
        }
        if case .reference = type {} else {
            let name = try spelling(type, packIndex: packIndex)
            if let known = knownTypes[try Self.key(name)] { return [known] }
        }
        if case .tuple(let fields, let labels) = type {
            let groups = try fields.map { try types($0, packIndex: packIndex) }
            let elements = groups.flatMap { $0 }
            let names = groups.enumerated().flatMap { index, types in
                Array(repeating: labels?[index] ?? "", count: types.count)
            }
            let pointers = elements.map { Optional(unsafeBitCast($0, to: UnsafeRawPointer.self)) }
            let metadata = pointers.withUnsafeBufferPointer { pointers in
                if names.allSatisfy(\.isEmpty) { return ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, nil) }
                return (names.joined(separator: " ") + " ").withCString {
                    ABISwiftTupleTypeMetadata(pointers.baseAddress, pointers.count, $0)
                }
            }
            guard let metadata else {
                throw ABIResolutionError.metadataUnavailable("The tuple exceeds Swift's metadata element count.")
            }
            return [unsafeBitCast(metadata, to: Any.Type.self)]
        }
        let descriptor: SwiftNominalDescriptor
        let parameters: [SwiftFormalType]
        if case .reference(let reference, let arguments) = type {
            descriptor = reference
            parameters = arguments
        } else {
            let nominal = type.nominalDeclaration
            let declarationName: String
            if let nominal { declarationName = nominal.name; parameters = nominal.arguments }
            else if case .named(let name, let arguments) = type { declarationName = name; parameters = arguments }
            else {
                throw ABIResolutionError.metadataUnavailable("Cannot construct metadata for " + type.spelling + ".")
            }
            if let type = NSClassFromString(declarationName.hasPrefix("__C.") ? String(declarationName.dropFirst(4)) : declarationName),
               parameters.isEmpty { return [type] }
            descriptor = try SwiftNominalDescriptor(resolver.resolve(
                .init(name: "nominal type descriptor for " + declarationName, language: .swift, kind: .data),
                in: .automatic, loading: .loadedOnly))
        }
        let arguments: [NativeSwiftGenericArgument] = try parameters.map { parameter in
            let values = try types(parameter, packIndex: packIndex).map { NativeSwiftGenericArgument.type($0) }
            switch parameter {
            case .pack, .packValue: return .pack(values)
            default: if packIndex == nil && isPack(parameter) { return .pack(values) }
            }
            guard values.count == 1 else {
                throw ABIResolutionError.signatureMismatch(.init(expected: "One type for " + parameter.spelling, found: []))
            }
            return values[0]
        }
        let metadata = try SwiftGenericTypeMetadata(descriptor: descriptor, arguments: arguments)
        boundTypes.metadata.withLock { $0[ObjectIdentifier(metadata.value)] = metadata }
        return [metadata.value]
    }

    func packCount(in type: SwiftFormalType) throws -> Int {
        var counts: [Int] = []
        func visit(_ type: SwiftFormalType) {
            switch type {
            case .objectiveCClass: break
            case .named(let name, let parameters):
                if let argument = arguments[String(name.prefix { $0 != "." })], argument.isPack {
                    counts.append(argument.types.count)
                }
                parameters.forEach(visit)
            case .nominal(_, let parameters), .reference(_, let parameters): parameters.forEach(visit)
            case .nested(let parent, _, let parameters): visit(parent); parameters.forEach(visit)
            case .associated(let base, _, _): visit(base)
            case .tuple(let fields, _), .packValue(let fields): fields.forEach(visit)
            case .function(let parameters, let result, let failure, _):
                parameters.forEach(visit); visit(result); if let failure { visit(failure) }
            case .foreignFunction(_, let parameters, let result):
                parameters.forEach(visit); visit(result)
            case .pack(let value, let shape): visit(shape ?? value)
            case .borrowing(let value), .consuming(let value), .inoutValue(let value), .metatype(let value), .existentialMetatype(let value): visit(value)
            }
        }
        visit(type)
        guard let count = counts.first, counts.allSatisfy({ $0 == count }) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "Equal lengths for the packs in " + type.spelling, found: counts.map(String.init)))
        }
        return count
    }

    func spelling(_ type: SwiftFormalType, packIndex: Int? = nil) throws -> String {
        let packIndex = packIndex ?? packElementIndex
        switch type {
        case .objectiveCClass(let name): return name
        case .named(let name, let parameters):
            if parameters.isEmpty && arguments[String(name.prefix { $0 != "." })] != nil {
                let resolved = try types(type, packIndex: packIndex)
                return try resolved.map(swiftNativeTypeName).joined(separator: ", ")
            }
            return name + (parameters.isEmpty ? "" : "<" + (try parameters.map { try spelling($0, packIndex: packIndex) }).joined(separator: ", ") + ">")
        case .nominal(let name, let parameters):
            return name + (parameters.isEmpty ? "" : "<" + (try parameters.map { try spelling($0, packIndex: packIndex) }).joined(separator: ", ") + ">")
        case .reference:
            return try types(type, packIndex: packIndex).map(swiftNativeTypeName).joined(separator: ", ")
        case .associated:
            return try types(type, packIndex: packIndex).map(swiftNativeTypeName).joined(separator: ", ")
        case .nested(let parent, let name, let parameters):
            return try spelling(parent, packIndex: packIndex) + "." + name
                + (parameters.isEmpty ? "" : "<" + parameters.map { try spelling($0, packIndex: packIndex) }.joined(separator: ", ") + ">")
        case .tuple(let values, let labels):
            let fields = try values.enumerated().map { index, value in
                let type = try spelling(value, packIndex: packIndex)
                if type.isEmpty { return "" }
                return (labels?[index].isEmpty == false ? labels![index] + ": " : "") + type
            }
            return "(" + fields.filter { !$0.isEmpty }.joined(separator: ", ") + ")"
        case .pack(let value, let shape):
            return try (0..<packCount(in: shape ?? value)).map { try spelling(value, packIndex: $0) }.joined(separator: ", ")
        case .packValue(let elements):
            return "Pack{" + (try elements.map { try spelling($0, packIndex: packIndex) }).filter { !$0.isEmpty }.joined(separator: ", ") + "}"
        case .inoutValue(let value), .borrowing(let value), .consuming(let value): return try spelling(value, packIndex: packIndex)
        case .metatype, .existentialMetatype:
            return try swiftNativeTypeName(types(type, packIndex: packIndex)[0])
        case .function(let values, let result, let failure, let isAsync):
            let error = try failure.map { try spelling($0, packIndex: packIndex) }
            return "(" + (try values.map { try spelling($0, packIndex: packIndex) }).joined(separator: ", ") + ")" + (isAsync ? " async" : "")
                + (error.map { $0 == "Swift.Never" ? "" : $0 == "Swift.Error" ? " throws" : " throws(" + $0 + ")" } ?? "")
                + " -> " + (try spelling(result, packIndex: packIndex))
        case .foreignFunction(let convention, let values, let result):
            return "@convention(" + convention.rawValue + ") ("
                + (try values.map { try spelling($0, packIndex: packIndex) }).joined(separator: ", ")
                + ") -> " + (try spelling(result, packIndex: packIndex))
        }
    }

    func resultType(_ actual: Any.Type, for formal: SwiftFormalType) throws -> Any.Type {
        if actual == NativeSwiftValue.self { return try types(formal)[0] }
        let optional = actual as? any NativeOptionalValue.Type
        if (optional?.wrappedType ?? actual) == AnyObject.self {
            let native = try types(formal)[0]
            let nativeOptional = native as? any NativeOptionalValue.Type
            if (optional != nil) == (nativeOptional != nil),
               (nativeOptional?.wrappedType ?? native) is AnyClass { return native }
        }
        try validate(actual, for: formal)
        return actual
    }

    func validate(_ type: Any.Type, for formal: SwiftFormalType, packIndex: Int? = nil) throws {
        if case .objectiveCClass = formal {
            guard try type == types(formal)[0] else {
                throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling, found: [String(reflecting: type)]))
            }
            return
        }
        if let convention = formal.argumentConvention {
            guard let argument = type as? any SwiftConventionArgument.Type, argument.convention == convention.convention else {
                throw ABIResolutionError.signatureMismatch(.init(expected: formal.spelling + " with its Swift argument wrapper",
                    found: [String(reflecting: type)]))
            }
            return try validate(argument.wrappedType, for: convention.value, packIndex: packIndex)
        }
        let expected = try spelling(formal, packIndex: packIndex)
        let actual: String
        if case .function = formal { actual = try swiftFunctionTypeName(type) }
        else { actual = try swiftNativeTypeName(type) }
        guard try Self.key(expected) == Self.key(actual) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: expected, found: [actual]))
        }
    }

    func runtimeValuePlan(metadata: Any.Type, type: CValueType) throws -> SwiftRuntimeValuePlan {
        try SwiftRuntimeValuePlan(metadata: metadata, type: type, resolver: resolver,
            retaining: images + typeOwners.flatMap(\.codeImages))
    }

    func validateArgument(_ actual: Any.Type, for formal: SwiftFormalType) throws {
        if actual == NativeSwiftValue.self || actual == NativeSwiftBorrowedValue.self {
            _ = try types(formal)
        } else {
            try validate(actual, for: formal)
        }
    }
}
