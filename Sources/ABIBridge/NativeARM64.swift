/// Address-producing ARM64 instructions used by native reference discovery.
///
/// Decoding reads no memory. Addresses follow AArch64's wrapping 64-bit arithmetic.
/// Register 31 denotes SP or the zero register as specified by the instruction.
public enum NativeARM64Instruction: Sendable, Equatable {
    /// ADRP produces the base of a 4 KiB page.
    case pageAddress(register: Int, address: UInt64)
    /// ADR produces a PC-relative address.
    case address(register: Int, address: UInt64)
    /// A 64-bit ADD with an unsigned immediate, including its optional shift.
    case addImmediate(destination: Int, source: Int, immediate: UInt64)
    /// A 32-bit or 64-bit LDR with an unsigned, scaled immediate.
    case load(destination: Int, base: Int, offset: UInt64, byteCount: Int)
    /// BL calls a PC-relative address.
    case call(address: UInt64)

    /// Decodes one instruction at its original, four-byte-aligned PC.
    ///
    /// Returns nil for another instruction encoding or an unaligned PC.
    public init?(encoding: UInt32, at address: UInt64) {
        guard address & 3 == 0 else { return nil }
        let destination = Int(encoding & 31)
        let source = Int((encoding >> 5) & 31)
        if encoding & 0x1f00_0000 == 0x1000_0000 {
            let immediate =
                UInt64((encoding >> 5) & 0x7ffff) << 2
                | UInt64((encoding >> 29) & 3)
            let displacement = Self.signExtend(immediate, bits: 21)
            if encoding & 0x8000_0000 != 0 {
                self = .pageAddress(
                    register: destination,
                    address: (address & ~UInt64(4095)) &+ (displacement << 12)
                )
            } else {
                self = .address(register: destination, address: address &+ displacement)
            }
        } else if encoding & 0xff80_0000 == 0x9100_0000 {
            let shift = (encoding >> 22) & 1 == 0 ? 0 : 12
            self = .addImmediate(
                destination: destination,
                source: source,
                immediate: UInt64((encoding >> 10) & 4095) << shift
            )
        } else if encoding & 0xffc0_0000 == 0xf940_0000
            || encoding & 0xffc0_0000 == 0xb940_0000
        {
            let byteCount = encoding >> 30 == 3 ? 8 : 4
            self = .load(
                destination: destination,
                base: source,
                offset: UInt64((encoding >> 10) & 4095) * UInt64(byteCount),
                byteCount: byteCount
            )
        } else if encoding & 0xfc00_0000 == 0x9400_0000 {
            let displacement = Self.signExtend(UInt64(encoding & 0x03ff_ffff), bits: 26) << 2
            self = .call(address: address &+ displacement)
        } else {
            return nil
        }
    }

    private static func signExtend(_ value: UInt64, bits: Int) -> UInt64 {
        let sign = UInt64(1) << (bits - 1)
        return (value ^ sign) &- sign
    }
}

/// A statically calculated reference, not evidence that its target is mapped or live.
public struct NativeARM64Reference: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// ADR or ADD forms an address.
        case address
        /// LDR reads this many bytes from the target address.
        case load(byteCount: Int)
        /// BL names a direct call target.
        case call
    }
    /// Original PC of the instruction that forms or uses the target address.
    public let instructionAddress: UInt64
    /// The calculated 64-bit target; no pointer authentication is performed.
    public let targetAddress: UInt64
    public let kind: Kind
}

/// Reference evidence and the bounded memory read from which it was obtained.
public struct NativeARM64ReferenceResult: Sendable {
    public let references: [NativeARM64Reference]
    /// Preserves partial reads and their original Mach error.
    public let memory: NativeMemoryReadResult
    /// Complete four-byte instructions examined; trailing bytes are not interpreted.
    public var instructionByteCount: Int { memory.bytes.count / 4 * 4 }
}

/// The supplied region does not start on an ARM64 instruction boundary.
public enum NativeARM64ReferenceError: Error, Sendable, Equatable {
    case unalignedAddress(UInt)
}

extension NativeMemoryRegion {
    /// Finds address and load references and direct calls in a bounded ARM64 code range.
    ///
    /// Reads the region once through the recoverable memory reader, then examines complete
    /// little-endian instructions in address order. ADR/ADRP and 64-bit ADD propagate known
    /// register addresses; LDR reports its source address without dereferencing it.
    /// NOP preserves known registers. A call or any other instruction clears them.
    ///
    /// This is limited straight-line analysis, not control-flow recovery or emulation.
    /// References after a branch may belong to an unreachable path. Unknown instructions
    /// can hide additional references. The result does not claim to find every reference.
    /// Supply code bounds and synchronization; neither referenced data nor callees are read.
    ///
    /// - Throws: An unaligned region throws NativeARM64ReferenceError before reading.
    public func arm64References() throws -> NativeARM64ReferenceResult {
        guard address & 3 == 0 else { throw NativeARM64ReferenceError.unalignedAddress(address) }
        let memory = read()
        var registers = [UInt64?](repeating: nil, count: 31)
        var references: [NativeARM64Reference] = []
        memory.bytes.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: bytes.count / 4 * 4, by: 4) {
                let encoding = UInt32(
                    littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                )
                let pc = UInt64(address) + UInt64(offset)
                if encoding == 0xd503_201f { continue }  // NOP
                guard let instruction = NativeARM64Instruction(encoding: encoding, at: pc) else {
                    registers = [UInt64?](repeating: nil, count: 31)
                    continue
                }
                switch instruction {
                case .pageAddress(let register, let target):
                    if register < 31 { registers[register] = target }
                case .address(let register, let target):
                    if register < 31 {
                        registers[register] = target
                        references.append(
                            .init(instructionAddress: pc, targetAddress: target, kind: .address)
                        )
                    }
                case .addImmediate(let destination, let source, let immediate):
                    let target = source < 31 ? registers[source].map { $0 &+ immediate } : nil
                    if destination < 31 {
                        registers[destination] = target
                        if let target {
                            references.append(
                                .init(instructionAddress: pc, targetAddress: target, kind: .address)
                            )
                        }
                    }
                case .load(let destination, let base, let offset, let byteCount):
                    if base < 31, let target = registers[base] {
                        references.append(
                            .init(
                                instructionAddress: pc,
                                targetAddress: target &+ offset,
                                kind: .load(byteCount: byteCount)
                            )
                        )
                    }
                    if destination < 31 { registers[destination] = nil }
                case .call(let target):
                    references.append(
                        .init(instructionAddress: pc, targetAddress: target, kind: .call)
                    )
                    registers = [UInt64?](repeating: nil, count: 31)
                }
            }
        }
        return NativeARM64ReferenceResult(references: references, memory: memory)
    }
}
