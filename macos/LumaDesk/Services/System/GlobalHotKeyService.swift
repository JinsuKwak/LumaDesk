import Carbon.HIToolbox
import Foundation

final class GlobalHotKeyService {
    private static let signature: OSType = 0x4453434E // DSCN

    private var handlerRef: EventHandlerRef?
    private var registrations: [UUID: EventHotKeyRef] = [:]
    private var profileByRegistrationID: [UInt32: UUID] = [:]
    private var onProfile: ((UUID) -> Void)?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    deinit {
        registrations.values.forEach { UnregisterEventHotKey($0) }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    @discardableResult
    func register(
        profiles: [DisplaySwitchingProfile],
        onProfile: @escaping (UUID) -> Void
    ) -> [String] {
        unregisterAll()
        self.onProfile = onProfile

        var errors: [String] = []

        for (offset, profile) in profiles.enumerated() {
            guard let hotKey = profile.macHotKey else { continue }

            let registrationID = UInt32(offset + 1)
            let eventID = EventHotKeyID(signature: Self.signature, id: registrationID)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotKey.keyCode,
                hotKey.carbonModifiers,
                eventID,
                GetApplicationEventTarget(),
                0,
                &reference
            )

            if status == noErr, let reference {
                registrations[profile.id] = reference
                profileByRegistrationID[registrationID] = profile.id
            } else {
                errors.append("\(profile.name): \(hotKey.displayText)")
            }
        }

        return errors
    }

    func unregisterAll() {
        registrations.values.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        profileByRegistrationID.removeAll()
    }

    fileprivate func handle(event: EventRef?) -> OSStatus {
        guard let event else { return OSStatus(eventNotHandledErr) }

        var eventID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventID
        )

        guard status == noErr,
              eventID.signature == Self.signature,
              let profileID = profileByRegistrationID[eventID.id]
        else {
            return OSStatus(eventNotHandledErr)
        }

        onProfile?(profileID)
        return noErr
    }
}

private let globalHotKeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let service = Unmanaged<GlobalHotKeyService>.fromOpaque(userData).takeUnretainedValue()
    return service.handle(event: event)
}
