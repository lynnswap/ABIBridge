// Declarations that must fail to type-check: an enum payload cannot be
// opaque, and a stored property cannot take another declaration's opaque
// type, so a stored property spells every opaque type it stores.
public protocol P {}
extension Int: P {}
public func makeP() -> some P { 7 }
public enum PayloadOpaque { case a(some P) }
public enum StructuralPayloadOpaque { case a([some P]) }
public struct InferredOpaque { public var x = makeP() }
