import Foundation
import ObjectiveC

// Loads the frameworks named on the command line and dumps every Objective-C
// protocol registered with the runtime.
let sdkFrameworks = "/System/Library/Frameworks/"
for name in CommandLine.arguments.dropFirst() {
    _ = dlopen(name.hasPrefix("/") ? name : sdkFrameworks + name + ".framework/" + name, RTLD_LAZY)
}
var count: UInt32 = 0
guard let list = objc_copyProtocolList(&count) else { exit(1) }
var result: [[String: Any]] = []
for index in 0..<Int(count) {
    let proto = list[index]
    var methods: [[String: Any]] = []
    for required in [true, false] {
        for instance in [true, false] {
            var n: UInt32 = 0
            if let descriptions = protocol_copyMethodDescriptionList(proto, required, instance, &n)
            {
                for i in 0..<Int(n) {
                    let d = descriptions[i]
                    guard let sel = d.name else { continue }
                    methods.append([
                        "sel": NSStringFromSelector(sel),
                        "required": required, "instance": instance,
                        "types": d.types.map { String(cString: $0) } ?? "",
                    ])
                }
                free(descriptions)
            }
        }
    }
    var properties: [[String: Any]] = []
    for required in [true, false] {
        for instance in [true, false] {
            var n: UInt32 = 0
            if let props = protocol_copyPropertyList2(proto, &n, required, instance) {
                for i in 0..<Int(n) {
                    properties.append([
                        "name": String(cString: property_getName(props[i])),
                        "attributes": property_getAttributes(props[i]).map { String(cString: $0) }
                            ?? "",
                        "required": required, "instance": instance,
                    ])
                }
                free(props)
            }
        }
    }
    var inherited: [String] = []
    var n: UInt32 = 0
    if let parents = protocol_copyProtocolList(proto, &n) {
        for i in 0..<Int(n) { inherited.append(NSStringFromProtocol(parents[i])) }
        free(UnsafeMutableRawPointer(parents))
    }
    result.append([
        "name": NSStringFromProtocol(proto), "methods": methods,
        "properties": properties, "inherited": inherited,
    ])
}
free(UnsafeMutableRawPointer(list))
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
