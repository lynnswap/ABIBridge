import ABIBridgeCore

/// Maps source-level parameters to the original declaration's SIL parameters.
/// A variadic pack is one native address vector even after substitution makes
/// its elements separate parameters in the caller's function type.
struct SwiftGenericParameters: Sendable {
    enum Group: Sendable {
        case value(Int)
        case pack(Range<Int>, CValueType)
    }
    let arguments: [SwiftGenericArgument]
    let groups: [Group]
    let hasPacks: Bool
    private let constants: [SwiftValueConstants]
    var needsEncoding: Bool { hasPacks || constants.contains { !$0.isEmpty } }

    init(formal: [SwiftFormalType], actual: [Any.Type], binding: SwiftGenericBinding, defaultConsuming: Bool = false) throws {
        var arguments: [SwiftGenericArgument] = []
        var groups: [Group] = []
        var index = 0
        var hasPacks = false
        for parameter in formal {
            if case .pack(let pattern, let shape) = parameter {
                let count = try binding.packCount(in: shape ?? pattern)
                guard index + count <= actual.count else { throw Self.mismatch(actual.count) }
                let range = index..<(index + count)
                for (packIndex, position) in range.enumerated() {
                    let element = binding.selectingPackElement(at: packIndex)
                    arguments.append(try SwiftGenericCallPlan.argument(pattern, actual: actual[position], binding: element,
                        defaultConsuming: defaultConsuming))
                }
                groups.append(.pack(range, try CValueType(indirectSwiftSize: count * MemoryLayout<UInt>.size,
                                                           alignment: MemoryLayout<UInt>.alignment)))
                hasPacks = true
                index += count
            } else {
                guard index < actual.count else { throw Self.mismatch(actual.count) }
                groups.append(.value(index))
                arguments.append(try SwiftGenericCallPlan.argument(parameter, actual: actual[index], binding: binding,
                    defaultConsuming: defaultConsuming))
                index += 1
            }
        }
        guard index == actual.count else { throw Self.mismatch(actual.count) }
        self.arguments = arguments
        self.groups = groups
        self.hasPacks = hasPacks
        constants = actual.map(SwiftValueConstants.init)
    }

    static func storageType(_ type: Any.Type) throws -> CValueType {
        let layout = ABISwiftGetValueLayout(unsafeBitCast(type, to: UnsafeRawPointer.self))
        return try CValueType(indirectSwiftSize: layout.size, alignment: layout.alignment)
    }

    private static func mismatch(_ count: Int) -> ABIResolutionError {
        .signatureMismatch(.init(expected: "The instantiated declaration's argument count", found: ["\(count) arguments"]))
    }

    func types(from logical: [CValueType]) -> [CValueType] {
        groups.map {
            switch $0 {
            case .value(let index): logical[index]
            case .pack(_, let type): type
            }
        }
    }

    struct Encoded {
        let addresses: [UnsafeMutableRawPointer?]
        let packs: [NativeValueStorage]
    }

    func encode(_ logical: [UnsafeMutableRawPointer?]) -> Encoded {
        guard needsEncoding else { return Encoded(addresses: logical, packs: []) }
        var packs: [NativeValueStorage] = []
        let logical = zip(logical, constants).map { address, constants -> UnsafeMutableRawPointer? in
            guard !constants.isEmpty, let address else { return address }
            let storage = constants.copyStorage(from: address)
            packs.append(storage)
            return storage.address
        }
        let addresses = groups.map { group -> UnsafeMutableRawPointer? in
            switch group {
            case .value(let index): return logical[index]
            case .pack(let range, let type):
                let storage = NativeValueStorage(size: type.size, alignment: type.alignment)
                for (element, index) in range.enumerated() {
                    storage.address.storeBytes(of: logical[index],
                        toByteOffset: element * MemoryLayout<UInt>.size, as: UnsafeMutableRawPointer?.self)
                }
                packs.append(storage)
                return storage.address
            }
        }
        return Encoded(addresses: addresses, packs: packs)
    }

    func encode(_ logical: UnsafePointer<UnsafeMutableRawPointer?>?) -> Encoded {
        encode(Array(UnsafeBufferPointer(start: logical, count: arguments.count)))
    }

    func unpack(_ native: UnsafePointer<UnsafeMutableRawPointer?>?) -> [UnsafeMutableRawPointer?] {
        var arguments: [UnsafeMutableRawPointer?] = []
        for (index, group) in groups.enumerated() {
            switch group {
            case .value: arguments.append(native![index])
            case .pack(let range, _):
                for element in 0..<range.count {
                    arguments.append(native![index]!.load(fromByteOffset: element * MemoryLayout<UInt>.size,
                                                          as: UnsafeMutableRawPointer?.self))
                }
            }
        }
        return arguments
    }
}
