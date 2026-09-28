import CoreGraphics

public final class ClosureValueHolder {
    private let callback: (Int64) -> Int64
    init(_ callback: @escaping (Int64) -> Int64) { self.callback = callback }
    public func callAsFunction(_ value: Int64) -> Int64 { callback(value) }
}

@inline(never) public func callClosureValue(_ callback: (Int64) -> Int64, _ value: Int64) -> Int64 {
    callback(value)
}

@inline(never) public func holdClosureValue(_ callback: @escaping (Int64) -> Int64) -> ClosureValueHolder {
    ClosureValueHolder(callback)
}

@inline(never) public func makeStringClosureValue(_ prefix: String) -> (String) -> String {
    { prefix + $0 }
}

@inline(never) public func callRectClosureValue(_ callback: (CGRect) -> CGRect, _ value: CGRect) -> CGRect {
    callback(value)
}

@inline(never) public func callPointerClosureValue(
    _ callback: (UnsafePointer<Int64>?) -> Int64, _ value: UnsafePointer<Int64>?
) -> Int64 {
    callback(value)
}

@inline(never) public func callVoidClosureValue(_ callback: () -> Void) {
    callback()
}
