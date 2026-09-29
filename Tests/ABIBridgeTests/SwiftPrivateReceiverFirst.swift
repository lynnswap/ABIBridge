import Foundation

private class PrivateMemberBase: NSObject {
    var seed = 11
    @inline(never) func inherited() -> Int { seed }
}

private class PrivateMemberReceiver: PrivateMemberBase {
    private var storage = 11
    var value: Int {
        @inline(never) get { storage }
        @inline(never) set { storage = newValue }
    }
    @inline(never) func title() -> String { String(value) }
    @inline(never) func echo(_ number: Int) -> Int { value + number }
}

@inline(never) func makeFirstPrivateReceiver() -> AnyObject {
    let receiver = PrivateMemberReceiver()
    // Compiler calls keep these private entries live in optimized fixtures and
    // provide a control independent of the symbol lookup being tested.
    precondition(receiver.title() == "11" && receiver.echo(1) == 12)
    precondition(receiver.inherited() == 11)
    receiver.value = 12
    precondition(receiver.value == 12)
    receiver.value = 11
    return receiver
}
