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
    a + b + c + d + e + f + g + h + i + j
}
@inline(never) public func architectureDecorate(_ value: String) -> String { value + "!" }
public final class ArchitectureCounter {
    let value: Int
    public init(_ value: Int) { self.value = value }
    @inline(never) public func adding(_ delta: Int) -> Int { value + delta }
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
    case "native":
        if let error = ABIValidateNativeCalls() { throw ArchitectureValidationFailure(description: String(cString: error)) }
        checks.append("C/C++ typed calls, indirect results, bound ownership, and authenticated virtual dispatch")
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
