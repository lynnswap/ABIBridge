import ABIBridgeCore

extension NativeVTable {
    /// One selected absolute entry, retaining its bounded table and metadata image.
    /// This describes a slot; capturing a callable reads its current contents.
    public struct Entry {
        /// The zero-based offset from this table's address point.
        public let index: Int
        /// The function-pointer schema recorded in the original fixup or adapter.
        public let authentication: NativePointerAuthentication
        /// The original method or adjustment-thunk symbol, when metadata is available.
        public let symbolName: String?
        /// The source declaration used for named selection; nil for an explicit
        /// adapter entry. This does not identify an already replaced live target.
        public let declaration: NativeDeclaration?
        let table: NativeVTable
        let image: NativeImage?
    }

    /// Selects an entry by its qualified implementation declaration, including
    /// argument types and qualifiers, such as `Example::Derived::value(int) const`.
    ///
    /// Reads the matching loaded image's original chained fixups and symbols.
    /// Secondary/covariant thunks keep their slot identity and authentication.
    /// Existing hooks do not affect selection. Repeated queries share the runtime's
    /// retained table owner and normalized original declarations. Stripped identities, missing files, ambiguous aliases and
    /// unsupported layouts require ``entry(at:authentication:)`` adapter metadata.
    /// The table bounds and subobject were established when constructing this view;
    /// neither class layouts nor method signatures are inferred from the name.
    /// Known null slots in the original image do not prevent named selection.
    /// A live zero does not establish a missing original entry's identity.
    public nonisolated(nonsending) func entry(
        named name: String, using runtime: ABIRuntime = .shared
    ) async throws -> Entry {
        let address = unsafe storage.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
        let result = try await runtime.virtualEntry(named: name, addressPoint: address, entryCount: entryCount)
        return Entry(index: result.index, authentication: result.authentication, symbolName: result.symbol, declaration: .init(name: name, language: .cxx), table: self, image: result.image)
    }

    /// Selects a bounded slot using a target-specific native adapter's schema.
    /// The caller establishes the absolute-table format and actual authentication
    /// identity. This does not inspect the current target or infer a signature.
    @unsafe public func entry(at index: Int, authentication: NativePointerAuthentication) throws -> Entry {
        guard index >= 0, index < entryCount else {
            throw NativeDispatchError.entryOutOfBounds(index: index, count: entryCount)
        }
        return Entry(index: index, authentication: authentication, symbolName: nil, declaration: nil, table: self, image: nil)
    }
}

extension ABIRuntime {
    func virtualEntry(named name: String, addressPoint: UInt, entryCount: Int) throws -> VirtualEntryResolution {
        try resolver.virtualEntry(named: name, addressPoint: addressPoint, entryCount: entryCount)
    }
}
