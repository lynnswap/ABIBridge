import ABIBridge
import Foundation
import ObjectiveCFixtures
import Testing

private typealias IntegerBlock = @convention(block) (Int32) -> Int32
private typealias ObjectBlock = @convention(block) () -> AnyObject
private typealias ProviderBlock = @convention(block) (@escaping (NSArray) -> Void) -> Void

private final class BlockOwner: NSObject {
    let value: Int32 = 31
}

struct ObjectiveCBlockTests {
    @MainActor @Test func capturingAndNullableArgumentsStayOnCaller() throws {
        let method = try ABIRuntime.shared.object(ABIBlockFixture()).method(
            selector: "apply:using:", as: ((Int32, IntegerBlock?) -> Int32).self
        )
        let owner = BlockOwner()
        let callback: IntegerBlock = { value in
            MainActor.preconditionIsolated()
            return owner.value + value
        }
        #expect(try unsafe method.unsafeInvoke(11, callback) == 42)
        #expect(try unsafe method.unsafeInvoke(11, nil) == -1)
    }

    @Test func storedAndReturnedBlocksKeepCapturesAlive() throws {
        weak var observed: BlockOwner?
        try autoreleasepool {
            let fixture = ABIBlockFixture()
            let object = ABIRuntime.shared.object(fixture)
            let setter = try object.method(selector: "setHandler:", as: ((IntegerBlock?) -> Void).self)
            let getter = try object.method(selector: "handler", as: (() -> IntegerBlock?).self)
            try autoreleasepool {
                let owner = BlockOwner()
                observed = owner
                let callback: IntegerBlock = { owner.value + $0 }
                try unsafe setter.unsafeInvoke(callback)
            }
            #expect(observed != nil)
            var returned = try unsafe getter.unsafeInvoke()
            try unsafe setter.unsafeInvoke(nil)
            #expect(try unsafe getter.unsafeInvoke() == nil)
            #expect(returned?(11) == 42)
            #expect(observed != nil)
            returned = nil
        }
        #expect(observed == nil)
    }

    @Test func returnedBlocksHandleBorrowedAndOwnedMethodFamilies() throws {
        for selector in ["blockHolding:", "copyBlockHolding:"] {
            weak var observed: BlockOwner?
            var returned: ObjectBlock?
            try autoreleasepool {
                let method = try ABIRuntime.shared.object(ABIBlockFixture()).method(
                    selector: selector, as: ((NSObject) -> ObjectBlock).self
                )
                let owner = BlockOwner()
                observed = owner
                returned = try unsafe method.unsafeInvoke(owner)
            }
            #expect(observed != nil)
            #expect(returned?() === observed)
            returned = nil
            #expect(observed == nil)
        }
    }

    @Test func nilResultsAndNonBlockObjectsAreChecked() throws {
        let object = ABIRuntime.shared.object(ABIBlockFixture())
        let optional = try object.method(selector: "nilBlock", as: (() -> IntegerBlock?).self)
        #expect(try unsafe optional.unsafeInvoke() == nil)
        let required = try object.method(selector: "nilBlock", as: (() -> IntegerBlock).self)
        #expect(throws: ABIInvocationError.self) { try unsafe required.unsafeInvoke() }
        let wrong = try object.method(selector: "plainObject", as: (() -> IntegerBlock).self)
        #expect(throws: ABIInvocationError.self) { try unsafe wrong.unsafeInvoke() }
    }

    @Test func nestedCompletionBlocksRoundTripThroughTheCompilerABI() throws {
        let getter = try ABIRuntime.shared.object(ABIBlockFixture()).method(
            selector: "provider", as: (() -> ProviderBlock).self
        )
        let provider = try unsafe getter.unsafeInvoke()
        var received: [String]?
        provider { received = $0 as? [String] }
        #expect(received == ["first", "second"])
    }

    @Test func objectEncodedBlocksPreserveTheirTypedRepresentation() throws {
        let erase = try ABIRuntime.shared.object(ABIBlockFixture()).method(
            selector: "eraseBlock:", as: ((IntegerBlock?) -> IntegerBlock?).self
        )
        let owner = BlockOwner()
        let callback: IntegerBlock = { owner.value + $0 }
        let result = try unsafe erase.unsafeInvoke(callback)
        #expect(result?(11) == 42)
        #expect(try unsafe erase.unsafeInvoke(nil) == nil)
    }

    @Test func ordinarySwiftClosuresAndFunctionPointersAreNotBlocks() throws {
        let object = ABIRuntime.shared.object(ABIBlockFixture())
        #expect(throws: ABIResolutionError.self) {
            _ = try object.method(selector: "apply:using:", as: ((Int32, ((Int32) -> Int32)?) -> Int32).self)
        }
        typealias CFunction = @convention(c) (Int32) -> Int32
        #expect(throws: ABIResolutionError.self) {
            _ = try object.method(selector: "apply:using:", as: ((Int32, CFunction) -> Int32).self)
        }
    }
}
