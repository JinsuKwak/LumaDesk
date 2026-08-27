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

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct GeneralSettings: Codable, Equatable {
    var launchAtLogin: Bool = false
    var autoTurnOn: Bool = false
    var autoTurnOff: Bool = true
    var theme: AppTheme = .system

    enum CodingKeys: String, CodingKey {
        case launchAtLogin
        case autoTurnOn
        case autoTurnOff
        case theme
        case startupBehavior
        case turnLightOffOnSleep
        case turnLightOnOnWake
        case attemptLightOffOnQuit
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        theme = try container.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system

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
        try container.encode(theme, forKey: .theme)
    }
}

enum DynamicCaptureLossBehavior: String, Codable, CaseIterable, Identifiable {
    case keepLastColor
    case turnLightOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepLastColor: "Keep last color"
        case .turnLightOff: "Turn light off"
        }
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
    var captureLossBehavior: DynamicCaptureLossBehavior = .keepLastColor

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
        case captureLossBehavior
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
        captureLossBehavior = try container.decodeIfPresent(DynamicCaptureLossBehavior.self, forKey: .captureLossBehavior) ?? .keepLastColor
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

/// The transport/command convention used to change an external display's active input.
/// The LG option follows its undocumented DDC2AB side channel; it is intentionally
/// explicit rather than an automatic fallback because most displays cannot confirm a
/// successful switch after their current video link is disconnected.
enum DisplayInputSwitchMethod: String, Codable, CaseIterable, Identifiable {
    case standardDDCCI
    case lgDDC2AB
    case customVCP

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standardDDCCI: "Standard DDC/CI"
        case .lgDDC2AB: "LG DDC2AB"
        case .customVCP: "Custom VCP"
        }
    }

    var detail: String {
        switch self {
        case .standardDDCCI: "Source 0x51 · VCP 0x60"
        case .lgDDC2AB: "Source 0x50 · VCP 0xF4"
        case .customVCP: "Custom source address, VCP, and value"
        }
    }
}

/// Legacy per-monitor switch setting. Kept only to migrate preferences written by
/// older LumaDesk builds.
struct DisplaySwitchProfile: Codable, Equatable {
    var method: DisplayInputSwitchMethod = .standardDDCCI
    var awayInputCode: UInt16 = DisplayInputSource.displayPort1.rawValue
    var customPacketSourceAddress: UInt8 = 0x51
    var customVCPCode: UInt8 = 0x60
    var retryCount: Int = 2
    var retryDelayMilliseconds: Int = 450

    static let standardDefault = DisplaySwitchProfile()

    var command: DisplayInputSwitchCommand {
        switch method {
        case .standardDDCCI:
            DisplayInputSwitchCommand(
                packetSourceAddress: 0x51,
                vcpCode: 0x60,
                value: awayInputCode,
                canVerifyCurrentInput: true
            )
        case .lgDDC2AB:
            DisplayInputSwitchCommand(
                packetSourceAddress: 0x50,
                vcpCode: 0xF4,
                value: awayInputCode,
                canVerifyCurrentInput: false
            )
        case .customVCP:
            DisplayInputSwitchCommand(
                packetSourceAddress: customPacketSourceAddress,
                vcpCode: customVCPCode,
                value: awayInputCode,
                canVerifyCurrentInput: false
            )
        }
    }

    var inputDescription: String {
        "0x\(String(format: "%04X", awayInputCode))"
    }
}

/// The DDC packet convention for one physical monitor. This belongs to the
/// monitor, not to a switching profile: every profile can reuse it.
struct MonitorDDCConfiguration: Codable, Equatable {
    var packetSourceAddress: UInt8 = 0x51
    var vcpCode: UInt8 = 0x60
    var pairingID: String?

    static let standardDefault = MonitorDDCConfiguration()

    var displayText: String {
        "Source 0x\(String(format: "%02X", packetSourceAddress)) · VCP 0x\(String(format: "%02X", vcpCode))"
    }

    func command(value: UInt16) -> DisplayInputSwitchCommand {
        DisplayInputSwitchCommand(
            packetSourceAddress: packetSourceAddress,
            vcpCode: vcpCode,
            value: value,
            canVerifyCurrentInput: packetSourceAddress == 0x51 && vcpCode == 0x60
        )
    }

    func networkIdentity(fallback: String) -> String {
        guard let pairingID = pairingID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pairingID.isEmpty
        else { return fallback }
        return "PAIR:\(pairingID.lowercased())"
    }
}

enum ProfileCoordinationMode: String, Codable, CaseIterable, Identifiable {
    case managed
    case thisDevice = "self"
    case restore
    case external

    var id: String { rawValue }

    var title: String {
        switch self {
        case .managed: "Mac + Windows"
        case .thisDevice: "This Device"
        case .restore: "Restore Layout"
        case .external: "External device"
        }
    }
}

enum ManagedProfileTarget: String, Codable, CaseIterable, Identifiable {
    case macOS
    case windows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: "Mac"
        case .windows: "Windows"
        }
    }
}

/// macOS intentionally exposes no hard-disable option. `handedOff` uses only
/// public CoreGraphics operations: another display becomes primary and the
/// handed display is folded into that desktop by mirroring while it is away.
enum MacDisplayBehavior: String, Codable, CaseIterable, Identifiable {
    case unchanged
    case primary
    case extended
    case mirrorPrimary
    case handedOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchanged: "Unchanged"
        case .primary: "Primary"
        case .extended: "Extended"
        case .mirrorPrimary: "Mirror Primary"
        case .handedOff: "Handed Off"
        }
    }
}

enum WindowsDisplayBehavior: String, Codable, CaseIterable, Identifiable {
    case unchanged
    case primary
    case extended
    case mirrorPrimary
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unchanged: "Unchanged"
        case .primary: "Primary"
        case .extended: "Extended"
        case .mirrorPrimary: "Mirror Primary"
        case .disabled: "Disabled"
        }
    }
}

struct MacGlobalHotKey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayText: String
}

struct WindowsGlobalHotKey: Codable, Equatable {
    var virtualKey: UInt32
    var modifiers: UInt32
    var displayText: String
}

/// A named, cross-host switching transaction. Missing monitor assignments and
/// missing topology behaviors intentionally leave the corresponding display
/// untouched. New fields decode with safe defaults so existing preferences
/// migrate without changing their current switching behavior.
struct DisplaySwitchingProfile: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var coordinationMode: ProfileCoordinationMode = .managed
    var restorePeerLayout: Bool = true
    var selfPrimaryMonitorID: String = ""
    var peerPrimaryMonitorID: String = ""
    var layoutPrimaryMonitorID: String = ""
    var layoutMonitorIDs: [String] = []
    var inputAssignments: [String: UInt16] = [:]
    var macDisplayBehaviors: [String: MacDisplayBehavior] = [:]
    var windowsDisplayBehaviors: [String: WindowsDisplayBehavior] = [:]
    var macHotKey: MacGlobalHotKey?
    var windowsHotKey: WindowsGlobalHotKey?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coordinationMode
        case restorePeerLayout
        case selfPrimaryMonitorID
        case peerPrimaryMonitorID
        case layoutPrimaryMonitorID
        case layoutMonitorIDs
        case inputAssignments
        case macDisplayBehaviors
        case windowsDisplayBehaviors
        case macHotKey
        case windowsHotKey
    }

    init(
        id: UUID = UUID(),
        name: String,
        coordinationMode: ProfileCoordinationMode = .managed,
        restorePeerLayout: Bool = true,
        selfPrimaryMonitorID: String = "",
        peerPrimaryMonitorID: String = "",
        layoutPrimaryMonitorID: String = "",
        layoutMonitorIDs: [String] = [],
        inputAssignments: [String: UInt16] = [:],
        macDisplayBehaviors: [String: MacDisplayBehavior] = [:],
        windowsDisplayBehaviors: [String: WindowsDisplayBehavior] = [:],
        macHotKey: MacGlobalHotKey? = nil,
        windowsHotKey: WindowsGlobalHotKey? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinationMode = coordinationMode
        self.restorePeerLayout = restorePeerLayout
        self.selfPrimaryMonitorID = selfPrimaryMonitorID
        self.peerPrimaryMonitorID = peerPrimaryMonitorID
        self.layoutPrimaryMonitorID = layoutPrimaryMonitorID
        self.layoutMonitorIDs = layoutMonitorIDs
        self.inputAssignments = inputAssignments
        self.macDisplayBehaviors = macDisplayBehaviors
        self.windowsDisplayBehaviors = windowsDisplayBehaviors
        self.macHotKey = macHotKey
        self.windowsHotKey = windowsHotKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // Existing profiles were intentionally one-way. Preserve that behavior
        // until the user explicitly opts a profile into Mac + Windows handshakes.
        coordinationMode = try container.decodeIfPresent(ProfileCoordinationMode.self, forKey: .coordinationMode) ?? .external
        restorePeerLayout = try container.decodeIfPresent(Bool.self, forKey: .restorePeerLayout) ?? true
        selfPrimaryMonitorID = try container.decodeIfPresent(String.self, forKey: .selfPrimaryMonitorID) ?? ""
        peerPrimaryMonitorID = try container.decodeIfPresent(String.self, forKey: .peerPrimaryMonitorID)
            ?? selfPrimaryMonitorID
        layoutPrimaryMonitorID = try container.decodeIfPresent(String.self, forKey: .layoutPrimaryMonitorID) ?? ""
        layoutMonitorIDs = try container.decodeIfPresent([String].self, forKey: .layoutMonitorIDs) ?? []
        inputAssignments = try container.decodeIfPresent([String: UInt16].self, forKey: .inputAssignments) ?? [:]
        macDisplayBehaviors = try container.decodeIfPresent([String: MacDisplayBehavior].self, forKey: .macDisplayBehaviors) ?? [:]
        windowsDisplayBehaviors = try container.decodeIfPresent([String: WindowsDisplayBehavior].self, forKey: .windowsDisplayBehaviors) ?? [:]
        macHotKey = try container.decodeIfPresent(MacGlobalHotKey.self, forKey: .macHotKey)
        windowsHotKey = try container.decodeIfPresent(WindowsGlobalHotKey.self, forKey: .windowsHotKey)
    }
}

struct DisplaySyncSettings: Codable, Equatable {
    var isEnabled: Bool = false
    var pollingRateHz: Double = 2
    var monitorDDCConfigurations: [String: MonitorDDCConfiguration] = [:]
    var switchingProfiles: [DisplaySwitchingProfile] = []
    var defaultSwitchingProfileID: UUID?

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case pollingRateHz
        case monitorDDCConfigurations
        case switchingProfiles
        case defaultSwitchingProfileID
        // Legacy key, written by builds which had one "away" setting per monitor.
        case switchProfiles
        case awayInputAssignments
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        pollingRateHz = (try container.decodeIfPresent(Double.self, forKey: .pollingRateHz) ?? 2).clamped(to: 1 ... 10)

        monitorDDCConfigurations = try container.decodeIfPresent([String: MonitorDDCConfiguration].self, forKey: .monitorDDCConfigurations) ?? [:]
        switchingProfiles = try container.decodeIfPresent([DisplaySwitchingProfile].self, forKey: .switchingProfiles) ?? []
        defaultSwitchingProfileID = try container.decodeIfPresent(UUID.self, forKey: .defaultSwitchingProfileID)

        // Migrate the previous per-monitor method/value model into one reusable
        // default profile. This preserves both the command convention and target.
        if switchingProfiles.isEmpty,
           let legacyProfiles = try container.decodeIfPresent([String: DisplaySwitchProfile].self, forKey: .switchProfiles),
           !legacyProfiles.isEmpty
        {
            let assignments = legacyProfiles.mapValues(\.awayInputCode)
            monitorDDCConfigurations = legacyProfiles.mapValues { legacy in
                let command = legacy.command
                return MonitorDDCConfiguration(packetSourceAddress: command.packetSourceAddress, vcpCode: command.vcpCode)
            }
            let profile = DisplaySwitchingProfile(
                name: "Default",
                coordinationMode: .external,
                inputAssignments: assignments
            )
            switchingProfiles = [profile]
            defaultSwitchingProfileID = profile.id
        } else if switchingProfiles.isEmpty,
                  let rawAssignments = try container.decodeIfPresent([String: UInt16].self, forKey: .awayInputAssignments),
                  !rawAssignments.isEmpty
        {
            let profile = DisplaySwitchingProfile(
                name: "Default",
                coordinationMode: .external,
                inputAssignments: rawAssignments
            )
            switchingProfiles = [profile]
            defaultSwitchingProfileID = profile.id
        }

        if defaultSwitchingProfileID == nil {
            defaultSwitchingProfileID = switchingProfiles.first?.id
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(pollingRateHz, forKey: .pollingRateHz)
        try container.encode(monitorDDCConfigurations, forKey: .monitorDDCConfigurations)
        try container.encode(switchingProfiles, forKey: .switchingProfiles)
        try container.encodeIfPresent(defaultSwitchingProfileID, forKey: .defaultSwitchingProfileID)
    }
}

struct LANPeerSettings: Codable, Equatable {
    var isEnabled: Bool = true
    var deviceName: String = Host.current().localizedName ?? "Mac"
    var sharedKey: String = ""
    var commandPort: UInt16 = 47_831
    var rollbackOnPeerFailure: Bool = true
    var confirmationTimeoutSeconds: Int = 5

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case deviceName
        case sharedKey
        case commandPort
        case rollbackOnPeerFailure
        case confirmationTimeoutSeconds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? (Host.current().localizedName ?? "Mac")
        sharedKey = try container.decodeIfPresent(String.self, forKey: .sharedKey) ?? ""
        commandPort = try container.decodeIfPresent(UInt16.self, forKey: .commandPort) ?? 47_831
        rollbackOnPeerFailure = try container.decodeIfPresent(Bool.self, forKey: .rollbackOnPeerFailure) ?? true
        confirmationTimeoutSeconds = min(max(
            try container.decodeIfPresent(Int.self, forKey: .confirmationTimeoutSeconds) ?? 5,
            2
        ), 15)
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
    var lanPeer: LANPeerSettings = .init()

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
        case lanPeer
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
        lanPeer = try container.decodeIfPresent(LANPeerSettings.self, forKey: .lanPeer) ?? .init()
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
    var displayNumber: Int
    var state: DisplaySyncDisplayState
    var lastBrightnessPercent: Double?
    var lastSeen: Date?
    var ddcConfiguration: MonitorDDCConfiguration
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
