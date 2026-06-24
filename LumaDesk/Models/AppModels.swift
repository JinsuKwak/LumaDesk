import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI

enum LightingMode: String, Codable, CaseIterable, Identifiable {
    case dynamic
    case `static`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dynamic: "Dynamic"
        case .static: "Static"
        }
    }
}

enum DynamicAnalysisMode: String, Codable, CaseIterable, Identifiable {
    case full
    case center
    case edge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .full: "Full"
        case .center: "Center"
        case .edge: "Edge"
        }
    }
}

enum ColorExtractionMethod: String, Codable, CaseIterable, Identifiable {
    case weightedAverage
    case dominant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weightedAverage: "Weighted"
        case .dominant: "Dominant"
        }
    }
}

enum StartupBehavior: String, Codable, CaseIterable, Identifiable {
    case on
    case restore
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .on: "Turn light on at launch"
        case .restore: "Restore last state"
        case .off: "Keep light off at launch"
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting(String?)
    case connected(String)
    case error(String)

    var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .scanning: "Scanning"
        case .connecting(let name): "Connecting\(name.map { " \($0)" } ?? "")"
        case .connected(let name): "Connected \(name)"
        case .error(let message): "Error \(message)"
        }
    }

    var compactLabel: String {
        switch self {
        case .disconnected: "Offline"
        case .scanning: "Scanning"
        case .connecting: "Pairing"
        case .connected: "Connected"
        case .error: "Error"
        }
    }

    var deviceName: String? {
        switch self {
        case .connecting(let name):
            name
        case .connected(let name):
            name
        case .disconnected, .scanning, .error:
            nil
        }
    }

    var canDisconnect: Bool {
        switch self {
        case .scanning, .connecting, .connected:
            true
        case .disconnected, .error:
            false
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            .green
        case .connecting, .scanning:
            .orange
        case .error:
            .red
        case .disconnected:
            .secondary
        }
    }
}

enum CaptureStreamState: String, Equatable {
    case idle
    case starting
    case active
    case error
}

struct RGBColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = RGBColor(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double) {
        self.red = red.clamped(to: 0 ... 1)
        self.green = green.clamped(to: 0 ... 1)
        self.blue = blue.clamped(to: 0 ... 1)
    }

    init(hue: Double, saturation: Double = 1.0, brightness: Double = 1.0) {
        let hue = hue - floor(hue)
        let s = saturation.clamped(to: 0 ... 1)
        let v = brightness.clamped(to: 0 ... 1)
        let i = floor(hue * 6)
        let f = hue * 6 - i
        let p = v * (1 - s)
        let q = v * (1 - f * s)
        let t = v * (1 - (1 - f) * s)

        switch Int(i) % 6 {
        case 0: self.init(red: v, green: t, blue: p)
        case 1: self.init(red: q, green: v, blue: p)
        case 2: self.init(red: p, green: v, blue: t)
        case 3: self.init(red: p, green: q, blue: v)
        case 4: self.init(red: t, green: p, blue: v)
        default: self.init(red: v, green: p, blue: q)
        }
    }

    var brightness: Double {
        max(red, green, blue)
    }

    var luminance: Double {
        (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
    }

    var saturation: Double {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        guard maxComponent > 0 else { return 0 }
        return (maxComponent - minComponent) / maxComponent
    }

    var isNearlyBlack: Bool {
        brightness < 0.01
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    func scaled(by factor: Double) -> RGBColor {
        RGBColor(red: red * factor, green: green * factor, blue: blue * factor)
    }

    func scaled(toBrightness targetBrightness: Double) -> RGBColor {
        let targetBrightness = targetBrightness.clamped(to: 0 ... 1)
        guard brightness > 0.0001 else { return .black }
        return scaled(by: targetBrightness / brightness)
    }

    func blended(toward target: RGBColor, amount: Double) -> RGBColor {
        let clampedAmount = amount.clamped(to: 0 ... 1)
        return RGBColor(
            red: red + ((target.red - red) * clampedAmount),
            green: green + ((target.green - green) * clampedAmount),
            blue: blue + ((target.blue - blue) * clampedAmount)
        )
    }

    var hueSaturationBrightness: (hue: Double, saturation: Double, brightness: Double) {
        let maxComponent = max(red, green, blue)
        let minComponent = min(red, green, blue)
        let delta = maxComponent - minComponent

        guard delta > 0.0001, maxComponent > 0 else {
            return (0, 0, maxComponent)
        }

        let rawHue: Double
        if maxComponent == red {
            rawHue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxComponent == green {
            rawHue = ((blue - red) / delta) + 2
        } else {
            rawHue = ((red - green) / delta) + 4
        }

        let hue = rawHue / 6
        return (
            hue: hue < 0 ? hue + 1 : hue,
            saturation: delta / maxComponent,
            brightness: maxComponent
        )
    }
}

struct NormalizedRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let defaultCenter = NormalizedRect(x: 0.29, y: 0.29, width: 0.42, height: 0.42)

    init(x: Double, y: Double, width: Double, height: Double) {
        let safeWidth = (width.isFinite ? width : 0.42).clamped(to: 0.01 ... 1)
        let safeHeight = (height.isFinite ? height : 0.42).clamped(to: 0.01 ... 1)

        self.width = safeWidth
        self.height = safeHeight
        self.x = (x.isFinite ? x : 0.29).clamped(to: 0 ... max(0, 1 - safeWidth))
        self.y = (y.isFinite ? y : 0.29).clamped(to: 0 ... max(0, 1 - safeHeight))
    }

    func clamped(minimumSize: Double = 0.01) -> NormalizedRect {
        let minimumSize = minimumSize.clamped(to: 0.01 ... 1)
        let safeWidth = width.clamped(to: minimumSize ... 1)
        let safeHeight = height.clamped(to: minimumSize ... 1)

        return NormalizedRect(
            x: x.clamped(to: 0 ... max(0, 1 - safeWidth)),
            y: y.clamped(to: 0 ... max(0, 1 - safeHeight)),
            width: safeWidth,
            height: safeHeight
        )
    }
}

struct GeneralSettings: Codable, Equatable {
    var launchAtLogin: Bool = false
    var autoTurnOn: Bool = false
    var autoTurnOff: Bool = true

    enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case autoTurnOn
        case autoTurnOff
        case startupBehavior
        case turnLightOffOnSleep
        case turnLightOnOnWake
        case attemptLightOffOnQuit
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false

        if let decodedAutoTurnOn = try container.decodeIfPresent(Bool.self, forKey: .autoTurnOn) {
            autoTurnOn = decodedAutoTurnOn
        } else {
            let legacyStartup = try container.decodeIfPresent(StartupBehavior.self, forKey: .startupBehavior) ?? .restore
            let legacyWake = try container.decodeIfPresent(Bool.self, forKey: .turnLightOnOnWake) ?? false
            autoTurnOn = legacyStartup == .on || legacyWake
        }

        if let decodedAutoTurnOff = try container.decodeIfPresent(Bool.self, forKey: .autoTurnOff) {
            autoTurnOff = decodedAutoTurnOff
        } else {
            let legacySleepOff = try container.decodeIfPresent(Bool.self, forKey: .turnLightOffOnSleep) ?? true
            let legacyQuitOff = try container.decodeIfPresent(Bool.self, forKey: .attemptLightOffOnQuit) ?? true
            autoTurnOff = legacySleepOff || legacyQuitOff
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(autoTurnOn, forKey: .autoTurnOn)
        try container.encode(autoTurnOff, forKey: .autoTurnOff)
    }
}

struct DynamicSettings: Codable, Equatable {
    var updateRate: Int = 12
    var smoothing: Double = 0.32
    var edgeSamplingWidthPercent: Double = 12
    var edgeZoneCount: Int = 12
    var colorExtractionMethod: ColorExtractionMethod = .weightedAverage
    var saturationWeight: Double = 1.35
    var saturationBoost: Double = 0.15
    var gamma: Double = 2.2
    var blackThreshold: Double = 0.03
    var mutedDarkOffEnabled: Bool = true
    var mutedDarkLuminanceThreshold: Double = 0.12
    var mutedDarkSaturationThreshold: Double = 0.12

    enum CodingKeys: String, CodingKey {
        case updateRate
        case smoothing
        case edgeSamplingWidthPercent
        case edgeZoneCount
        case colorExtractionMethod
        case saturationWeight
        case saturationBoost
        case gamma
        case blackThreshold
        case mutedDarkOffEnabled
        case mutedDarkLuminanceThreshold
        case mutedDarkSaturationThreshold
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updateRate = try container.decodeIfPresent(Int.self, forKey: .updateRate) ?? 12
        smoothing = try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? 0.32
        edgeSamplingWidthPercent = try container.decodeIfPresent(Double.self, forKey: .edgeSamplingWidthPercent) ?? 12
        edgeZoneCount = try container.decodeIfPresent(Int.self, forKey: .edgeZoneCount) ?? 12
        colorExtractionMethod = try container.decodeIfPresent(ColorExtractionMethod.self, forKey: .colorExtractionMethod) ?? .weightedAverage
        saturationWeight = try container.decodeIfPresent(Double.self, forKey: .saturationWeight) ?? 1.35
        saturationBoost = try container.decodeIfPresent(Double.self, forKey: .saturationBoost) ?? 0.15
        gamma = try container.decodeIfPresent(Double.self, forKey: .gamma) ?? 2.2
        blackThreshold = try container.decodeIfPresent(Double.self, forKey: .blackThreshold) ?? 0.03
        mutedDarkOffEnabled = try container.decodeIfPresent(Bool.self, forKey: .mutedDarkOffEnabled) ?? true
        mutedDarkLuminanceThreshold = try container.decodeIfPresent(Double.self, forKey: .mutedDarkLuminanceThreshold) ?? 0.12
        mutedDarkSaturationThreshold = try container.decodeIfPresent(Double.self, forKey: .mutedDarkSaturationThreshold) ?? 0.12
    }
}

struct CalibrationSettings: Codable, Equatable {
    var blackThreshold: Double = 0.03
    var centerSamplingRect: NormalizedRect = .defaultCenter
    var mutedDarkOffEnabled: Bool = true
    var mutedDarkLuminanceThreshold: Double = 0.12
    var mutedDarkSaturationThreshold: Double = 0.12
    var pureWhiteSnapEnabled: Bool = true
    var pureWhiteLuminanceThreshold: Double = 0.82
    var pureWhiteSaturationThreshold: Double = 0.10
    var whiteColor: RGBColor = RGBColor(red: 1, green: 1, blue: 1)

    enum CodingKeys: String, CodingKey {
        case blackThreshold
        case centerSamplingRect
        case mutedDarkOffEnabled
        case mutedDarkLuminanceThreshold
        case mutedDarkSaturationThreshold
        case pureWhiteSnapEnabled
        case pureWhiteLuminanceThreshold
        case pureWhiteSaturationThreshold
        case whiteColor
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blackThreshold = try container.decodeIfPresent(Double.self, forKey: .blackThreshold) ?? 0.03
        centerSamplingRect = try container.decodeIfPresent(NormalizedRect.self, forKey: .centerSamplingRect) ?? .defaultCenter
        mutedDarkOffEnabled = try container.decodeIfPresent(Bool.self, forKey: .mutedDarkOffEnabled) ?? true
        mutedDarkLuminanceThreshold = try container.decodeIfPresent(Double.self, forKey: .mutedDarkLuminanceThreshold) ?? 0.12
        mutedDarkSaturationThreshold = try container.decodeIfPresent(Double.self, forKey: .mutedDarkSaturationThreshold) ?? 0.12
        pureWhiteSnapEnabled = try container.decodeIfPresent(Bool.self, forKey: .pureWhiteSnapEnabled) ?? true
        pureWhiteLuminanceThreshold = try container.decodeIfPresent(Double.self, forKey: .pureWhiteLuminanceThreshold) ?? 0.82
        pureWhiteSaturationThreshold = try container.decodeIfPresent(Double.self, forKey: .pureWhiteSaturationThreshold) ?? 0.10
        whiteColor = try container.decodeIfPresent(RGBColor.self, forKey: .whiteColor) ?? RGBColor(red: 1, green: 1, blue: 1)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blackThreshold, forKey: .blackThreshold)
        try container.encode(centerSamplingRect, forKey: .centerSamplingRect)
        try container.encode(mutedDarkOffEnabled, forKey: .mutedDarkOffEnabled)
        try container.encode(mutedDarkLuminanceThreshold, forKey: .mutedDarkLuminanceThreshold)
        try container.encode(mutedDarkSaturationThreshold, forKey: .mutedDarkSaturationThreshold)
        try container.encode(pureWhiteSnapEnabled, forKey: .pureWhiteSnapEnabled)
        try container.encode(pureWhiteLuminanceThreshold, forKey: .pureWhiteLuminanceThreshold)
        try container.encode(pureWhiteSaturationThreshold, forKey: .pureWhiteSaturationThreshold)
        try container.encode(whiteColor, forKey: .whiteColor)
    }
}

struct SceneRuleSettings: Codable, Equatable {
    var darkSceneOffEnabled: Bool = false
    var darkSceneLuminanceThreshold: Double = 0.08
    var dimBrightNeutralEnabled: Bool = false
    var brightNeutralLuminanceThreshold: Double = 0.82
    var brightNeutralSaturationThreshold: Double = 0.14
    var brightNeutralDimAmount: Double = 0.45
}

struct BLESettings: Codable, Equatable {
    var preferredDeviceNamePrefix: String = "ELK-BLEDOM"
    var autoReconnect: Bool = true
}

enum DisplayInputSource: UInt16, Codable, CaseIterable, Identifiable {
    case displayPort1 = 0x0F
    case displayPort2 = 0x10
    case hdmi1 = 0x11
    case hdmi2 = 0x12
    case usbC = 0x1B

    var id: UInt16 { rawValue }

    var title: String {
        switch self {
        case .displayPort1: "DisplayPort 1"
        case .displayPort2: "DisplayPort 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .usbC: "USB-C"
        }
    }

    var shortTitle: String {
        switch self {
        case .displayPort1: "DP 1"
        case .displayPort2: "DP 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .usbC: "USB-C"
        }
    }

    var codeText: String {
        Self.codeText(for: rawValue)
    }

    static func title(for code: UInt16) -> String {
        guard code != 0 else { return "Unknown" }
        return Self(rawValue: code)?.shortTitle ?? "Input \(codeText(for: code))"
    }

    static func codeText(for code: UInt16) -> String {
        String(format: "0x%02X", code)
    }
}

struct DisplaySyncSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var pollingRateHz: Double = 2
    var awayInputAssignments: [String: DisplayInputSource] = [:]

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case pollingRateHz
        case awayInputAssignments
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        pollingRateHz = (try container.decodeIfPresent(Double.self, forKey: .pollingRateHz) ?? 2).clamped(to: 1 ... 10)

        if let rawAssignments = try container.decodeIfPresent([String: UInt16].self, forKey: .awayInputAssignments) {
            awayInputAssignments = rawAssignments.compactMapValues(DisplayInputSource.init(rawValue:))
        } else {
            awayInputAssignments = [:]
        }
    }
}

struct AppPreferences: Codable, Equatable {
    var lightingMode: LightingMode = .dynamic
    var dynamicAnalysisMode: DynamicAnalysisMode = .full
    var staticHue: Double = 0.02
    var brightness: Double = 0.72
    var lastLightEnabled: Bool = true
    var whiteOverrideEnabled: Bool = false
    var general: GeneralSettings = .init()
    var dynamic: DynamicSettings = .init()
    var calibration: CalibrationSettings = .init()
    var sceneRules: SceneRuleSettings = .init()
    var ble: BLESettings = .init()
    var displaySync: DisplaySyncSettings = .init()

    enum CodingKeys: String, CodingKey {
        case lightingMode
        case dynamicAnalysisMode
        case staticHue
        case brightness
        case lastLightEnabled
        case whiteOverrideEnabled
        case general
        case dynamic
        case calibration
        case sceneRules
        case ble
        case displaySync
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lightingMode = try container.decodeIfPresent(LightingMode.self, forKey: .lightingMode) ?? .dynamic
        dynamicAnalysisMode = try container.decodeIfPresent(DynamicAnalysisMode.self, forKey: .dynamicAnalysisMode) ?? .full
        staticHue = try container.decodeIfPresent(Double.self, forKey: .staticHue) ?? 0.02
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0.72
        lastLightEnabled = try container.decodeIfPresent(Bool.self, forKey: .lastLightEnabled) ?? true
        whiteOverrideEnabled = try container.decodeIfPresent(Bool.self, forKey: .whiteOverrideEnabled) ?? false
        general = try container.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .init()
        dynamic = try container.decodeIfPresent(DynamicSettings.self, forKey: .dynamic) ?? .init()
        if let decodedCalibration = try container.decodeIfPresent(CalibrationSettings.self, forKey: .calibration) {
            calibration = decodedCalibration
        } else {
            var legacyCalibration = CalibrationSettings()
            legacyCalibration.blackThreshold = dynamic.blackThreshold
            legacyCalibration.mutedDarkOffEnabled = dynamic.mutedDarkOffEnabled
            legacyCalibration.mutedDarkLuminanceThreshold = dynamic.mutedDarkLuminanceThreshold
            legacyCalibration.mutedDarkSaturationThreshold = dynamic.mutedDarkSaturationThreshold
            calibration = legacyCalibration
        }
        sceneRules = try container.decodeIfPresent(SceneRuleSettings.self, forKey: .sceneRules) ?? .init()
        ble = try container.decodeIfPresent(BLESettings.self, forKey: .ble) ?? .init()
        displaySync = try container.decodeIfPresent(DisplaySyncSettings.self, forKey: .displaySync) ?? .init()
    }
}

struct PermissionState: Equatable {
    var bluetoothAuthorized: Bool = false
    var screenRecordingAuthorized: Bool = false
}

enum DisplaySyncDisplayState: Equatable {
    case disabled
    case ready
    case connected
    case syncing
    case switching
    case sent
    case away
    case disconnected
    case unsupported
    case error(String)

    var label: String {
        switch self {
        case .disabled: "Disabled"
        case .ready: "Ready"
        case .connected: "Synced"
        case .syncing: "Syncing"
        case .switching: "Switching"
        case .sent: "Sent"
        case .away: "Away"
        case .disconnected: "Disconnected"
        case .unsupported: "Unsupported"
        case .error(let message): "Error \(message)"
        }
    }

    var tint: Color {
        switch self {
        case .connected:
            .green
        case .ready:
            .secondary
        case .syncing, .switching, .sent:
            .orange
        case .away:
            .blue
        case .disconnected, .error:
            .red
        case .unsupported:
            .orange
        case .disabled:
            .secondary
        }
    }
}

struct DisplaySyncSnapshot: Equatable, Identifiable {
    var id: String
    var name: String
    var state: DisplaySyncDisplayState
    var lastBrightnessPercent: Double?
    var lastSeen: Date?
    var awayInput: DisplayInputSource?
    var currentInputCode: UInt16?
}

struct CaptureDiagnostics: Equatable {
    var streamState: CaptureStreamState = .idle
    var frameCount: Int = 0
    var analysisCount: Int = 0
    var sendCount: Int = 0
    var lastFrameTime: Date?
    var lastAnalyzedTime: Date?
    var lastSentTime: Date?
    var lastFrameStatus: String = "—"
    var frameSize: String = "—"
    var pixelFormat: String = "—"
    var screenColor: RGBColor = .black
    var ledColor: RGBColor = .black
    var sampleCount: Int = 0
    var lastError: String?
}

final class CapturedFrame {
    let pixelBuffer: CVPixelBuffer
    let presentationTimeStamp: CMTime
    let receivedAt: Date
    let statusLabel: String

    init(pixelBuffer: CVPixelBuffer, presentationTimeStamp: CMTime, receivedAt: Date, statusLabel: String) {
        self.pixelBuffer = pixelBuffer
        self.presentationTimeStamp = presentationTimeStamp
        self.receivedAt = receivedAt
        self.statusLabel = statusLabel
    }
}

struct FrameAnalysis: Equatable {
    let color: RGBColor
    let luminance: Double
    let saturation: Double
    let sampleCount: Int
    let frameWidth: Int
    let frameHeight: Int
    let pixelFormat: String
    let sourceTime: CMTime
    let capturedAt: Date
}

struct DynamicEngineConfiguration: Equatable {
    var analysisMode: DynamicAnalysisMode
    var colorExtractionMethod: ColorExtractionMethod
    var brightnessCap: Double
    var updateRate: Int
    var smoothing: Double
    var centerSamplingRect: NormalizedRect
    var edgeSamplingWidthPercent: Double
    var edgeZoneCount: Int
    var saturationWeight: Double
    var saturationBoost: Double
    var gamma: Double
    var blackThreshold: Double
    var mutedDarkOffEnabled: Bool
    var mutedDarkLuminanceThreshold: Double
    var mutedDarkSaturationThreshold: Double
    var pureWhiteSnapEnabled: Bool
    var pureWhiteLuminanceThreshold: Double
    var pureWhiteSaturationThreshold: Double
    var calibratedWhiteColor: RGBColor
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
