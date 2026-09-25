import ABIBridgeCore
import Foundation

private final class LazyLibraryBox {
    var strings: [UnsafeMutablePointer<CChar>] = []
    var infos: [ABILazyLibraryInfo] = []
    var symbols: [[ABILazySymbolInfo]] = []

    init(_ entries: [NativeLazyLibrary]) {
        func boolean(_ value: Bool?) -> Int32 { value.map { $0 ? 1 : 0 } ?? -1 }
        for entry in entries {
            infos.append(ABILazyLibraryInfo(
                commandOffset: entry.commandOffset, path: copy(entry.path),
                isOptional: boolean(entry.isOptional), areSymbolsPrebound: boolean(entry.areSymbolsPrebound),
                isInitialized: boolean(entry.isInitialized), symbolsAvailable: entry.symbols == nil ? 0 : 1,
                symbolCount: entry.symbols?.count ?? 0
            ))
            symbols.append((entry.symbols ?? []).map { .init(name: copy($0.name), rawName: copy($0.rawName)) })
        }
    }

    private func copy(_ value: String?) -> UnsafePointer<CChar>? {
        guard let value else { return nil }
        let copy = strdup(value)!
        strings.append(copy)
        return UnsafePointer(copy)
    }

    deinit { for string in strings { free(string) } }
}

private func box(_ handle: OpaquePointer) -> LazyLibraryBox {
    Unmanaged<LazyLibraryBox>.fromOpaque(UnsafeRawPointer(handle)).takeUnretainedValue()
}

private func copyLibraries(_ error: UnsafeMutablePointer<OpaquePointer?>?, _ body: () throws -> [NativeLazyLibrary]) -> OpaquePointer? {
    error?.pointee = nil
    do { return OpaquePointer(Unmanaged.passRetained(LazyLibraryBox(try body())).toOpaque()) }
    catch let failure { error?.pointee = nativeFailure(failure); return nil }
}

@_cdecl("ABICopyLazyLibrariesForImage")
package func nativeCopyLazyLibrariesForImage(_ generation: UInt64, _ error: UnsafeMutablePointer<OpaquePointer?>?) -> OpaquePointer? {
    copyLibraries(error) {
        guard let snapshot = try ImageSnapshot.current().first(where: { $0.identity.loadGeneration == generation }) else {
            throw ABIResolutionError.imageChanged
        }
        return try LazyLibraryReader.read(image: snapshot.retain())
    }
}

@_cdecl("ABICopyLazyLibrariesInFile")
package func nativeCopyLazyLibrariesInFile(_ path: UnsafePointer<CChar>, _ error: UnsafeMutablePointer<OpaquePointer?>?) -> OpaquePointer? {
    copyLibraries(error) { try LazyLibraryReader.read(file: URL(fileURLWithPath: String(cString: path))) }
}

@_cdecl("ABILazyLibraryListCount")
package func nativeLazyLibraryListCount(_ list: OpaquePointer) -> Int { box(list).infos.count }

@_cdecl("ABILazyLibraryListGet")
package func nativeLazyLibraryListGet(_ list: OpaquePointer, _ index: Int) -> ABILazyLibraryInfo { box(list).infos[index] }

@_cdecl("ABILazyLibraryListSymbol")
package func nativeLazyLibraryListSymbol(_ list: OpaquePointer, _ library: Int, _ symbol: Int) -> ABILazySymbolInfo {
    box(list).symbols[library][symbol]
}

@_cdecl("ABIFreeLazyLibraryList")
package func nativeFreeLazyLibraryList(_ list: OpaquePointer?) {
    if let list { Unmanaged<LazyLibraryBox>.fromOpaque(UnsafeRawPointer(list)).release() }
}
