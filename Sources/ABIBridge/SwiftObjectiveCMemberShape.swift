import Foundation

/// The parts of a Swift request that Objective-C protocol records can rule
/// out without knowing the importer's Swift name. This deliberately accepts
/// encodings whose relationship to the host type is not established.
struct SwiftObjectiveCMemberShape {
    enum Role: Sendable { case method, initializer, getter, setter, subscriptAccessor }
    let role: Role
    let isStatic: Bool
    let parameters: [Any.Type]
    let result: Any.Type
    let isAsync: Bool

    func matchesMethod(selector: String, encoding: String?, isInstance: Bool) -> Bool {
        if role == .initializer || role == .subscriptAccessor {
            guard isInstance else { return false }
        } else if isInstance == isStatic {
            return false
        }
        let count = selector.filter { $0 == ":" }.count
        let actual = parameters.count
        guard actual <= count else { return false }
        guard let encoding, let types = SwiftObjectiveCEncoding.types(encoding), types.count >= 3
        else {
            return true
        }
        let arguments = Array(types.dropFirst(3))
        guard arguments.count == count else { return true }
        let removable = arguments.indices.filter {
            arguments[$0] == "^@" || (isAsync && arguments[$0].hasPrefix("@?"))
        }
        guard actual >= count - removable.count else { return false }
        if actual == count {
            guard zip(parameters, arguments).allSatisfy(Self.compatible) else { return false }
            return role == .initializer || Self.compatible(result, types[0])
        }
        if actual == count - 1, removable.count == 1 {
            let dropped = removable[0]
            let remaining = arguments.enumerated().filter { $0.offset != dropped }.map(\.element)
            guard zip(parameters, remaining).allSatisfy(Self.compatible) else { return false }
            if arguments[dropped] == "^@", role != .initializer {
                return Self.compatible(result, "v") || Self.compatible(result, types[0])
            }
        }
        return true
    }

    func matchesProperty(encoding: String, isInstance: Bool, isReadOnly: Bool) -> Bool {
        guard isInstance != isStatic else { return false }
        let encoding = SwiftObjectiveCEncoding.types(encoding)?.first ?? "?"
        switch role {
        case .getter: return parameters.isEmpty && Self.compatible(result, encoding)
        case .setter:
            return !isReadOnly && parameters.count == 1 && Self.compatible(parameters[0], encoding)
        case .method, .initializer, .subscriptAccessor: return false
        }
    }

    private enum Scalar: Equatable { case integer(Int), float, double, void, object }

    private static func scalar(_ type: Any.Type) -> Scalar? {
        switch type {
        case is Int8.Type, is UInt8.Type, is Bool.Type: .integer(1)
        case is Int16.Type, is UInt16.Type: .integer(2)
        case is Int32.Type, is UInt32.Type: .integer(4)
        case is Int64.Type, is UInt64.Type: .integer(8)
        case is Int.Type, is UInt.Type: .integer(MemoryLayout<Int>.size)
        case is Float.Type: .float
        case is Double.Type: .double
        default: type == Void.self ? .void : type == AnyObject.self ? .object : nil
        }
    }

    private static func compatible(_ host: Any.Type, _ encoding: String) -> Bool {
        guard let scalar = scalar(host), let code = encoding.first else { return true }
        switch code {
        case "B", "c", "C": return scalar == .integer(1)
        case "s", "S": return scalar == .integer(2)
        case "i", "I": return scalar == .integer(4)
        case "l", "L": return scalar == .integer(MemoryLayout<CLong>.size)
        case "q", "Q": return scalar == .integer(8)
        case "f": return scalar == .float
        case "d": return scalar == .double
        case "v": return scalar == .void
        case "@": return scalar == .object && !encoding.hasPrefix("@?")
        case "#", "^": return scalar == .object
        case ":", "*": return false
        default: return true
        }
    }
}

/// Reads complete encoded types, keeping an error pointer and a block
/// distinguishable. Missing or unknown records never exclude a requirement.
enum SwiftObjectiveCEncoding {
    static func types(_ encoding: String) -> [String]? {
        var reader = Reader(bytes: Array(encoding.utf8))
        var result: [String] = []
        while reader.index < reader.bytes.count {
            guard let value = reader.type() else { return nil }
            result.append(value)
            while let byte = reader.current, (48...57).contains(byte) || byte == 45 {
                reader.index += 1
            }
        }
        return result
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func quoted() -> Bool {
            index += 1
            while let byte = current {
                index += 1
                if byte == 34 { return true }
                if byte == 92, current != nil { index += 1 }
            }
            return false
        }

        mutating func type() -> String? {
            while let byte = current, Array("rnNoORVA".utf8).contains(byte) { index += 1 }
            let start = index
            guard let byte = current else { return nil }
            index += 1
            switch byte {
            case 94, 106:
                guard type() != nil else { return nil }
            case 64:
                if current == 63 {
                    index += 1
                    if current == 60 {
                        var depth = 0
                        repeat {
                            guard let next = current else { return nil }
                            index += 1
                            if next == 60 { depth += 1 }
                            if next == 62 { depth -= 1 }
                        } while depth > 0
                    }
                } else if current == 34, !quoted() {
                    return nil
                }
            case 123, 40, 91:
                var closing: [UInt8] = [byte == 123 ? 125 : byte == 40 ? 41 : 93]
                while let next = current, !closing.isEmpty {
                    if next == 34 {
                        guard quoted() else { return nil }
                        continue
                    }
                    index += 1
                    if next == 123 {
                        closing.append(125)
                    } else if next == 40 {
                        closing.append(41)
                    } else if next == 91 {
                        closing.append(93)
                    } else if next == closing.last {
                        closing.removeLast()
                    }
                }
                guard closing.isEmpty else { return nil }
            case 98:
                while let next = current, (48...57).contains(next) { index += 1 }
            default: break
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
