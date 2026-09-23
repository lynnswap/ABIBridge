import ABIBridgeCore

/// A range that cannot be represented or lies outside its enclosing region.
public enum NativeMemoryError: Error, Sendable, Equatable {
    /// A negative byte count or an overflowing half-open address range.
    case invalidRange(address: UInt, byteCount: Int)
    /// A requested subrange exceeds the region's explicit extent.
    case outOfBounds(offset: Int, byteCount: Int, regionSize: Int)
}

/// The outcome of copying current-process native memory.
public enum NativeMemoryReadStatus: Int32, Sendable {
    /// All requested bytes were copied, including an empty request.
    case complete = 0
    /// No bytes were copied because the range was invalid.
    case invalidRange = 1
    /// Reading failed before a complete page chunk could be copied.
    case failed = 2
    /// Only a prefix of the requested range was copied.
    case partial = 3
}

/// Owned copied bytes and the outcome of reading them.
///
/// The bytes remain available after the region and its owner are released.
/// A complete read is not atomic and does not establish object validity,
/// pointee ownership, or continued readability of the original address.
public struct NativeMemoryReadResult: Sendable {
    /// The current-process address where copying began.
    public let sourceAddress: UInt
    /// The requested extent, which may exceed the number of copied bytes.
    public let requestedByteCount: Int
    /// The successfully copied prefix. No bytes from a failed chunk are exposed.
    public let bytes: [UInt8]
    /// Whether the read completed or stopped early.
    public let status: NativeMemoryReadStatus
    /// The original Mach kern_return_t, or zero when no OS error occurred.
    public let systemErrorCode: Int32
    /// Whether every requested byte was copied.
    public var isComplete: Bool { status == .complete }
}

/// A bounded current-process address range with an optional lifetime owner.
///
/// Creating a region does not access memory or promise that it is readable.
/// Callers supply allocation bounds, pointee ownership, and synchronization.
/// Retaining an owner alone cannot prevent its storage from moving or being
/// destroyed explicitly. Unlike ``NativeValue``, reads return copied bytes.
public struct NativeMemoryRegion {
    /// The numeric address of the first byte in the current process.
    public let address: UInt
    /// The explicit size of this region.
    public let byteCount: Int
    private let owner: Any?

    /// Describes a region without dereferencing its address.
    ///
    /// - Parameters:
    ///   - address: An address in the current process.
    ///   - byteCount: A nonnegative extent whose half-open end does not overflow.
    ///   - owner: A value retained by every copy of the region.
    /// - Throws: ``NativeMemoryError/invalidRange(address:byteCount:)`` for an invalid extent.
    public init(address: UInt, byteCount: Int, retaining owner: Any? = nil) throws {
        guard byteCount >= 0, !address.addingReportingOverflow(UInt(byteCount)).overflow else {
            throw NativeMemoryError.invalidRange(address: address, byteCount: byteCount)
        }
        self.address = address
        self.byteCount = byteCount
        self.owner = owner
    }

    /// Copies this region up to the first failed page.
    ///
    /// Inspect ``NativeMemoryReadResult/status`` and
    /// ``NativeMemoryReadResult/systemErrorCode`` for recoverable read failures.
    /// A zero-length region succeeds without accessing memory.
    public func read() -> NativeMemoryReadResult {
        copy(offset: 0, count: byteCount)
    }

    /// Copies a subrange, reporting inaccessible memory in the result.
    ///
    /// - Throws: ``NativeMemoryError/outOfBounds(offset:byteCount:regionSize:)``
    ///   if the requested subrange exceeds this region, before accessing memory.
    public func read(at offset: Int, byteCount count: Int) throws -> NativeMemoryReadResult {
        guard offset >= 0, count >= 0, offset <= byteCount, count <= byteCount - offset else {
            throw NativeMemoryError.outOfBounds(offset: offset, byteCount: count, regionSize: byteCount)
        }
        return copy(offset: offset, count: count)
    }

    private func copy(offset: Int, count: Int) -> NativeMemoryReadResult {
        withExtendedLifetime(owner) {
            var bytes = [UInt8](repeating: 0, count: count)
            let result = bytes.withUnsafeMutableBytes {
                ABIReadMemory(address + UInt(offset), count, $0.baseAddress)
            }
            bytes.removeLast(count - result.byteCount)
            return NativeMemoryReadResult(
                sourceAddress: address + UInt(offset), requestedByteCount: count,
                bytes: bytes, status: NativeMemoryReadStatus(rawValue: result.status)!,
                systemErrorCode: result.systemError
            )
        }
    }
}
