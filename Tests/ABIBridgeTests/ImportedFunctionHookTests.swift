#if os(macOS)
import ABIBridge
import ABIBridgeCore
import CoreGraphics
import Darwin
import Foundation
import Synchronization
import Testing

private final class ImportHookFixture {
    let provider: FixtureLibrary
    let consumer: FixtureLibrary
    let declaration: NativeDeclaration
    init(extraProtectedReference: Bool = false, lazy: Bool = false) throws {
        let name = "ImportHook_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        provider = try FixtureLibrary(namespace: name,cxxSource: """
        namespace \(name) { int calls = 0; int add(int a, int b) { ++calls; return a+b; } }
        extern "C" int ABIHookCalls() { return \(name)::calls; }
        """)
        declaration = .init(name: "\(name)::add(int, int)",language: .cxx)
        consumer = try FixtureLibrary(cxxSource: """
        namespace \(name) { int add(int,int); }
        extern "C" { int (*ABIHookSlot)(int,int) = &\(name)::add; }
        extern "C" __attribute__((noinline)) int ABIHookCall(int a, int b) { return \(lazy ? "\(name)::add(a,b)" : "ABIHookSlot(a,b)"); }
        \(extraProtectedReference ? "extern \"C\" int ABIHookDirect(int a,int b) { return \(name)::add(a,b); }" : "")
        """,linkArguments: [provider.libraryURL.path] + (lazy ? ["-Wl,-no_fixup_chains"] : []))
    }
    func cleanup() { consumer.cleanup(); provider.cleanup() }
    var scope: ImageSelector { .path(consumer.libraryURL) }
    func call(_ runtime: ABIRuntime) async throws -> NativeFunction<Int32,Int32,Int32> {
        try await runtime.cFunction(named: "ABIHookCall",as: ((Int32,Int32)->Int32).self,in: scope)
    }
}

private final class HookSentinel: @unchecked Sendable {}
private enum HookFailure: Error { case expected }

@Suite(.serialized)
struct ImportedFunctionHookTests {
    @Test func changesArgumentsAndResultsWithOrderedIndependentOwners() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        let errors=Mutex<[String]>([])
        let expectedDeclaration = fixture.declaration
        let first=try await unsafe runtime.hookImportedFunction(fixture.declaration,as: ((Int32,Int32)->Int32).self,
            in: fixture.scope,onFailure: { e in errors.withLock { $0.append(String(describing:e)) } }) { call,a,b in
                #expect(call.declaration == expectedDeclaration)
                #expect(ObjectIdentifier(call.signature) == ObjectIdentifier(((Int32, Int32) -> Int32).self))
                #expect(call.description.contains(expectedDeclaration.name))
                return try call.proceed(a,b)+1
            }
        let second=try await unsafe runtime.hookImportedFunction(fixture.declaration,as: ((Int32,Int32)->Int32).self,
            in: fixture.scope,from: .path(fixture.provider.libraryURL),onFailure: { Issue.record($0) }) { call,a,b in try call.proceed(a*2,b) }
        #expect(try unsafe call.unsafeInvoke(20,1)==42)
        #expect(first.slots.count==1 && first.slots[0].status == .active)
        second.invalidate(); #expect(try unsafe call.unsafeInvoke(20,21)==42)
        first.invalidate(); #expect(try unsafe call.unsafeInvoke(20,22)==42)
        #expect(first.slots[0].status == .invalidated)
        #expect(errors.withLock { $0.isEmpty })
    }

    @Test func errorsPreserveLatestProceedAndDoNotRepeatNativeSideEffects() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        let failures=Mutex(0)
        let hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as: ((Int32,Int32)->Int32).self,
            in: fixture.scope,onFailure: { error in
                #expect(error is HookFailure)
                failures.withLock { $0 += 1 }
            }) { call,a,b in
                if a>0 { _=try call.proceed(a,b) }; throw HookFailure.expected
            }
        #expect(try unsafe call.unsafeInvoke(20,22)==42)
        #expect(try unsafe call.unsafeInvoke(-1,43)==42)
        let count=try await runtime.cFunction(named:"ABIHookCalls",as:(()->Int32).self,in:.path(fixture.provider.libraryURL))
        #expect(try unsafe count.unsafeInvoke()==2)
        #expect(failures.withLock { $0 }==2)
        hook.invalidate()
    }

    @Test func releasesCapturesWhileSavedEntriesRemainCallable() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime()
        weak var weakSentinel: HookSentinel?
        let hook: NativeImportedFunctionHook
        do {
            let sentinel=HookSentinel(); weakSentinel=sentinel
            hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
                in:fixture.scope,onFailure:{ Issue.record($0) }) { call,a,b in
                    withExtendedLifetime(sentinel) {}
                    return try call.proceed(a,b)+1
                }
        }
        let slot=try await runtime.resolve(.init(name:"ABIHookSlot",language:.c,kind:.data),in:fixture.scope)
        let saved=unsafe slot.withUnsafeAddress { $0.load(as: (@convention(c)(Int32,Int32)->Int32).self) }
        #expect(saved(20,21)==42 && weakSentinel != nil)
        hook.invalidate(); hook.invalidate()
        #expect(weakSentinel == nil && saved(20,22)==42)
        let next=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
            in:fixture.scope,onFailure:{ Issue.record($0) }) { call,a,b in try call.proceed(a,b)+2 }
        #expect(saved(20,20)==42)
        next.invalidate()
    }

    @Test func expiredContinuationAndWrongThreadAreReported() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        // Deliberately bypass Sendable to exercise runtime scope diagnostics.
        final class Saved: @unchecked Sendable { var call: NativeImportedFunctionInvocation<Int32,Int32,Int32>? }
        let saved=Saved()
        let hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
            in:fixture.scope,onFailure:{ Issue.record($0) }) { invocation,a,b in
                saved.call=invocation
                let finished=DispatchSemaphore(value:0)
                Thread.detachNewThread {
                    #expect(throws: NativeImportedInvocationError.wrongThread) { try saved.call!.proceed(a,b) }
                    finished.signal()
                }
                finished.wait()
                return try invocation.proceed(a,b)
            }
        #expect(try unsafe call.unsafeInvoke(20,22)==42)
        #expect(throws: NativeImportedInvocationError.expiredInvocation) { try saved.call!.proceed(20,22) }
        hook.invalidate()
    }

    @Test func reportsExternalDisplacementAndDoesNotOverwriteIt() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        let slot=try await runtime.resolve(.init(name:"ABIHookSlot",language:.c,kind:.data),in:fixture.scope)
        let original=unsafe slot.withUnsafeAddress { $0.load(as: UInt.self) }
        let hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
            in:fixture.scope,onFailure:{ Issue.record($0) }) { call,a,b in try call.proceed(a,b)+1 }
        unsafe slot.withUnsafeAddress { UnsafeMutableRawPointer(mutating:$0).storeBytes(of:original,as:UInt.self) }
        #expect(hook.slots[0].status == .displaced)
        hook.invalidate()
        #expect(try unsafe call.unsafeInvoke(20,22)==42)
    }

    @Test func rejectsAConflictingSignatureWithoutChangingEarlierHooks() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        let hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
            in:fixture.scope,onFailure:{ Issue.record($0) }) { call,a,b in try call.proceed(a,b)+1 }
        do {
            _=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int64,Int64)->Int64).self,
                in:fixture.scope,onFailure:{ Issue.record($0) }) { call,a,b in try call.proceed(a,b) }
            Issue.record("Expected signature mismatch")
        } catch let error as NativeImportedHookInstallationError {
            #expect(error.failedIndex==0)
        }
        #expect(try unsafe call.unsafeInvoke(20,21)==42)
        hook.invalidate()
    }

    @Test func invalidatingAnInFlightCallKeepsItsSnapshotAndReleasesItAfterReturn() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        let entered=DispatchSemaphore(value:0), finish=DispatchSemaphore(value:0)
        weak var observed: HookSentinel?
        let hook: NativeImportedFunctionHook
        do {
            let sentinel=HookSentinel(); observed=sentinel
            hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
                in:fixture.scope,onFailure:{ Issue.record($0) }) { next,a,b in
                    entered.signal(); finish.wait()
                    withExtendedLifetime(sentinel) {}
                    return try next.proceed(a,b)+1
                }
        }
        let task=Task.detached { try unsafe call.unsafeInvoke(20,21) }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { entered.wait(); continuation.resume() }
        }
        hook.invalidate()
        #expect(observed != nil)
        #expect(try unsafe call.unsafeInvoke(20,22)==42)
        finish.signal(); #expect(try await task.value==42)
        #expect(observed == nil)
    }

    @Test func reportsPartialPublicationAndAllowsRetryAfterRollback() async throws {
        let fixture=try ImportHookFixture(extraProtectedReference:true); defer { fixture.cleanup() }
        // Use two images sharing a framework basename, so the first loaded image
        // contributes a mutable slot and the later image contributes a GOT slot.
        let framework="ImportBatch_"+UUID().uuidString.replacingOccurrences(of:"-",with:"_")
        var handles:[UnsafeMutableRawPointer]=[]
        defer { handles.reversed().forEach { dlclose($0) } }
        let source=try String(contentsOf:fixture.consumer.directory.appendingPathComponent("fixture.cpp"),encoding:.utf8)
        // Strip the direct-call oracle from the first file to avoid a GOT import.
        let directLine=source.split(separator:"\n").last.map(String.init)!
        let ordinary=try FixtureLibrary(load:false,cxxSource:source.replacingOccurrences(of:directLine,with:""),linkArguments:[fixture.provider.libraryURL.path])
        defer { ordinary.cleanup() }
        var paths:[URL]=[]
        for lib in [ordinary,fixture.consumer] {
            let directory=lib.directory.appendingPathComponent("\(framework).framework")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let path=directory.appendingPathComponent(framework)
            try FileManager.default.copyItem(at:lib.libraryURL,to:path)
            let handle=try #require(dlopen(path.path,RTLD_NOW | RTLD_LOCAL)); handles.append(handle); paths.append(path)
        }
        let runtime=ABIRuntime()
        do {
            let hooks=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
                in:.framework(named:framework),onFailure:{ Issue.record($0) }) { next,a,b in try next.proceed(a,b)+1 }
            // Hosts without TPRO can legitimately publish every slot.
            #expect(hooks.slots.allSatisfy { $0.status == .active }); hooks.invalidate()
        } catch let error as NativeImportedHookInstallationError {
            #expect(error.registration.slots.contains { $0.mutation.didWrite })
            #expect(error.registration.slots.filter { $0.mutation.didWrite }.allSatisfy { $0.rollback.didWrite })
            let failed=try #require(error.failedIndex)
            #expect(error.registration.slots[failed].mutation.systemErrorCode == KERN_PROTECTION_FAILURE)
            let retry=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
                in:.path(paths[0]),onFailure:{ Issue.record($0) }) { next,a,b in try next.proceed(a,b)+1 }
            #expect(retry.slots.allSatisfy { $0.status == .active })
            do {
                _=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
                    in:.framework(named:framework),onFailure:{ Issue.record($0) }) { next,a,b in try next.proceed(a,b)+2 }
                Issue.record("The same protected slot should still reject publication")
            } catch is NativeImportedHookInstallationError {}
            let call=try await runtime.cFunction(named:"ABIHookCall",as:((Int32,Int32)->Int32).self,in:.path(paths[0]))
            #expect(retry.slots.allSatisfy { $0.status == .active })
            #expect(try unsafe call.unsafeInvoke(20,21)==42)
            retry.invalidate()
        }
    }

    @Test func preservesNarrowAndAggregateResults() async throws {
        let provider=try FixtureLibrary(cxxSource:"""
        struct Size { double width, height; };
        extern "C" signed char ABIImportedNarrow(signed char value) { return value; }
        extern "C" Size ABIImportedSize(Size value) { return {value.width+1,value.height+2}; }
        """)
        defer { provider.cleanup() }
        let consumer=try FixtureLibrary(cxxSource:"""
        struct Size { double width, height; };
        extern "C" signed char ABIImportedNarrow(signed char);
        extern "C" Size ABIImportedSize(Size);
        signed char (*narrowSlot)(signed char)=ABIImportedNarrow;
        Size (*sizeSlot)(Size)=ABIImportedSize;
        extern "C" signed char ABIImportedNarrowCall(signed char value) { return narrowSlot(value); }
        extern "C" Size ABIImportedSizeCall(Size value) { return sizeSlot(value); }
        """,linkArguments:[provider.libraryURL.path])
        defer { consumer.cleanup() }
        let runtime=ABIRuntime(), scope=ImageSelector.path(consumer.libraryURL)
        let narrow=try await unsafe runtime.hookImportedFunction(.init(name:"ABIImportedNarrow",language:.c),as:((Int8)->Int8).self,
            in:scope,onFailure:{ Issue.record($0) }) { call,value in try call.proceed(value)-1 }
        let size=try await unsafe runtime.hookImportedFunction(.init(name:"ABIImportedSize",language:.c),as:((CGSize)->CGSize).self,
            in:scope,onFailure:{ Issue.record($0) }) { call,value in
                let next=try call.proceed(value); return CGSize(width:next.width+1,height:next.height+1)
            }
        let narrowCall=try await runtime.cFunction(named:"ABIImportedNarrowCall",as:((Int8)->Int8).self,in:scope)
        let sizeCall=try await runtime.cFunction(named:"ABIImportedSizeCall",as:((CGSize)->CGSize).self,in:scope)
        #expect(try unsafe narrowCall.unsafeInvoke(-41) == -42)
        #expect(try unsafe sizeCall.unsafeInvoke(CGSize(width:40,height:39)) == CGSize(width:42,height:42))
        narrow.invalidate(); size.invalidate()
    }

    @Test func lazyImportsDoNotExecuteDuringRegistrationAndWorkAfterNormalBinding() async throws {
        let namespace="LazyHook_"+UUID().uuidString.replacingOccurrences(of:"-",with:"_")
        let provider=try FixtureLibrary(cxxSource:"""
        namespace \(namespace) { int calls=0; int value(int x) { ++calls; return x; } }
        extern "C" int ABILazyHookCount() { return \(namespace)::calls; }
        """)
        defer { provider.cleanup() }
        let consumer=try FixtureLibrary(load:false,cxxSource:"""
        namespace \(namespace) { int value(int); }
        extern "C" int ABILazyHookCall(int value) { return \(namespace)::value(value); }
        """,linkArguments:[provider.libraryURL.path,"-Wl,-no_fixup_chains"])
        defer { consumer.cleanup() }
        let handle=try #require(dlopen(consumer.libraryURL.path,RTLD_LAZY|RTLD_LOCAL)); defer { dlclose(handle) }
        let runtime=ABIRuntime(), scope=ImageSelector.path(consumer.libraryURL)
        let query=NativeDeclaration(name:"\(namespace)::value(int)",language:.cxx)
        do {
            let first=try await unsafe runtime.hookImportedFunction(query,as:((Int32)->Int32).self,in:scope,
                onFailure:{ Issue.record($0) }) { call,value in try call.proceed(value)+1 }
            first.invalidate() // A dyld that eagerly resolved the slot is also valid.
        } catch ABIResolutionError.unsupportedDeclaration(let reason) { #expect(reason.contains("lazy-bound")) }
        let count=try await runtime.cFunction(named:"ABILazyHookCount",as:(()->Int32).self,in:.path(provider.libraryURL))
        #expect(try unsafe count.unsafeInvoke()==0)
        let call=try await runtime.cFunction(named:"ABILazyHookCall",as:((Int32)->Int32).self,in:scope)
        #expect(try unsafe call.unsafeInvoke(42)==42)
        let hook=try await unsafe runtime.hookImportedFunction(query,as:((Int32)->Int32).self,in:scope,
            onFailure:{ Issue.record($0) }) { next,value in try next.proceed(value)+1 }
        #expect(try unsafe call.unsafeInvoke(41)==42)
        #expect(try unsafe count.unsafeInvoke()==2)
        hook.invalidate()
    }

    @Test func callbackCanInvalidateItselfAndReenterTheImportedCall() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let runtime=ABIRuntime(), call=try await fixture.call(ABIRuntime())
        let owner=Mutex<NativeImportedFunctionHook?>(nil)
        let hook=try await unsafe runtime.hookImportedFunction(fixture.declaration,as:((Int32,Int32)->Int32).self,
            in:fixture.scope,onFailure:{ Issue.record($0) }) { next,a,b in
                owner.withLock { $0 }?.invalidate()
                #expect(try unsafe call.unsafeInvoke(0,42)==42)
                return try next.proceed(a,b)+1
            }
        owner.withLock { $0=hook }
        #expect(try unsafe call.unsafeInvoke(20,21)==42)
        #expect(hook.slots[0].status == .invalidated)
        #expect(try unsafe call.unsafeInvoke(20,22)==42)
        owner.withLock { $0=nil }
    }

    @Test func concurrentRuntimesShareOneSlotAndIndependentRegistrations() async throws {
        let fixture=try ImportHookFixture(); defer { fixture.cleanup() }
        let declaration=fixture.declaration, scope=fixture.scope
        let hooks=try await withThrowingTaskGroup(of:NativeImportedFunctionHook.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await unsafe ABIRuntime().hookImportedFunction(declaration,as:((Int32,Int32)->Int32).self,
                        in:scope,onFailure:{ Issue.record($0) }) { next,a,b in try next.proceed(a,b)+1 }
                }
            }
            var hooks:[NativeImportedFunctionHook]=[]
            for try await hook in group { hooks.append(hook) }
            return hooks
        }
        let call=try await fixture.call(ABIRuntime())
        #expect(try unsafe call.unsafeInvoke(20,14)==42)
        for (index,hook) in hooks.enumerated() {
            hook.invalidate()
            #expect(try unsafe call.unsafeInvoke(20,Int32(15+index))==42)
        }
    }
}
#endif
