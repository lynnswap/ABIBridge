import ABIBridgeRuntime
import ABIBridgeTestSupport
#if os(macOS) && DEBUG
@testable import ABIBridge
import ABIBridgeCore
import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct VirtualEntryTests {
    @Test func nullSlotsPreserveNamedSelectionAmbiguityAndOriginalIdentity() async throws {
        let library = try FixtureLibrary(
            cxxSource: """
                namespace NullVirtual { int target(int value) { return value + 42; } }
                using Function = int (*)(int);
                extern "C" {
                    Function sparse[] = {NullVirtual::target, nullptr};
                    Function zeros[2] = {};
                    Function repeated[] = {NullVirtual::target, nullptr, NullVirtual::target};
                    Function unidentified[] = {NullVirtual::target, reinterpret_cast<Function>(0x12345)};
                }
                """,
            linkArguments: ["-O2", "-g", "-Wl,-fixup_chains", "-Wl,-no_data_const"]
        )
        defer { library.cleanup() }
        let runtime = ABIRuntime()
        let name = "NullVirtual::target(int)"
        let sparse = try await runtime.resolve(
            .init(name: "sparse", language: .c, kind: .data),
            in: .path(library.libraryURL),
            loading: .loadedOnly
        )
        for count in [1, 2] {
            let table = try unsafe sparse.withUnsafeAddress {
                try unsafe NativeVTable(borrowing: $0, entryCount: count, retaining: sparse)
            }
            let entry = try await table.entry(named: name, using: runtime)
            #expect(entry.index == 0 && entry.authentication == .unsigned)
        }
        try unsafe sparse.withUnsafeAddress {
            let words = $0.assumingMemoryBound(to: UInt.self)
            let saved = words.pointee
            let writable = UnsafeMutablePointer(mutating: words)
            writable[0] = 0
            writable[1] = saved
        }
        let changed = try unsafe sparse.withUnsafeAddress {
            try unsafe NativeVTable(borrowing: $0, entryCount: 2, retaining: sparse)
        }
        #expect(try await changed.entry(named: name, using: ABIRuntime()).index == 0)
        let repeated = try await runtime.resolve(
            .init(name: "repeated", language: .c, kind: .data),
            in: .path(library.libraryURL),
            loading: .loadedOnly
        )
        let duplicate = try unsafe repeated.withUnsafeAddress {
            try unsafe NativeVTable(borrowing: $0, entryCount: 3, retaining: repeated)
        }
        do {
            _ = try await duplicate.entry(named: name, using: runtime);
            Issue.record("Null slots hid duplicate original entries")
        } catch ABIResolutionError.ambiguousDeclaration {}
        let unknown = try await runtime.resolve(
            .init(name: "unidentified", language: .c, kind: .data),
            in: .path(library.libraryURL),
            loading: .loadedOnly
        )
        try unsafe unknown.withUnsafeAddress {
            UnsafeMutableRawPointer(mutating: $0).storeBytes(
                of: UInt(0),
                toByteOffset: 8,
                as: UInt.self
            )
        }
        let unidentified = try unsafe unknown.withUnsafeAddress {
            try unsafe NativeVTable(borrowing: $0, entryCount: 2, retaining: unknown)
        }
        do {
            _ = try await unidentified.entry(named: name, using: runtime);
            Issue.record("A live zero replaced unavailable original identity")
        } catch ABIResolutionError.metadataUnavailable {}
        let zeros = try await runtime.resolve(
            .init(name: "zeros", language: .c, kind: .data),
            in: .path(library.libraryURL),
            loading: .loadedOnly
        )
        let empty = try unsafe zeros.withUnsafeAddress {
            try unsafe NativeVTable(borrowing: $0, entryCount: 2, retaining: zeros)
        }
        do {
            _ = try await empty.entry(named: name, using: runtime);
            Issue.record("Zero-fill slots acquired a named target")
        } catch ABIResolutionError.declarationNotFound {}
        try FileManager.default.removeItem(at: library.libraryURL)
        #expect(try await changed.entry(named: name, using: runtime).index == 0)
    }

    private func fixture() throws -> FixtureLibrary {
        try FixtureLibrary(
            cxxSource: """
                #include <stdint.h>
                namespace NamedVirtual {
                struct Primary { virtual int value(int) const; };
                struct Secondary { virtual int adjusted(int) const; virtual Secondary *identity(); };
                struct Derived : Primary, Secondary {
                    int value(int) const override; int adjusted(int) const override; Derived *identity() override;
                };
                int Primary::value(int x) const { return x; }
                int Secondary::adjusted(int x) const { return x; }
                Secondary *Secondary::identity() { return this; }
                int Derived::value(int x) const { return x + 40; }
                int Derived::adjusted(int x) const { return x + 80; }
                Derived *Derived::identity() { return this; }
                Derived object;
                int duplicate(int x) { return x + 1; }
                using Function = int(*)(int);
                Function repeated[] = {duplicate, duplicate};
                }
                extern "C" const void *ABINamedTable(int kind) {
                    if(kind == 2) return NamedVirtual::repeated;
                    if(kind == 1) return __builtin_get_vtable_pointer(static_cast<NamedVirtual::Secondary*>(&NamedVirtual::object));
                    return __builtin_get_vtable_pointer(&NamedVirtual::object);
                }
                extern "C" void *ABINamedReceiver(int kind) {
                    if(kind == 1) return static_cast<NamedVirtual::Secondary*>(&NamedVirtual::object);
                    return &NamedVirtual::object;
                }
                """,
            linkArguments: ["-O2", "-g", "-Wl,-fixup_chains", "-Wl,-no_data_const"]
        )
    }

    private func pointer(
        _ library: FixtureLibrary,
        _ function: String,
        _ kind: Int32
    ) throws -> UnsafeMutableRawPointer {
        let resolver = SymbolResolver()
        let symbol = try resolver.resolve(
            .init(name: function, language: .c),
            in: .path(library.libraryURL),
            loading: .loadedOnly
        )
        return try unsafe symbol.withUnsafeAddress {
            let function = unsafeBitCast(
                $0,
                to: (@convention(c) (Int32) -> UnsafeMutableRawPointer?).self
            )
            return try #require(function(kind))
        }
    }

    @Test func selectsPrimarySecondaryAndCovariantThunksAndInvokes() async throws {
        let library = try fixture(); defer { library.cleanup() }
        let runtime = ABIRuntime()
        for (kind, name, slot, argumentResult) in [
            (Int32(0), "NamedVirtual::Derived::value(int) const", 0, Int32(42)),
            (Int32(1), "NamedVirtual::Derived::adjusted(int) const", 0, Int32(82)),
            (Int32(1), "NamedVirtual::Derived::identity()", 1, Int32(0)),
        ] {
            let address = try pointer(library, "ABINamedTable", kind)
            let table = try unsafe NativeVTable(
                borrowing: address,
                entryCount: kind == 0 ? 1 : 2,
                retaining: library
            )
            let entry = try await table.entry(named: name, using: runtime)
            #expect(entry.index == slot && entry.authentication == .unsigned)
            let rawName = try #require(entry.symbolName)
            let decoded = try #require(DeclarationKey.demangle(rawName, language: .cxx))
            if kind == 1 { #expect(decoded.contains("thunk to")) }
            let receiver = try pointer(library, "ABINamedReceiver", kind)
            let storage = unsafe NativeValue(
                borrowing: receiver,
                as: try .opaque(named: "receiver"),
                retaining: library
            )
            let object = runtime.cxxObject(storage, typeNamed: "NamedVirtual::Derived")
            if slot == 1 {
                let call = try unsafe object.virtualMethod(
                    entry,
                    as: (() -> UnsafeMutableRawPointer?).self
                )
                #expect(try unsafe call.unsafeInvoke() == receiver)
            } else {
                let call = try unsafe object.virtualMethod(entry, as: ((Int32) -> Int32).self)
                #expect(try unsafe call.unsafeInvoke(2) == argumentResult)
            }
        }
    }

    @Test func originalSelectionSurvivesReplacementAndCachesWithoutReopeningFile() async throws {
        let library = try fixture(); defer { library.cleanup() }
        let runtime = ABIRuntime()
        let address = try pointer(library, "ABINamedTable", 0)
        let table = try unsafe NativeVTable(borrowing: address, entryCount: 1, retaining: library)
        let first = try await table.entry(
            named: "NamedVirtual::Derived::value(int) const",
            using: runtime
        )
        let bits = address.assumingMemoryBound(to: UInt.self)
        let saved = bits.pointee
        bits.pointee = 0
        defer { bits.pointee = saved }
        // A separate resolver proves selection is independent of live targets.
        let second = try await table.entry(
            named: "NamedVirtual::Derived::value(int) const",
            using: ABIRuntime()
        )
        #expect(second.index == first.index && second.symbolName == first.symbolName)
        try FileManager.default.removeItem(at: library.libraryURL)
        let cached = try await table.entry(
            named: "NamedVirtual::Derived::value(int) const",
            using: runtime
        )
        #expect(cached.symbolName == first.symbolName)
        await runtime.removeCachedResults()
        await #expect(throws: ABIResolutionError.self) {
            _ = try await table.entry(
                named: "NamedVirtual::Derived::value(int) const",
                using: runtime
            )
        }
    }

    @Test func capturedReplacementRetainsOriginalClassImage() async throws {
        let library = try fixture(); defer { library.cleanup() }
        let replacement = try FixtureLibrary(
            cxxSource: "extern \"C\" int ABINamedReplacement(void *, int x) { return x + 100; }"
        )
        defer { replacement.cleanup() }
        let runtime = ABIRuntime()
        let address = try pointer(library, "ABINamedTable", 0)
        let table = try unsafe NativeVTable(borrowing: address, entryCount: 1)
        var entry: NativeVTable.Entry? = try await table.entry(
            named: "NamedVirtual::Derived::value(int) const",
            using: runtime
        )
        weak var originalLease = entry?.image?.lease
        let target = try SymbolResolver().resolve(
            .init(name: "ABINamedReplacement", language: .c),
            in: .path(replacement.libraryURL)
        )
        let bits = address.assumingMemoryBound(to: UInt.self)
        let saved = bits.pointee
        bits.pointee = unsafe target.withUnsafeAddress { UInt(bitPattern: $0) }
        defer { bits.pointee = saved }
        let receiver = try pointer(library, "ABINamedReceiver", 0)
        let object = runtime.cxxObject(
            unsafe NativeValue(borrowing: receiver, as: try .opaque(named: "receiver")),
            typeNamed: "NamedVirtual::Derived"
        )
        var method: NativeBoundCXXMethod<Int32, Int32>? = try unsafe object.virtualMethod(
            entry!,
            as: ((Int32) -> Int32).self
        )
        entry = nil
        await runtime.removeCachedResults()
        #expect(originalLease != nil)
        #expect(try unsafe method!.unsafeInvoke(2) == 102)
        method = nil
        #expect(originalLease == nil)
    }

    @Test func duplicateEntriesAreAmbiguousAndExplicitBoundsRemainAvailable() async throws {
        let library = try fixture(); defer { library.cleanup() }
        let address = try pointer(library, "ABINamedTable", 2)
        let table = try unsafe NativeVTable(borrowing: address, entryCount: 2, retaining: library)
        let runtime = ABIRuntime()
        let bounded = try unsafe NativeVTable(borrowing: address, entryCount: 1, retaining: library)
        for _ in 0..<3 {
            #expect(
                try await bounded.entry(named: "NamedVirtual::duplicate(int)", using: runtime).index
                    == 0
            )
            do {
                _ = try await table.entry(named: "NamedVirtual::duplicate(int)", using: runtime)
                Issue.record("Wider bounds must remain ambiguous after a narrower cached lookup")
            } catch ABIResolutionError.ambiguousDeclaration(_, let candidates) {
                #expect(candidates.count == 2)
            }
        }
        let explicit = try unsafe table.entry(at: 1, authentication: .unsigned)
        #expect(explicit.index == 1 && explicit.symbolName == nil)
        #expect(throws: NativeDispatchError.entryOutOfBounds(index: 2, count: 2)) {
            try unsafe table.entry(at: 2, authentication: .unsigned)
        }
    }

    @Test func reportsUnknownNamesAndMissingMetadataAndRejectsOtherFile() async throws {
        let library = try fixture(); defer { library.cleanup() }
        let other = try FixtureLibrary(); defer { other.cleanup() }
        let address = try pointer(library, "ABINamedTable", 0)
        let table = try unsafe NativeVTable(borrowing: address, entryCount: 1, retaining: library)
        let missing = NativeDeclaration(name: "NamedVirtual::Derived::absent()", language: .cxx)
        await #expect(throws: ABIResolutionError.declarationNotFound(missing)) {
            _ = try await table.entry(named: missing.name, using: ABIRuntime())
        }
        try FileManager.default.removeItem(at: library.libraryURL)
        try FileManager.default.copyItem(at: other.libraryURL, to: library.libraryURL)
        await #expect(throws: ABIResolutionError.self) {
            _ = try await table.entry(
                named: "NamedVirtual::Derived::value(int) const",
                using: ABIRuntime()
            )
        }
        let heap = UnsafeMutablePointer<UInt>.allocate(capacity: 1); defer { heap.deallocate() }
        heap.initialize(to: 0)
        let unknown = try unsafe NativeVTable(borrowing: heap, entryCount: 1)
        await #expect(throws: ABIResolutionError.self) {
            _ = try await unknown.entry(
                named: "NamedVirtual::Derived::value(int) const",
                using: ABIRuntime()
            )
        }
    }

    @Test func foldedSymbolAliasesDoNotEstablishDeclarationIdentity() async throws {
        let library = try FixtureLibrary(
            cxxSource: """
                namespace Folded { int first(int value) { return value; } }
                asm(".globl __ZN6Folded6secondEi\\n.set __ZN6Folded6secondEi, __ZN6Folded5firstEi");
                using F = int(*)(int);
                extern "C" { F ABIFoldedTable[] = {Folded::first}; }
                """
        )
        defer { library.cleanup() }
        let resolver = SymbolResolver()
        let symbol = try resolver.resolve(
            .init(name: "ABIFoldedTable", language: .c, kind: .data),
            in: .path(library.libraryURL)
        )
        let table = try unsafe symbol.withUnsafeAddress {
            try unsafe NativeVTable(borrowing: $0, entryCount: 1, retaining: symbol)
        }
        let runtime = ABIRuntime()
        for name in ["Folded::first(int)", "Folded::second(int)", "Folded::first(int)"] {
            do {
                _ = try await table.entry(named: name, using: runtime)
                Issue.record(
                    "An address shared by two symbols cannot establish the original declaration"
                )
            } catch ABIResolutionError.ambiguousDeclaration(let declaration, let candidates) {
                #expect(declaration.name == name)
                #expect(candidates.count == 2)
            }
        }
    }

    @Test(arguments: [false, true]) func missingOriginalIdentitiesRequireAdapter(
        legacy: Bool
    ) async throws {
        let library = try FixtureLibrary(
            cxxSource: """
                namespace Hidden {
                __attribute__((visibility("hidden"))) int value(int x) { return x; }
                }
                using F = int(*)(int);
                static F table[] = {Hidden::value};
                extern "C" const void *ABINamedTable(int) { return table; }
                """,
            linkArguments: legacy ? ["-Wl,-no_fixup_chains"] : ["-Wl,-fixup_chains", "-Wl,-x"]
        )
        defer { library.cleanup() }
        let address = try pointer(library, "ABINamedTable", 0)
        let table = try unsafe NativeVTable(borrowing: address, entryCount: 1, retaining: library)
        do {
            _ = try await table.entry(named: "Hidden::value(int)", using: ABIRuntime())
            Issue.record("Unavailable original identity must require an adapter")
        } catch ABIResolutionError.metadataUnavailable {}
        #expect(try unsafe table.entry(at: 0, authentication: .unsigned).index == 0)
    }

    @Test func nativeLookupOwnsMetadataAndValidatesBounds() throws {
        let library = try fixture(); defer { library.cleanup() }
        let address = try pointer(library, "ABINamedTable", 1)
        let runtime = ABICreateSymbolRuntime()!; defer { ABIReleaseSymbolRuntime(runtime) }
        var error: OpaquePointer?
        let entry = try #require(
            ABICopyVirtualEntry(runtime, address, 2, "NamedVirtual::Derived::identity()", &error)
        )
        defer { ABIReleaseVirtualEntry(entry) }
        #expect(error == nil)
        let info = ABIVirtualEntryGet(entry)
        #expect(
            info.addressPoint == UnsafeRawPointer(address) && info.entryCount == 2
                && info.index == 1
        )
        #expect(info.key == ABIAuthenticationUnsigned)
        #expect(String(cString: ABIVirtualEntrySymbolName(entry)).contains("_ZT"))
        #expect(
            ABICopyVirtualEntry(runtime, address, 1, "NamedVirtual::Derived::identity()", &error)
                == nil
        )
        #expect(ABIResolutionFailureCode(try #require(error)) == ABIFailureDeclarationNotFound)
        ABIReleaseResolutionFailure(error); error = nil
        #expect(ABICopyVirtualEntry(runtime, address, Int.max, "unused()", &error) == nil)
        #expect(ABIResolutionFailureCode(try #require(error)) == ABIFailureInvalidAddress)
        ABIReleaseResolutionFailure(error)
    }
}
#endif
