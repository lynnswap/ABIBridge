import ABIBridgeRuntime
import ABIBridgeCore
import Foundation

/// A copied symbol name recorded by a lazy-load dependency.
///
/// This describes an import, not a resolved address, storage kind, or call signature.
public struct NativeLazySymbol: Sendable {
    /// The exact recorded spelling, or nil for an unreadable string.
    public let rawName: String?
    /// A demangled Swift/C++ name, or the original name without a Mach-O underscore.
    /// Nil means that the recorded string could not be read.
    public let name: String?

    init(rawName: String?) {
        self.rawName = rawName
        name = rawName.map {
            DeclarationKey.demangle($0, language: .swift)
                ?? DeclarationKey.demangle($0, language: .cxx)
                ?? DeclarationKey.demangle($0, language: .c)!
        }
    }
}

/// Copied diagnostics for one `LC_LAZY_LOAD_DYLIB_INFO` command.
///
/// Optional fields represent unavailable metadata. An empty symbols array means
/// the command records no symbols; nil means the array could not be read.
/// Results contain no borrowed addresses and may outlive their source image.
public struct NativeLazyLibrary: Sendable {
    /// Byte offset of the command from its Mach-O header.
    public let commandOffset: UInt64
    /// The recorded install path, including any unresolved loader tokens.
    public let path: String?
    /// Whether dyld allows this dependency to be absent, or nil if unknown.
    public let isOptional: Bool?
    /// Whether symbols were prebound, independently of library initialization.
    public let areSymbolsPrebound: Bool?
    /// Whether dyld's live initialized flag was nonzero when copied.
    /// Always nil for file inspection; disk contents cannot establish live state.
    public let isInitialized: Bool?
    /// Symbol names in their recorded order. Individual unreadable strings have nil names.
    public let symbols: [NativeLazySymbol]?
}

extension ABIRuntime {
    /// Copies lazy-load dependency diagnostics from a retained image.
    ///
    /// Reading does not load a dependency or walk its mutable binding chain.
    /// The initialized flag is an observation, not synchronization with dyld.
    /// Malformed command payloads remain represented with unavailable fields.
    /// - Parameter image: The loaded image declaring the dependencies.
    /// - Returns: Commands in load-command order, or an empty array if none exist.
    /// - Throws: `ABIResolutionError.metadataUnavailable` if the header or command table cannot be read.
    public func lazyLibraries(in image: NativeImage) throws -> [NativeLazyLibrary] {
        try withRuntimeErrors {
            try LazyLibraryReader.read(image: image.runtimeValue).map(NativeLazyLibrary.init)
        }
    }
}

extension ABIRuntime {
    /// Copies lazy-load metadata from a thin Mach-O file without loading it.
    ///
    /// Results do not claim that any recorded library is initialized in the
    /// current process. Universal/fat files are not accepted by this operation.
    /// - Parameter url: A thin Mach-O file, which is read into owned storage.
    /// - Returns: One diagnostic value per lazy-load command, including malformed payloads.
    /// - Throws: The file-reading error, or `ABIResolutionError.metadataUnavailable` for an invalid container.
    public func lazyLibraries(inFileAt url: URL) throws -> [NativeLazyLibrary] {
        try withRuntimeErrors { try LazyLibraryReader.read(file: url).map(NativeLazyLibrary.init) }
    }
}

extension NativeLazyLibrary {
    init(_ value: RuntimeLazyLibrary) {
        self.init(
            commandOffset: value.commandOffset,
            path: value.path,
            isOptional: value.isOptional,
            areSymbolsPrebound: value.areSymbolsPrebound,
            isInitialized: value.isInitialized,
            symbols: value.symbols?.map { NativeLazySymbol(rawName: $0.rawName) }
        )
    }
}
