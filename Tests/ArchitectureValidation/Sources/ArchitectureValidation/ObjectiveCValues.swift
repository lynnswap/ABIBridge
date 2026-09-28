import ABIBridge
import CoreGraphics
import Foundation
import Synchronization

private final class AggregateHookFailures: Sendable {
    let messages = Mutex<[String]>([])
    func append(_ error: any Error) { messages.withLock { $0.append(String(describing: error)) } }
    var isEmpty: Bool { messages.withLock { $0.isEmpty } }
}
#if canImport(UIKit)
import UIKit

@MainActor private final class InsetsReceiver: NSObject {
    @objc dynamic func insets(_ value: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(top: value.top + 1, left: value.left + 2,
                     bottom: value.bottom + 3, right: value.right + 4)
    }
    @objc dynamic func directional(_ value: NSDirectionalEdgeInsets) -> NSDirectionalEdgeInsets {
        NSDirectionalEdgeInsets(top: value.top + 1, leading: value.leading + 2,
                                bottom: value.bottom + 3, trailing: value.trailing + 4)
    }
}
#endif

@MainActor private final class TransformReceiver: NSObject {
    @objc dynamic func transform(_ value: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx + 3, ty: value.ty + 4)
    }
}

@MainActor func validateObjectiveCValues() throws -> [String] {
    let runtime = ABIRuntime()
    var checks: [String] = []
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ArchitectureValidationFailure(description: message) }
        checks.append(message)
    }
    let receiver = TransformReceiver()
    let input = CGAffineTransform(a: 1, b: 2, c: 3, d: 4, tx: 5, ty: 6)
    let method = try runtime.object(receiver).method(selector: "transform:",
        as: ((CGAffineTransform) -> CGAffineTransform).self)
    try check(try unsafe method.unsafeInvoke(input) == receiver.transform(input),
              "CGAffineTransform uses the Objective-C runtime aggregate layout")
    let captured = try runtime.objcImplementation(on: TransformReceiver.self, selector: "transform:",
        as: ((CGAffineTransform) -> CGAffineTransform).self)
    try check(try unsafe captured.unsafeInvoke(on: receiver, input) == receiver.transform(input),
              "Captured aggregate implementation agrees with compiler dispatch")

#if canImport(UIKit)
    let insetsReceiver = InsetsReceiver()
    let insets = UIEdgeInsets(top: 1, left: 2, bottom: 3, right: 4)
    let ordinary = try runtime.object(insetsReceiver).method(selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self)
    try check(try unsafe ordinary.unsafeInvoke(insets) == insetsReceiver.insets(insets),
              "UIEdgeInsets arguments and results need no ABIBridge registration")
    let implementation = try runtime.objcImplementation(on: InsetsReceiver.self, selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self)
    try check(try unsafe implementation.unsafeInvoke(on: insetsReceiver, insets) == insetsReceiver.insets(insets),
              "Captured UIEdgeInsets uses the native floating register classification")
    let directional = try runtime.object(insetsReceiver).method(selector: "directional:",
        as: ((NSDirectionalEdgeInsets) -> NSDirectionalEdgeInsets).self)
    let value = NSDirectionalEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
    let result = try unsafe directional.unsafeInvoke(value)
    try check(result.top == 2 && result.leading == 4 && result.bottom == 6 && result.trailing == 8,
              "NSDirectionalEdgeInsets shares the same generic structure path")
    let failures = AggregateHookFailures()
    let hook = try unsafe runtime.hookMethod(on: InsetsReceiver.self, selector: "insets:",
        as: ((UIEdgeInsets) -> UIEdgeInsets).self, onFailure: { failures.append($0) }) { call, value in
            var result = try call.proceed(value)
            result.top += 100
            return result
        }
    defer { hook.invalidate() }
    let hooked = insetsReceiver.insets(insets)
    try check(hooked.top == 102 && hooked.right == 8 && failures.isEmpty, "Managed callback round-trips UIEdgeInsets through the native ABI")
#endif
    return checks
}
