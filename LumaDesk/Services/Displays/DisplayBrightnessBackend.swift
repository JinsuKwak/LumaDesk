import Foundation

enum DDCFeatureCode {
    static let luminance: UInt8 = 0x10
    static let inputSource: UInt8 = 0x60
}

struct DisplayBrightnessTarget: @unchecked Sendable {
    var id: String
    var name: String
    var service: IOAVService?
}

protocol DisplayBrightnessBackend {
    func discoverExternalDisplays() async -> [DisplayBrightnessTarget]
    func readMaxBrightness(_ target: DisplayBrightnessTarget) async -> UInt16?
    func setBrightness(_ target: DisplayBrightnessTarget, rawValue: UInt16) async -> Bool
    func readInputSourceCode(_ target: DisplayBrightnessTarget) async -> UInt16?
    func setInputSourceCode(_ target: DisplayBrightnessTarget, code: UInt16) async -> Bool
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

final class AppleSiliconDDCDisplayBrightnessBackend: DisplayBrightnessBackend {
    func discoverExternalDisplays() async -> [DisplayBrightnessTarget] {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                AppleSiliconDDCMinimal.discoverDisplays().map {
                    DisplayBrightnessTarget(id: $0.id, name: $0.displayName, service: $0.service)
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

    func setInputSourceCode(_ target: DisplayBrightnessTarget, code: UInt16) async -> Bool {
        await Task.detached(priority: .utility) {
            autoreleasepool {
                AppleSiliconDDCMinimal.write(service: target.service, command: DDCFeatureCode.inputSource, value: code)
            }
        }.value
    }
}

extension UInt16 {
    func clamped(to range: ClosedRange<UInt16>) -> UInt16 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
