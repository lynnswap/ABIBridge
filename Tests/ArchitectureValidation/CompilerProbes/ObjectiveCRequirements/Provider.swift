import Foundation
@objc public protocol Parent { func inherited() -> Int64 }
@objc public protocol Foreign: Parent {
    func storeValue(_ value: Int64)
    func store(value: Int64) -> Int64
    @objc(renamedSelector:) func extra(_ x: Int64) -> Int64
    func plain() -> Int64
    var name: String { get set }
    @objc(isOn) var on: Bool { get }
    static func make() -> Int64
    init(seed: Int64)
    @objc(makeWithCount:) init(count: Int64)
    func fail() throws
    func load(_ x: Int64) throws -> String
    func fetch() async -> Int64
    func fetch(_ x: Int64) async throws -> String
    @objc optional func maybe() -> Int64
    subscript(index: Int) -> Int64 { get }
    subscript(key: String) -> Int64 { @objc(valueForKey2:) get }
    func take(
        _ c: @escaping (Int64) -> Void,
        flag: Bool,
        d: Double,
        f: Float,
        p: UnsafeMutableRawPointer?,
        o: AnyObject,
        s: Selector,
        cls: AnyClass
    ) -> UInt8
    func rect(_ r: CGRect) -> CGPoint
}
