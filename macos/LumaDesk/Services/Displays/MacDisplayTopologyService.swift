import CoreGraphics
import ColorSync
import Foundation

final class MacDisplayTopologyService {
    enum ApplyResult: Equatable {
        case applied
        case noMatchingDisplays
        case failed(CGError)
    }

    private let defaults: UserDefaults
    private let layoutStorageKey = "LumaDesk.DisplayLayouts.v1"
    private var savedLayouts: [String: SavedDisplayLayout]
    private var isApplying = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: layoutStorageKey),
           let layouts = try? JSONDecoder().decode([String: SavedDisplayLayout].self, from: data) {
            savedLayouts = layouts
        } else {
            savedLayouts = [:]
        }
    }

    func apply(
        profile: DisplaySwitchingProfile,
        connectedTargets: [DisplayBrightnessTarget]
    ) -> ApplyResult {
        guard !isApplying else { return .applied }

        let displays = onlineDisplays()
        let targetMap = match(targets: connectedTargets, to: displays)
        let behaviors = profile.macDisplayBehaviors.compactMap { stableID, behavior -> (CGDirectDisplayID, MacDisplayBehavior)? in
            guard behavior != .unchanged, let displayID = targetMap[normalize(stableID)] else { return nil }
            return (displayID, behavior)
        }

        guard !behaviors.isEmpty else { return .noMatchingDisplays }

        let foldsDesktop = behaviors.contains { _, behavior in
            behavior == .mirrorPrimary || behavior == .handedOff
        }
        if foldsDesktop {
            captureCurrentExtendedLayout()
        }

        let handedOffIDs = Set(behaviors.compactMap { $0.1 == .handedOff ? $0.0 : nil })
        let explicitPrimary = behaviors.first(where: { $0.1 == .primary })?.0
        let currentPrimary = CGMainDisplayID()
        let replacementPrimary = explicitPrimary
            ?? (handedOffIDs.contains(currentPrimary)
                ? displays.first(where: { !handedOffIDs.contains($0.id) })?.id
                : currentPrimary)

        guard let primaryID = replacementPrimary else { return .noMatchingDisplays }

        var configuration: CGDisplayConfigRef?
        let beginError = CGBeginDisplayConfiguration(&configuration)
        guard beginError == .success, let configuration else { return .failed(beginError) }

        isApplying = true
        defer { isApplying = false }

        for (displayID, behavior) in behaviors where behavior == .primary || behavior == .extended {
            CGConfigureDisplayMirrorOfDisplay(configuration, displayID, kCGNullDirectDisplay)
        }

        let savedLayout = foldsDesktop ? nil : savedLayout(for: displays)
        if let savedLayout,
           let primaryUUID = displays.first(where: { $0.id == primaryID })?.uuid,
           let primaryOrigin = savedLayout.origins[primaryUUID] {
            for display in displays where !handedOffIDs.contains(display.id) {
                guard let origin = savedLayout.origins[display.uuid] else { continue }
                CGConfigureDisplayOrigin(
                    configuration,
                    display.id,
                    origin.x - primaryOrigin.x,
                    origin.y - primaryOrigin.y
                )
            }
        } else if primaryID != currentPrimary {
            let primaryOrigin = CGDisplayBounds(primaryID).origin
            for display in displays where !handedOffIDs.contains(display.id) {
                let bounds = CGDisplayBounds(display.id)
                let x = Int32((bounds.origin.x - primaryOrigin.x).rounded())
                let y = Int32((bounds.origin.y - primaryOrigin.y).rounded())
                CGConfigureDisplayOrigin(configuration, display.id, x, y)
            }
        }

        for (displayID, behavior) in behaviors where behavior == .mirrorPrimary || behavior == .handedOff {
            guard displayID != primaryID else { continue }
            CGConfigureDisplayMirrorOfDisplay(configuration, displayID, primaryID)
        }

        let completeError = CGCompleteDisplayConfiguration(configuration, .forSession)
        return completeError == .success ? .applied : .failed(completeError)
    }

    /// Mirroring collapses independent display coordinates. Preserve the last
    /// healthy extended arrangement before a Handed Off/Mirror profile does so.
    /// The active UUID set is part of the key, keeping docked, undocked, and
    /// clamshell layouts independent from one another.
    private func captureCurrentExtendedLayout() {
        let displays = activeDisplays()
        guard !displays.isEmpty,
              displays.allSatisfy({ CGDisplayMirrorsDisplay($0.id) == kCGNullDirectDisplay })
        else { return }

        let primaryID = CGMainDisplayID()
        guard let primary = displays.first(where: { $0.id == primaryID }) else { return }

        let primaryOrigin = primary.bounds.origin
        let origins = Dictionary(uniqueKeysWithValues: displays.map { display in
            let x = Int32((display.bounds.origin.x - primaryOrigin.x).rounded())
            let y = Int32((display.bounds.origin.y - primaryOrigin.y).rounded())
            return (display.uuid, SavedDisplayOrigin(x: x, y: y))
        })
        let key = layoutKey(for: displays)
        savedLayouts[key] = SavedDisplayLayout(
            primaryUUID: primary.uuid,
            origins: origins,
            capturedAt: Date()
        )

        if savedLayouts.count > 24 {
            let staleKeys = savedLayouts
                .sorted { $0.value.capturedAt < $1.value.capturedAt }
                .prefix(savedLayouts.count - 24)
                .map(\.key)
            for staleKey in staleKeys {
                savedLayouts.removeValue(forKey: staleKey)
            }
        }

        guard let data = try? JSONEncoder().encode(savedLayouts) else { return }
        defaults.set(data, forKey: layoutStorageKey)
    }

    private func savedLayout(for displays: [DisplayDescriptor]) -> SavedDisplayLayout? {
        let active = displays.filter { CGDisplayIsActive($0.id) != 0 }
        guard !active.isEmpty else { return nil }
        return savedLayouts[layoutKey(for: active)]
    }

    private func activeDisplays() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else { return [] }
        return descriptors(for: Array(displayIDs.prefix(Int(count))))
    }

    private func onlineDisplays() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }

        return descriptors(for: Array(displayIDs.prefix(Int(count))))
    }

    private func descriptors(for displayIDs: [CGDirectDisplayID]) -> [DisplayDescriptor] {
        displayIDs.map { displayID in
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).takeRetainedValue()
            let uuidText = CFUUIDCreateString(nil, uuid) as String
            return DisplayDescriptor(
                id: displayID,
                uuid: normalize(uuidText),
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                bounds: CGDisplayBounds(displayID)
            )
        }
    }

    private func layoutKey(for displays: [DisplayDescriptor]) -> String {
        displays.map(\.uuid).sorted().joined(separator: "|")
    }

    private func match(
        targets: [DisplayBrightnessTarget],
        to displays: [DisplayDescriptor]
    ) -> [String: CGDirectDisplayID] {
        var result: [String: CGDirectDisplayID] = [:]
        let externalDisplays = displays
            .filter { !$0.isBuiltIn }
            .sorted {
                if $0.bounds.minX == $1.bounds.minX { return $0.bounds.minY < $1.bounds.minY }
                return $0.bounds.minX < $1.bounds.minX
            }

        for target in targets {
            let normalizedID = normalize(target.id)
            if let exact = displays.first(where: { $0.uuid == normalizedID }) {
                result[normalizedID] = exact.id
                continue
            }

            let fallbackIndex = target.displayNumber - 1
            if externalDisplays.indices.contains(fallbackIndex) {
                result[normalizedID] = externalDisplays[fallbackIndex].id
            }
        }

        return result
    }

    private func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}

private struct DisplayDescriptor {
    var id: CGDirectDisplayID
    var uuid: String
    var isBuiltIn: Bool
    var bounds: CGRect
}

private struct SavedDisplayLayout: Codable {
    var primaryUUID: String
    var origins: [String: SavedDisplayOrigin]
    var capturedAt: Date
}

private struct SavedDisplayOrigin: Codable {
    var x: Int32
    var y: Int32
}
