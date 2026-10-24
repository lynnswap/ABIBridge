import ABIBridgeRuntime
import Foundation
import ObjectiveC

/// Checks every inherited record before a protocol-qualified request selects
/// an extension. Selectors alone do not establish Swift names.
enum SwiftObjectiveCRequirements {
    static func check(
        _ root: Protocol,
        query: SwiftMemberQuery,
        signature: SwiftFunctionSignature,
        displayed: NativeDeclaration,
        extensionMember: NativeDeclaration
    ) throws {
        let role: SwiftObjectiveCMemberShape.Role
        if query.namesSubscript {
            role = .subscriptAccessor
        } else {
            role =
                switch query.role {
                case .method: .method
                case .initializer: .initializer
                case .getter: .getter
                case .setter: .setter
                }
        }
        let shape = SwiftObjectiveCMemberShape(
            role: role,
            isStatic: query.isStatic,
            parameters: signature.parameters,
            result: signature.result,
            isAsync: signature.isAsync
        )
        let optionalResult =
            signature.result is any NativeOptionalValue.Type
            || SwiftGenericCallPlan.runtimeHandle(signature.result) != nil
        let member = try query.match(in: query.qualifier ?? displayed.name).path.member
        func fail(_ protocolName: String, selector: String, evidence: String) throws {
            throw ABIResolutionError.metadataUnavailable(
                displayed.name
                    + ": Objective-C protocol \(protocolName) has requirement selector \(selector); "
                    + evidence
                    + " Name the extension member with its complete declaration `\(extensionMember.name)` to select it, or use NativeObject to call the Objective-C selector."
            )
        }
        var pending = [root]
        var visited: Set<ObjectIdentifier> = []
        while let proto = pending.popLast() {
            guard visited.insert(ObjectIdentifier(proto)).inserted else { continue }
            let name = NSStringFromProtocol(proto)
            var count: UInt32 = 0
            if let parents = protocol_copyProtocolList(proto, &count) {
                defer { free(UnsafeMutableRawPointer(parents)) }
                for index in 0..<Int(count) { pending.append(parents[index]) }
            }
            // The generated names also count selectors missing from an older
            // OS's copy of NSObjectProtocol. Unknown selectors still use shape.
            let names = name == "NSObject" ? swiftNSObjectRequirementNames : []
            for entry in names
            where entry.matches(
                role: role,
                isStatic: query.isStatic,
                optionalResult: optionalResult
            ) {
                if SwiftMemberPath(owner: "", member: entry.member)?.member == member {
                    try fail(
                        name,
                        selector: entry.selector,
                        evidence: "the SDK imports it as \(entry.member)."
                    )
                }
            }
            for required in [true, false] {
                for instance in [true, false] {
                    if role == .getter || role == .setter {
                        if !required && (role != .getter || !optionalResult) { continue }
                        if let properties = protocol_copyPropertyList2(
                            proto,
                            &count,
                            required,
                            instance
                        ) {
                            defer { free(properties) }
                            for index in 0..<Int(count) {
                                let property = properties[index]
                                let propertyName = String(cString: property_getName(property))
                                guard let encoded = property_getAttributes(property) else {
                                    continue
                                }
                                let attributes = String(cString: encoded).split(separator: ",").map(
                                    String.init
                                )
                                let getter =
                                    attributes.first { $0.hasPrefix("G") }.map {
                                        String($0.dropFirst())
                                    } ?? propertyName
                                let setter =
                                    attributes.first { $0.hasPrefix("S") }.map {
                                        String($0.dropFirst())
                                    }
                                    ?? "set" + propertyName.prefix(1).uppercased()
                                    + propertyName.dropFirst() + ":"
                                let selector = role == .getter ? getter : setter
                                // Swift's property list can mark an optional
                                // property required without a `?` attribute;
                                // its getter still lives in the optional method list.
                                var optionalCount: UInt32 = 0
                                let optionalMethods = protocol_copyMethodDescriptionList(
                                    proto,
                                    false,
                                    instance,
                                    &optionalCount
                                )
                                let optionalGetter: Bool
                                if let optionalMethods {
                                    defer { free(optionalMethods) }
                                    optionalGetter = (0..<Int(optionalCount)).contains {
                                        optionalMethods[$0].name.map(NSStringFromSelector) == getter
                                    }
                                } else {
                                    optionalGetter = false
                                }
                                let isOptional =
                                    !required || attributes.contains("?") || optionalGetter
                                if isOptional && (role != .getter || !optionalResult) { continue }
                                if names.contains(where: {
                                    $0.selector == selector && $0.isInstance == instance
                                }) {
                                    continue
                                }
                                let encoding =
                                    attributes.first { $0.hasPrefix("T") }.map {
                                        String($0.dropFirst())
                                    } ?? "?"
                                if shape.matchesProperty(
                                    encoding: encoding,
                                    isInstance: instance,
                                    isReadOnly: attributes.contains("R")
                                ) {
                                    try fail(
                                        name,
                                        selector: selector,
                                        evidence:
                                            "its property shape fits, but no record establishes its Swift name."
                                    )
                                }
                            }
                        }
                    } else {
                        // Optional methods need optional chaining; a plain
                        // method, initializer or subscript request selects none.
                        guard required else { continue }
                        if let methods = protocol_copyMethodDescriptionList(
                            proto,
                            required,
                            instance,
                            &count
                        ) {
                            defer { free(methods) }
                            for index in 0..<Int(count) {
                                let method = methods[index]
                                guard let selector = method.name.map(NSStringFromSelector) else {
                                    continue
                                }
                                if names.contains(where: {
                                    $0.selector == selector && $0.isInstance == instance
                                }) {
                                    continue
                                }
                                if shape.matchesMethod(
                                    selector: selector,
                                    encoding: method.types.map { String(cString: $0) },
                                    isInstance: instance
                                ) {
                                    try fail(
                                        name,
                                        selector: selector,
                                        evidence:
                                            "its method shape fits, but no record establishes its Swift name."
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
