import ABIBridgeCore
import ObjectiveC

/// Reads the stable Swift class ABI, not the current contents of virtual slots.
/// Descriptor identity keeps selection independent of an earlier interposer.
/// Layouts follow swift/ABI/Metadata.h; arm64e descriptor-pointer constants
/// and method discriminators are also checked against compiler-generated IR.
struct SwiftClassDispatch {
    let address: UInt
    let authentication: NativePointerAuthentication

    init(metadata: Any.Type, implementation: UInt) throws {
        guard let selected = metadata as? AnyClass else {
            throw Self.unsupported("Virtual replacement requires a Swift class instance method.")
        }
        let selectedAddress = UInt(bitPattern: unsafeBitCast(selected, to: UnsafeRawPointer.self))
        let selectedHeader = try Header(address: selectedAddress)
        var current: AnyClass? = selected
        while let type = current {
            let header = try Header(address: UInt(bitPattern: unsafeBitCast(type, to: UnsafeRawPointer.self)))
            if let descriptor = header.descriptor {
                let layout = try Descriptor(address: descriptor)
                var matches: [(Int, UInt32)] = []
                for index in 0..<layout.count {
                    let method = layout.methods + UInt(index * 8)
                    if try Self.relative(method + 4) == implementation {
                        matches.append((try layout.offset() + index * Self.word, try Self.read(method)))
                    }
                }
                for index in 0..<layout.overrideCount {
                    let entry = layout.overrides + UInt(index * 12)
                    guard try Self.relative(entry + 8) == implementation else { continue }
                    let base = try Descriptor(address: Self.indirect(entry, discriminator: 44678))
                    let method = try Self.indirect(entry + 4, discriminator: 26458)
                    guard method >= base.methods, method - base.methods < UInt(base.count * 8),
                          (method - base.methods) % 8 == 0 else {
                        throw Self.unsupported("The override does not reference an established base method descriptor.")
                    }
                    matches.append((try base.offset() + Int(method - base.methods) / 8 * Self.word, try Self.read(method)))
                }
                if !matches.isEmpty {
                    guard matches.count == 1 else {
                        throw Self.unsupported("Multiple virtual descriptors share this implementation address.")
                    }
                    let (offset, flags) = matches[0]
                    let kind = flags & 0xf
                    // Initializers, async entries and coroutine accessors have
                    // different context or continuation contracts.
                    guard flags & 0x10 != 0, flags & 0x40 == 0, [0, 2, 3].contains(kind) else {
                        throw Self.unsupported("This virtual descriptor is not a synchronous instance method, getter or setter.")
                    }
                    guard offset >= -selectedHeader.addressPoint,
                          offset <= selectedHeader.size - selectedHeader.addressPoint - Self.word else {
                        throw Self.unsupported("The virtual entry lies outside the selected class metadata allocation.")
                    }
                    address = try Self.add(selectedAddress, offset)
                    authentication = NativePointerAuthentication.isEnabled
                        ? .signed(key: .instructionA, discriminator: UInt(flags >> 16), addressDiversity: true) : .unsigned
                    return
                }
            }
            current = class_getSuperclass(type)
        }
        throw Self.unsupported("No virtual metadata entry describes this implementation. Direct and final methods have no replaceable class slot.")
    }

    private static let word = MemoryLayout<UInt>.size
    private static func unsupported(_ message: String) -> ABIResolutionError { .unsupportedDeclaration(message) }

    private struct Header {
        let descriptor: UInt?
        let size: Int
        let addressPoint: Int
        init(address: UInt) throws {
            let data: UInt = try read(address + UInt(4 * word))
            guard data & 2 != 0 else { descriptor = nil; size = 0; addressPoint = 0; return }
            size = Int(try read(address + UInt(5 * word + 16)) as UInt32)
            addressPoint = Int(try read(address + UInt(5 * word + 20)) as UInt32)
            let field = address + UInt(5 * word + 24)
            let bits: UInt = try read(field)
            descriptor = bits == 0 ? nil : try pointer(field, discriminator: 44678)
        }
    }

    private struct Descriptor {
        let address: UInt
        let flags: UInt32
        let methods: UInt
        let count: Int
        let overrides: UInt
        let overrideCount: Int
        let vtableOffset: Int

        init(address: UInt) throws {
            self.address = address
            flags = try read(address)
            guard flags & 0x1f == 16, flags & 0x80 == 0 else {
                throw unsupported("Generic class descriptor tails require a separate metadata layout adapter.")
            }
            var tail = address + 44
            if flags & 0x20000000 != 0 { tail += 4 } // Resilient superclass reference.
            switch (flags >> 16) & 3 {
            case 0: break
            case 1: tail += 12 // Singleton metadata initialization.
            case 2: tail += 4 // Foreign metadata initialization.
            default: throw unsupported("Unknown class metadata initialization layout.")
            }
            if flags & 0x80000000 != 0 {
                vtableOffset = Int(try read(tail) as UInt32) * word
                count = Int(try read(tail + 4) as UInt32)
                tail += 8
                methods = tail
                tail += UInt(count * 8)
            } else {
                vtableOffset = 0; count = 0; methods = tail
            }
            if flags & 0x40000000 != 0 {
                overrideCount = Int(try read(tail) as UInt32)
                overrides = tail + 4
            } else { overrideCount = 0; overrides = tail }
        }

        func offset() throws -> Int {
            guard flags & 0x20000000 != 0 else { return vtableOffset }
            // NativeSwiftType requests complete metadata before reaching this
            // reader. Its allocation orders bounds-cache initialization, so this
            // immutable immediate-members offset needs no additional acquire.
            let bounds = try relative(address + 24)
            let immediate: Int = try read(bounds)
            guard immediate != 0, immediate % word == 0 else {
                throw unsupported("The resilient class metadata bounds have not been initialized.")
            }
            return immediate + vtableOffset
        }
    }

    private static func read<T: FixedWidthInteger>(_ address: UInt) throws -> T {
        var value: T = 0
        guard ABIReadMemory(address, MemoryLayout<T>.size, &value).status == ABIMemoryReadComplete else {
            throw ABIResolutionError.invalidAddress
        }
        return value
    }
    private static func add(_ address: UInt, _ offset: Int) throws -> UInt {
        let result = offset >= 0 ? address.addingReportingOverflow(UInt(offset))
            : address.subtractingReportingOverflow(offset.magnitude)
        guard !result.overflow else { throw ABIResolutionError.invalidAddress }
        return result.partialValue
    }
    private static func relative(_ field: UInt) throws -> UInt {
        let offset: Int32 = try read(field)
        return offset == 0 ? 0 : try add(field, Int(offset))
    }
    private static func indirect(_ field: UInt, discriminator: UInt) throws -> UInt {
        let offset: Int32 = try read(field)
        guard offset != 0 else { throw ABIResolutionError.invalidAddress }
        let address = try add(field, Int(offset & ~1))
        return offset & 1 == 0 ? address : try pointer(address, discriminator: discriminator)
    }
    private static func pointer(_ field: UInt, discriminator: UInt) throws -> UInt {
        let _: UInt = try read(field)
        guard let pointer = ABIUnsafeReadAuthenticatedPointer(UnsafeRawPointer(bitPattern: field),
            Int32(ABIAuthenticationDataA), discriminator, true) else { throw ABIResolutionError.invalidAddress }
        return UInt(bitPattern: pointer)
    }
}
