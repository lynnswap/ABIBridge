import Foundation

@main struct Check {
    static func main() throws {
        let records =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            ) as! [[String: Any]]
        func host(_ name: String) -> Any.Type {
            switch name {
            case "Int8": Int8.self
            case "UInt8": UInt8.self
            case "Int16": Int16.self
            case "UInt16": UInt16.self
            case "Int32": Int32.self
            case "UInt32": UInt32.self
            case "Int64": Int64.self
            case "UInt64": UInt64.self
            case "Int": Int.self
            case "UInt": UInt.self
            case "Bool": Bool.self
            case "Float": Float.self
            case "Double": Double.self
            case "Void": Void.self
            case "AnyObject": AnyObject.self
            default: String.self
            }
        }
        var failures: [String] = []
        for record in records {
            let role: SwiftObjectiveCMemberShape.Role =
                switch record["role"] as! String {
                case "getter": .getter
                case "setter": .setter
                case "initializer": .initializer
                case "subscript": .subscriptAccessor
                default: .method
                }
            let shape = SwiftObjectiveCMemberShape(
                role: role,
                isStatic: record["static"] as! Bool,
                parameters: (record["parameters"] as! [String]).map(host),
                result: host(record["result"] as! String),
                isAsync: record["async"] as! Bool
            )
            let matches: Bool
            if role == .getter || role == .setter {
                matches = shape.matchesProperty(
                    encoding: record["encoding"] as! String,
                    isInstance: record["instance"] as! Bool,
                    isReadOnly: record["readonly"] as! Bool
                )
            } else {
                matches = shape.matchesMethod(
                    selector: record["selector"] as! String,
                    encoding: record["encoding"] as! String,
                    isInstance: record["instance"] as! Bool
                )
            }
            if !matches { failures.append(record["declaration"] as! String) }
        }
        guard failures.isEmpty else {
            for failure in failures { print("Shape excluded its own declaration: " + failure) }
            exit(1)
        }
        print(
            "Product shape rule accepts all \(records.count) compiled SDK and fixture declarations"
        )
    }
}
