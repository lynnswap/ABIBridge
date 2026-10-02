import ABIBridgeCore
import Darwin

/// Immutable metadata/witness words. Native calls only borrow this buffer.
final class SwiftGenericArgumentBuffer: @unchecked Sendable {
    private let storage: NativeValueStorage
    private let count: Int
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

struct SwiftGenericBinding: Sendable {
    struct BoundArgument: Sendable {
        let types: [Any.Type]
        let isPack: Bool
    }
    struct Conformance: Sendable {
        let subject: SwiftFormalType
        let name: String
        let descriptor: ResolvedSymbol?
    }

    let declaration: SwiftGenericDeclaration
    let arguments: [String: BoundArgument]
    let conformances: [Conformance]
    let typeOwners: [NativeSwiftType]
    private let knownTypes: [[UInt8]: Any.Type]
    private let resolver: SymbolResolver
    private(set) var metadataArguments: [UInt] = []
    private(set) var images: [NativeImage] = []
    private(set) var packs: [SwiftGenericArgumentBuffer] = []

    init(declaration: SwiftGenericDeclaration, arguments: [NativeSwiftGenericArgument],
         signature: SwiftFunctionSignature, resolver: SymbolResolver) throws {
        guard arguments.count == declaration.parameters.count else {
            throw ABIResolutionError.signatureMismatch(.init(
                expected: "\(declaration.parameters.count) generic arguments", found: ["\(arguments.count) generic arguments"]))
        }
        self.declaration = declaration
        self.resolver = resolver
        var bound: [String: BoundArgument] = [:]
        var owners: [NativeSwiftType] = []
        var known: [[UInt8]: Any.Type] = [:]
        func remember(_ type: Any.Type) throws {
            known[try Self.key(swiftNativeTypeName(type))] = type
            if let optional = type as? any NativeOptionalValue.Type { try remember(optional.wrappedType) }
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
        conformances = try declaration.requirements.compactMap { requirement in
            guard case .conformance(let subject, let name) = requirement else { return nil }
            // Marker protocols have no runtime witness table. Their source-level
            // concurrency/ownership requirements remain the unsafe caller's contract.
            if ["AnyObject", "Swift.AnyObject", "Swift.Sendable", "Swift.Copyable", "Swift.Escapable"].contains(name) {
                return Conformance(subject: subject, name: name, descriptor: nil)
            }
            return Conformance(subject: subject, name: name, descriptor: try resolver.resolve(
                .init(name: "protocol descriptor for " + name, language: .swift, kind: .data),
                in: .automatic, loading: .loadedOnly))
        }
        for requirement in declaration.requirements {
            switch requirement {
            case .sameType(let left, let right):
                let lhs = try spelling(left), rhs = try spelling(right)
                guard try Self.key(lhs) == Self.key(rhs) else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: lhs, found: [rhs]))
                }
            case .sameShape(let left, let right):
                guard try types(left).count == types(right).count else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "Equal type pack lengths", found: [left.spelling, right.spelling]))
                }
            case .conformance: break
            }
        }
        for parameter in declaration.parameters where parameter.isPack {
            metadataArguments.append(UInt(bound[parameter.name]!.types.count))
        }
        for parameter in declaration.parameters {
            let argument = bound[parameter.name]!
            let metadata = argument.types.map { unsafeBitCast($0, to: UInt.self) }
            if argument.isPack {
                metadataArguments.append(appendPack(metadata))
            } else {
                metadataArguments.append(metadata[0])
            }
        }
        for conformance in conformances {
            let types = try types(conformance.subject)
            if let descriptor = conformance.descriptor {
                images.append(descriptor.image)
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
                       let image = try Self.image(containing: address) { images.append(image) }
                }
                if isPack(conformance.subject) { metadataArguments.append(appendPack(witnesses)) }
                else { metadataArguments.append(contentsOf: witnesses) }
            } else if conformance.name.hasSuffix("AnyObject") {
                guard types.allSatisfy({ $0 is AnyClass }) else {
                    throw ABIResolutionError.signatureMismatch(.init(expected: "A class type", found: types.map { String(reflecting: $0) }))
                }
            }
        }
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

    private static func image(containing address: UnsafeRawPointer) throws -> NativeImage? {
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let path = info.dli_fname else { return nil }
        return try NativeImage.opening(path: String(cString: path), loading: .loadedOnly)
    }

    func isPack(_ type: SwiftFormalType) -> Bool {
        switch type {
        case .pack: true
        case .named(let name, _): arguments[String(name.prefix { $0 != "." })]?.isPack == true
        default: false
        }
    }

    func isClassBound(_ type: SwiftFormalType) -> Bool {
        conformances.contains { conformance in
            guard conformance.subject == type else { return false }
            if conformance.name.hasSuffix("AnyObject") { return true }
            guard let descriptor = conformance.descriptor else { return false }
            return unsafe descriptor.withUnsafeAddress { $0.loadUnaligned(as: UInt32.self) & 0x10000 == 0 }
        }
    }

    func types(_ type: SwiftFormalType) throws -> [Any.Type] {
        if case .pack(let pattern) = type { return try types(pattern) }
        if case .named(let name, let parameters) = type, parameters.isEmpty {
            if let direct = arguments[name] { return direct.types }
            let components = name.split(separator: ".").map(String.init)
            if let root = components.first, let argument = arguments[root], components.count > 1 {
                return try argument.types.map { base in
                    var metadata = base
                    var path = root
                    var remaining = Array(components.dropFirst())
                    while !remaining.isEmpty {
                        var candidates = conformances.filter { $0.subject.spelling == path && $0.descriptor != nil }
                        if remaining.count > 2 {
                            let qualified = remaining.dropLast().joined(separator: ".")
                            if let chosen = conformances.first(where: { $0.name == qualified }) {
                                candidates = [chosen]
                                remaining = [remaining.last!]
                            }
                        }
                        let member = remaining.removeFirst()
                        var matches: [Any.Type] = []
                        for candidate in candidates {
                            let descriptor = candidate.descriptor!
                            let found = unsafe descriptor.withUnsafeAddress { protocolAddress in
                                member.withCString { ABISwiftAssociatedType(unsafeBitCast(metadata, to: UnsafeRawPointer.self), protocolAddress, $0) }
                            }
                            if let found {
                                let type = unsafeBitCast(found, to: Any.Type.self)
                                if !matches.contains(where: { $0 == type }) { matches.append(type) }
                            }
                        }
                        guard matches.count == 1 else {
                            throw ABIResolutionError.metadataUnavailable("Cannot resolve associated type " + path + "." + member + ".")
                        }
                        metadata = matches[0]
                        path += "." + member
                    }
                    return metadata
                }
            }
        }
        let name = try spelling(type)
        if let known = knownTypes[try Self.key(name)] { return [known] }
        let descriptor = try resolver.resolve(.init(name: "nominal type descriptor for " + name, language: .swift, kind: .data),
                                              in: .automatic, loading: .loadedOnly)
        let isGeneric = unsafe descriptor.withUnsafeAddress { $0.loadUnaligned(as: UInt32.self) & 0x80 != 0 }
        guard !isGeneric else {
            throw ABIResolutionError.signatureMismatch(.init(expected: "Explicit generic arguments for " + name, found: []))
        }
        let accessor = try resolver.resolve(.init(name: "type metadata accessor for " + name, language: .swift),
                                            in: .automatic, loading: .loadedOnly)
        let function = try NativeSwiftFunction<(UInt) -> SwiftMetadataResponse>(symbol: accessor)
        let response = try unsafe function.unsafeInvoke(0)
        guard response.address != 0, response.state == 0 else {
            throw ABIResolutionError.metadataUnavailable("Complete Swift metadata is unavailable for " + name)
        }
        return [unsafeBitCast(response.address, to: Any.Type.self)]
    }

    func spelling(_ type: SwiftFormalType) throws -> String {
        switch type {
        case .named(let name, let parameters):
            if arguments[String(name.prefix { $0 != "." })] != nil {
                let resolved = try types(type)
                return try resolved.map(swiftNativeTypeName).joined(separator: ", ")
            }
            return name + (parameters.isEmpty ? "" : "<" + (try parameters.map(spelling)).joined(separator: ", ") + ">")
        case .tuple(let values): return "(" + (try values.map(spelling)).joined(separator: ", ") + ")"
        case .pack(let value): return try spelling(value)
        case .inoutValue(let value), .borrowing(let value), .consuming(let value): return try spelling(value)
        case .metatype(let value): return try spelling(value) + ".Type"
        case .function(let values, let result, let failure, let isAsync):
            return "(" + (try values.map(spelling)).joined(separator: ", ") + ")" + (isAsync ? " async" : "")
                + (try failure.map { $0.spelling == "Swift.Error" ? " throws" : " throws(" + (try spelling($0)) + ")" } ?? "")
                + " -> " + (try spelling(result))
        }
    }

    func validate(_ type: Any.Type, for formal: SwiftFormalType) throws {
        let expected = try spelling(formal)
        let actual: String
        if case .function = formal { actual = try swiftFunctionTypeName(type) }
        else { actual = try swiftNativeTypeName(type) }
        guard try Self.key(expected) == Self.key(actual) else {
            throw ABIResolutionError.signatureMismatch(.init(expected: expected, found: [actual]))
        }
    }
}
