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
@inline(never) public func coalescedValue(_ object: CoalescedParent) -> Int64 { object.value() }
@inline(never) public func coalescedExtra(_ object: CoalescedChild) -> Int64 { object.extra() }
@inline(never) public func coalescedFinal(_ object: CoalescedChild) -> Int64 { object.finalValue() }

open class CallerOverridingRenderer: ReplacementRenderer {
    @inline(never) public override func scalar(_ value: Int64) -> Int64 { value + 5 }
}
@inline(never) public func callbackMixed(_ object: CallbackRenderer) -> Double {
    object.mixed(0, 1, 2, 3, 4, 5, 6, 7, 8, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5, 8.5).checksum
}
@inline(never) public func callbackQuartet(_ object: CallbackRenderer, _ value: Int64) -> Int64 { object.quartet(value).checksum }

@inline(never) public func callbackConsumeSelf(_ object: CallbackRenderer, _ value: Int64) -> Int64 { object.consumeSelf(value) }
