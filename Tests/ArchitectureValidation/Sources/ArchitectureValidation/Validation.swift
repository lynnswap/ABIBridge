import ABIBridge
import ABIBridgeCore
import ArchitectureFixtures
import Darwin
import Foundation

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
        try check(unsafe saved.unsafeInvoke(on: receiver, 2) == 43, "Saved implementation follows middle removal")
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
        var bound: NativeBoundSwiftMethod<Int, Int>?
        do {
            let receiver = ArchitectureCounter(40)
            observed = receiver
            bound = try await runtime.object(receiver).method(named: "adding(_:)", as: ((Int) -> Int).self)
        }
        try check(observed != nil, "Swift bound receiver retention")
        try check(unsafe bound!.unsafeInvoke(2) == 42, "Swift context register")
        bound = nil
        try check(observed == nil, "Swift bound receiver release")
    case "ffi":
        let add = try await runtime.cFunction(named: "ABIValidationAdd", as: ((Int32, Int32) -> Int32).self)
        try check(unsafe add.unsafeInvoke(20,22) == ABIValidationAdd(20,22), "libffi signed function call")
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
