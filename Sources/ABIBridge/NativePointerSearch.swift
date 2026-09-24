import ABIBridgeCore

/// Interpretation of data-address bits for inspection, never authentication.
public enum NativePointerNormalization: Int32, Sendable {
    /// Compare and read the stored address bits unchanged.
    case none = 0
    /// Strip data-address signatures, including when plain arm64 inspects arm64e data.
    ///
    /// Requires a 64-bit ARM CPU with pointer authentication. This does not
    /// verify signatures or produce authenticated function-call targets.
    case stripDataSignature = 1
    /// Strip data signatures when the current CPU supports pointer authentication.
    ///
    /// On other CPUs, or when capability detection is unavailable, address bits
    /// remain unchanged. This does not authenticate pointers or remove arbitrary tags.
    case automatic = 2
}

/// Whether to inspect every eligible slot or stop at a matching candidate.
public enum NativePointerSearchPolicy: Int32, Sendable {
    /// Scan every eligible slot, including when a valid hint matches.
    case all = 0
    /// Stop at the first match, prioritizing a valid hint; makes no uniqueness claim.
    case first = 1
}

/// A setup failure, distinct from recoverable reads reported by the result.
public enum NativePointerSearchError: Error, Sendable {
    /// Invalid range, stride, alignment, vptr offset, or null address point.
    case invalidOptions
    /// The current architecture or CPU cannot perform requested normalization.
    case normalizationUnavailable
    /// The native result could not be allocated.
    case allocationFailed
}

/// Caller-supplied layout and search policy for native-width absolute pointers.
public struct NativePointerSearchOptions: Sendable {
    /// First slot offset within the region.
    public var firstOffset: Int
    /// Positive byte step between eligible slots.
    public var stride: Int
    /// Power-of-two alignment for slot addresses; stride must be a multiple.
    public var alignment: Int
    /// Byte offset of the absolute vptr inside each pointee.
    public var vptrOffset: Int
    /// Interpretation of slot values, vptr values, and the expected address point.
    public var normalization: NativePointerNormalization
    /// Exhaustive scan or first observed match.
    public var policy: NativePointerSearchPolicy
    /// Revalidated hint, scoped by the caller to the region lifetime, layout,
    /// and target identity. Invalid or off-grid hints are ignored.
    public var hintOffset: Int?

    /// Defaults to aligned pointer-sized slots, a vptr at zero, and an exhaustive
    /// search with automatic normalization. No vtable header length is inferred.
    public init(
        firstOffset: Int = 0, stride: Int = MemoryLayout<UInt>.size,
        alignment: Int = MemoryLayout<UInt>.alignment, vptrOffset: Int = 0,
        normalization: NativePointerNormalization = .automatic,
        policy: NativePointerSearchPolicy = .all, hintOffset: Int? = nil
    ) {
        self.firstOffset = firstOffset
        self.stride = stride
        self.alignment = alignment
        self.vptrOffset = vptrOffset
        self.normalization = normalization
        self.policy = policy
        self.hintOffset = hintOffset
    }
}

/// Evidence for one matching slot, retaining the enclosing region's owner.
///
/// Multiple slots may alias the same ``addressForInspection``. The owner must
/// also keep the pointee alive for later receiver use. A vtable match does not
/// prove object validity or authenticate a pointer.
public struct NativePointerCandidate {
    /// The slot's byte offset within the search region.
    public let offset: Int
    /// Original storage address, needed for address-diversified authentication.
    public let slotAddress: UInt
    /// Original slot bits before normalization.
    public let pointerBits: UInt
    /// Normalized address used for recoverable inspection, not authenticated dispatch.
    public let addressForInspection: UInt
    /// Original vptr storage address inside the candidate.
    public let vptrAddress: UInt
    /// Original vptr bits before normalization.
    public let vptrBits: UInt
    /// The enclosing region, retaining its optional owner.
    public let sourceRegion: NativeMemoryRegion
}

/// A slot or pointee read failure, collected by searches or thrown by single-slot inspection.
public struct NativePointerSearchFailure: Error, Sendable {
    /// The read that failed.
    public enum Stage: Int32, Sendable {
        /// Could not copy the pointer slot.
        case slot = 0
        /// Could not copy the pointee's vptr.
        case vptr = 1
    }
    /// Source-slot offset within the region.
    public let offset: Int
    /// Whether the slot or its pointee could not be read.
    public let stage: Stage
    /// Attempted address, or the pointee base when adding vptrOffset overflowed.
    public let address: UInt
    /// The underlying bounded-read outcome.
    public let status: NativeMemoryReadStatus
    /// Successfully copied bytes in this incomplete pointer read.
    public let copiedByteCount: Int
    /// Original Mach error, or zero for a range error or short successful read.
    public let systemErrorCode: Int32
}

/// Observed matching slots and failures from a non-atomic search.
public struct NativePointerSearchResult {
    /// Every observed matching slot, including aliases, ordered by source offset.
    public let candidates: [NativePointerCandidate]
    /// Unreadable slots and pointees, ordered by source offset.
    public let failures: [NativePointerSearchFailure]
    /// Number of different normalized pointee addresses among observed matches.
    public let distinctCount: Int
    /// Number of visited slots, including a visited hint and failures.
    public let visitedCount: Int
    /// True only after scanning every eligible slot without read failures.
    /// Stopping at a first match always returns false.
    public let isComplete: Bool
    /// The first alias only when a complete scan observed exactly one target.
    public var uniqueCandidate: NativePointerCandidate? {
        isComplete && distinctCount == 1 ? candidates.first : nil
    }
}

extension NativeMemoryRegion {
    /// Revalidates one slot without searching elsewhere in this region.
    ///
    /// The slot may be unaligned but must fit entirely inside the region.
    /// A null reference or readable unequal vptr returns nil. A match makes no
    /// uniqueness claim and retains this region's optional owner. Reads are
    /// non-atomic; callers synchronize and establish the pointee's lifetime.
    ///
    /// - Parameters:
    ///   - offset: Byte offset of the full-width pointer slot.
    ///   - addressPoint: The actual vtable address point.
    ///   - vptrOffset: Byte offset of the absolute vptr within the pointee.
    ///   - normalization: Interpretation of slot and vptr bits for inspection;
    ///     defaults to automatic selection for the current CPU.
    /// - Returns: Matching evidence, or nil for a readable nonmatch.
    /// - Throws: ``NativePointerSearchError`` for invalid setup, or
    ///   ``NativePointerSearchFailure`` when the slot or pointee cannot be read.
    public func pointer(
        at offset: Int, toVTable addressPoint: UInt, vptrOffset: Int = 0,
        normalization: NativePointerNormalization = .automatic
    ) throws -> NativePointerCandidate? {
        guard offset >= 0, vptrOffset >= 0 else { throw NativePointerSearchError.invalidOptions }
        return try withExtendedLifetime(self) {
            let result = ABIInspectPointer(address, byteCount, offset, addressPoint, vptrOffset, normalization.rawValue)
            switch result.status {
            case Int32(ABIPointerInspectionMatch):
                return NativePointerCandidate(result.candidate, in: self)
            case Int32(ABIPointerInspectionNoMatch):
                return nil
            case Int32(ABIPointerInspectionReadFailed):
                throw NativePointerSearchFailure(result.failure)
            case Int32(ABIPointerInspectionNormalizationUnavailable):
                throw NativePointerSearchError.normalizationUnavailable
            default:
                throw NativePointerSearchError.invalidOptions
            }
        }
    }

    /// Finds references whose absolute vptr matches an explicit address point.
    ///
    /// Only full-width slots inside the declared range are visited. Null
    /// references are skipped. Failed reads are collected while the scan
    /// continues. Even a complete result is not atomic; callers synchronize.
    ///
    /// A matching hint can short-circuit only ``NativePointerSearchPolicy/first``.
    /// Cached offsets must be invalidated on region lifetime, layout, or target
    /// changes; each call re-reads both the slot and pointee at the hinted offset.
    ///
    /// - Parameters:
    ///   - addressPoint: The actual vtable address point, not its symbol base.
    ///   - options: Slot layout, vptr offset, normalization, policy, and optional hint.
    /// - Returns: Evidence retaining this region's owner through its candidates.
    /// - Throws: ``NativePointerSearchError`` if setup fails. Memory read failures
    ///   are represented by ``NativePointerSearchResult/failures``.
    public func pointers(
        toVTable addressPoint: UInt, options: NativePointerSearchOptions = .init()
    ) throws -> NativePointerSearchResult {
        guard options.firstOffset >= 0, options.stride > 0,
              options.alignment > 0, options.vptrOffset >= 0 else {
            throw NativePointerSearchError.invalidOptions
        }
        var query = ABIPointerSearchOptions(
            address: address, byteCount: byteCount, firstOffset: options.firstOffset,
            stride: options.stride, alignment: options.alignment,
            vtableAddressPoint: addressPoint, vptrOffset: options.vptrOffset,
            normalization: options.normalization.rawValue, policy: options.policy.rawValue,
            hintOffset: options.hintOffset.flatMap { $0 >= 0 ? $0 : nil } ?? -1
        )
        return try withExtendedLifetime(self) {
            var error: Int32 = 0
            guard let result = ABICopyPointerSearch(&query, &error) else {
                switch error {
                case Int32(ABIPointerSearchNormalizationUnavailable):
                    throw NativePointerSearchError.normalizationUnavailable
                case Int32(ABIPointerSearchAllocationFailed):
                    throw NativePointerSearchError.allocationFailed
                default: throw NativePointerSearchError.invalidOptions
                }
            }
            defer { ABIFreePointerSearch(result) }
            let candidates = (0..<ABIPointerSearchCandidateCount(result)).map { index in
                let value = ABIPointerSearchCandidateAt(result, index)
                return NativePointerCandidate(value, in: self)
            }
            let failures = (0..<ABIPointerSearchFailureCount(result)).map { index in
                let value = ABIPointerSearchFailureAt(result, index)
                return NativePointerSearchFailure(value)
            }
            return NativePointerSearchResult(
                candidates: candidates, failures: failures,
                distinctCount: ABIPointerSearchDistinctCount(result),
                visitedCount: ABIPointerSearchVisitedCount(result),
                isComplete: ABIPointerSearchIsComplete(result) != 0
            )
        }
    }
}

private extension NativePointerCandidate {
    init(_ value: ABIPointerCandidate, in region: NativeMemoryRegion) {
        self.init(
            offset: value.offset, slotAddress: value.slotAddress, pointerBits: value.pointerBits,
            addressForInspection: value.addressForInspection, vptrAddress: value.vptrAddress,
            vptrBits: value.vptrBits, sourceRegion: region
        )
    }
}

private extension NativePointerSearchFailure {
    init(_ value: ABIPointerSearchFailure) {
        self.init(
            offset: value.offset, stage: .init(rawValue: value.stage)!, address: value.address,
            status: .init(rawValue: value.read.status)!, copiedByteCount: value.read.byteCount,
            systemErrorCode: value.read.systemError
        )
    }
}
