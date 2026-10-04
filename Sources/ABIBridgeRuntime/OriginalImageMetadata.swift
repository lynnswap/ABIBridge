import Foundation
import MachO
import MachOKit
import Darwin

package struct OriginalImageMetadata {
    package let image: RuntimeImage
    package let file: MachOFile

    package init(image: RuntimeImage) throws {
        self.image = image
        let macho = MachOImage(
            ptr: UnsafePointer<mach_header>(bitPattern: UInt(image.identity.headerAddress))!
        )
        let files: [MachOFile]
        do {
            switch try MachOKit.loadFromFile(url: URL(fileURLWithPath: image.path)) {
            case .machO(let file): files = [file]
            case .fat(let file): files = try file.machOFiles()
            }
        } catch {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original file for \(image.path) is unavailable: \(error)"
            )
        }
        guard let uuid = image.identity.uuid,
            let file = files.first(where: { file in
                file.header.layout.cputype == macho.header.layout.cputype
                    && file.header.layout.cpusubtype == macho.header.layout.cpusubtype
                    && file.loadCommands.contains {
                        if case .uuid(let command) = $0 { command.uuid == uuid } else { false }
                    }
            })
        else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original file does not match the loaded image: \(image.path)"
            )
        }
        self.file = file
    }

    package struct Pointer {
        package let pointer: DyldChainedFixupPointer
        package let address: UInt64
        package let width: Int
    }

    package func openReadHandle() throws -> FileHandle {
        let handle = try FileHandle(forReadingFrom: file.url)
        let header = try Self.read(mach_header.self, from: handle, at: file.headerStartOffset)
        guard header.cputype == file.header.layout.cputype,
            header.cpusubtype == file.header.layout.cpusubtype,
            let uuid = file.loadCommands.compactMap({ command -> UUIDCommand? in
                if case .uuid(let value) = command { return value }
                return nil
            }).first
        else { throw unavailable("original pointer bytes have no matching architecture or UUID") }
        let command = try Self.read(
            uuid_command.self,
            from: handle,
            at: file.cmdsStartOffset + uuid.offset
        )
        guard command.cmd == LC_UUID, UUID(uuid: command.uuid) == image.identity.uuid else {
            throw unavailable("original pointer bytes do not match the loaded image")
        }
        return handle
    }

    package static func read<Value: BitwiseCopyable>(
        _ type: Value.Type,
        from handle: FileHandle,
        at offset: Int
    ) throws -> Value {
        var data = Data(count: MemoryLayout<Value>.size)
        let count = data.withUnsafeMutableBytes {
            pread(handle.fileDescriptor, $0.baseAddress, $0.count, off_t(offset))
        }
        guard count == data.count else {
            let reason =
                count < 0
                ? NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
                : "truncated original pointer bytes"
            throw RuntimeResolutionError.metadataUnavailable(reason)
        }
        return data.withUnsafeBytes { $0.loadUnaligned(as: Value.self) }
    }

    package func chainedPointers() throws -> [Pointer] {
        guard let fixups = file.dyldChainedFixups, let starts = fixups.startsInImage else {
            throw RuntimeResolutionError.metadataUnavailable(
                "Original chained fixups are unavailable: \(image.path)"
            )
        }
        let segments = file.segments.map {
            (
                address: UInt64($0.virtualMemoryAddress), size: UInt64($0.virtualMemorySize),
                file: UInt64($0.fileOffset)
            )
        }
        var result: [Pointer] = []
        for segment in fixups.startsInSegments(of: starts) where segment.offset != starts.offset {
            guard let format = segment.pointerFormat else {
                throw unavailable("unknown chained pointer format")
            }
            let width: Int
            switch format {
            case ._32: width = 4
            case ._64, ._64_offset, .arm64e, .arm64e_kernel, .arm64e_firmware, .arm64e_userland,
                .arm64e_userland24:
                width = 8
            default: throw unavailable("unsupported chained pointer format \(format)")
            }
            guard segments.indices.contains(segment.segmentIndex) else {
                throw unavailable("chain segment is out of range")
            }
            let extent = segments[segment.segmentIndex]
            // MachOKit 0.53 walks segment_offset as a file offset; zero-fill
            // makes that differ from the VM offset encoded in the command.
            var fileSegment = segment
            fileSegment.layout.segment_offset = extent.file
            guard !fixups.pages(of: segment).contains(where: { !$0.isNone && $0.isMulti }) else {
                throw unavailable(
                    "the file walker cannot decode multi-start chain overflow entries"
                )
            }
            for pointer in fixups.pointers(of: fileSegment, in: file) {
                guard pointer.offset >= 0, UInt64(pointer.offset) >= extent.file else {
                    throw unavailable("invalid chain offset")
                }
                let offset = UInt64(pointer.offset) - extent.file
                guard offset <= extent.size, UInt64(width) <= extent.size - offset else {
                    throw unavailable("fixup exceeds its segment")
                }
                let unslid = extent.address.addingReportingOverflow(offset)
                guard !unslid.overflow else { throw unavailable("fixup address overflow") }
                let slid = Int64(bitPattern: unslid.partialValue).addingReportingOverflow(
                    image.identity.slide
                )
                guard !slid.overflow else { throw unavailable("fixup slide overflow") }
                result.append(
                    Pointer(
                        pointer: pointer,
                        address: UInt64(bitPattern: slid.partialValue),
                        width: width
                    )
                )
            }
        }
        return result
    }

    package static func authentication(
        _ bind: any DyldChainedPointerContentBind
    ) throws -> RuntimePointerAuthentication {
        if let auth = bind as? DyldChainedPtrArm64eAuthBind {
            return try schema(
                key: Int32(auth.layout.key),
                discriminator: UInt(auth.layout.diversity),
                addressDiversity: auth.layout.addrDiv != 0
            )
        }
        if let auth = bind as? DyldChainedPtrArm64eAuthBind24 {
            return try schema(
                key: Int32(auth.layout.key),
                discriminator: UInt(auth.layout.diversity),
                addressDiversity: auth.layout.addrDiv != 0
            )
        }
        guard !bind.isAuth else {
            throw RuntimeResolutionError.metadataUnavailable("Unknown authenticated bind")
        }
        return .unsigned
    }

    package static func authentication(
        _ rebase: any DyldChainedPointerContentRebase
    ) throws -> RuntimePointerAuthentication {
        if let auth = rebase as? DyldChainedPtrArm64eAuthRebase {
            return try schema(
                key: Int32(auth.layout.key),
                discriminator: UInt(auth.layout.diversity),
                addressDiversity: auth.layout.addrDiv != 0
            )
        }
        guard !rebase.isAuth else {
            throw RuntimeResolutionError.metadataUnavailable("Unknown authenticated rebase")
        }
        return .unsigned
    }

    private static func schema(
        key: Int32,
        discriminator: UInt,
        addressDiversity: Bool
    ) throws -> RuntimePointerAuthentication {
        guard let key = RuntimePointerAuthentication.Key(rawValue: key) else {
            throw RuntimeResolutionError.metadataUnavailable("Unknown authentication key")
        }
        return .signed(key: key, discriminator: discriminator, addressDiversity: addressDiversity)
    }

    private func unavailable(_ message: String) -> RuntimeResolutionError {
        .metadataUnavailable("Original fixups in \(image.path): \(message)")
    }
}
