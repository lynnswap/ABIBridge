import ABIBridgeRuntime

/// The CPU fields recorded in a loaded image's Mach-O header.
///
/// Raw values preserve unknown architectures and all CPU subtype capability bits.
public struct NativeImageArchitecture: Sendable, Hashable {
    /// The header's CPU type, including its architecture flags.
    public let cpuType: Int32
    /// The complete CPU subtype, including capability bits.
    public let cpuSubtype: Int32
}

/// A section's recorded name and extent in the current process.
///
/// The range includes the image's slide. It describes storage, not its current readability or the layout of values within it. Keep the source image retained while using its addresses.
public struct NativeImageSection: Sendable, Hashable {
    /// The segment name recorded by the section.
    public let segmentName: String
    /// The section name recorded in the image.
    public let name: String
    /// The section's half-open address range after applying the image's slide.
    public let addressRange: Range<UInt64>
}

/// Copied image metadata together with the image that keeps its addresses valid.
///
/// Retaining this value retains the same image generation. Extracted address arrays and ranges do not carry that ownership; retain ``image`` when using them with ``NativeMemoryRegion``. Recorded function starts do not establish a function's size, signature, or calling convention.
public struct NativeImageMetadata: Sendable {
    /// The retained source image.
    public let image: NativeImage
    /// Whether the image uses a 64-bit Mach-O header, independently of pointer size.
    public let is64Bit: Bool
    /// The CPU fields from the image's header.
    public let architecture: NativeImageArchitecture
    /// Sections in load-command order, including zero-length sections.
    public let sections: [NativeImageSection]
    /// Function starts recorded by `LC_FUNCTION_STARTS`, as addresses in the current process.
    ///
    /// Nil means the command is absent. An empty array means it records no starts. A malformed or unreadable table fails metadata resolution instead of producing an empty array. Entries follow their recorded order and have the image's slide applied once.
    public let functionStartAddresses: [UInt64]?

    init(_ value: RuntimeImageMetadata) {
        image = NativeImage(value.image)
        is64Bit = value.is64Bit
        architecture = NativeImageArchitecture(
            cpuType: value.architecture.cpuType,
            cpuSubtype: value.architecture.cpuSubtype
        )
        sections = value.sections.map {
            NativeImageSection(
                segmentName: $0.segmentName,
                name: $0.name,
                addressRange: $0.addressRange
            )
        }
        functionStartAddresses = value.functionStartAddresses
    }
}

extension ABIRuntime {
    /// Copies architecture, section, and function-start metadata from a retained loaded image.
    ///
    /// Inspection runs on the caller's thread and does not load dependencies or prepare symbol indexes. The result retains the source image. It does not establish current memory protections or a callable ABI.
    /// - Parameter image: The loaded image to inspect.
    /// - Returns: Copied metadata with section and function-start addresses relocated into the current process.
    /// - Throws: `ABIResolutionError.metadataUnavailable` when required metadata is unreadable, malformed, or cannot be represented as process addresses. A malformed function-start table fails the entire operation; an absent command remains nil in the result.
    public nonisolated func resolveImageMetadataAndWait(
        in image: NativeImage
    ) throws -> NativeImageMetadata {
        try withRuntimeErrors {
            NativeImageMetadata(try ImageMetadataReader.read(image: image.runtimeValue))
        }
    }

    /// Copies loaded-image metadata on a worker queue while the caller suspends.
    ///
    /// This has the same ownership and failure contract as `resolveImageMetadataAndWait(in:)`. Neither form requires earlier preparation.
    public nonisolated func resolveImageMetadata(
        in image: NativeImage
    ) async throws -> NativeImageMetadata {
        try await NativePreparation.run { try self.resolveImageMetadataAndWait(in: image) }
    }
}
