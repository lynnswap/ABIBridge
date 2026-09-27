import SwiftReplacementFixtures

// Separate compilation keeps these oracles independent of replacement code.
@inline(never) public func importedScalar(_ value: Int64) -> Int64 { scalar(value) }
@inline(never) public func importedText(_ value: String) -> String { text(value) }
@inline(never) public func importedPayload(_ value: Int64) -> Int64 { payload(value).checksum }
@inline(never) public func importedValueMethod(_ value: Int64) -> Int64 { ReplacementValue(40).scalar(value) }
@inline(never) public func classScalar(_ object: ReplacementRenderer, _ value: Int64) -> Int64 { object.scalar(value) }
@inline(never) public func classText(_ object: ReplacementRenderer, _ value: String) -> String { object.text(value) }
@inline(never) public func classPayload(_ object: ReplacementRenderer, _ value: Int64) -> Int64 { object.payload(value).checksum }
@inline(never) public func classFinal(_ object: ReplacementRenderer, _ value: Int64) -> Int64 { object.finalScalar(value) }
