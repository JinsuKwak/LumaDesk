import Foundation

enum DDCFeatureCode {
    static let luminance: UInt8 = 0x10
    static let inputSource: UInt8 = 0x60
}

struct DisplayInputSwitchCommand: Equatable {
    /// Byte used as the DDC packet source address. Standard DDC/CI uses 0x51;
    /// LG's DDC2AB side channel uses 0x50.
    var packetSourceAddress: UInt8
    var vcpCode: UInt8
    var value: UInt16
    var canVerifyCurrentInput: Bool
}

enum DisplayInputSwitchResult: Equatable {
    case alreadySelected
    case sent(DisplayInputSwitchCommand)
    case failed

    var wasSent: Bool {
        switch self {
        case .alreadySelected, .sent:
            true
        case .failed:
            false
        }
    }
}

struct DisplayBrightnessTarget: @unchecked Sendable {
    var id: String
    var sharedID: String
    var name: String
    var displayNumber: Int
    var service: IOAVService?
}

protocol DisplayBrightnessBackend {
    func discoverExternalDisplays() async -> [DisplayBrightnessTarget]
    func readMaxBrightness(_ target: DisplayBrightnessTarget) async -> UInt16?
    func setBrightness(_ target: DisplayBrightnessTarget, rawValue: UInt16) async -> Bool
}

/// Keep input switching independent of brightness syncing so additional monitor
/// protocols can be added without changing the brightness path.
protocol DisplayInputSwitchBackend {
    func readInputSourceCode(_ target: DisplayBrightnessTarget) async -> UInt16?
    func sendInputSwitchCommand(_ target: DisplayBrightnessTarget, command: DisplayInputSwitchCommand) async -> Bool
}

final class DisplayInputSwitchingService {
    private let backend: DisplayInputSwitchBackend

    init(backend: DisplayInputSwitchBackend) {
        self.backend = backend
    }

    /// This is deliberately always the standard VCP 0x60 read. LG DDC2AB input
    /// writes do not reliably provide a corresponding readable value.
    func readCurrentStandardInput(on target: DisplayBrightnessTarget) async -> UInt16? {
        await backend.readInputSourceCode(target)
    }

    func switchInput(
        on target: DisplayBrightnessTarget,
        configuration: MonitorDDCConfiguration,
        value: UInt16
    ) async -> DisplayInputSwitchResult {
        let command = configuration.command(value: value)

        if command.canVerifyCurrentInput,
           await backend.readInputSourceCode(target) == command.value
        {
            return .alreadySelected
        }

        let attempts = 2
        for attempt in 0 ..< attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 450_000_000)
            }

            if await backend.sendInputSwitchCommand(target, command: command) {
                // A monitor commonly drops this Mac's video link immediately after
                // accepting the command, making read-back impossible. Treat this as
                // transport-level delivery, not proof that the panel changed input.
                return .sent(command)
            }
        }

        return .failed
    }
}

protocol BuiltInBrightnessProvider {
    func readBuiltInBrightness() async throws -> Double
}

enum DisplayBrightnessError: LocalizedError {
    case unsupportedPlatform
    case noBuiltInDisplay
    case noReadableBrightness

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Apple Silicon required"
        case .noBuiltInDisplay:
            "No built-in display"
        case .noReadableBrightness:
            "Brightness unavailable"
        }
    }
}

final class AppleSiliconDDCDisplayBrightnessBackend: DisplayBrightnessBackend, DisplayInputSwitchBackend {
    func discoverExternalDisplays() async -> [DisplayBrightnessTarget] {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                AppleSiliconDDCMinimal.discoverDisplays().enumerated().map { index, display in
                    DisplayBrightnessTarget(
                        id: display.id,
                        sharedID: display.sharedID,
                        name: display.displayName,
                        displayNumber: index + 1,
                        service: display.service
                    )
                }
            }
        }.value
    }

    func readMaxBrightness(_ target: DisplayBrightnessTarget) async -> UInt16? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                AppleSiliconDDCMinimal.read(service: target.service, command: DDCFeatureCode.luminance)?.max
            }
        }.value
    }

    func setBrightness(_ target: DisplayBrightnessTarget, rawValue: UInt16) async -> Bool {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                AppleSiliconDDCMinimal.write(service: target.service, command: DDCFeatureCode.luminance, value: rawValue)
            }
        }.value
    }

    func readInputSourceCode(_ target: DisplayBrightnessTarget) async -> UInt16? {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                guard let value = AppleSiliconDDCMinimal.read(service: target.service, command: DDCFeatureCode.inputSource) else {
                    return nil
                }

                return value.current
            }
        }.value
    }

    func sendInputSwitchCommand(_ target: DisplayBrightnessTarget, command: DisplayInputSwitchCommand) async -> Bool {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                AppleSiliconDDCMinimal.write(
                    service: target.service,
                    command: command.vcpCode,
                    value: command.value,
                    packetSourceAddress: command.packetSourceAddress
                )
            }
        }.value
    }
}

extension UInt16 {
    func clamped(to range: ClosedRange<UInt16>) -> UInt16 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
