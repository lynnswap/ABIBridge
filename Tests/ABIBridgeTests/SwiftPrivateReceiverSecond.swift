import Foundation

private class PrivateMemberBase: NSObject {
    var seed = 22
    @inline(never) func inherited() -> Int { seed }
}

private class PrivateMemberReceiver: PrivateMemberBase {
    private var storage = 22
    var value: Int {
        @inline(never) get { storage }
        @inline(never) set { storage = newValue }
    }
    @inline(never) func title() -> String { String(value) }
    @inline(never) func echo(_ number: Int) -> Int { value + number }
}

@inline(never) func makeSecondPrivateReceiver() -> AnyObject {
    let receiver = PrivateMemberReceiver()
    // Compiler calls keep these private entries live in optimized fixtures and
    // provide a control independent of the symbol lookup being tested.
    precondition(receiver.title() == "22" && receiver.echo(1) == 23)
    precondition(receiver.inherited() == 22)
    receiver.value = 23
    precondition(receiver.value == 23)
    receiver.value = 22
    return receiver
}
