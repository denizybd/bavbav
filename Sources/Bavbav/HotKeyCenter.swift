import Carbon.HIToolbox
import Foundation

@MainActor
final class HotKeyCenter {
    enum HotKeyError: LocalizedError {
        case registrationFailed(Int, OSStatus)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let number, let status):
                return "Could not register global window shortcut \(number) (macOS \(status)). Try another key."
            }
        }
    }

    private var handlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var current: [Int: ShortcutStroke] = [:]
    private var suspended = false
    private let callback: (Int) -> Void

    init(bindings: ShortcutSettings? = nil, callback: @escaping (Int) -> Void) throws {
        self.callback = callback
        try installHandler()
        do { try reconfigure(bindings?.overrides ?? [:]) }
        catch {
            if let handlerRef { RemoveEventHandler(handlerRef); self.handlerRef = nil }
            throw error
        }
    }

    deinit {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    fileprivate func dispatch(number: Int) {
        guard !suspended, current[number] != nil else { return }
        callback(number)
    }

    static func configuration(_ overrides: [String: ShortcutBinding]) -> [Int: ShortcutStroke] {
        var result: [Int: ShortcutStroke] = [:]
        for (index, definition) in ShortcutCatalog.all.filter(\.global).enumerated() {
            let value = overrides[definition.id] ?? definition.defaultBinding
            if !value.disabled { result[index + 1] = value.strokes.first }
        }
        return result
    }
    func reconfigure(_ overrides: [String: ShortcutBinding]) throws {
        let next = Self.configuration(overrides)
        guard next != current else { return }
        if suspended { current = next; return }
        let previous = current
        unregister()
        do {
            try registerAll(next)
            current = next
        } catch {
            unregister()
            // Roll back the complete registration set, including swaps.
            do { try registerAll(previous) }
            catch { NSLog("[Bavbav] Hotkey rollback failed: %@", error.localizedDescription) }
            throw error
        }
    }
    func setSuspended(_ value: Bool) throws {
        guard value != suspended else { return }
        if value { unregister(); suspended = true }
        else {
            do { try registerAll(current); suspended = false }
            catch { unregister(); throw error }
        }
    }
    private func unregister() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
    }
    private func registerAll(_ values: [Int: ShortcutStroke]) throws {
        for number in values.keys.sorted() { try register(number: number, stroke: values[number]!) }
    }

    private func installHandler() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard readStatus == noErr else { return readStatus }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in center.dispatch(number: Int(hotKeyID.id)) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard status == noErr else {
            throw HotKeyError.registrationFailed(0, status)
        }
    }

    private func register(number: Int, stroke: ShortcutStroke) throws {
        let signature: OSType = 0x42564256 // BVBV
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(stroke.code),
            Self.carbonModifiers(stroke),
            EventHotKeyID(signature: signature, id: UInt32(number)),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            throw HotKeyError.registrationFailed(number, status)
        }
        hotKeyRefs.append(reference)
    }
    static func carbonModifiers(_ stroke: ShortcutStroke) -> UInt32 {
        var flags: UInt32 = 0
        if stroke.flags.contains(.command) { flags |= UInt32(cmdKey) }
        if stroke.flags.contains(.control) { flags |= UInt32(controlKey) }
        if stroke.flags.contains(.option) { flags |= UInt32(optionKey) }
        if stroke.flags.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
