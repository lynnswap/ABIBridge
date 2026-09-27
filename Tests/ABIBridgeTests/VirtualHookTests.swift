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
        let edit: @convention(c) (UnsafeMutableRawPointer) -> Int32
        let receiver: @convention(c) (Int32) -> UnsafeMutableRawPointer
        let table: @convention(c) (Int32) -> UnsafeRawPointer

        init() throws {
            name = "VirtualHook_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
            library = try FixtureLibrary(namespace: name, cxxSource: """
            namespace \(name) {
            struct Request { int value, observed; };
            struct Primary { virtual int value(int) const; virtual int edit(Request *) const; };
            struct Secondary { virtual int adjusted(int) const; virtual Secondary *identity(); };
            struct Derived : Primary, Secondary {
                int seed; Derived(int x):seed(x) {}
                int value(int) const override; int edit(Request *) const override; int adjusted(int) const override; Derived *identity() override;
            };
            int Primary::value(int x) const { return x; }
            int Primary::edit(Request *r) const { return r->observed = r->value; }
            int Secondary::adjusted(int x) const { return x; }
            Secondary *Secondary::identity() { return this; }
            int Derived::value(int x) const { return seed + x; }
            int Derived::edit(Request *r) const { return r->observed = seed + r->value; }
            int Derived::adjusted(int x) const { return seed + 20 + x; }
            Derived *Derived::identity() { return this; }
            Derived objects[] = {Derived(40), Derived(90)};
            __attribute__((noinline)) int invoke(const Primary *p, int x) { return p->value(x); }
            __attribute__((noinline)) int edit(const Primary *p, Request *r) { return p->edit(r); }
            }
            extern "C" int ABIVirtualOracle(int object, int value) { return \(name)::invoke(&\(name)::objects[object],value); }
            extern "C" int ABIVirtualEdit(void *request) { return \(name)::edit(&\(name)::objects[0], static_cast<\(name)::Request*>(request)); }
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
            edit = try address("ABIVirtualEdit", as: (@convention(c) (UnsafeMutableRawPointer) -> Int32).self)
            receiver = try address("ABIVirtualReceiver", as: (@convention(c) (Int32) -> UnsafeMutableRawPointer).self)
            table = try address("ABIVirtualTable", as: (@convention(c) (Int32) -> UnsafeRawPointer).self)
        }
        func entry(_ name: String = "value(int) const", secondary: Bool = false) async throws -> NativeVTable.Entry {
            let view = try unsafe NativeVTable(borrowing: table(secondary ? 1 : 0), entryCount: 2, retaining: library)
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
        let declaration = entry.declaration
        let first = try unsafe entry.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, value in
            #expect(call.declaration == declaration)
            #expect(ObjectIdentifier(call.signature) == ObjectIdentifier(((Int32) -> Int32).self))
            #expect(call.description.contains("::Derived::value(int) const"))
            return try call.proceed(value + 1) + 10
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

    private struct RequestData { var value: Int32; var observed: Int32 }
    // A borrowed adapter for this fixture's pointer and two-int C++ layout.
    private struct RequestView: ABIBridgeValue {
        static var abiType: NativeType { .pointer }
        let pointer: UnsafeMutablePointer<RequestData>
        init(_ pointer: UnsafeMutablePointer<RequestData>) { self.pointer = pointer }
        init(nativeValue: NativeValue) throws {
            pointer = try unsafe nativeValue.read(as: UnsafeMutablePointer<RequestData>.self)
        }
        static func nativeValue(from value: Self) throws -> NativeValue {
            try NativeValue(copying: value.pointer, as: .pointer)
        }
        var value: Int32 {
            get { pointer.pointee.value }
            nonmutating set { pointer.pointee.value = newValue }
        }
        var observed: Int32 {
            get { pointer.pointee.observed }
            nonmutating set { pointer.pointee.observed = newValue }
        }
    }

    @Test func editsNativeArgumentsReplacesReferencesAndPreservesSideEffectsOnFailure() async throws {
        enum Expected: Error { case failed }
        let fixture = try Fixture(); defer { fixture.library.cleanup() }
        let data = UnsafeMutablePointer<RequestData>.allocate(capacity: 1)
        data.initialize(to: .init(value: 2, observed: 0))
        let replacement = UnsafeMutablePointer<RequestData>.allocate(capacity: 1)
        replacement.initialize(to: .init(value: 11, observed: 0))
        defer { data.deinitialize(count: 1); data.deallocate(); replacement.deinitialize(count: 1); replacement.deallocate() }
        let entry = try await fixture.entry("edit(\(fixture.name)::Request*) const")
        let hook = try unsafe entry.hookSharedCalls(as: ((RequestView) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, request in
            request.value = 7
            let result = try call.proceed(request)
            request.observed += 1
            return result
        }
        #expect(fixture.edit(data) == 47 && data.pointee.value == 7 && data.pointee.observed == 48)
        hook.invalidate()
        let bits = UInt(bitPattern: replacement)
        let redirect = try unsafe entry.hookSharedCalls(as: ((RequestView) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, _ in
            try call.proceed(RequestView(UnsafeMutablePointer<RequestData>(bitPattern: bits)!))
        }
        data.pointee = .init(value: 3, observed: 0)
        #expect(fixture.edit(data) == 51 && replacement.pointee.observed == 51)
        #expect(data.pointee.value == 3 && data.pointee.observed == 0)
        redirect.invalidate()
        let errors = ErrorCounter()
        for after in [false, true] {
            data.pointee = .init(value: 2, observed: 0)
            let failing = try unsafe entry.hookSharedCalls(as: ((RequestView) -> Int32).self, onFailure: { _ in errors.increment() }) { call, request in
                request.value = 8
                if after { _ = try call.proceed(request); request.value = 10 }
                throw Expected.failed
            }
            #expect(fixture.edit(data) == 48)
            #expect(data.pointee.value == (after ? 10 : 8) && data.pointee.observed == 48)
            failing.invalidate()
        }
        #expect(errors.count == 2)
    }

    private final class ErrorCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func reportsExpiredAndWrongThreadContinuations() async throws {
        final class Saved: @unchecked Sendable { var call: NativeVirtualInvocation<Int32, Int32>? }
        let fixture = try Fixture(); defer { fixture.library.cleanup() }
        let saved = Saved()
        let entry = try await fixture.entry()
        let explicit = try unsafe entry.table.entry(at: entry.index, authentication: entry.authentication)
        let hook = try unsafe explicit.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { Issue.record(Comment(rawValue: "\($0)")) }) { call, value in
            #expect(call.declaration == nil && call.description.contains("<virtual entry 0>"))
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
        #expect(saved.call?.description.contains("Swift.Int32") == true)
        #expect(throws: NativeVirtualInvocationError.expiredInvocation) { try saved.call!.proceed(2) }
        hook.invalidate()
    }
}
#endif
