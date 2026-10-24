import ABIBridgeCore
import ABIBridgeRuntime
import Foundation

extension NativeSwiftType {
    /// Resolves an owned Swift writable key path to a computed instance property.
    ///
    /// The key path preserves the native property's identity and accessors. Its concrete
    /// root and value types need not be available at compile time. This supports
    /// non-generic roots with a nontrivial, writable property descriptor without
    /// captured arguments. Trivial descriptors and generic property contexts are unsupported.
    ///
    /// Lookup and descriptor preparation run on a worker. The owned value is created
    /// on the caller's executor and retains the root, value, and property implementation images.
    /// Applying the extracted key path calls the native accessors synchronously. Use it
    /// on the actor or thread required by the property; it does not perform an actor hop.
    /// To use the result with KVC/KVO, supply the property's Objective-C key through
    /// `keyValueCodingKey`. The caller must provide the key for this same property;
    /// resolution does not verify that correspondence. KVC and KVO apply their usual runtime requirements.
    /// - Parameters:
    ///   - name: A property name in this type's image, or a complete property name such as
    ///     `(extension in Module):OtherModule.Root.property` for an already-loaded extension.
    ///   - valueType: The property's actual value type, checked against its descriptor declaration.
    ///   - keyValueCodingKey: The property's Objective-C KVC key, including any `@objc` rename.
    ///     Nil omits the KVC compatibility string.
    /// - Returns: A `NativeSwiftValue` containing the concrete `Swift.WritableKeyPath`,
    ///   or its `Swift.ReferenceWritableKeyPath` subclass for a nonmutating setter.
    /// - Throws: A lookup error or an unsupported property descriptor error.
    public nonisolated(nonsending) func resolveWritableKeyPath(
        named name: String,
        valueType: NativeSwiftType,
        keyValueCodingKey: String? = nil
    ) async throws -> NativeSwiftValue {
        let prepared = try await NativePreparation.run {
            try self.prepareWritableKeyPath(
                named: name,
                valueType: valueType,
                keyValueCodingKey: keyValueCodingKey
            )
        }
        return try makeWritableKeyPath(prepared, valueType: valueType)
    }

    /// Resolves a writable key path synchronously on the caller's thread.
    ///
    /// This has the same property, type, and ownership contract as
    /// `resolveWritableKeyPath(named:valueType:keyValueCodingKey:)`. Lookup and preparation can block.
    public nonisolated func resolveWritableKeyPathAndWait(
        named name: String,
        valueType: NativeSwiftType,
        keyValueCodingKey: String? = nil
    ) throws -> NativeSwiftValue {
        let prepared = try prepareWritableKeyPath(
            named: name,
            valueType: valueType,
            keyValueCodingKey: keyValueCodingKey
        )
        return try makeWritableKeyPath(prepared, valueType: valueType)
    }

    private nonisolated func prepareWritableKeyPath(
        named name: String,
        valueType: NativeSwiftType,
        keyValueCodingKey: String?
    ) throws -> (plan: RuntimeWritableKeyPathPlan, image: NativeImage) {
        let generic = try genericMetadata ?? SwiftGenericTypeMetadata(metadata: metadata)
        guard generic.arguments.isEmpty, SwiftGenericSyntax.groups(in: name).isEmpty else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Writable key path resolution does not support generic root or property contexts."
            )
        }
        let rootName = try swiftNativeTypeName(metadata)
        let query = try SwiftMemberQuery(
            .init(role: .getter, isStatic: false, name: name, options: .init())
        ).inContext(of: rootName)
        if query.qualifier != nil, !SwiftMemberLookup.belongs(name, to: rootName) {
            throw ABIResolutionError.unsupportedDeclaration(
                "The writable key path property must belong to " + rootName + "."
            )
        }
        guard !query.isComplete else {
            throw ABIResolutionError.unsupportedDeclaration(
                "Name the writable key path's property by its name, such as text."
            )
        }
        // The diagnostics' spelling of the property.
        let displayed = NativeDeclaration(
            name: query.qualifier == nil ? rootName + "." + query.member : name,
            language: .swift,
            kind: .data
        )
        // A property's descriptor is one of its member entries, which the
        // records of the root's members select, as for its accessors. The
        // root's image declares its own properties; an extension's are found
        // in the loaded images.
        guard let path = SwiftMemberPath(owner: rootName, member: query.member) else {
            throw ABIResolutionError.declarationNotFound(displayed)
        }
        func candidates(includingSharedCache: Bool) throws -> [SwiftCandidate] {
            let tiers =
                query.includesOwnerExtension ? [false, true] : [query.extensionModule != nil]
            for extensionsOnly in tiers {
                let found = try resolver.swiftMemberCandidates(
                    SwiftMemberMatch(
                        path: path,
                        accessor: nil,
                        isStatic: false,
                        initializer: .excluded,
                        entry: .propertyDescriptor
                    ),
                    owner: rootName,
                    in: extensionsOnly ? nil : image,
                    extensionsOnly: extensionsOnly,
                    includingSharedCache: includingSharedCache
                ).filter { $0.record.kind == .variable && query.isDeclared(by: $0.record) }
                if !found.isEmpty { return found }
            }
            return []
        }
        // As for members, the images can hold another extension's property
        // of that name while only the shared cache's local symbols describe
        // the requested one.
        var descriptors = try candidates(includingSharedCache: false)
        if descriptors.isEmpty { descriptors = try candidates(includingSharedCache: true) }
        guard descriptors.count <= 1 else {
            throw ABIResolutionError.ambiguousDeclaration(
                displayed,
                candidates: descriptors.map(\.symbol.linkageName)
            )
        }
        guard let selected = descriptors.first else {
            throw ABIResolutionError.declarationNotFound(displayed)
        }
        let descriptor = selected.symbol
        // The descriptor's declared type, which its symbol spells, is the
        // value type.
        let context = ABISwiftTypeDescriptor(unsafeBitCast(metadata, to: UnsafeRawPointer.self))
        guard let declared = selected.record.declaredType,
            let declaredType = declared.withCString({
                ABISwiftTypeForMangledName($0, strlen($0), context, nil)
            })
        else {
            throw ABIResolutionError.metadataUnavailable(
                descriptor.declaration.name + ": its declared type cannot be resolved."
            )
        }
        guard declaredType == unsafeBitCast(valueType.metadata, to: UnsafeRawPointer.self) else {
            throw ABIResolutionError.signatureMismatch(
                .init(
                    declaration: displayed,
                    position: .result,
                    expected: valueType.name,
                    found: [descriptor.declaration.name]
                )
            )
        }
        let plan = try withRuntimeErrors {
            try RuntimeWritableKeyPathPlan(
                descriptor: descriptor.runtimeValue,
                root: metadata,
                value: valueType.metadata,
                keyValueCodingKey: keyValueCodingKey
            )
        }
        return (plan, descriptor.image)
    }

    private nonisolated func makeWritableKeyPath(
        _ prepared: (plan: RuntimeWritableKeyPathPlan, image: NativeImage),
        valueType: NativeSwiftType
    ) throws -> NativeSwiftValue {
        var keyPath = prepared.plan.instantiate()
        let keyPathType = try swiftRuntimeValueType(
            metadata: Swift.type(of: keyPath),
            retaining: [self, valueType]
        )
        SwiftValueCodeLifetime.connect([keyPathType.codeLifetime], retaining: [prepared.image])
        return try withUnsafePointer(to: &keyPath) {
            try NativeSwiftValue.copy(from: $0, type: keyPathType)
        }
    }
}
