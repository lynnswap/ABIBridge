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
        let member = try SwiftMemberLookup.qualifiedName(name, owner: rootName)
        guard SwiftMemberLookup.belongs(member, to: rootName) else {
            throw ABIResolutionError.unsupportedDeclaration(
                "The writable key path property must belong to " + rootName + "."
            )
        }
        let declaration = NativeDeclaration(
            name: "property descriptor for " + member + " : "
                + (try swiftNativeTypeName(valueType.metadata)),
            language: .swift,
            kind: .data
        )
        let descriptor: ResolvedSymbol
        if SymbolIndex.extensionMemberName(member) != nil {
            descriptor = try resolver.resolve(declaration, in: .automatic, loading: .loadedOnly)
        } else {
            descriptor = try resolver.resolve(declaration, in: image, loading: .loadedOnly)
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
