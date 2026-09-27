#if os(macOS) && DEBUG
@testable import ABIBridge
import Foundation
import Testing

@Suite(.serialized)
struct VirtualHookTests {
    private final class Fixture {
        let library: FixtureLibrary
        let runtime = ABIRuntime()
        let name: String
        typealias Oracle = @convention(c) (Int32, Int32) -> Int32
        let oracle: Oracle
        let receiver: @convention(c) (Int32) -> UnsafeMutableRawPointer
        let table: @convention(c) (Int32) -> UnsafeRawPointer

        init() throws {
            name = "VirtualHook_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
            library = try FixtureLibrary(namespace: name, cxxSource: """
            namespace \(name) {
            struct Primary { virtual int value(int) const; };
            struct Secondary { virtual int adjusted(int) const; virtual Secondary *identity(); };
            struct Derived : Primary, Secondary {
                int seed; Derived(int x):seed(x) {}
                int value(int) const override; int adjusted(int) const override; Derived *identity() override;
            };
            int Primary::value(int x) const { return x; }
            int Secondary::adjusted(int x) const { return x; }
            Secondary *Secondary::identity() { return this; }
            int Derived::value(int x) const { return seed + x; }
            int Derived::adjusted(int x) const { return seed + 20 + x; }
            Derived *Derived::identity() { return this; }
            Derived objects[] = {Derived(40), Derived(90)};
            __attribute__((noinline)) int invoke(const Primary *p, int x) { return p->value(x); }
            }
            extern "C" int ABIVirtualOracle(int object, int value) { return \(name)::invoke(&\(name)::objects[object],value); }
            extern "C" void *ABIVirtualReceiver(int secondary) {
                if (secondary) return static_cast<\(name)::Secondary*>(&\(name)::objects[0]);
                return &\(name)::objects[0];
            }
            extern "C" const void *ABIVirtualTable(int secondary) {
                if (secondary) return __builtin_get_vtable_pointer(static_cast<\(name)::Secondary*>(&\(name)::objects[0]));
                return __builtin_get_vtable_pointer(&\(name)::objects[0]);
            }
            """, linkArguments: ["-O2", "-Wl,-no_data_const"])
            let resolver = SymbolResolver()
            let libraryURL = library.libraryURL
            func address<T>(_ name: String, as: T.Type) throws -> T {
                let symbol = try resolver.resolve(.init(name: name, language: .c), in: .path(libraryURL))
                return unsafe symbol.withUnsafeAddress { unsafeBitCast($0, to: T.self) }
            }
            oracle = try address("ABIVirtualOracle", as: Oracle.self)
            receiver = try address("ABIVirtualReceiver", as: (@convention(c) (Int32) -> UnsafeMutableRawPointer).self)
            table = try address("ABIVirtualTable", as: (@convention(c) (Int32) -> UnsafeRawPointer).self)
        }
        func entry(_ name: String = "value(int) const", secondary: Bool = false) async throws -> NativeVTable.Entry {
            let view = try unsafe NativeVTable(borrowing: table(secondary ? 1 : 0), entryCount: secondary ? 2 : 1, retaining: library)
            return try await view.entry(named: "\(self.name)::Derived::\(name)", using: runtime)
        }
        func object(secondary: Bool = false) throws -> NativeCXXObject {
            runtime.cxxObject(unsafe NativeValue(borrowing: receiver(secondary ? 1 : 0), as: try .opaque(named: name), retaining: library), typeNamed: name + "::Derived")
        }
    }

    @Test func sharedOrderInvalidationAndCapturedCalls() async throws {
        let fixture = try Fixture(); defer { fixture.library.cleanup() }
        let entry = try await fixture.entry()
        let before = try unsafe fixture.object().virtualMethod(entry, as: ((Int32) -> Int32).self)
        let first = try unsafe entry.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, value in
            try call.proceed(value + 1) + 10
        }
        let captured = try unsafe fixture.object().virtualMethod(entry, as: ((Int32) -> Int32).self)
        let second = try unsafe entry.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, value in
            try call.proceed(value) * 2
        }
        #expect(fixture.oracle(0, 2) == 106 && fixture.oracle(1, 2) == 206)
        #expect(try unsafe before.unsafeInvoke(2) == 42)
        #expect(try unsafe captured.unsafeInvoke(2) == 106)
        #expect(first.slot?.status == .active && first.slot?.mutation.didWrite == true)
        #expect(second.slot?.status == .active && second.slot?.mutation.didWrite == false)
        first.invalidate()
        #expect(first.slot?.status == .invalidated && fixture.oracle(0, 2) == 84)
        second.invalidate()
        #expect(fixture.oracle(0, 2) == 42)
        #expect(try unsafe captured.unsafeInvoke(2) == 42)
    }

    @Test func preservesSecondaryReceiverAndCovariantResult() async throws {
        let fixture = try Fixture(); defer { fixture.library.cleanup() }
        let receiverBits = UInt(bitPattern: fixture.receiver(1))
        let adjusted = try await fixture.entry("adjusted(int) const", secondary: true)
        let first = try unsafe adjusted.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, value in
            #expect(UInt(bitPattern: call.receiver) == receiverBits)
            return try call.proceed(value) + 1
        }
        defer { first.invalidate() }
        let method = try unsafe fixture.object(secondary: true).virtualMethod(adjusted, as: ((Int32) -> Int32).self)
        #expect(try unsafe method.unsafeInvoke(2) == 63)
        let identity = try await fixture.entry("identity()", secondary: true)
        let second = try unsafe identity.hookSharedCalls(as: (() -> UnsafeMutableRawPointer?).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call in
            #expect(UInt(bitPattern: call.receiver) == receiverBits)
            return try call.proceed()
        }
        defer { second.invalidate() }
        let returned = try unsafe fixture.object(secondary: true).virtualMethod(identity, as: (() -> UnsafeMutableRawPointer?).self)
        let pointer = try unsafe returned.unsafeInvoke()
        #expect(pointer.map(UInt.init(bitPattern:)) == receiverBits)
    }

    @Test func reportsExpiredAndWrongThreadContinuations() async throws {
        final class Saved: @unchecked Sendable { var call: NativeVirtualInvocation<Int32, Int32>? }
        let fixture = try Fixture(); defer { fixture.library.cleanup() }
        let saved = Saved()
        let entry = try await fixture.entry()
        let hook = try unsafe entry.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, value in
            saved.call = call
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                #expect(throws: NativeVirtualInvocationError.wrongThread) { try saved.call!.proceed(value) }
                done.signal()
            }
            done.wait()
            return try call.proceed(value)
        }
        #expect(fixture.oracle(0, 2) == 42)
        #expect(throws: NativeVirtualInvocationError.expiredInvocation) { try saved.call!.proceed(2) }
        hook.invalidate()
    }
}
#endif
