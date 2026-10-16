import ABIBridge
import ArchitectureFixtures
import Darwin
import Foundation

@MainActor func validateNativeLookup() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    @MainActor func measure(
        _ label: String,
        repetitions: Int = 1,
        operation: @MainActor () async throws -> Void
    ) async throws {
        print("LOOKUP started: \(label)")
        fflush(nil)
        let start = ContinuousClock.now
        for _ in 0..<repetitions { try await operation() }
        let elapsed = start.duration(to: .now).components
        let result =
            "\(label): \((Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18) / Double(repetitions)) s (mean of \(repetitions))"
        checks.append(result)
        print("LOOKUP completed: \(result)")
        fflush(nil)
    }
    for pass in ["cold", "warm"] {
        try await measure("C function \(pass)", repetitions: pass == "warm" ? 100 : 1) {
            let function = try runtime.resolveCFunctionAndWait(
                named: "ABIValidationAdd",
                as: ((Int32, Int32) -> Int32).self
            )
            guard try unsafe function.unsafeInvoke(20, 22) == 42 else {
                throw ArchitectureValidationFailure(
                    description: "C function result differs from the fixture"
                )
            }
        }
    }
    runtime.removeCachedResults()
    guard let counter = ABIValidationCreateCounter() else {
        throw ArchitectureValidationFailure(description: "Counter allocation failed")
    }
    defer { ABIValidationDeleteCounter(counter) }
    let object = runtime.cxxObject(
        unsafe NativeValue(borrowing: counter, as: try .opaque(named: "ABIArchitecture::Counter")),
        typeNamed: "ABIArchitecture::Counter"
    )
    for pass in ["cold", "warm"] {
        try await measure("C++ first member \(pass)", repetitions: pass == "warm" ? 100 : 1) {
            let method = try object.resolveMethodAndWait(
                named: "add(int)",
                as: ((Int32) -> Int32).self
            )
            guard try unsafe method.unsafeInvoke(0) == 40 else {
                throw ArchitectureValidationFailure(
                    description: "C++ member result differs from the fixture"
                )
            }
        }
    }
    try await measure("C++ another member of the same class") {
        let method = try object.resolveMethodAndWait(
            named: "current() const",
            as: (() -> Int32).self
        )
        guard try unsafe method.unsafeInvoke() == 40 else {
            throw ArchitectureValidationFailure(
                description: "C++ const member result differs from the fixture"
            )
        }
    }
    for (label, declaration) in [
        ("missing C symbol", NativeDeclaration(name: "ABIBridgeLookupFixtureAbsent", language: .c)),
        (
            "missing C++ member",
            NativeDeclaration(
                name: "ABIBridgeLookupFixtureAbsent::Counter::missing()",
                language: .cxx
            )
        ),
    ] {
        runtime.removeCachedResults()
        for pass in ["cold", "warm"] {
            try await measure("\(label) \(pass)", repetitions: pass == "warm" ? 100 : 1) {
                do {
                    _ = try runtime.resolveAndWait(declaration)
                    throw ArchitectureValidationFailure(
                        description: "The absent fixture unexpectedly resolved"
                    )
                } catch ABIResolutionError.declarationNotFound(let missing)
                    where missing == declaration
                {}
            }
        }
    }
    checks += try await validateImageMetadata(using: runtime)
    return checks
}

@MainActor private func validateImageMetadata(using runtime: ABIRuntime) async throws -> [String] {
    var checks: [String] = []
    let function = try runtime.resolveAndWait(.init(name: "ABIValidationAdd", language: .c))
    let metadata = try await runtime.resolveImageMetadata(in: function.image)
    guard metadata.image == function.image,
        UInt32(bitPattern: metadata.architecture.cpuType) == ABIValidationCPUType(),
        UInt32(bitPattern: metadata.architecture.cpuSubtype) == ABIValidationCPUSubtype()
    else {
        throw ArchitectureValidationFailure(
            description: "Image metadata differs from the native CPU oracle"
        )
    }
    checks.append(
        "Image CPU oracle: type=0x\(String(UInt32(bitPattern: metadata.architecture.cpuType), radix: 16)), subtype=0x\(String(UInt32(bitPattern: metadata.architecture.cpuSubtype), radix: 16)), is64Bit=\(metadata.is64Bit)"
    )
    let functionAddress = unsafe function.withUnsafeAddress { UInt64(UInt(bitPattern: $0)) }
    guard metadata.functionStartAddresses?.contains(functionAddress) == true,
        metadata.sections.contains(where: { $0.addressRange.contains(functionAddress) })
    else {
        throw ArchitectureValidationFailure(
            description: "Image metadata omits the compiled C function entry"
        )
    }
    checks.append("Image function starts contain the compiled C fixture entry")

    let literal: StaticString = "ABIBridge image metadata literal"
    let literalAddress = unsafe UInt64(UInt(bitPattern: literal.utf8Start))
    var location = Dl_info()
    guard unsafe dladdr(literal.utf8Start, &location) != 0,
        let header = location.dli_fbase,
        let literalImage = try runtime.resolveImagesAndWait().first(where: {
            $0.identity.headerAddress == UInt64(UInt(bitPattern: header))
        })
    else {
        throw ArchitectureValidationFailure(
            description: "The literal's loaded image is unavailable"
        )
    }
    let literalMetadata = try runtime.resolveImageMetadataAndWait(in: literalImage)
    guard
        literalMetadata.sections.contains(where: {
            $0.name == "__cstring" && $0.addressRange.contains(literalAddress)
                && UInt64(literal.utf8CodeUnitCount) <= $0.addressRange.upperBound - literalAddress
        })
    else {
        throw ArchitectureValidationFailure(
            description: "Image metadata omits the known C string span"
        )
    }
    let copied = try NativeMemoryRegion(
        address: UInt(literalAddress),
        byteCount: literal.utf8CodeUnitCount,
        retaining: literalMetadata.image
    ).read()
    guard copied.isComplete, copied.bytes == literal.withUTF8Buffer({ Array($0) }) else {
        throw ArchitectureValidationFailure(
            description: "The image's C string bytes differ from the literal"
        )
    }
    checks.append(
        "Image C string section contains the independently located literal and its readable bytes"
    )

    let systemFunction = try runtime.resolveAndWait(.init(name: "getpid", language: .c))
    let systemMetadata = try await runtime.resolveImageMetadata(in: systemFunction.image)
    let systemAddress = unsafe systemFunction.withUnsafeAddress { UInt64(UInt(bitPattern: $0)) }
    guard systemMetadata.image == systemFunction.image,
        systemMetadata.sections.contains(where: { $0.addressRange.contains(systemAddress) })
    else {
        throw ArchitectureValidationFailure(
            description: "System image metadata omits its resolved function"
        )
    }
    let starts = systemMetadata.functionStartAddresses.map { String($0.count) } ?? "absent"
    checks.append(
        "System image metadata: \(systemMetadata.image.path), type=0x\(String(UInt32(bitPattern: systemMetadata.architecture.cpuType), radix: 16)), subtype=0x\(String(UInt32(bitPattern: systemMetadata.architecture.cpuSubtype), radix: 16)), is64Bit=\(systemMetadata.is64Bit), sections=\(systemMetadata.sections.count), functionStarts=\(starts)"
    )
    return checks
}
