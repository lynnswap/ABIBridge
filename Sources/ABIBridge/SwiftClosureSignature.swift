import ABIBridgeCore

// The SIL discriminator hashes formal value types, not their register widths.
// Class identity, isolation, and ownership qualifiers are intentionally erased.
// https://github.com/swiftlang/swift/blob/main/lib/SIL/IR/SILFunctionType.cpp
func swiftClosureAuthType(_ type: Any.Type) throws -> String {
    let base = (type as? any NativeOptionalValue.Type)?.wrappedType ?? type
    guard !(base is any ABIBridgeValue.Type), !(base is any SwiftClosureValue.Type) else {
        throw ABIResolutionError.unsupportedDeclaration(
            "Closure signatures require built-in Swift representations; custom adapters and nested closures are not supported."
        )
    }
    if base is AnyClass || base == AnyObject.self { return "-class" }
    guard var name = _mangledTypeName(base) else {
        throw ABIResolutionError.metadataUnavailable("No Swift closure type identity for \(String(reflecting: type)).")
    }
    // SIL ignores the pointee substitution for these standard nominal types.
    if base is any NativePointerValue.Type {
        if name.hasPrefix("SPy") { name = "SP" }
        else if name.hasPrefix("Spy") { name = "Sp" }
    }
    let nominal = "$s" + name
    return type is any NativeOptionalValue.Type ? "Optional<" + nominal + ">" : nominal
}

func swiftClosureDiscriminator(parameters: [String], result: String?) -> UInt16 {
    let description = "function:\(parameters.count):" + parameters.map { $0 + ":" }.joined()
        + (result.map { "1:" + $0 + ":" } ?? "0:")
    return swiftPointerAuthHash(description)
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
    static func makeClosureCodec() throws -> SwiftClosureCodec
    var closureStorage: SwiftClosureStorage { get }
}

struct SwiftClosureCodec: Sendable {
    let type: CValueType
    let makeValue: @Sendable (ABISwiftClosureValue, Any?, Bool) throws -> Any
}

final class SwiftClosureStorage {
    let value: ABISwiftClosureValue
    let implementation: SwiftImplementation
    private let owner: Any?

    // Consumes one native context reference, including on preparation failure.
    init(adopting value: ABISwiftClosureValue, discriminator: UInt16, retaining owner: Any?) throws {
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
        self.owner = owner
    }

    deinit {
        withExtendedLifetime((implementation, owner)) { ABIReleaseSwiftClosureContext(value.context) }
    }

    func encoded() -> NativeValueStorage { Self.copy(value, retaining: self) }

    static func copy(_ value: ABISwiftClosureValue, retaining owner: AnyObject) -> NativeValueStorage {
        let storage = NativeValueStorage(
            size: MemoryLayout<ABISwiftClosureValue>.stride,
            alignment: MemoryLayout<ABISwiftClosureValue>.alignment,
            owner: owner, destroyingWith: destroy
        )
        ABIRetainSwiftClosureContext(value.context)
        storage.store(value)
        return storage
    }

    static func destroy(_ address: UnsafeMutableRawPointer) {
        ABIReleaseSwiftClosureContext(address.load(as: ABISwiftClosureValue.self).context)
    }
}
