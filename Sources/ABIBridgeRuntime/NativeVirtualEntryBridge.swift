import ABIBridgeCore
import Foundation

private final class NativeVirtualEntryBox {
    let info: ABIVirtualEntryInfo
    let resolution: RuntimeVirtualEntryResolution
    let symbol: UnsafeMutablePointer<CChar>
    init(info: ABIVirtualEntryInfo, resolution: RuntimeVirtualEntryResolution) {
        self.info = info
        self.resolution = resolution
        symbol = strdup(resolution.symbol)!
    }
    deinit { free(symbol) }
}

@c(ABICopyVirtualEntry)
package func copyVirtualEntry(
    _ runtime: OpaquePointer,
    _ addressPoint: UnsafeRawPointer?,
    _ entryCount: UInt,
    _ name: UnsafePointer<CChar>,
    _ error: UnsafeMutablePointer<OpaquePointer?>?
) -> OpaquePointer? {
    do {
        guard let addressPoint, let count = Int(exactly: entryCount) else {
            throw RuntimeResolutionError.invalidAddress
        }
        let resolver = Unmanaged<RuntimeSymbolResolver>.fromOpaque(UnsafeRawPointer(runtime))
            .takeUnretainedValue()
        let result = try resolver.virtualEntry(
            named: String(cString: name),
            addressPoint: UInt(bitPattern: addressPoint),
            entryCount: count
        )
        let auth = result.authentication
        let info = ABIVirtualEntryInfo(
            addressPoint: addressPoint,
            entryCount: count,
            index: result.index,
            key: auth.keyCode,
            discriminator: auth.discriminator,
            addressDiversity: auth.addressDiversity
        )
        error?.pointee = nil
        return OpaquePointer(
            Unmanaged.passRetained(NativeVirtualEntryBox(info: info, resolution: result)).toOpaque()
        )
    } catch let failure {
        if let error { error.pointee = nativeFailure(failure) }
        return nil
    }
}

@c(ABIVirtualEntryGet)
package func virtualEntryGet(_ entry: OpaquePointer) -> ABIVirtualEntryInfo {
    Unmanaged<NativeVirtualEntryBox>.fromOpaque(UnsafeRawPointer(entry)).takeUnretainedValue().info
}

@c(ABIVirtualEntrySymbolName)
package func virtualEntrySymbolName(_ entry: OpaquePointer) -> UnsafePointer<CChar> {
    UnsafePointer(
        Unmanaged<NativeVirtualEntryBox>.fromOpaque(UnsafeRawPointer(entry)).takeUnretainedValue()
            .symbol
    )
}

@c(ABIReleaseVirtualEntry)
package func releaseVirtualEntry(_ entry: OpaquePointer?) {
    if let entry { Unmanaged<NativeVirtualEntryBox>.fromOpaque(UnsafeRawPointer(entry)).release() }
}
