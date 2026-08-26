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
    @State private var monitorDDCDrafts: [String: MonitorDDCConfiguration] = [:]
    @State private var switchingProfileDrafts: [DisplaySwitchingProfile] = []
    @State private var defaultSwitchingProfileID: UUID?
    @State private var unlockedDDCDisplays = Set<String>()
    @State private var lanSharedKeyDraft = ""

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar

            Divider()

            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(.ultraThinMaterial)
        .preferredColorScheme(appState.preferences.general.theme.colorScheme)
        .onAppear {
            appState.refreshPermissions()
            lanSharedKeyDraft = appState.preferences.lanPeer.sharedKey
            loadDisplaySwitchDrafts(appState.displaySyncSnapshots)
        }
        .onChange(of: appState.displaySyncSnapshots) { _, snapshots in
            loadDisplaySwitchDrafts(snapshots)
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
            Section("Appearance") {
                Picker(
                    "Theme",
                    selection: Binding(
                        get: { appState.preferences.general.theme },
                        set: appState.setTheme
                    )
                ) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)

                Text("Window materials remain translucent in both Light and Dark modes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Mac + Windows LAN") {
                Toggle(
                    "Enable managed profile coordination",
                    isOn: Binding(
                        get: { appState.preferences.lanPeer.isEnabled },
                        set: appState.setLANPeerEnabled
                    )
                )

                LabeledContent("Device name") {
                    TextField(
                        "Mac",
                        text: Binding(
                            get: { appState.preferences.lanPeer.deviceName },
                            set: appState.setLANDeviceName
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                }

                LabeledContent("Pairing key") {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            TextField(
                                "",
                                text: $lanSharedKeyDraft,
                                prompt: Text("Pairing key")
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .foregroundStyle(isLANSharedKeyDraftValid ? Color.primary : Color.red)
                            .overlay {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(isLANSharedKeyDraftValid ? Color.clear : Color.red, lineWidth: 1)
                            }
                            .frame(width: 230)

                            Button("Save") {
                                lanSharedKeyDraft = lanSharedKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                                appState.setLANSharedKey(lanSharedKeyDraft)
                            }
                            .disabled(!isLANSharedKeyDraftValid || lanSharedKeyDraft == appState.preferences.lanPeer.sharedKey)
                        }

                        if !isLANSharedKeyDraftValid {
                            Text("Use 8 or more characters")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }
                }

                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        Text(appState.lanPeerStatus)
                            .foregroundStyle(.secondary)

                        Button("Rescan") {
                            appState.rescanLANPeers()
                        }
                        .disabled(!appState.preferences.lanPeer.isEnabled)
                    }
                }

                Text("Enter the exact same key in the Windows app. Peers are discovered at launch, on demand, or with Rescan; there is no periodic background broadcast.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

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

            Section("Capture interruption") {
                Picker(
                    "When the main display disconnects",
                    selection: Binding(
                        get: { appState.preferences.dynamic.captureLossBehavior },
                        set: appState.setDynamicCaptureLossBehavior
                    )
                ) {
                    ForEach(DynamicCaptureLossBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                }

                Text("Dynamic capture retries automatically after macOS assigns a new main display or the display reconnects.")
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
                    Text("Input status is refreshed every second when the display still answers DDC.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Spacer()

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

                    HStack {
                        Text("Unlock DDC/CI fields to edit. Nothing is applied until saved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Save Display Settings") {
                            appState.saveDisplaySwitchSettings(
                                monitorConfigurations: monitorDDCDrafts,
                                switchingProfiles: switchingProfileDrafts,
                                defaultProfileID: defaultSwitchingProfileID
                            )
                            unlockedDDCDisplays.removeAll()
                        }
                        .disabled(!hasUnsavedDisplaySwitchChanges || !areProfileNamesValid || !arePairingIDsValid)
                    }
                    .padding(.top, 4)

                    if !arePairingIDsValid {
                        Text("Pairing IDs must be unique on this device.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Switching Profiles") {
                if switchingProfileDrafts.isEmpty {
                    Text("Add a profile to choose which connected monitors should change input together.")
                        .foregroundStyle(.secondary)
                }

                ForEach(switchingProfileDrafts.indices, id: \.self) { index in
                    switchingProfileRow(index)
                }

                Button {
                    addSwitchingProfile()
                } label: {
                    Label("Add Profile", systemImage: "plus")
                }

                if !areProfileNamesValid {
                    Text("Profile names must be unique and cannot be empty.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if let hotKeyRegistrationError = appState.hotKeyRegistrationError {
                    Text(hotKeyRegistrationError)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                Text("Profile inputs and display behaviors are stored locally on this Mac after Save Display Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Source is the DDC packet source address, not a monitor input. VCP is the command code used for every profile on that monitor.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("DDC/CI")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LG DDC2AB reference")
                        .fontWeight(.medium)
                    Text("Source 50 · VCP F4")
                    Text("HDMI 1 0090 · HDMI 2 0091 · DisplayPort 00D0")
                    Text("Enter hexadecimal values without the 0x prefix.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
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
        let configuration = monitorDDCDraft(for: snapshot)
        let isUnlocked = unlockedDDCDisplays.contains(snapshot.id)

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "display")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 12) {
                    Text(snapshot.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 12)

                    labeledHexField(
                        "Source",
                        value: hexBinding(
                            value: configuration.packetSourceAddress,
                            onSet: { value in
                                updateDDCDraft(forDisplayID: snapshot.id) { $0.packetSourceAddress = value }
                            }
                        ),
                        width: 44
                    )
                    .disabled(!isUnlocked)

                    labeledHexField(
                        "VCP",
                        value: hexBinding(
                            value: configuration.vcpCode,
                            onSet: { value in
                                updateDDCDraft(forDisplayID: snapshot.id) { $0.vcpCode = value }
                            }
                        ),
                        width: 44
                    )
                    .disabled(!isUnlocked)

                    Button {
                        if isUnlocked {
                            unlockedDDCDisplays.remove(snapshot.id)
                        } else {
                            unlockedDDCDisplays.insert(snapshot.id)
                        }
                    } label: {
                        Image(systemName: isUnlocked ? "lock.open" : "lock")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 22, height: 22, alignment: .center)
                    .contentShape(Rectangle())
                    .help(isUnlocked ? "Lock DDC/CI settings" : "Unlock DDC/CI settings")
                }

                HStack(alignment: .center, spacing: 8) {
                    Text("\(displayLabel(for: snapshot)) · \(displaySyncDetailText(snapshot))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    HStack(alignment: .center, spacing: 5) {
                        Circle()
                            .fill(snapshot.state.tint)
                            .frame(width: 7, height: 7)

                        Text(snapshot.state.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(displayInputStatusText(snapshot))
                }

                if isUnlocked {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Pairing ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "",
                            text: pairingIDBinding(forDisplayID: snapshot.id, configuration: configuration),
                            prompt: Text("desk-center")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.caption.monospaced())
                        .multilineTextAlignment(.leading)
                        .help("Use the same Pairing ID for this physical monitor on Mac and Windows.")

                        Text("Same value on both devices")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
    }

    private func displaySyncDetailText(_ snapshot: DisplaySyncSnapshot) -> String {
        if let lastBrightnessPercent = snapshot.lastBrightnessPercent {
            return lastBrightnessPercent.formatted(.percent.precision(.fractionLength(0)))
        }

        return "Not synced"
    }

    private func displayInputStatusText(_ snapshot: DisplaySyncSnapshot) -> String {
        if let currentInputCode = snapshot.currentInputCode {
            return "Current input: \(DisplayInputSource.title(for: currentInputCode))"
        }

        return "Current input unavailable"
    }

    private func displayLabel(for snapshot: DisplaySyncSnapshot) -> String {
        let pairingID = appState.preferences.displaySync.monitorDDCConfigurations[snapshot.id]?
            .pairingID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pairingID.isEmpty ? "Display \(snapshot.displayNumber)" : pairingID
    }

    private var hasUnsavedDisplaySwitchChanges: Bool {
        monitorDDCDrafts != appState.preferences.displaySync.monitorDDCConfigurations
            || switchingProfileDrafts != appState.preferences.displaySync.switchingProfiles
            || defaultSwitchingProfileID != appState.preferences.displaySync.defaultSwitchingProfileID
    }

    private var isLANSharedKeyDraftValid: Bool {
        lanSharedKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
    }

    private var arePairingIDsValid: Bool {
        let pairingIDs = monitorDDCDrafts.values.compactMap { configuration -> String? in
            let value = configuration.pairingID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return value.isEmpty ? nil : value
        }
        return Set(pairingIDs).count == pairingIDs.count
    }

    private func loadDisplaySwitchDrafts(_ snapshots: [DisplaySyncSnapshot]) {
        for snapshot in snapshots where monitorDDCDrafts[snapshot.id] == nil {
            monitorDDCDrafts[snapshot.id] = snapshot.ddcConfiguration
        }
        if switchingProfileDrafts.isEmpty {
            switchingProfileDrafts = appState.preferences.displaySync.switchingProfiles
            defaultSwitchingProfileID = appState.preferences.displaySync.defaultSwitchingProfileID
        }
        migrateProfileKeys(for: snapshots)
    }

    private func monitorDDCDraft(for snapshot: DisplaySyncSnapshot) -> MonitorDDCConfiguration {
        monitorDDCDrafts[snapshot.id] ?? snapshot.ddcConfiguration
    }

    private func updateDDCDraft(forDisplayID displayID: String, update: (inout MonitorDDCConfiguration) -> Void) {
        var configuration = monitorDDCDrafts[displayID] ?? .standardDefault
        update(&configuration)
        monitorDDCDrafts[displayID] = configuration
    }

    private func pairingIDBinding(
        forDisplayID displayID: String,
        configuration: MonitorDDCConfiguration
    ) -> Binding<String> {
        Binding(
            get: { monitorDDCDrafts[displayID]?.pairingID ?? configuration.pairingID ?? "" },
            set: { value in
                let oldKey = profileStorageKey(displayID: displayID, configuration: monitorDDCDrafts[displayID] ?? configuration)
                updateDDCDraft(forDisplayID: displayID) { $0.pairingID = value }
                let newConfiguration = monitorDDCDrafts[displayID] ?? configuration
                let newKey = profileStorageKey(displayID: displayID, configuration: newConfiguration)
                migrateProfileKey(from: oldKey, to: newKey)
            }
        )
    }

    private func profileStorageKey(for snapshot: DisplaySyncSnapshot) -> String {
        profileStorageKey(displayID: snapshot.id, configuration: monitorDDCDraft(for: snapshot))
    }

    private func profileStorageKey(displayID: String, configuration: MonitorDDCConfiguration) -> String {
        configuration.networkIdentity(fallback: displayID)
    }

    private func migrateProfileKeys(for snapshots: [DisplaySyncSnapshot]) {
        for snapshot in snapshots {
            migrateProfileKey(from: snapshot.id, to: profileStorageKey(for: snapshot))
        }
    }

    private func migrateProfileKey(from oldKey: String, to newKey: String) {
        guard oldKey.caseInsensitiveCompare(newKey) != .orderedSame else { return }
        for index in switchingProfileDrafts.indices {
            if switchingProfileDrafts[index].inputAssignments[newKey] == nil,
               let value = switchingProfileDrafts[index].inputAssignments.removeValue(forKey: oldKey) {
                switchingProfileDrafts[index].inputAssignments[newKey] = value
            }
            if switchingProfileDrafts[index].macDisplayBehaviors[newKey] == nil,
               let value = switchingProfileDrafts[index].macDisplayBehaviors.removeValue(forKey: oldKey) {
                switchingProfileDrafts[index].macDisplayBehaviors[newKey] = value
            }
            if switchingProfileDrafts[index].windowsDisplayBehaviors[newKey] == nil,
               let value = switchingProfileDrafts[index].windowsDisplayBehaviors.removeValue(forKey: oldKey) {
                switchingProfileDrafts[index].windowsDisplayBehaviors[newKey] = value
            }
        }
    }

    private func switchingProfileRow(_ index: Int) -> some View {
        let profile = switchingProfileDrafts[index]
        let isDefault = defaultSwitchingProfileID == profile.id

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 0) {
                Button {
                    defaultSwitchingProfileID = profile.id
                } label: {
                    Image(systemName: isDefault ? "star.fill" : "star")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDefault ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22, alignment: .center)
                .contentShape(Rectangle())
                .help(isDefault ? "Default switching profile" : "Make default switching profile")

                TextField("", text: Binding(
                    get: { switchingProfileDrafts[index].name },
                    set: { switchingProfileDrafts[index].name = $0 }
                ))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .multilineTextAlignment(.leading)
                .padding(.leading, 3)
                .frame(width: 300)

                Spacer(minLength: 10)

                Button(role: .destructive) {
                    let removedID = switchingProfileDrafts[index].id
                    switchingProfileDrafts.remove(at: index)
                    if defaultSwitchingProfileID == removedID {
                        defaultSwitchingProfileID = switchingProfileDrafts.first?.id
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22, alignment: .center)
                .contentShape(Rectangle())
                .help("Delete profile")
            }

            HStack(alignment: .center, spacing: 8) {
                Picker("", selection: Binding(
                    get: { switchingProfileDrafts[index].coordinationMode },
                    set: { switchingProfileDrafts[index].coordinationMode = $0 }
                )) {
                    ForEach(ProfileCoordinationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 132)

                if switchingProfileDrafts[index].coordinationMode == .managed {
                    Text("Mac → Windows")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("One-way DDC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text("Shortcut")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ShortcutRecorder(hotKey: Binding(
                    get: { switchingProfileDrafts[index].macHotKey },
                    set: { switchingProfileDrafts[index].macHotKey = $0 }
                ))
                .frame(width: 122, height: 22)
            }
            .padding(.leading, 25)

            ForEach(appState.displaySyncSnapshots) { snapshot in
                let profileKey = profileStorageKey(for: snapshot)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .center, spacing: 7) {
                        Toggle("", isOn: profileAssignmentEnabledBinding(profileIndex: index, displayID: profileKey))
                            .labelsHidden()
                            .toggleStyle(.checkbox)

                        Text("\(displayLabel(for: snapshot)) ·")
                            .font(.caption)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(snapshot.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)

                        Spacer(minLength: 8)

                        labeledHexField(
                            "Input",
                            value: profileInputBinding(profileIndex: index, displayID: profileKey),
                            width: 58
                        )
                        .disabled(switchingProfileDrafts[index].inputAssignments[profileKey] == nil)
                        .opacity(switchingProfileDrafts[index].inputAssignments[profileKey] == nil ? 0.45 : 1)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text("Display behavior")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 8)

                        Picker("This Mac", selection: macBehaviorBinding(profileIndex: index, displayID: profileKey)) {
                            ForEach(MacDisplayBehavior.allCases) { behavior in
                                Text(behavior.title).tag(behavior)
                            }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .frame(width: 150)

                        if switchingProfileDrafts[index].coordinationMode == .managed {
                            Picker("Windows", selection: windowsBehaviorBinding(profileIndex: index, displayID: profileKey)) {
                                ForEach(WindowsDisplayBehavior.allCases) { behavior in
                                    Text(behavior.title).tag(behavior)
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(width: 160)
                        }
                    }
                    .padding(.leading, 25)
                }
                .padding(.leading, 14)
                .padding(.vertical, 3)
            }
        }
        .padding(.vertical, 4)
    }

    private var areProfileNamesValid: Bool {
        let names = switchingProfileDrafts.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return !names.contains(where: \.isEmpty) && Set(names).count == names.count
    }

    private func addSwitchingProfile() {
        let existingNames = Set(switchingProfileDrafts.map { $0.name.lowercased() })
        var number = 1
        var name = "Profile \(number)"
        while existingNames.contains(name.lowercased()) {
            number += 1
            name = "Profile \(number)"
        }

        let profile = DisplaySwitchingProfile(name: name)
        switchingProfileDrafts.append(profile)
        if defaultSwitchingProfileID == nil {
            defaultSwitchingProfileID = profile.id
        }
    }

    private func profileAssignmentEnabledBinding(profileIndex: Int, displayID: String) -> Binding<Bool> {
        Binding(
            get: { switchingProfileDrafts[profileIndex].inputAssignments[displayID] != nil },
            set: { enabled in
                if enabled {
                    switchingProfileDrafts[profileIndex].inputAssignments[displayID] = DisplayInputSource.displayPort1.rawValue
                } else {
                    switchingProfileDrafts[profileIndex].inputAssignments.removeValue(forKey: displayID)
                }
            }
        )
    }

    private func profileInputBinding(profileIndex: Int, displayID: String) -> Binding<String> {
        Binding(
            get: { String(format: "%04X", switchingProfileDrafts[profileIndex].inputAssignments[displayID] ?? 0) },
            set: { text in
                guard let value = parseHex(text), value <= UInt32(UInt16.max) else { return }
                switchingProfileDrafts[profileIndex].inputAssignments[displayID] = UInt16(value)
            }
        )
    }

    private func macBehaviorBinding(profileIndex: Int, displayID: String) -> Binding<MacDisplayBehavior> {
        Binding(
            get: { switchingProfileDrafts[profileIndex].macDisplayBehaviors[displayID] ?? .unchanged },
            set: { behavior in
                if behavior == .unchanged {
                    switchingProfileDrafts[profileIndex].macDisplayBehaviors.removeValue(forKey: displayID)
                } else {
                    switchingProfileDrafts[profileIndex].macDisplayBehaviors[displayID] = behavior
                }
            }
        )
    }

    private func windowsBehaviorBinding(profileIndex: Int, displayID: String) -> Binding<WindowsDisplayBehavior> {
        Binding(
            get: { switchingProfileDrafts[profileIndex].windowsDisplayBehaviors[displayID] ?? .unchanged },
            set: { behavior in
                if behavior == .unchanged {
                    switchingProfileDrafts[profileIndex].windowsDisplayBehaviors.removeValue(forKey: displayID)
                } else {
                    switchingProfileDrafts[profileIndex].windowsDisplayBehaviors[displayID] = behavior
                }
            }
        )
    }

    private func hexField(_ title: String, value: Binding<String>, width: CGFloat) -> some View {
        TextField(title, text: value)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .controlSize(.small)
            .frame(width: width, height: 22)
    }

    private func labeledHexField(_ title: String, value: Binding<String>, width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            hexField("", value: value, width: width)
                .padding(.leading, 5)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hexBinding(value: UInt16, onSet: @escaping (UInt16) -> Void) -> Binding<String> {
        Binding(
            get: { String(format: "%04X", value) },
            set: { text in
                guard let parsed = parseHex(text), parsed <= UInt32(UInt16.max) else { return }
                onSet(UInt16(parsed))
            }
        )
    }

    private func hexBinding(value: UInt8, onSet: @escaping (UInt8) -> Void) -> Binding<String> {
        Binding(
            get: { String(format: "%02X", value) },
            set: { text in
                guard let parsed = parseHex(text), parsed <= UInt32(UInt8.max) else { return }
                onSet(UInt8(parsed))
            }
        )
    }

    private func parseHex(_ text: String) -> UInt32? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.lowercased().hasPrefix("0x") ? String(trimmed.dropFirst(2)) : trimmed
        return UInt32(digits, radix: 16)
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
