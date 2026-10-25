import ABIBridgeCore
import ABIBridgeCore.Backend
import ObjectiveC
import Foundation

package struct RuntimeClassDispatch {
    package let address: UInt
    package let authentication: RuntimePointerAuthentication
    /// Whether the slot holds an async function pointer instead of code.
    package let isAsync: Bool
    /// The image of the class whose descriptor introduces the slot.
    package let image: RuntimeImage

    /// The virtual-table entry that calls of `declaration` read in the
    /// metadata of `metadata`, which can inherit or override it.
    ///
    /// The class that introduces an entry describes it with a method
    /// descriptor, which a symbol names after the declaration; an override
    /// reuses the entry it overrides, which its class's override table
    /// records. Both descriptors are named from the declaration's record by
    /// the remangler: the declaration's own, then the same member of each
    /// ancestor class, never from a spelling of the declaration.
    ///
    /// - Parameters:
    ///   - declaration: The record of the declaration, or of the dispatch
    ///     thunk that dispatches it.
    ///   - asynchronous: The requested effect, when known. An entry with
    ///     another effect does not apply, and the method descriptor decides
    ///     that before the class layout is decoded.
    package init(
        metadata: Any.Type,
        declaration: RuntimeSwiftDeclaration,
        resolver: RuntimeSymbolResolver,
        asynchronous: Bool? = false
    ) throws {
        guard let selected = metadata as? AnyClass else {
            throw Self.unsupported("Virtual dispatch requires a Swift class member.")
        }
        guard let entity = SwiftEntitySyntax(declaration.identity) else {
            throw Self.unsupported("Cannot decode the declaration " + declaration.identity + ".")
        }
        // A class member's slot holds its implementation for the metatype.
        let isClassMember = declaration.isStatic
        let selectedAddress = UInt(bitPattern: unsafeBitCast(selected, to: UnsafeRawPointer.self))
        let selectedHeader = try Header(address: selectedAddress)
        var current: AnyClass? = selected
        var declaring: UInt?
        while let type = current {
            let header = try Header(
                address: UInt(bitPattern: unsafeBitCast(type, to: UnsafeRawPointer.self))
            )
            if let classDescriptor = header.descriptor {
                let image = try runtimeClassImage(
                    type,
                    named: runtimeClassTypeName(type),
                    resolver: resolver
                )
                let context = Self.context(of: type, descriptor: classDescriptor, in: image, resolver)
                if declaring == nil, let context, entity.isDeclared(in: context) {
                    declaring = classDescriptor
                }
                if let declaringDescriptor = declaring, let context,
                    let name = entity.methodDescriptor(in: context),
                    let found = try Self.symbol(named: name, in: image, resolver)
                {
                    let method = UInt(found.address)
                    // The descriptor decides the effect before any layout is
                    // decoded, so a member with another effect yields to other
                    // candidates even when its class's layout is unsupported.
                    let flags: UInt32 = try Self.read(method)
                    let isAsync = flags & 0x40 != 0
                    if let asynchronous, asynchronous != isAsync {
                        throw RuntimeResolutionError.signatureMismatch(
                            .init(
                                expected: asynchronous ? "async" : "synchronous",
                                found: [isAsync ? "async" : "synchronous"]
                            )
                        )
                    }
                    let layout = try Descriptor(address: classDescriptor)
                    guard method >= layout.methods,
                        method - layout.methods < UInt(layout.count * 8),
                        (method - layout.methods) % 8 == 0
                    else {
                        throw Self.unsupported(
                            "The method descriptor is outside its declaring class's virtual table description."
                        )
                    }
                    // A same-named ancestor can be inaccessible to this
                    // declaration. Only an override record establishes that
                    // it introduces this declaration's inherited slot.
                    let declaringLayout = try Descriptor(address: declaringDescriptor)
                    guard
                        try declaringLayout.address == layout.address
                            || declaringLayout.overrides(method)
                    else {
                        throw Self.unsupported(
                            "The selected declaration does not override this superclass method descriptor."
                        )
                    }
                    let offset = try layout.offset() + Int(method - layout.methods) / 8 * Self.word
                    let kind = flags & 0xf
                    let isInstance = flags & 0x10 != 0
                    guard isInstance != isClassMember, [0, 2, 3].contains(kind) else {
                        throw Self.unsupported(
                            "This virtual descriptor is not a matching method, getter or setter."
                        )
                    }
                    guard offset >= -selectedHeader.addressPoint,
                        offset <= selectedHeader.size - selectedHeader.addressPoint - Self.word
                    else {
                        throw Self.unsupported(
                            "The virtual entry lies outside the selected class metadata allocation."
                        )
                    }
                    address = try Self.add(selectedAddress, offset)
                    authentication =
                        RuntimePointerAuthentication.isEnabled
                        ? .signed(
                            key: isAsync ? .dataA : .instructionA,
                            discriminator: UInt(flags >> 16),
                            addressDiversity: true
                        ) : .unsigned
                    self.image = image
                    self.isAsync = isAsync
                    return
                }
            }
            current = class_getSuperclass(type)
        }
        guard declaring != nil else {
            throw Self.unsupported(
                "No class of the lookup type's hierarchy declares this member, so it has no class slot; members of extensions have none."
            )
        }
        throw Self.unsupported(
            "No introducing virtual method descriptor matches this declaration. Direct, final, and static members have no class slot; stripped or differently lowered descriptors require an adapter."
        )
    }

    /// The symbol named `name` in `image`, nil when the image has none.
    private static func symbol(
        named name: String,
        in image: RuntimeImage,
        _ resolver: RuntimeSymbolResolver
    ) throws -> RuntimeSymbol? {
        do {
            return try resolver.resolve(
                RuntimeDeclaration(machOName: "_" + name, language: .swift, kind: .data),
                in: image,
                loading: .loadedOnly
            )
        } catch RuntimeResolutionError.declarationNotFound {
            return nil
        }
    }

    /// The tree that names `type` as the context of its members, preferring
    /// its nominal type descriptor's symbol over its runtime mangling.
    /// Runtime manglings can omit constrained-extension generic requirements
    /// or encode a private or local context by its address instead of its
    /// declaration, so that fallback may not identify the declared context.
    private static func context(
        of type: AnyClass,
        descriptor: UInt,
        in image: RuntimeImage,
        _ resolver: RuntimeSymbolResolver
    ) -> SwiftTypeSyntax? {
        let mangled =
            resolver.swiftTypeDeclaration(at: UInt64(descriptor), in: image)
            ?? _mangledTypeName(type)
        return mangled.flatMap(SwiftTypeSyntax.init)
    }

    package static func nominalDescriptor(of type: AnyClass) throws -> UInt? {
        try Header(address: UInt(bitPattern: unsafeBitCast(type, to: UnsafeRawPointer.self)))
            .descriptor
    }

    private static let word = MemoryLayout<UInt>.size
    private static func unsupported(_ message: String) -> RuntimeResolutionError {
        .unsupportedDeclaration(message)
    }

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
                throw unsupported(
                    "Generic class descriptor tails require a separate metadata layout adapter."
                )
            }
            var tail = address + 44
            if flags & 0x20000000 != 0 { tail += 4 }  // Resilient superclass reference.
            switch (flags >> 16) & 3 {
            case 0: break
            case 1: tail += 12  // Singleton metadata initialization.
            case 2: tail += 4  // Foreign metadata initialization.
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
            } else {
                overrideCount = 0; overrideEntries = tail
            }
        }

        func overrides(_ method: UInt) throws -> Bool {
            for index in 0..<overrideCount {
                let field = overrideEntries + UInt(index * 12 + 4)
                let offset: Int32 = try read(field)
                guard offset != 0 else { throw RuntimeResolutionError.invalidAddress }
                let target = try add(field, Int(offset & ~1))
                let descriptor =
                    offset & 1 == 0 ? target : try pointer(target, discriminator: 26458)
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
        guard ABIReadMemory(address, MemoryLayout<T>.size, &value).status == ABIMemoryReadComplete
        else {
            throw RuntimeResolutionError.invalidAddress
        }
        return value
    }
    private static func add(_ address: UInt, _ offset: Int) throws -> UInt {
        let result =
            offset >= 0
            ? address.addingReportingOverflow(UInt(offset))
            : address.subtractingReportingOverflow(offset.magnitude)
        guard !result.overflow else { throw RuntimeResolutionError.invalidAddress }
        return result.partialValue
    }
    private static func relative(_ field: UInt) throws -> UInt {
        let offset: Int32 = try read(field)
        return offset == 0 ? 0 : try add(field, Int(offset))
    }
    private static func pointer(_ field: UInt, discriminator: UInt) throws -> UInt {
        let _: UInt = try read(field)
        guard
            let pointer = ABIUnsafeReadAuthenticatedPointer(
                UnsafeRawPointer(bitPattern: field),
                Int32(ABIAuthenticationDataA),
                discriminator,
                true
            )
        else { throw RuntimeResolutionError.invalidAddress }
        return UInt(bitPattern: pointer)
    }
}

package func runtimeClassImage(
    _ type: AnyClass,
    named name: String,
    resolver: RuntimeSymbolResolver
) throws -> RuntimeImage {
    // A live class has one defining image. Retaining that image also prevents
    // class-address reuse; this does not cache user-supplied filesystem selectors.
    try resolver.image(forSwiftClass: type) {
        guard let path = class_getImageName(type) else {
            throw RuntimeResolutionError.declarationNotFound(
                .init(name: "nominal type descriptor for " + name, language: .swift, kind: .data)
            )
        }
        let images = try resolver.images(
            matching: .path(URL(fileURLWithPath: String(cString: path)))
        )
        guard let image = images.first else { throw RuntimeResolutionError.imageNotLoaded }
        return image
    }
}

package func runtimeTypeDeclarationName(
    _ type: Any.Type,
    in image: RuntimeImage,
    suggestedName: String,
    resolver: RuntimeSymbolResolver
) throws -> String {
    guard let descriptor = ABISwiftTypeDescriptor(unsafeBitCast(type, to: UnsafeRawPointer.self))
    else { return suggestedName }
    return try resolver.swiftNominalTypeName(
        at: UInt64(UInt(bitPattern: descriptor)),
        in: image,
        suggestedName: suggestedName
    ) ?? suggestedName
}

package func runtimeClassTypeName(_ type: AnyClass) -> String {
    guard let mangled = _mangledTypeName(type),
        let name = DeclarationKey.demangle("$s" + mangled, language: .swift)
    else {
        return String(reflecting: type)
    }
    return name
}

/// A parsed Swift declaration, whose member can be named in the context of
/// another class.
private final class SwiftEntitySyntax {
    private let syntax: OpaquePointer
    private let entity: OpaquePointer
    private let context: OpaquePointer

    init?(_ mangled: String) {
        guard
            let syntax = mangled.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftSymbolSyntax($0.baseAddress, $0.count - 1)
            })
        else { return nil }
        self.syntax = syntax
        guard let root = ABISwiftSyntaxRoot(syntax),
            String(cString: ABISwiftSyntaxNodeKind(root)) == "Global",
            ABISwiftSyntaxNodeChildCount(root) == 1, let entity = ABISwiftSyntaxNodeChild(root, 0),
            let context = ABISwiftSyntaxEntityContext(entity)
        else {
            ABIReleaseSwiftSyntax(syntax)
            return nil
        }
        self.entity = entity
        self.context = context
    }

    deinit { ABIReleaseSwiftSyntax(syntax) }

    /// Whether `type` is the context that declares this member.
    func isDeclared(in type: SwiftTypeSyntax) -> Bool {
        withExtendedLifetime(type) { ABISwiftSyntaxNodesEqual(context, type.root) }
    }

    /// The mangled name of the method descriptor of the same member
    /// declared in `type`, as the remangler spells it.
    func methodDescriptor(in type: SwiftTypeSyntax) -> String? {
        withExtendedLifetime(type) {
            guard let name = ABICopySwiftMethodDescriptorSymbolName(entity, type.root) else {
                return nil
            }
            defer { ABIFreeString(name) }
            return String(cString: name)
        }
    }
}

/// A parsed Swift type mangling.
private final class SwiftTypeSyntax {
    private let syntax: OpaquePointer
    let root: OpaquePointer

    init?(_ mangled: String) {
        guard
            let syntax = mangled.utf8CString.withUnsafeBufferPointer({
                ABICopySwiftTypeSyntax($0.baseAddress, $0.count - 1)
            })
        else { return nil }
        guard let root = ABISwiftSyntaxRoot(syntax) else {
            ABIReleaseSwiftSyntax(syntax)
            return nil
        }
        self.syntax = syntax
        self.root = root
    }

    deinit { ABIReleaseSwiftSyntax(syntax) }
}
