import ABIBridge
import SwiftValueFixtures

@MainActor func validateSwiftGenericReceivers() async throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    weak var observed: GenericMemberReceiver<GenericReceiverText>?
    var retained: NativeBoundSwiftMethod<String, String>?
    do {
        let receiver = GenericMemberReceiver(GenericReceiverText(String(repeating: "owned", count: 100)))
        observed = receiver
        let object = runtime.object(receiver)
        retained = try await object.method(named: "concrete(_:)", as: ((String) -> String).self)
        let complete = try await object.method(named: "concrete(Swift.String) -> Swift.String", as: ((String) -> String).self)
        let getter = try await object.getter(named: "valueText", as: String.self)
        try check(unsafe retained!.unsafeInvoke("prefix:") == receiver.concrete("prefix:"),
                  "Generic Swift receiver uses its metadata and witness context")
        try check(unsafe complete.unsafeInvoke("") == receiver.concrete(""),
                  "Generic Swift complete concrete declaration")
        try check(unsafe getter.unsafeInvoke() == receiver.valueText, "Generic Swift concrete getter")
    }
    let inherited = InheritedGenericMemberReceiver(GenericReceiverNumber(42))
    let method = try await runtime.object(inherited).method(named: "concrete(_:)", as: ((String) -> String).self)
    try check(unsafe method.unsafeInvoke("") == inherited.concrete(""),
              "Generic Swift superclass implementation")
    let constrained = try await runtime.object(inherited).method(named: "specialized(_:)", as: ((String) -> String).self)
    let constrainedGetter = try await runtime.object(inherited).getter(named: "specializedText", as: String.self)
    try check(unsafe constrained.unsafeInvoke("prefix:") == inherited.specialized("prefix:"),
              "Swift same-type constrained superclass member")
    try check(unsafe constrainedGetter.unsafeInvoke() == inherited.specializedText,
              "Swift same-type constrained getter")
    do {
        _ = try await runtime.object(inherited).method(named: "witnessText()", as: (() -> String).self)
        throw ArchitectureValidationFailure(description: "Extra witness argument was not supplied")
    } catch ABIResolutionError.declarationNotFound {
        checks.append("Additional extension witness keeps its adapter boundary")
    }
    await runtime.removeCachedResults()
    try check(observed != nil, "Generic Swift receiver retained after cache removal")
    try check(unsafe retained!.unsafeInvoke("") == String(repeating: "owned", count: 100),
              "Generic Swift specialized metadata stays distinct")
    retained = nil
    try check(observed == nil, "Generic Swift receiver final release")
    return checks
}
