enum AINativeInputTriggerKey: Equatable {
    case mention
    case slash
    case tab
    case space
    case other
}

enum AINativeInputTriggerAction: Equatable {
    case none
    case switchToEnglish(previousInputSourceIdentifier: String)
    case restoreInputSource(identifier: String)
}

struct AINativeInputTriggerStateMachine {
    private(set) var previousInputSourceIdentifier: String?

    var isActive: Bool {
        previousInputSourceIdentifier != nil
    }

    mutating func handle(
        _ key: AINativeInputTriggerKey,
        currentInputSourceIdentifier: String,
        isCurrentInputSourceCJKV: Bool
    ) -> AINativeInputTriggerAction {
        switch key {
        case .mention, .slash:
            guard previousInputSourceIdentifier == nil,
                  isCurrentInputSourceCJKV
            else { return .none }

            previousInputSourceIdentifier = currentInputSourceIdentifier
            return .switchToEnglish(previousInputSourceIdentifier: currentInputSourceIdentifier)

        case .tab, .space:
            guard let previousInputSourceIdentifier else { return .none }

            self.previousInputSourceIdentifier = nil
            return .restoreInputSource(identifier: previousInputSourceIdentifier)

        case .other:
            return .none
        }
    }

    mutating func reset() -> AINativeInputTriggerAction {
        guard let previousInputSourceIdentifier else { return .none }

        self.previousInputSourceIdentifier = nil
        return .restoreInputSource(identifier: previousInputSourceIdentifier)
    }
}
