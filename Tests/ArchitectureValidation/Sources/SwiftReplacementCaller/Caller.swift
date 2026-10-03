import SwiftReplacementFixtures
import Foundation

@inline(never) public func composedHookInteger(_ value: Int64) -> Int64 { composedHookEcho(value) }
@inline(never) public func composedHookString(_ value: String) -> String { composedHookEcho(value) }
@inline(never) public func composedHookObject(_ value: NSObject) -> NSObject { composedHookEcho(value) }
@inline(never) public func composedHookBoolean(_ value: Bool) -> Bool { composedHookEcho(value) }
@inline(never) public func composedHookFactoryResult(_ value: Int64) -> Int64 { composedHookFactory(value)() }
@inline(never) public func composedHookErrorResult(_ value: Int64) throws(NSError) -> Int64 { try composedHookError(value) }

// Separate compilation keeps these oracles independent of replacement code.
@inline(never) public func importedScalar(_ value: Int64) -> Int64 { scalar(value) }
@inline(never) public func importedOpaqueScalar(_ value: Int64) -> Int64 { opaqueScalar(value) as! Int64 }
@inline(never) public func importedOpaqueText(_ value: String) -> String { opaqueText(value) as! String }
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

@inline(never) public func hookRender(_ object: HookRenderer, _ value: Int64) -> Int64 { object.render(value) }
@inline(never) public func hookDirectRender(_ object: HookRenderer, _ value: Int64) -> Int64 { object.directRender(value) }
@inline(never) public func hookConsume(_ object: HookRenderer, _ value: Int64) -> Int64 { object.consume(value) }
@inline(never) public func hookSetText(_ object: HookRenderer, _ value: String) -> String { object.text = value; return object.text }
@inline(never) public func makeCallerRenderer() -> CallerOverridingRenderer { CallerOverridingRenderer() }

@inline(never) public func hookValueAdd(_ value: Int64) -> Int64 { HookCounter(40).adding(value) }
@inline(never) public func hookValueIncrement(_ seed: Int64, _ delta: Int64) -> Int64 {
    var value = HookCounter(seed)
    let result = value.increment(delta)
    return value.count * 1000 + result
}
@inline(never) public func hookValueStack() -> Int64 { HookCounter(40).stack(1,2,3,4,5,6,7,8,9,10,11,12) }
@inline(never) public func hookValueConsumeText(_ text: String) -> String { HookTextValue(text).consume() }
@inline(never) public func hookValueAppendText(_ input: String, _ suffix: String) -> String {
    var value = HookTextValue(input)
    let result = value.append(suffix)
    return result + "|" + value.text
}
@inline(never) public func hookWideValueSum(_ seed: Int64, _ delta: Int64) -> Int64 { HookWideValue(seed).sum(delta) }
@inline(never) public func hookWideValueConsume(_ seed: Int64, _ delta: Int64) -> Int64 { HookWideValue(seed).consume(delta) }

@inline(never) public nonisolated(nonsending) func importedAsyncHookInteger(_ value: Int64) async -> Int64 { await asyncHookEcho(value) }
@inline(never) public nonisolated(nonsending) func importedAsyncHookString(_ value: String) async -> String { await asyncHookEcho(value) }
@inline(never) public nonisolated(nonsending) func importedAsyncHookThrowing(_ value: Int64) async throws(NSError) -> String { try await asyncHookThrowing(value) }
@inline(never) @MainActor public func importedAsyncHookActor(_ value: Int64) async -> Int64 { await asyncHookActor(value) }
@inline(never) public nonisolated(nonsending) func importedAsyncHookMethod(_ object: AsyncHookRenderer, _ value: String) async throws(NSError) -> String { try await object.render(value) }


@inline(never) public func callConsumeTicket(_ number: Int64) -> Int64 { consumeHookTicket(HookTicket(number)) }
@inline(never) public func callMoveTicket(_ number: Int64) -> Int64 {
    let value = moveHookTicket(HookTicket(number))
    return value.read()
}

@inline(never) public func callVirtualMoveTicket(_ number: Int64) -> Int64 {
    let value = makeHookTicketRenderer().move(HookTicket(number))
    return value.read()
}

@inline(never) @concurrent public func callAsyncMoveTicket(_ number: Int64) async -> Int64 {
    let value = await moveAsyncHookTicket(HookTicket(number))
    return value.read()
}

@inline(never) public func callConsumeAnyErrorTicket(_ number: Int64) throws -> Int64 {
    try consumeAnyErrorHookTicket(HookTicket(number))
}

@inline(never) public func callOptionalHookPointer(_ value: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? { hookOptionalPointer(value) }
@inline(never) public func callConsumeHookObject(_ value: consuming NSObject) -> Int64 { consumeHookObject(value) }

@inline(never) public func callBorrowedHookPointer(_ value: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? { hookBorrowedPointer(value) }
@inline(never) public func callMoveTicketWithBody(_ number: Int64) -> (Int64, Int64) {
    var body = { Int64(42) }
    let value = moveHookTicketWithBody(HookTicket(number), &body, { 99 })
    return (value.read(), body())
}
@inline(never) @concurrent public func callAsyncMoveTicketWithBody(_ number: Int64) async -> (Int64, Int64) {
    var body = { Int64(42) }
    let value = await moveAsyncHookTicketWithBody(HookTicket(number), &body, { 99 })
    return (value.read(), body())
}

@inline(never) public func callHookPointerAndBorrow(_ value: UnsafeMutableRawPointer?, _ text: String) -> UnsafeMutableRawPointer? {
    hookPointerAndBorrow(value, { text })
}
@inline(never) public func callConsumeHookTuple(_ value: NSObject) -> Int64 { consumeHookTuple((value, 42)) }

@inline(never) public func callAdapterWriteback(_ value: UnsafeMutableRawPointer?) -> Int64 {
    var body = { Int64(0) }
    hookAdapterWriteback(value, &body)
    return body()
}

@inline(never) public func callDiscardTicket(_ pointer: UnsafeMutableRawPointer?) -> Int64 { hookDiscardTicket(HookTicket(42), pointer) }
