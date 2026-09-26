import ArchitectureFixtures
import Darwin
import Foundation
import MachOKit

private struct ImportProbeSlot {
    let address: UnsafeMutableRawPointer
    let format: String
    var key: Int32 = -1
    var extra: UInt = 0
    var diverse = false
}

@MainActor func validateImportReplacement() throws -> [String] {
    func failure(_ message: String) -> ArchitectureValidationFailure { .init(description: message) }
    guard let header = ABIImportProbeImage() else { throw failure("Import fixture image unavailable") }
    let image = MachOImage(ptr: header.assumingMemoryBound(to: mach_header.self))
    var location = Dl_info()
    guard dladdr(header, &location) != 0, let path = location.dli_fname,
          let slide = image.vmaddrSlide else { throw failure("Import fixture path/slide unavailable") }
    let file = try MachOFile(url: URL(fileURLWithPath: String(cString: path)))
    let fileUUID = file.loadCommands.compactMap { if case .uuid(let value) = $0 { value.uuid } else { nil } }.first
    let imageUUID = image.loadCommands.compactMap { if case .uuid(let value) = $0 { value.uuid } else { nil } }.first
    guard file.header.layout.cputype == image.header.layout.cputype,
          file.header.layout.cpusubtype == image.header.layout.cpusubtype,
          let fileUUID, fileUUID == imageUUID else {
        throw failure("Import fixture file does not identify the loaded image")
    }
    // Only this compiled, zero-addend function import is mutated. The general
    // import index and provider/ordinal matching belong to a later delivery.
    let name = "_getppid"
    var slots: [ImportProbeSlot] = []
    if let fixups = file.dyldChainedFixups {
        guard let starts = fixups.startsInImage else { throw failure("Fixture chain starts unavailable") }
        // Zero segment-info offsets denote segments without chains.
        for segment in fixups.startsInSegments(of: starts) where segment.offset != starts.offset {
            for pointer in fixups.pointers(of: segment, in: file) {
                guard let bind = pointer.fixupInfo.bind,
                      fixups.imports.indices.contains(bind.ordinal) else { continue }
                let item = fixups.imports[bind.ordinal].info
                guard fixups.symbolName(for: item.nameOffset) == name else { continue }
                guard bind.addend == 0, item.addend == 0 else { throw failure("Fixture import has a nonzero addend") }
                var slot = ImportProbeSlot(address: UnsafeMutableRawPointer(mutating: header).advanced(by: pointer.offset),
                    format: "chained \(pointer.fixupInfo.pointerFormat)")
                if let auth = bind as? DyldChainedPtrArm64eAuthBind {
                    slot.key = Int32(auth.layout.key); slot.extra = UInt(auth.layout.diversity); slot.diverse = auth.layout.addrDiv != 0
                } else if let auth = bind as? DyldChainedPtrArm64eAuthBind24 {
                    slot.key = Int32(auth.layout.key); slot.extra = UInt(auth.layout.diversity); slot.diverse = auth.layout.addrDiv != 0
                } else if bind.isAuth { throw failure("Fixture import has an unhandled authentication format") }
                slots.append(slot)
            }
        }
    } else {
        guard !ABIValidationPACCompiled() else { throw failure("Authenticated legacy import schema requires a separate fixture") }
        for bind in image.bindingSymbols + image.lazyBindingSymbols where bind.symbolName == name {
            guard let address = bind.address(in: image), bind.addend == 0,
                  let pointer = UnsafeMutableRawPointer(bitPattern: Int(address) + slide) else {
                throw failure("Fixture bind address/addend unavailable")
            }
            slots.append(ImportProbeSlot(address: pointer, format: "legacy bind"))
        }
    }
    guard slots.count == 1 else { throw failure("Expected one fixture import, found \(slots.count)") }
    let slot = slots[0]
    var result = ABIImportProbeResult()
    if let error = ABIValidateImportSlot(slot.address, slot.key, slot.extra, slot.diverse, &result) {
        throw failure("Imported slot (\(slot.format)): " + String(cString: error))
    }
    let outcome = result.changed ? "replacement and captured predecessor passed" : "kernel refused TPRO mutation (\(result.protectionResult)); no slot changed"
    var checks = ["Imported getppid: \(outcome); \(slot.format), key=\(slot.key), discriminator=\(slot.extra), addressDiversity=\(slot.diverse), regionFlags=\(result.regionFlags), protection=\(result.protectionBefore)->\(result.protectionAfter), maximum=\(result.maximumBefore)->\(result.maximumAfter)"]
    if let error = ABIValidateReadOnlySignedSlot(&result) { throw failure("Read-only control: " + String(cString: error)) }
    guard result.changed else { throw failure("Read-only control was not replaced") }
    checks.append("Read-only control replacement/predecessor/restoration: PAC=\(ABIValidationPACCompiled()), addressDiversity=true, protection=\(result.protectionBefore)->\(result.protectionAfter), maximum=\(result.maximumBefore)->\(result.maximumAfter)")
    return checks
}
