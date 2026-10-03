import ABIBridgeCore
import Synchronization

// The SIL discriminator hashes formal value types, not their register widths.
// Class identity, isolation, and ownership qualifiers are intentionally erased.
// https://github.com/swiftlang/swift/blob/main/lib/SIL/IR/SILFunctionType.cpp
func swiftClosureAuthType(_ type: Any.Type) throws -> String {
    guard !(type is any SwiftConventionArgument.Type) else {
        throw ABIResolutionError.unsupportedDeclaration("Inout and ownership-qualified callback parameters require a scoped native adapter.")
    }
    let base = (type as? any NativeOptionalValue.Type)?.wrappedType ?? type
    let managed = type is any ABIBridgeSwiftValue.Type
    guard (!(base is any ABIBridgeValue.Type) || managed), !(base is any SwiftClosureValue.Type) else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Closure signatures require built-in or explicitly described Swift values; foreign conversions and nested closures are not supported."
        )
    }
    if base is AnyClass || base == AnyObject.self { return "-class" }
    if let metatype = SwiftMetatypeMetadata(base) {
        return type is any NativeOptionalValue.Type && metatype.isExistential ? "Optional<-metatype>" : "-metatype"
    }
    if let existential = SwiftExistentialRepresentation(base) {
        return existential.closureAuthType(optional: type is any NativeOptionalValue.Type)
    }
    if let value = type as? any ABIBridgeSwiftValue.Type {
        guard let components = value.swiftABIType.cType else { return "-indirect" }
        if withExtendedLifetime(components, { ABISwiftValueIsIndirect(components.handle) }) {
            return "-indirect"
        }
    }
    guard var name = _mangledTypeName(base) else {
        throw ABIResolutionError.metadataUnavailable("No Swift closure type identity for \(String(reflecting: type)).")
    }
    // SIL hashes these nominal declarations without their generic substitutions.
    if base is any SwiftArrayValue.Type {
        name = "Sa"
    } else if base is any NativePointerValue.Type {
        if name.hasPrefix("SPy") { name = "SP" }
        else if name.hasPrefix("Spy") { name = "Sp" }
    }
    if managed, name.hasSuffix("G") { name = try swiftNominalClosureName(name) }
    let nominal = "$s" + name
    return type is any NativeOptionalValue.Type ? "Optional<" + nominal + ">" : nominal
}

// A bound nominal mangling contains its declaration before the generic
// argument list. Let Swift's demangler validate candidate prefixes rather than
// interpreting identifier lengths, word substitutions, or nested contexts here.
private func swiftNominalClosureName(_ mangled: String) throws -> String {
    guard let fullName = DeclarationKey.demangle("$s" + mangled, language: .swift) else {
        throw ABIResolutionError.metadataUnavailable("No generic Swift value identity.")
    }
    var nominalName = "", depth = 0
    for character in fullName {
        if character == "<" { depth += 1 }
        else if character == ">" { depth -= 1 }
        else if depth == 0 { nominalName.append(character) }
    }
    for index in mangled.indices where mangled[index] == "y" {
        let candidate = String(mangled[..<index])
        if DeclarationKey.demangle("$s" + candidate, language: .swift) == nominalName {
            return candidate
        }
    }
    throw ABIResolutionError.unsupportedDeclaration(
        "Cannot establish the nominal closure identity for " + fullName + "."
    )
}

private let swiftClosureDiscriminators = Mutex<[String: UInt16]>([:])

func swiftClosureDiscriminator(parameters: [String], result: String?) -> UInt16 {
    swiftClosureDiscriminator(parameters: parameters, results: result.map { [$0] } ?? [])
}

func swiftClosureDiscriminator(parameters: [String], results: [String]) -> UInt16 {
    let description = "function:\(parameters.count):" + parameters.map { $0 + ":" }.joined()
        + "\(results.count):" + results.map { $0 + ":" }.joined()
    return swiftClosureDiscriminators.withLock { cache in
        if let value = cache[description] { return value }
        let value = swiftPointerAuthHash(description)
        if cache.count == 128 { cache.removeAll(keepingCapacity: true) }
        cache[description] = value
        return value
    }
}

func swiftClosureAuthTypes(_ type: Any.Type) throws -> [String] {
    if let tuple = SwiftTupleMetadata(type) {
        return try tuple.elements.flatMap { try swiftClosureAuthTypes($0.type) }
    }
    return [try swiftClosureAuthType(type)]
}

// ABI-stable SipHash-2-4, with LLVM's fixed ptrauth key and nonzero 16-bit range.
// https://github.com/llvm/llvm-project/blob/main/llvm/lib/Support/SipHash.cpp
private func swiftPointerAuthHash(_ string: String) -> UInt16 {
    let bytes = Array(string.utf8)
    let key0: UInt64 = 0x794a1079ebc9d4b5, key1: UInt64 = 0xd48187421b8bec6f
    var a: UInt64 = 0x736f6d6570736575 ^ key0
    var b: UInt64 = 0x646f72616e646f6d ^ key1
    var c: UInt64 = 0x6c7967656e657261 ^ key0
    var d: UInt64 = 0x7465646279746573 ^ key1
    func rotate(_ value: UInt64, by amount: UInt64) -> UInt64 {
        value << amount | value >> (64 - amount)
    }
    func rounds(_ count: Int) {
        for _ in 0..<count {
            a &+= b; b = rotate(b, by: 13) ^ a; a = rotate(a, by: 32)
            c &+= d; d = rotate(d, by: 16) ^ c
            a &+= d; d = rotate(d, by: 21) ^ a
            c &+= b; b = rotate(b, by: 17) ^ c; c = rotate(c, by: 32)
        }
    }
    let full = bytes.count / 8 * 8
    for offset in stride(from: 0, to: full, by: 8) {
        var word: UInt64 = 0
        for index in 0..<8 { word |= UInt64(bytes[offset + index]) << (index * 8) }
        d ^= word; rounds(2); a ^= word
    }
    var tail = UInt64(bytes.count & 0xff) << 56
    for index in full..<bytes.count { tail |= UInt64(bytes[index]) << ((index - full) * 8) }
    d ^= tail; rounds(2); a ^= tail
    c ^= 0xff; rounds(4)
    return UInt16((a ^ b ^ c ^ d) % 0xffff + 1)
}

protocol SwiftClosureValue: SendableMetatype {
    static var swiftFunctionType: Any.Type { get }
    static var requiresExplicitDeclaration: Bool { get }
    static var supportsResult: Bool { get }
    static func makeClosureCodec() throws -> SwiftClosureCodec
    func encodeClosure() -> NativeValueStorage
}

extension SwiftClosureValue {
    static var requiresExplicitDeclaration: Bool { false }
    static var supportsResult: Bool { true }
}

struct SwiftClosureCodec: Sendable {
    let type: CValueType
    let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool, SwiftValueCodeLifetime?) throws -> Any
}

final class SwiftClosureStorage {
    let value: ABISwiftClosureValue
    let implementation: SwiftImplementation
    let codeOwner: Any?
    let codeLifetime: SwiftValueCodeLifetime?

    // Consumes one native context reference, including on preparation failure.
    init(adopting value: ABISwiftClosureValue, discriminator: UInt16, retaining owner: Any?,
         codeLifetime: SwiftValueCodeLifetime? = nil) throws {
        do {
            guard let function = ABIAuthenticateSwiftClosureFunction(value.function, discriminator) else {
                throw ABIInvocationError.unexpectedNilResult(expected: "a Swift closure")
            }
            implementation = try SwiftImplementation(function: function, retaining: nil)
        } catch {
            withExtendedLifetime(owner) { ABIReleaseSwiftClosureContext(value.context) }
            throw error
        }
        self.value = value
        let callbackOwner = ABICopySwiftClosureCallbackCodeOwner(implementation.function).map {
            Unmanaged<AnyObject>.fromOpaque($0).takeRetainedValue()
        }
        codeOwner = (owner, implementation, callbackOwner)
        let callbackLifetime = (callbackOwner as? SwiftClosureCodeOwner)?.codeLifetime
        let images = implementation.image.map { [$0] } ?? []
        let lifetime = codeLifetime ?? callbackLifetime
            ?? (images.isEmpty ? nil : SwiftValueCodeLifetime(images))
        self.codeLifetime = SwiftValueCodeLifetime.connect([lifetime, callbackLifetime].compactMap { $0 },
            retaining: images)
    }

    deinit {
        withExtendedLifetime((implementation, codeOwner)) { ABIReleaseSwiftClosureContext(value.context) }
    }

    func encoded(codeLifetime: SwiftValueCodeLifetime? = nil) -> NativeValueStorage {
        Self.copy(value, retaining: self, codeLifetime: codeLifetime ?? self.codeLifetime)
    }

    static func copy(_ value: ABISwiftClosureValue, retaining owner: AnyObject,
                     codeLifetime: SwiftValueCodeLifetime? = nil) -> NativeValueStorage {
        let storage = NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            owner: owner, codeLifetime: codeLifetime, destroyingWith: destroy
        )
        ABIRetainSwiftClosureContext(value.context)
        storage.store(value)
        return storage
    }

    static func destroy(_ address: UnsafeMutableRawPointer) {
        ABIReleaseSwiftClosureContext(address.load(as: ABISwiftClosureValue.self).context)
    }
}
