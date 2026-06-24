import SwiftUI

private enum SettingsTab: CaseIterable, Hashable {
    case general
    case dynamic
    case calibration
    case device
    case displays

    var title: String {
        switch self {
        case .general: "General"
        case .dynamic: "Dynamic"
        case .calibration: "Calibration"
        case .device: "Device"
        case .displays: "Displays"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dynamic: "waveform.path.ecg"
        case .calibration: "dial.medium"
        case .device: "dot.radiowaves.left.and.right"
        case .displays: "display"
        }
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var appState: AppStateStore
    @State private var selection: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LumaDesk")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 18)

                        Text(tab.title)
                            .font(.system(size: 13, weight: .medium))

                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(12)
        .frame(minWidth: 156, idealWidth: 156, maxWidth: 156, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selection {
        case .general:
            generalPane
        case .dynamic:
            dynamicPane
        case .calibration:
            calibrationPane
        case .device:
            devicePane
        case .displays:
            displaysPane
        }
    }

    private var generalPane: some View {
        Form {
            Section("Launch") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { appState.preferences.general.launchAtLogin },
                        set: appState.setLaunchAtLogin
                    )
                )

                if let launchAtLoginError = appState.launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Lifecycle") {
                Toggle(
                    "Automatically turn light on when LumaDesk launches or Mac wakes",
                    isOn: Binding(
                        get: { appState.preferences.general.autoTurnOn },
                        set: appState.setAutoTurnOn
                    )
                )

                Toggle(
                    "Automatically turn light off when Mac sleeps or app quits",
                    isOn: Binding(
                        get: { appState.preferences.general.autoTurnOff },
                        set: appState.setAutoTurnOff
                    )
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var dynamicPane: some View {
        Form {
            Section("Sampling") {
                LabeledContent("Target") {
                    Text("Main display")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Downsample") {
                    Text("160 px")
                        .foregroundStyle(.secondary)
                }

                settingsSlider(
                    title: "Rate",
                    valueText: "\(appState.preferences.dynamic.updateRate) fps",
                    value: Binding(
                        get: { Double(appState.preferences.dynamic.updateRate) },
                        set: appState.setUpdateRate
                    ),
                    range: 1 ... 60,
                    step: 1
                )

                settingsSlider(
                    title: "Edge depth",
                    valueText: "\(Int(appState.preferences.dynamic.edgeSamplingWidthPercent.rounded()))%",
                    value: Binding(
                        get: { appState.preferences.dynamic.edgeSamplingWidthPercent },
                        set: appState.setEdgeSamplingWidth
                    ),
                    range: 5 ... 20
                )

                settingsSlider(
                    title: "Zones",
                    valueText: "\(appState.preferences.dynamic.edgeZoneCount)",
                    value: Binding(
                        get: { Double(appState.preferences.dynamic.edgeZoneCount) },
                        set: appState.setEdgeZoneCount
                    ),
                    range: 4 ... 64,
                    step: 1
                )
            }

            Section("Color") {
                Picker(
                    "Algorithm",
                    selection: Binding(
                        get: { appState.preferences.dynamic.colorExtractionMethod },
                        set: appState.setColorExtractionMethod
                    )
                ) {
                    ForEach(ColorExtractionMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)

                settingsSlider(
                    title: "Smoothing",
                    valueText: appState.preferences.dynamic.smoothing.formatted(.percent.precision(.fractionLength(0))),
                    value: Binding(
                        get: { appState.preferences.dynamic.smoothing },
                        set: appState.setSmoothing
                    ),
                    range: 0 ... 1
                )

                settingsSlider(
                    title: "Color weight",
                    valueText: appState.preferences.dynamic.saturationWeight.formatted(.number.precision(.fractionLength(2))),
                    value: Binding(
                        get: { appState.preferences.dynamic.saturationWeight },
                        set: appState.setSaturationWeight
                    ),
                    range: 0 ... 3
                )

                settingsSlider(
                    title: "Saturation",
                    valueText: appState.preferences.dynamic.saturationBoost.formatted(.percent.precision(.fractionLength(0))),
                    value: Binding(
                        get: { appState.preferences.dynamic.saturationBoost },
                        set: appState.setSaturationBoost
                    ),
                    range: 0 ... 1
                )

                settingsSlider(
                    title: "Gamma",
                    valueText: appState.preferences.dynamic.gamma.formatted(.number.precision(.fractionLength(1))),
                    value: Binding(
                        get: { appState.preferences.dynamic.gamma },
                        set: appState.setGamma
                    ),
                    range: 1 ... 4
                )
            }

            Section("Permissions") {
                permissionRow(
                    title: "Screen Recording",
                    granted: appState.permissionState.screenRecordingAuthorized,
                    actionTitle: "Open Settings",
                    action: appState.openScreenRecordingSettings
                )

                Text("Enable manually in macOS Settings, then return here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                HStack {
                    diagnosticLabel("Capture", value: appState.captureDiagnostics.streamState.rawValue.capitalized)
                    diagnosticLabel("Frames", value: compactCount(appState.captureDiagnostics.frameCount))
                    diagnosticLabel("Sends", value: compactCount(appState.captureDiagnostics.sendCount))
                }

                HStack {
                    diagnosticLabel("Status", value: appState.captureDiagnostics.lastFrameStatus)
                    diagnosticLabel("Samples", value: "\(appState.captureDiagnostics.sampleCount)")
                    diagnosticLabel("Size", value: appState.captureDiagnostics.frameSize)
                    diagnosticLabel("Format", value: appState.captureDiagnostics.pixelFormat)
                }

                HStack {
                    diagnosticLabel("Frame", value: appState.captureDiagnostics.lastFrameTime?.formatted(date: .omitted, time: .standard) ?? "—")
                    diagnosticLabel("Analyzed", value: appState.captureDiagnostics.lastAnalyzedTime?.formatted(date: .omitted, time: .standard) ?? "—")
                    diagnosticLabel("Send", value: appState.captureDiagnostics.lastSentTime?.formatted(date: .omitted, time: .standard) ?? "—")
                }

                HStack(spacing: 12) {
                    colorSwatch("Screen", color: appState.captureDiagnostics.screenColor)
                    colorSwatch("LED", color: appState.captureDiagnostics.ledColor)
                    Spacer()
                }

                if let error = appState.captureDiagnostics.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Restart capture") {
                    appState.restartDynamicCapture()
                }
                .disabled(appState.preferences.whiteOverrideEnabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var calibrationPane: some View {
        Form {
            Section("Center sample") {
                LabeledContent("Area") {
                    Text(centerRectText(appState.preferences.calibration.centerSamplingRect))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Select area") {
                        appState.selectCenterSamplingArea()
                    }

                    Button("Reset") {
                        appState.resetCenterSamplingArea()
                    }
                }

                Text("Used by Center mode. Stored as normalized primary-display coordinates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("White") {
                HStack(alignment: .center, spacing: 18) {
                    ColorWheelPicker(
                        color: Binding(
                            get: { appState.preferences.calibration.whiteColor },
                            set: appState.setCalibratedWhiteColor
                        )
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        colorSwatch("White", color: appState.preferences.calibration.whiteColor)

                        Text("Used by White mode and neutral Dynamic output.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Button("Reset white") {
                            appState.setCalibratedWhiteColor(RGBColor(red: 1, green: 1, blue: 1))
                        }
                    }
                }
            }

            Section("Pure white") {
                Toggle(
                    "Snap near-white scenes",
                    isOn: Binding(
                        get: { appState.preferences.calibration.pureWhiteSnapEnabled },
                        set: appState.setPureWhiteSnapEnabled
                    )
                )

                settingsSlider(
                    title: "White luminance",
                    valueText: appState.preferences.calibration.pureWhiteLuminanceThreshold.formatted(.number.precision(.fractionLength(2))),
                    value: Binding(
                        get: { appState.preferences.calibration.pureWhiteLuminanceThreshold },
                        set: appState.setPureWhiteLuminanceThreshold
                    ),
                    range: 0.4 ... 1
                )

                settingsSlider(
                    title: "White saturation",
                    valueText: appState.preferences.calibration.pureWhiteSaturationThreshold.formatted(.number.precision(.fractionLength(2))),
                    value: Binding(
                        get: { appState.preferences.calibration.pureWhiteSaturationThreshold },
                        set: appState.setPureWhiteSaturationThreshold
                    ),
                    range: 0 ... 0.35
                )
            }

            Section("Dark") {
                settingsSlider(
                    title: "Black",
                    valueText: appState.preferences.calibration.blackThreshold.formatted(.number.precision(.fractionLength(2))),
                    value: Binding(
                        get: { appState.preferences.calibration.blackThreshold },
                        set: appState.setBlackThreshold
                    ),
                    range: 0 ... 0.2
                )

                Toggle(
                    "Muted dark off",
                    isOn: Binding(
                        get: { appState.preferences.calibration.mutedDarkOffEnabled },
                        set: appState.setMutedDarkOffEnabled
                    )
                )

                settingsSlider(
                    title: "Muted luminance",
                    valueText: appState.preferences.calibration.mutedDarkLuminanceThreshold.formatted(.number.precision(.fractionLength(2))),
                    value: Binding(
                        get: { appState.preferences.calibration.mutedDarkLuminanceThreshold },
                        set: appState.setMutedDarkLuminanceThreshold
                    ),
                    range: 0 ... 0.4
                )

                settingsSlider(
                    title: "Muted saturation",
                    valueText: appState.preferences.calibration.mutedDarkSaturationThreshold.formatted(.number.precision(.fractionLength(2))),
                    value: Binding(
                        get: { appState.preferences.calibration.mutedDarkSaturationThreshold },
                        set: appState.setMutedDarkSaturationThreshold
                    ),
                    range: 0 ... 0.4
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var devicePane: some View {
        Form {
            Section("Status") {
                LabeledContent("Device") {
                    Text(appState.connectionState.deviceName ?? "None")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Circle()
                        .fill(appState.connectionState.tint)
                        .frame(width: 8, height: 8)

                    Text(appState.connectionState.label)
                        .foregroundStyle(.secondary)
                }

                TextField(
                    "Device name prefix",
                    text: Binding(
                        get: { appState.preferences.ble.preferredDeviceNamePrefix },
                        set: appState.setPreferredDeviceNamePrefix
                    )
                )

                Toggle(
                    "Auto reconnect",
                    isOn: Binding(
                        get: { appState.preferences.ble.autoReconnect },
                        set: appState.setAutoReconnect
                    )
                )

                Button("Retry connection") {
                    appState.retryDeviceConnection()
                }

                Button("Disconnect") {
                    appState.disconnectDevice()
                }
                .disabled(!appState.connectionState.canDisconnect)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Bluetooth",
                    granted: appState.permissionState.bluetoothAuthorized,
                    actionTitle: "Open Settings",
                    action: appState.openBluetoothSettings
                )
            }

            Section("Backend") {
                Text("BLE transport and ELK-BLEDOM packet generation stay isolated from the UI and Dynamic engine.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var displaysPane: some View {
        Form {
            Section("Sync") {
                Toggle(
                    "Sync external display brightness to built-in display",
                    isOn: Binding(
                        get: { appState.preferences.displaySync.isEnabled },
                        set: appState.setDisplaySyncEnabled
                    )
                )

                settingsSlider(
                    title: "Polling",
                    valueText: "\(appState.preferences.displaySync.pollingRateHz.formatted(.number.precision(.fractionLength(1)))) Hz",
                    value: Binding(
                        get: { appState.preferences.displaySync.pollingRateHz },
                        set: appState.setDisplaySyncPollingRate
                    ),
                    range: 1 ... 10,
                    step: 0.5
                )
                .disabled(!appState.preferences.displaySync.isEnabled)

                LabeledContent("Source") {
                    Text(appState.displaySyncSourceStatus)
                        .foregroundStyle(sourceStatusColor(appState.displaySyncSourceStatus))
                }

                HStack {
                    Text("Display attach/detach is event-based. Polling only watches built-in brightness.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Switch Away") {
                        appState.switchDisplaysAway()
                    }

                    Button("Refresh") {
                        appState.refreshDisplaySync()
                    }
                }
            }

            Section("Monitors") {
                if appState.displaySyncSnapshots.isEmpty {
                    Text(appState.preferences.displaySync.isEnabled ? "No external displays found." : "Use Refresh to scan displays.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.displaySyncSnapshots) { snapshot in
                        displaySyncRow(snapshot)
                    }
                }
            }

            Section("Backend") {
                Text("Uses a vendored minimal AppleSiliconDDC path for DDC/CI luminance writes. Unsupported displays stay visible for this app session only.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func permissionRow(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(granted ? "Allowed" : "Needs access")
                .foregroundStyle(granted ? .green : .secondary)
            Button(actionTitle, action: action)
        }
    }

    private func settingsSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .foregroundStyle(.secondary)
            }

            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    private func diagnosticLabel(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorSwatch(_ title: String, color: RGBColor) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.swiftUIColor)
                .frame(width: 42, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(rgbText(color))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func displaySyncRow(_ snapshot: DisplaySyncSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.name)
                    .font(.system(size: 13, weight: .medium))

                Text(displaySyncDetailText(snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 5) {
                Menu {
                    Button("None") {
                        appState.setAwayInput(nil, forDisplayID: snapshot.id)
                    }

                    Divider()

                    ForEach(DisplayInputSource.allCases) { source in
                        Button(source.title) {
                            appState.setAwayInput(source, forDisplayID: snapshot.id)
                        }
                    }
                } label: {
                    Text(snapshot.awayInput.map { "Away \($0.shortTitle)" } ?? "Away")
                        .font(.caption)
                }
                .frame(width: 92, alignment: .trailing)

                HStack(spacing: 6) {
                    Circle()
                        .fill(snapshot.state.tint)
                        .frame(width: 8, height: 8)

                    Text(snapshot.state.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 100, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    private func displaySyncDetailText(_ snapshot: DisplaySyncSnapshot) -> String {
        var parts: [String] = []

        if let lastBrightnessPercent = snapshot.lastBrightnessPercent {
            parts.append(lastBrightnessPercent.formatted(.percent.precision(.fractionLength(0))))
        }

        if let currentInputCode = snapshot.currentInputCode {
            parts.append("Input \(DisplayInputSource.title(for: currentInputCode))")
        }

        return parts.isEmpty ? "Not synced" : parts.joined(separator: " · ")
    }

    private func sourceStatusColor(_ status: String) -> Color {
        if status == "Off" || status == "Scanning" {
            return .secondary
        }

        if status.hasPrefix("Built-in") {
            return .green
        }

        return .orange
    }

    private func rgbText(_ color: RGBColor) -> String {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        return "\(red), \(green), \(blue)"
    }

    private func centerRectText(_ rect: NormalizedRect) -> String {
        let rect = rect.clamped(minimumSize: 0.02)
        let x = Int((rect.x * 100).rounded())
        let y = Int((rect.y * 100).rounded())
        let width = Int((rect.width * 100).rounded())
        let height = Int((rect.height * 100).rounded())
        return "x \(x)%  y \(y)%  w \(width)%  h \(height)%"
    }

    private func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000.0)
        }

        if value >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000.0)
        }

        return "\(value)"
    }
}
