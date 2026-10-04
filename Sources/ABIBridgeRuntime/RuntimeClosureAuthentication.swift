import Synchronization

private let swiftClosureDiscriminators = Mutex<[String: UInt16]>([:])

package func swiftClosureDiscriminator(parameters: [String], result: String?) -> UInt16 {
    swiftClosureDiscriminator(parameters: parameters, results: result.map { [$0] } ?? [])
}

package func swiftClosureDiscriminator(parameters: [String], results: [String]) -> UInt16 {
    let description = swiftClosureAuthDescription(parameters: parameters, results: results)
    return swiftClosureDiscriminators.withLock { cache in
        if let value = cache[description] { return value }
        let value = swiftPointerAuthHash(description)
        if cache.count == 128 { cache.removeAll(keepingCapacity: true) }
        cache[description] = value
        return value
    }
}

package func swiftClosureAuthDescription(parameters: [String], results: [String]) -> String {
    "function:\(parameters.count):" + parameters.map { $0 + ":" }.joined()
        + "\(results.count):" + results.map { $0 + ":" }.joined()
}

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
