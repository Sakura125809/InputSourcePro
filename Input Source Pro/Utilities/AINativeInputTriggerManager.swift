import AppKit
import Carbon
import Combine
import CoreGraphics

@MainActor
final class AINativeInputTriggerManager {
    private let logger = ISPLogger(category: String(describing: AINativeInputTriggerManager.self))

    private weak var preferencesVM: PreferencesVM?
    private var cancelBag = CancelBag()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var stateMachine = AINativeInputTriggerStateMachine()
    private var isEnabled = false

    init(preferencesVM: PreferencesVM) {
        self.preferencesVM = preferencesVM
        watchPreferences()

        if preferencesVM.preferences.isAINativeInputTriggerEnabled,
           preferencesVM.permissionsVM.isInputMonitoringEnabled
        {
            enable()
        }
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
    }

    private func watchPreferences() {
        guard let preferencesVM else { return }

        let isFeatureEnabled = preferencesVM.$preferences
            .map(\.isAINativeInputTriggerEnabled)
            .removeDuplicates()

        let isInputMonitoringEnabled = preferencesVM.permissionsVM.$isInputMonitoringEnabled
            .removeDuplicates()

        Publishers.CombineLatest(isFeatureEnabled, isInputMonitoringEnabled)
            .sink { [weak self] isFeatureEnabled, isInputMonitoringEnabled in
                guard let self else { return }

                if isFeatureEnabled, isInputMonitoringEnabled {
                    self.enable()
                } else {
                    self.disable(restorePreviousInputSource: true)
                }
            }
            .store(in: cancelBag)
    }

    private func enable() {
        guard !isEnabled else { return }

        if startMonitoring() {
            isEnabled = true
            logger.debug { "AI native input trigger started" }
        } else {
            logger.debug { "AI native input trigger failed to start" }
        }
    }

    private func disable(restorePreviousInputSource: Bool) {
        guard isEnabled || eventTap != nil else { return }

        stopMonitoring()
        isEnabled = false

        if restorePreviousInputSource {
            perform(stateMachine.reset())
        } else {
            stateMachine = AINativeInputTriggerStateMachine()
        }

        logger.debug { "AI native input trigger stopped" }
    }

    @discardableResult
    private func startMonitoring() -> Bool {
        stopMonitoring()

        let eventMask = 1 << CGEventType.keyDown.rawValue

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                if InputSourceSwitcher.isSyntheticEvent(event) {
                    return Unmanaged.passUnretained(event)
                }

                let manager = Unmanaged<AINativeInputTriggerManager>.fromOpaque(refcon)
                    .takeUnretainedValue()
                manager.handle(type: type, event: event)

                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource

        return true
    }

    private func stopMonitoring() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard isEnabled, type == .keyDown else { return }
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }

        let key = Self.triggerKey(for: event)
        guard key != .other else { return }

        let currentInputSource = InputSource.getCurrentInputSource()
        let action = stateMachine.handle(
            key,
            currentInputSourceIdentifier: currentInputSource.persistentIdentifier,
            isCurrentInputSourceCJKV: currentInputSource.isCJKVR
        )

        perform(action)
    }

    private func perform(_ action: AINativeInputTriggerAction) {
        switch action {
        case .none:
            break

        case .switchToEnglish:
            guard let englishInputSource else {
                logger.debug { "No non-CJKV input source available for AI native trigger" }
                return
            }

            englishInputSource.select(cJKVFixStrategy: nil)

        case let .restoreInputSource(identifier):
            guard let inputSource = InputSource.resolvePersistedIdentifier(identifier) else {
                logger.debug { "Unable to restore AI native trigger input source: \(identifier)" }
                return
            }

            inputSource.select(cJKVFixStrategy: preferencesVM?.activeCJKVFixStrategy())
        }
    }

    private var englishInputSource: InputSource? {
        if let defaultKeyboard = preferencesVM?.systemWideDefaultKeyboard,
           !defaultKeyboard.isCJKVR
        {
            return defaultKeyboard
        }

        return InputSource.nonCJKVSource()
    }

    private static func triggerKey(for event: CGEvent) -> AINativeInputTriggerKey {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        guard shouldHandle(flags: flags) else { return .other }

        switch keyCode {
        case UInt16(kVK_ANSI_2) where flags.contains(.maskShift):
            return .mention
        case UInt16(kVK_ANSI_Slash) where !flags.contains(.maskShift):
            return .slash
        case UInt16(kVK_Tab):
            return .tab
        case UInt16(kVK_Space):
            return .space
        default:
            return .other
        }
    }

    private static func shouldHandle(flags: CGEventFlags) -> Bool {
        let shortcutModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        return flags.intersection(shortcutModifiers).isEmpty
    }
}
