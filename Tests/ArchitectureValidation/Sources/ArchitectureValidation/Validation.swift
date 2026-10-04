import ABIBridge
import ABIBridgeCore
import ArchitectureFixtures
import Darwin
import Foundation
import Synchronization

public struct ArchitectureReport: Codable, Sendable {
    public let mode: String
    public let cpuType: UInt32
    public let cpuSubtype: UInt32
    public let pacCompiled: Bool
    public let checks: [String]
    public let allocationTag: UInt64?
}

public struct ArchitectureValidationFailure: Error, CustomStringConvertible {
    public let description: String
}

@inline(never) public func architectureSum(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ e: Int, _ f: Int, _ g: Int, _ h: Int, _ i: Int, _ j: Int) -> Int {
    // Test inputs 1...10 occupy separate hexadecimal digits, making their order observable.
    a + b * 0x10 + c * 0x100 + d * 0x1000 + e * 0x10000
        + f * 0x100000 + g * 0x1000000 + h * 0x10000000 + i * 0x100000000 + j * 0x1000000000
}
@inline(never) public func architectureDecorate(_ value: String) -> String { value + "!" }
public final class ArchitectureCounter {
    let value: Int
    public init(_ value: Int) { self.value = value }
    @inline(never) public func adding(_ delta: Int) -> Int { value + delta }
}

private final class ArchitectureObjCReceiver: NSObject {
    @objc func adding(_ value: Int32) -> Int32 { 40 + value }
}

private final class ArchitectureHookReceiver: NSObject {
    @objc dynamic func adding(_ value: Int32) -> Int32 { 40 + value }
}

private final class ArchitectureHookErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []
    func append(_ error: any Error) { lock.lock(); defer { lock.unlock() }; errors.append(String(describing: error)) }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return errors.isEmpty }
}

@MainActor public func runArchitectureValidation(mode: String) async throws -> ArchitectureReport {
    var checks: [String] = []
    var tag: UInt64?
    func check(_ value: Bool, _ name: String) throws {
        guard value else { throw ArchitectureValidationFailure(description: name) }
        checks.append(name)
    }
    let runtime = ABIRuntime()
    switch mode {
    case "invocation-timing":
        checks += try await validateInvocationTiming()
    case "native-lookup":
        checks += try await validateNativeLookup()
    case "swift-lookup":
        checks += try await validateSwiftLookup()
    case "objc-values":
        checks += try validateObjectiveCValues()
    case "swiftui":
        checks += try await validateSwiftUIValues()
        checks += try await validateSwiftUIHosts()
    case "swift-opaque":
        checks += try await validateSwiftOpaqueResults()
    case "swift-existentials":
        checks += try await validateSwiftExistentials()
    case "swift-arguments":
        checks += try await validateSwiftArguments()
    case "swift-async-closures":
        checks += try await validateSwiftAsyncClosures()
    case "swift-async":
        checks += try await validateSwiftAsyncValues()
    case "swift-errors":
        checks += try await validateSwiftErrors()
    case "swift-throwing-closures":
        checks += try await validateSwiftThrowingClosures()
    case "method-extraction":
        checks += try await validateMethodExtraction()
    case "swift-generic-bindings":
        checks += try await validateSwiftGenericBindings()
    case "swift-generic-borrows":
        checks += try await validateSwiftGenericBorrows()
    case "swift-closures":
        checks += try await validateSwiftClosureValues()
    case "swift-callback":
        checks += try await validateSwiftCallbacks()
    case "swift-replacement":
        checks += try await validateSwiftReplacement()
    case "virtual-public":
        var nativePublished = false
        if let error = ABIValidatePublicVirtualHooks(false, &nativePublished) {
            throw ArchitectureValidationFailure(description: String(cString: error))
        }
        checks.append(nativePublished ? "Public C/C++ virtual hooks preserve shared chains and thunks" : "Public C/C++ hooks report TPRO refusal without changing dispatch")
        for (kind, name, slot) in [
            (UInt32(0), "ABIVTable::Derived::value(int) const", 0),
            (UInt32(1), "ABIVTable::Derived::adjusted(int) const", 0),
            (UInt32(1), "ABIVTable::Derived::identity()", 1)
        ] {
            let table = try unsafe NativeVTable(borrowing: ABINamedVirtualTable(kind)!, entryCount: kind == 0 ? 1 : 2)
            let entry = try await table.entry(named: name, using: runtime)
            let receiver = ABINamedVirtualReceiver(kind)!
            let object = runtime.cxxObject(unsafe NativeValue(borrowing: receiver, as: try .opaque(named: "subobject")), typeNamed: "ABIVTable::Derived")
            let errors = ArchitectureHookErrors()
            do {
                if slot == 1 {
                    let hook = try unsafe entry.hookSharedCalls(as: (() -> UnsafeMutableRawPointer?).self, onFailure: { errors.append($0) }) { call in try call.proceed() }
                    defer { hook.invalidate() }
                    let method = try unsafe object.virtualMethod(entry, as: (() -> UnsafeMutableRawPointer?).self)
                    try check(try unsafe method.unsafeInvoke() == receiver, "Public Swift covariant callback preserves the return subobject")
                } else {
                    let hook = try unsafe entry.hookSharedCalls(as: ((Int32) -> Int32).self, onFailure: { errors.append($0) }) { call, value in try call.proceed(value + 1) + 10 }
                    defer { hook.invalidate() }
                    let method = try unsafe object.virtualMethod(entry, as: ((Int32) -> Int32).self)
                    try check(try unsafe method.unsafeInvoke(2) == (kind == 0 ? 53 : 73), "Public Swift shared callback preserves the incoming receiver")
                    hook.invalidate()
                    try check(try unsafe method.unsafeInvoke(2) == (kind == 0 ? 42 : 62), "Captured published entry passes through after invalidation")
                }
                try check(errors.isEmpty, "Public Swift callback reports no failure")
            } catch let error as NativeVirtualHookInstallationError {
                let mutation = error.registration.slot?.mutation
                guard !nativePublished, let mutation, !mutation.didWrite,
                      mutation.status == ABIPointerSlotProtectFailed, mutation.systemErrorCode == KERN_PROTECTION_FAILURE,
                      mutation.regionFlags & UInt32(VM_REGION_FLAG_TPRO_ENABLED) != 0 else { throw error }
                try check(errors.isEmpty, "Public Swift hook reports TPRO refusal before invoking callbacks")
            }
        }
    case "virtual-entries":
        for (kind, name, slot, discriminator) in [
            (UInt32(0), "ABIVTable::Derived::value(int) const", 0, UInt(42474)),
            (UInt32(1), "ABIVTable::Derived::adjusted(int) const", 0, UInt(2811)),
            (UInt32(1), "ABIVTable::Derived::identity()", 1, UInt(62021))
        ] {
            let table = try unsafe NativeVTable(borrowing: ABINamedVirtualTable(kind)!, entryCount: kind == 0 ? 1 : 2)
            let entry = try await table.entry(named: name, using: runtime)
            let expected: NativePointerAuthentication = ABIValidationPACCompiled() ? .cxxVirtualFunction(discriminator: discriminator) : .unsigned
            try check(entry.index == slot && entry.authentication == expected, "Original metadata identifies \(name) and its compiler slot schema")
            let receiver = ABINamedVirtualReceiver(kind)!
            let object = runtime.cxxObject(unsafe NativeValue(borrowing: receiver, as: try .opaque(named: "subobject")), typeNamed: "ABIVTable::Derived")
            if slot == 1 {
                let method = try unsafe object.virtualMethod(entry, as: (() -> UnsafeMutableRawPointer?).self)
                try check(try unsafe method.unsafeInvoke() == receiver, "Named covariant thunk preserves the secondary return pointer")
            } else {
                let method = try unsafe object.virtualMethod(entry, as: ((Int32) -> Int32).self)
                try check(try unsafe method.unsafeInvoke(2) == (kind == 0 ? 42 : 62), "Named virtual entry invokes the captured implementation")
            }
            let start = ContinuousClock.now
            for _ in 0..<1000 {
                let repeated = try await table.entry(named: name, using: runtime)
                guard repeated.index == slot && repeated.authentication == expected else {
                    throw ArchitectureValidationFailure(description: "Repeated virtual lookup changed its selected entry")
                }
            }
            let duration = start.duration(to: .now).components
            let seconds = (Double(duration.seconds) + Double(duration.attoseconds) / 1e18) / 1000
            checks.append("\(name) lookup: \(seconds) s (mean of 1000)")
        }
    case "virtual-hooks":
        var published = false
        if let error = ABIValidateManagedVirtualHooks(false, &published) {
            throw ArchitectureValidationFailure(description: String(cString: error))
        }
        checks.append(published ? "Managed virtual callbacks, thunks, snapshots and ownership passed" : "Managed virtual registration reports TPRO refusal without changing dispatch or retaining callbacks")
    case "virtual-replacement":
        for (index, name) in ["primary", "secondary", "covariant"].enumerated() {
            var result = ABIVirtualMutationProbeResult()
            if let error = ABIValidateVirtualEntry(UInt32(index), &result) {
                throw ArchitectureValidationFailure(description: String(cString: error))
            }
            checks.append("\(name): compiler dispatch, predecessor and RTTI preserved; secondary offset=\(result.secondaryOffset), vptr discriminator=\(result.tableDiscriminator), slot discriminator=\(result.slotDiscriminator)")
            checks.append("\(name): write=\(result.publication.didWrite), status=\(result.publication.status), kernel=\(result.publication.systemErrorCode), flags=\(result.publication.regionFlags), protections=\(result.protectionAfter)/\(result.maximumAfter)")
        }
    case "import-hooks":
        var location = Dl_info()
        guard let header = ABIImportProbeImage(), dladdr(header, &location) != 0, let path = location.dli_fname else {
            throw ArchitectureValidationFailure(description: "Imported hook fixture image unavailable")
        }
        let baseline = ABIImportedUIDCall()
        let failures = ArchitectureHookErrors()
        let hook = try await unsafe runtime.hookImportedFunction(.init(name: "getuid", language: .c), as: (() -> UInt32).self,
            in: .path(URL(fileURLWithPath: String(cString: path))), onFailure: { failures.append($0) }) { call in try call.proceed()+1 }
        defer { hook.invalidate() }
        try check(ABIImportedUIDCall() == baseline+1, "Typed Swift callback on a compiler-created imported function pointer")
        if let error = ABIValidateImportedHookFrontend(path,baseline+1) { throw ArchitectureValidationFailure(description:String(cString:error)) }
        checks.append("C++ and Swift callbacks share ordering and independent invalidation")
        hook.invalidate()
        try check(ABIImportedUIDCall() == baseline, "Imported function passes through after logical invalidation")
        try check(failures.isEmpty, "Imported callbacks completed without conversion errors")
        let applied = Mutex(false)
        let monitor = try await unsafe runtime.monitorImportedFunction(.init(name: "getuid", language: .c), as: (() -> UInt32).self,
            in: .path(URL(fileURLWithPath: String(cString: path))), onFailure: { failures.append($0) },
            onImageUpdate: { update in
                switch update.state {
                case .installed: applied.withLock { $0 = true }
                case .failed(let error): failures.append(error)
                default: break
                }
            }) { call in try call.proceed()+3 }
        defer { monitor.invalidate() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !applied.withLock({ $0 }) && failures.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(applied.withLock { $0 } && failures.isEmpty && ABIImportedUIDCall() == baseline+3,
            "Asynchronous monitor applies a typed callback to the imported function")
        monitor.invalidate()
        try check(ABIImportedUIDCall() == baseline, "Monitor invalidation leaves the imported function callable")
    case "import-replacement":
        checks = try validateImportReplacement()
    case "coordinated-hooks":
        let failures = ArchitectureHookErrors()
        let receiver = ArchitectureHookReceiver()
        func request(_ delta: Int32) -> NativeObjCHookRequest {
            unsafe .method(on: ArchitectureHookReceiver.self, selector: "adding:", as: ((Int32) -> Int32).self,
                onFailure: { failures.append($0) }) { call, value in try call.proceed(value) + delta }
        }
        let hooks = try unsafe runtime.installHooks([request(1),request(2)])
        defer { hooks.forEach { $0.invalidate() } }
        try check(receiver.adding(1) == 44, "Coordinated Swift hooks preserve request order")
        hooks.forEach { $0.invalidate() }
        try check(receiver.adding(2) == 42, "Coordinated invalidation restores pass-through")
        try check(failures.isEmpty, "Coordinated callbacks complete without conversion failures")
        if let error = ABIValidateCoordinatedObjCHooks() {
            throw ArchitectureValidationFailure(description: String(cString: error))
        }
        checks.append("Coordinated C++ ordinary/initializer installation and preflight failure")
    case "native-hooks":
        if let error = ABIValidateNativeObjCHooks() {
            throw ArchitectureValidationFailure(description: String(cString: error))
        }
        checks.append("Native C++/Objective-C++ hook chaining, signed saved entries, and initializer ownership")
    case "initializers":
        let failures = ArchitectureHookErrors()
        let hook = try unsafe runtime.hookInitializer(on: ABIValidationInitializerClass(), selector: "initWithSeed:",
            as: ((Int32) -> NSObject?).self, onFailure: { failures.append($0) },
            transformingArguments: { $0 < 0 ? $0 : $0 + 1 }, after: { initialized in
                guard let initialized else { return }
                guard let value = initialized.value(forKey: "calls") as? NSNumber else {
                    throw ArchitectureValidationFailure(description: "Initializer result has no counter")
                }
                initialized.setValue(value.int32Value + 40, forKey: "calls")
            })
        defer { hook.invalidate() }
        let result = ABIValidationCreateInitialized(1)
        try check((result?.value(forKey: "calls") as? NSNumber)?.int32Value == 42,
            "Initializer argument transformation and initialized-object mutation")
        try check(ABIValidationCreateInitialized(-1) == nil, "Nil initializer result preserves consumed ownership")
        hook.invalidate()
        try check((ABIValidationCreateInitialized(1)?.value(forKey: "calls") as? NSNumber)?.int32Value == 1,
            "Initializer invalidation restores native behavior")
        try check(failures.isEmpty, "Initializer callbacks complete without conversion failures")
    case "hooks":
        let failures = ArchitectureHookErrors()
        let receiver = ArchitectureHookReceiver()
        let first = try unsafe runtime.hookMethod(on: ArchitectureHookReceiver.self, selector: "adding:",
            as: ((Int32) -> Int32).self, onFailure: { failures.append($0) }) { call, value in try call.proceed(value) + 1 }
        let second = try unsafe runtime.hookMethod(on: ArchitectureHookReceiver.self, selector: "adding:",
            as: ((Int32) -> Int32).self, onFailure: { failures.append($0) }) { call, value in try call.proceed(value * 2) }
        defer { first.invalidate(); second.invalidate() }
        let saved = try runtime.objcImplementation(on: ArchitectureHookReceiver.self, selector: "adding:", as: ((Int32) -> Int32).self)
        try check(receiver.adding(2) == 45, "Typed managed chain enters authenticated Objective-C dispatch")
        second.invalidate()
        try check(unsafe saved.unsafeInvoke(on: receiver, 2) == 43, "Saved implementation follows hook removal")
        first.invalidate()
        try check(unsafe saved.unsafeInvoke(on: receiver, 2) == 42, "Saved implementation remains callable after invalidation")
        try check(failures.isEmpty, "Typed hook callbacks complete without conversion failures")
    case "replacement":
        if let error = ABIValidateObjCReplacement() {
            throw ArchitectureValidationFailure(description: String(cString: error))
        }
        checks.append("Objective-C callback entry, signed cached IMP lifetime, and consuming initialization")
    case "native":
        if let error = ABIValidateNativeCalls() { throw ArchitectureValidationFailure(description: String(cString: error)) }
        checks.append("C/C++ typed calls, indirect results, bound ownership, and authenticated virtual dispatch")
        try check(ABIValidateAuthenticatedFunction(), "Unmodified function-pointer authentication")
    case "swift":
        let sum = try await runtime.swiftFunction(named: "ArchitectureValidation.architectureSum(_:_:_:_:_:_:_:_:_:_:)",
            as: ((Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) -> Int).self)
        try check(unsafe sum.unsafeInvoke(1,2,3,4,5,6,7,8,9,10) == architectureSum(1,2,3,4,5,6,7,8,9,10), "Swift register/stack arguments")
        let decorate = try await runtime.swiftFunction(named: "ArchitectureValidation.architectureDecorate(_:)", as: ((String) -> String).self)
        for size in [0, 100, 4096] {
            let value = String(repeating: "a", count: size)
            try check(unsafe decorate.unsafeInvoke(value) == architectureDecorate(value), "Swift owned String result (\(size))")
        }
        weak var observed: ArchitectureCounter?
        var bound: NativeBoundSwiftMethod<(Int) -> Int>?
        do {
            let receiver = ArchitectureCounter(40)
            observed = receiver
            bound = try await runtime.object(receiver).method(named: "adding(_:)", as: ((Int) -> Int).self)
        }
        try check(observed != nil, "Swift bound receiver retention")
        try check(unsafe bound!.unsafeInvoke(2) == 42, "Swift context register")
        bound = nil
        try check(observed == nil, "Swift bound receiver release")

        weak var privateObserved: ArchitecturePrivateCounter?
        var privateMethod: NativeBoundSwiftMethod<(Int) -> Int>?
        do {
            let receiver = ArchitecturePrivateCounter()
            privateObserved = receiver
            try check(receiver.adding(2) == 42 && receiver.inherited() == 42, "Private Swift compiler call control")
            receiver.value = 41
            try check(receiver.value == 41, "Private Swift compiler accessor control")
            receiver.value = 40
            let object = runtime.object(receiver)
            privateMethod = try await object.method(named: "adding(_:)", as: ((Int) -> Int).self)
            let complete = try await object.method(named: "adding(Swift.Int) -> Swift.Int", as: ((Int) -> Int).self)
            try check(unsafe complete.unsafeInvoke(2) == 42, "Private Swift complete member declaration")
            let inherited = try await object.method(named: "inherited()", as: (() -> Int).self)
            try check(unsafe inherited.unsafeInvoke() == 42, "Private Swift superclass declaration")
            let getter = try await object.getter(named: "value", as: (() -> Int).self)
            let setter = try await object.setter(named: "value", as: Int.self)
            try unsafe setter.unsafeInvoke(50)
            try check(unsafe getter.unsafeInvoke() == 50, "Private Swift getter and setter")
        }
        await runtime.removeCachedResults()
        try check(privateObserved != nil, "Private Swift receiver retention after cache removal")
        try check(unsafe privateMethod!.unsafeInvoke(2) == 52, "Private Swift context and retained owner")
        privateMethod = nil
        try check(privateObserved == nil, "Private Swift receiver release")
        checks += try await validateSwiftGenericReceivers()
    case "ffi":
        let add = try await runtime.cFunction(named: "ABIValidationAdd", as: ((Int32, Int32) -> Int32).self)
        try check(unsafe add.unsafeInvoke(20,22) == ABIValidationAdd(20,22), "libffi signed function call")
        let promoted = try await runtime.cFunction(named: "ABIValidationVariadicPromotions",
            as: ((Int32, Float, Int8, UInt16, Bool) -> Double).self, variadicFrom: 1)
        try check(try unsafe promoted.unsafeInvoke(40, 1.5, -8, 65500, true)
            == ABIValidationVariadicOracle(40, 1.5, -8, 65500, true), "Variadic scalar promotions match the compiler calling convention")
        let empty = try await runtime.cFunction(named: "ABIValidationVariadicSum",
            as: ((Int32) -> Double).self, variadicFrom: 1)
        try check(try unsafe empty.unsafeInvoke(0) == 0, "Variadic declarations accept an empty anonymous tail")
        let stack = try await runtime.cFunction(named: "ABIValidationVariadicSum",
            as: ((Int32, Float, Double, Float, Double, Float, Double, Float, Double, Double, Double, Float, Double) -> Double).self,
            variadicFrom: 1)
        try check(try unsafe stack.unsafeInvoke(12, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)
            == ABIValidationVariadicStackOracle(), "Variadic register and stack tails match compiler calls")
        let runtimeCall = try await runtime.cFunction(named: "ABIValidationVariadicSum",
            signature: .init(parameters: [.int32], variadicParameters: [.float, .double], returns: .double))
        let runtimeResult = try unsafe runtimeCall.unsafeInvoke(with: [try .init(copying: Int32(2), as: .int32),
            try .init(copying: Float(1.5), as: .float), try .init(copying: Double(2.5), as: .double)])
        try check(try unsafe runtimeResult.read(as: Double.self) == 4, "Runtime variadic signatures preserve input layouts and promoted native values")
        let largeType = try NativeType.structure(named: "ABIValidationLarge", fields: Array(repeating: .int64, count: 8))
        let shift = try await runtime.cFunction(named: "ABIValidationShiftLarge",
            signature: NativeSignature(parameters: [largeType], returns: largeType))
        let input = NativeValue(type: largeType) { bytes in
            for index in 0..<8 {
                bytes.baseAddress!.storeBytes(of: Int64(index + 1), toByteOffset: largeType.fields[index].offset, as: Int64.self)
            }
        }
        let expected = ABIValidationShiftLarge(ABIValidationLarge(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8))
        let output = try unsafe shift.unsafeInvoke(with: [input])
        let expectedFields = [expected.a, expected.b, expected.c, expected.d, expected.e, expected.f, expected.g, expected.h]
        for index in expectedFields.indices {
            try check(try unsafe output.field(at: index).read(as: Int64.self) == expectedFields[index],
                      "libffi aggregate argument/indirect result field \(index)")
        }
        guard let address = ABIValidationCreateCounter() else {
            throw ArchitectureValidationFailure(description: "Counter allocation failed")
        }
        let storage = unsafe NativeValue(adopting: address,
            as: try .opaque(named: "ABIArchitecture::Counter", size: Int(ABIValidationCounterSize()), alignment: Int(ABIValidationCounterAlignment())),
            release: { ABIValidationDeleteCounter($0) })
        let object = runtime.cxxObject(storage, typeNamed: "ABIArchitecture::Counter")
        let method = try await object.method(named: "add(int)", as: ((Int32) -> Int32).self)
        let directResult = try unsafe method.unsafeInvoke(2)
        try check(directResult == 42 && directResult == ABIValidationCounterOracle(address), "libffi C++ receiver call")
        let table = try unsafe NativeVTable(readingFrom: storage, entryCount: 1,
            authentication: .cxxVTablePointer(discriminator: ABIValidationTableDiscriminator()))
        let virtual = try unsafe object.virtualMethod(at: 0, in: table,
            authentication: .cxxVirtualFunction(discriminator: ABIValidationSlotDiscriminator()), as: (() -> Int32).self)
        try check(try unsafe virtual.unsafeInvoke() == ABIValidationCounterOracle(address), "libffi authenticated virtual call")
        let adapter = try await runtime.resolve(.init(name: "ABIValidationCounterAdapter", language: .c))
        let adapted = try await object.method(named: "add(int)", as: ((Int32) -> Int32).self, using: adapter)
        let adaptedResult = try unsafe adapted.unsafeInvoke(3)
        try check(adaptedResult == 45 && adaptedResult == ABIValidationCounterOracle(address), "libffi adapter and signed target")
        let objcReceiver = ArchitectureObjCReceiver()
        let objcMethod = try runtime.object(objcReceiver).method(selector: "adding:", as: ((Int32) -> Int32).self)
        try check(try unsafe objcMethod.unsafeInvoke(2) == objcReceiver.adding(2), "libffi Objective-C invocation")
    case "memory":
        guard let allocation = ABIValidationAllocate() else { throw ArchitectureValidationFailure(description: "Allocation failed") }
        defer { ABIValidationDeallocate(allocation) }
        let pointer = allocation.bindMemory(to: UInt.self, capacity: 32)
        pointer.initialize(repeating: 0, count: 32)
        defer { pointer.deinitialize(count: 32) }
        tag = UInt64(UInt(bitPattern: allocation)) >> 56
        let advanced = ABIValidationAdvance(allocation.assumingMemoryBound(to: CChar.self), 16)
        try check(UInt(bitPattern: advanced) == ABIValidationAdvanceInteger(UInt(bitPattern: allocation), 16), "In-bounds typed/integer pointer arithmetic")
        let table = allocation.advanced(by: 64)
        let object = allocation.advanced(by: 32)
        object.storeBytes(of: UInt(bitPattern: table), as: UInt.self)
        allocation.storeBytes(of: UInt(bitPattern: object), as: UInt.self)
        let region = try NativeMemoryRegion(address: UInt(bitPattern: allocation), byteCount: 16)
        let read = region.read()
        try check(read.isComplete, "Read memory through an allocation pointer")
        var options = ABIDefaultPointerSearchOptions()
        options.address = UInt(bitPattern: allocation)
        options.byteCount = 16
        options.vtableAddressPoint = UInt(bitPattern: table)
        var error: Int32 = -1
        guard let result = ABICopyPointerSearch(&options, &error) else {
            throw ArchitectureValidationFailure(description: "Pointer search failed: \(error)")
        }
        defer { ABIFreePointerSearch(result) }
        try check(ABIPointerSearchIsComplete(result) != 0 && ABIPointerSearchDistinctCount(result) == 1, "Bounded pointer discovery")
        let candidate = ABIPointerSearchCandidateAt(result, 0)
        try check(candidate.pointerBits == UInt(bitPattern: object) && candidate.vptrBits == UInt(bitPattern: table),
                  "Preserve original pointer and vptr tags")
        try check(candidate.offset == 0 && candidate.slotAddress == UInt(bitPattern: allocation),
                  "Preserve source slot location")
    case "tamper":
        let returned = ABIValidateTamperedFunction()
        throw ArchitectureValidationFailure(description: returned ? "Tampered PAC was accepted" : "Tamper control unavailable")
    default: throw ArchitectureValidationFailure(description: "Unknown validation mode: \(mode)")
    }
    return ArchitectureReport(mode: mode, cpuType: ABIValidationCPUType(), cpuSubtype: ABIValidationCPUSubtype(),
                              pacCompiled: ABIValidationPACCompiled(), checks: checks, allocationTag: tag)
}

private class ArchitecturePrivateBase {
    var seed = 42
    @inline(never) func inherited() -> Int { seed }
}

private final class ArchitecturePrivateCounter: ArchitecturePrivateBase {
    private var storage = 40
    var value: Int {
        @inline(never) get { storage }
        @inline(never) set { storage = newValue }
    }
    @inline(never) func adding(_ value: Int) -> Int { self.value + value }
}
