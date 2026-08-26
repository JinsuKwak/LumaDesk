import CoreGraphics
import ColorSync
import Foundation

final class MacDisplayTopologyService {
    enum ApplyResult: Equatable {
        case applied
        case noMatchingDisplays
        case failed(CGError)
    }

    private var isApplying = false

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

        if primaryID != currentPrimary {
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

    private func onlineDisplays() -> [DisplayDescriptor] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displayIDs, &count) == .success else { return [] }

        return displayIDs.prefix(Int(count)).map { displayID in
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
