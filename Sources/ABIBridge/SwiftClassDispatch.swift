import ABIBridgeCore
import ObjectiveC

/// Reads the stable Swift class ABI, not the current contents of virtual slots.
/// Resolve the introducing descriptor by declaration: unrelated optimized
/// methods can share code addresses, and current slots can contain interposers.
/// Layouts follow swift/ABI/Metadata.h; arm64e descriptor-pointer constants
/// and method discriminators are also checked against compiler-generated IR.
struct SwiftClassDispatch {
    let address: UInt
    let authentication: NativePointerAuthentication
    let isSetter: Bool

    let descriptor: ResolvedSymbol

    init(metadata: Any.Type, declaration: NativeDeclaration, resolver: SymbolResolver) throws {
        guard let selected = metadata as? AnyClass else {
            throw Self.unsupported("Virtual replacement requires a Swift class instance method.")
        }
        let selectedAddress = UInt(bitPattern: unsafeBitCast(selected, to: UnsafeRawPointer.self))
        let selectedHeader = try Header(address: selectedAddress)
        var current: AnyClass? = selected
        var member: String?
        var declaringLayout: Descriptor?
        while let type = current {
            let runtimeName = try swiftFunctionTypeName(type)
            let image = try swiftClassImage(type, named: runtimeName, resolver: resolver)
            let name = try swiftClassDeclarationName(type, in: image, suggestedName: runtimeName, resolver: resolver)
            let isDeclarationOwner = member == nil && declaration.name.hasPrefix(name + ".")
            if isDeclarationOwner {
                member = String(declaration.name.dropFirst(name.count + 1))
            }
            if let member {
                let header = try Header(address: UInt(bitPattern: unsafeBitCast(type, to: UnsafeRawPointer.self)))
                if let classDescriptor = header.descriptor {
                    if isDeclarationOwner { declaringLayout = try Descriptor(address: classDescriptor) }
                    let request = NativeDeclaration(name: "method descriptor for " + name + "." + member,
                        language: .swift, kind: .data)
                    let resolved: ResolvedSymbol?
                    do { resolved = try resolver.resolve(request, in: image, loading: .loadedOnly) }
                    catch ABIResolutionError.declarationNotFound { resolved = nil }
                    if let resolved {
                        let layout = try Descriptor(address: classDescriptor)
                        let method = UInt(resolved.address)
                        guard method >= layout.methods, method - layout.methods < UInt(layout.count * 8),
                              (method - layout.methods) % 8 == 0 else {
                            throw Self.unsupported("The method descriptor is outside its declaring class's virtual table description.")
                        }
                        guard let declaringLayout else {
                            throw Self.unsupported("The selected declaration has no established class metadata layout.")
                        }
                        // A same-named ancestor can be inaccessible to this
                        // declaration. Only an override record establishes that
                        // it introduces this declaration's inherited slot.
                        guard try declaringLayout.address == layout.address || declaringLayout.overrides(method) else {
                            throw Self.unsupported("The selected declaration does not override this superclass method descriptor.")
                        }
                        let offset = try layout.offset() + Int(method - layout.methods) / 8 * Self.word
                        let flags: UInt32 = try Self.read(method)
                        let kind = flags & 0xf
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
                        descriptor = resolved
                        isSetter = kind == 3
                        return
                    }
                }
            }
            current = class_getSuperclass(type)
        }
        throw Self.unsupported("No introducing virtual method descriptor matches this declaration. Direct and final methods have no class slot; stripped or differently lowered descriptors require an adapter.")
    }

    static func nominalDescriptor(of type: AnyClass) throws -> UInt? {
        try Header(address: UInt(bitPattern: unsafeBitCast(type, to: UnsafeRawPointer.self))).descriptor
    }

    private static let word = MemoryLayout<UInt>.size
    private static func unsupported(_ message: String) -> ABIResolutionError { .unsupportedDeclaration(message) }

    private struct Header {
        let descriptor: UInt?
        let size: Int
        let addressPoint: Int
        init(address: UInt) throws {
            // AnyClass uses ObjCClassWrapper metadata for imported classes.
            // That two-word record has no Swift class header or descriptor.
            let kind: UInt = try read(address)
            guard kind != 0x305 else { descriptor = nil; size = 0; addressPoint = 0; return }
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
        let vtableOffset: Int
        let overrideEntries: UInt
        let overrideCount: Int

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
                overrideEntries = tail + 4
            } else { overrideCount = 0; overrideEntries = tail }
        }

        func overrides(_ method: UInt) throws -> Bool {
            for index in 0..<overrideCount {
                let field = overrideEntries + UInt(index * 12 + 4)
                let offset: Int32 = try read(field)
                guard offset != 0 else { throw ABIResolutionError.invalidAddress }
                let target = try add(field, Int(offset & ~1))
                let descriptor = offset & 1 == 0 ? target : try pointer(target, discriminator: 26458)
                if descriptor == method { return true }
            }
            return false
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
    private static func pointer(_ field: UInt, discriminator: UInt) throws -> UInt {
        let _: UInt = try read(field)
        guard let pointer = ABIUnsafeReadAuthenticatedPointer(UnsafeRawPointer(bitPattern: field),
            Int32(ABIAuthenticationDataA), discriminator, true) else { throw ABIResolutionError.invalidAddress }
        return UInt(bitPattern: pointer)
    }
}
