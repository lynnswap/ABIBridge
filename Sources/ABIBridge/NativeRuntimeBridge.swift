import ABIBridgeRuntime

extension ResolvedSymbol {
    /// Acquires a Swift symbol from a borrowed native inspection handle.
    ///
    /// The handle must be a live, non-null `ABIResolvedSymbol *` returned by this
    /// library and remain alive during this call. This initializer does not consume
    /// its reference. The result independently retains the same image and metadata
    /// without repeating lookup; the native handle can then be released.
    ///
    /// - Parameter handle: A borrowed symbol from the C inspection interface.
    @unsafe public init(retainingNativeHandle handle: OpaquePointer) {
        self.init(unsafe RuntimeSymbol(retainingNativeHandle: handle))
    }

    /// Creates an owned native inspection handle for this resolved symbol.
    ///
    /// The returned `ABIResolvedSymbol *` owns one reference. Transfer it to a
    /// native owner or release it exactly once with `ABIReleaseResolvedSymbol`.
    /// It retains this symbol's image and metadata independently of the Swift
    /// value and runtime caches, without repeating lookup.
    ///
    /// - Returns: An owned, non-null C inspection handle.
    @unsafe public func copyNativeHandle() -> OpaquePointer {
        unsafe runtimeValue.copyNativeHandle()
    }
}
