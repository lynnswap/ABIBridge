import ABIBridgeCore

extension NativeVTable {
    /// One selected absolute entry, retaining its bounded table and metadata image. This describes a slot; capturing a callable reads its current contents.
    public struct Entry {
        /// The zero-based offset from this table's address point.
        public let index: Int
        /// The function-pointer schema recorded in the original fixup or adapter.
        public let authentication: NativePointerAuthentication
        /// The original method or adjustment-thunk symbol, when metadata is available.
        public let symbolName: String?
        /// The source declaration used for named selection; nil for an explicit adapter entry. This does not identify an already replaced live target.
        public let declaration: NativeDeclaration?
        let table: NativeVTable
        let image: NativeImage?
    }

    /// Selects an entry by its qualified implementation declaration.
    ///
    /// Include argument types and qualifiers, such as `Example::Derived::value(int) const`. Selection reads the loaded image's original fixups and symbols, preserving secondary and covariant-return thunk identity and authentication. Existing hooks do not change selection.
    ///
    /// Use ``entry(at:authentication:)`` adapter metadata for stripped identities, missing files, ambiguous aliases, or unsupported layouts. Construction of this view establishes table bounds and the subobject; the name does not establish class layout or a method signature.
    ///
    /// Known null slots in the original image can still be selected by name. A live zero alone cannot identify a missing original entry.
    public nonisolated func entry(
        named name: String, using runtime: ABIRuntime = .shared
    ) throws -> Entry {
        let address = unsafe storage.withUnsafeBytes { UInt(bitPattern: $0.baseAddress!) }
        let result = try runtime.virtualEntry(
            named: name,
            addressPoint: address,
            entryCount: entryCount
        )
        return Entry(index: result.index, authentication: result.authentication, symbolName: result.symbol, declaration: .init(name: name, language: .cxx), table: self, image: result.image)
    }

    /// Selects a bounded slot using a target-specific native adapter's schema. The caller establishes the absolute-table format and actual authentication identity. This does not inspect the current target or infer a signature.
    @unsafe public func entry(at index: Int, authentication: NativePointerAuthentication) throws -> Entry {
        guard index >= 0, index < entryCount else {
            throw NativeDispatchError.entryOutOfBounds(index: index, count: entryCount)
        }
        return Entry(index: index, authentication: authentication, symbolName: nil, declaration: nil, table: self, image: nil)
    }
}

extension ABIRuntime {
    nonisolated func virtualEntry(
        named name: String, addressPoint: UInt, entryCount: Int
    ) throws -> VirtualEntryResolution {
        try resolver.virtualEntry(named: name, addressPoint: addressPoint, entryCount: entryCount)
    }
}
