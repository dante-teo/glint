import Foundation

enum AgentPermissionDecider {
    static func selectOption(from options: [PermissionOption], approved: Bool) -> PermissionOption? {
        let preferredKinds: [PermissionOptionKind] = approved
            ? [.allowOnce, .allowAlways]
            : [.rejectOnce, .rejectAlways]
        for kind in preferredKinds {
            if let match = options.first(where: { $0.kind == kind }) {
                return match
            }
        }
        return nil
    }

    static func outcomeJSON(for option: PermissionOption?) -> ACPJSONValue {
        guard let option else {
            return (try? RequestPermissionResponse(outcome: .cancelled).jsonValue())
                ?? .object(["outcome": .object(["outcome": .string("cancelled")])])
        }
        return (try? RequestPermissionResponse(outcome: .selected(optionId: option.optionId)).jsonValue())
            ?? .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(option.optionId)])])
    }
}

private extension Encodable {
    func jsonValue() throws -> ACPJSONValue {
        try JSONDecoder.acp.decode(ACPJSONValue.self, from: JSONEncoder.acp.encode(self))
    }
}
