import Combine
import Foundation

@MainActor
final class AppStateStore: ObservableObject {
    @Published private(set) var preferences: AppPreferences
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var captureDiagnostics = CaptureDiagnostics()
    @Published private(set) var displaySyncSnapshots: [DisplaySyncSnapshot] = []
    @Published private(set) var displaySyncSourceStatus = "Off"
    @Published private(set) var permissionState = PermissionState()
    @Published var launchAtLoginError: String?

    private let preferencesStore: PreferencesStore
    private let permissionService: PermissionService
    private let launchAtLoginService: LaunchAtLoginService
    private let bleDeviceManager: BLEDeviceManager
    private let dynamicLightingEngine: DynamicLightingEngine
    private let centerRegionSelectionService: CenterRegionSelectionService
    private let displaySyncService: DisplaySyncService

    private var didBootstrap = false
    private var pendingStaticOutputTask: Task<Void, Never>?
    private var lastStaticOutputDate: Date?
    private var wakeLightingTask: Task<Void, Never>?

    init(
        preferencesStore: PreferencesStore,
        permissionService: PermissionService,
        launchAtLoginService: LaunchAtLoginService,
        bleDeviceManager: BLEDeviceManager,
        dynamicLightingEngine: DynamicLightingEngine,
        centerRegionSelectionService: CenterRegionSelectionService,
        displaySyncService: DisplaySyncService
    ) {
        self.preferencesStore = preferencesStore
        self.permissionService = permissionService
        self.launchAtLoginService = launchAtLoginService
        self.bleDeviceManager = bleDeviceManager
        self.dynamicLightingEngine = dynamicLightingEngine
        self.centerRegionSelectionService = centerRegionSelectionService
        self.displaySyncService = displaySyncService
        self.preferences = preferencesStore.load()

        bleDeviceManager.connectionStateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionState = state

                if case .connected = state {
                    self.applyLightingAfterDeviceReconnect()
                }
            }
        }

        dynamicLightingEngine.diagnosticsHandler = { [weak self] diagnostics in
            Task { @MainActor [weak self] in
                self?.captureDiagnostics = diagnostics
            }
        }

        dynamicLightingEngine.outputHandler = { [weak self] color in
            self?.sendDynamicColor(color)
        }

        displaySyncService.snapshotsHandler = { [weak self] snapshots in
            self?.displaySyncSnapshots = snapshots
        }

        displaySyncService.statusHandler = { [weak self] status in
            self?.displaySyncSourceStatus = status
        }
    }

    var currentStaticColor: RGBColor {
        RGBColor(hue: preferences.staticHue, brightness: preferences.brightness)
    }

    var currentWhiteColor: RGBColor {
        preferences.calibration.whiteColor.scaled(toBrightness: preferences.brightness)
    }

    var isDynamicOutputActive: Bool {
        preferences.lastLightEnabled
            && !preferences.whiteOverrideEnabled
            && preferences.lightingMode == .dynamic
    }

    var currentDynamicConfiguration: DynamicEngineConfiguration {
        DynamicEngineConfiguration(
            analysisMode: preferences.dynamicAnalysisMode,
            colorExtractionMethod: preferences.dynamic.colorExtractionMethod,
            brightnessCap: preferences.brightness,
            updateRate: preferences.dynamic.updateRate,
            smoothing: preferences.dynamic.smoothing,
            centerSamplingRect: preferences.calibration.centerSamplingRect,
            edgeSamplingWidthPercent: preferences.dynamic.edgeSamplingWidthPercent,
            edgeZoneCount: preferences.dynamic.edgeZoneCount,
            saturationWeight: preferences.dynamic.saturationWeight,
            saturationBoost: preferences.dynamic.saturationBoost,
            gamma: preferences.dynamic.gamma,
            blackThreshold: preferences.calibration.blackThreshold,
            mutedDarkOffEnabled: preferences.calibration.mutedDarkOffEnabled,
            mutedDarkLuminanceThreshold: preferences.calibration.mutedDarkLuminanceThreshold,
            mutedDarkSaturationThreshold: preferences.calibration.mutedDarkSaturationThreshold,
            pureWhiteSnapEnabled: preferences.calibration.pureWhiteSnapEnabled,
            pureWhiteLuminanceThreshold: preferences.calibration.pureWhiteLuminanceThreshold,
            pureWhiteSaturationThreshold: preferences.calibration.pureWhiteSaturationThreshold,
            calibratedWhiteColor: preferences.calibration.whiteColor
        )
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true

        permissionService.refresh()
        permissionState = permissionService.state
        bleDeviceManager.updateDeviceNamePrefix(preferences.ble.preferredDeviceNamePrefix)
        bleDeviceManager.setAutoReconnect(preferences.ble.autoReconnect)

        let systemLaunchAtLogin = launchAtLoginService.synchronizeFromSystem()
        if preferences.general.launchAtLogin != systemLaunchAtLogin {
            preferences.general.launchAtLogin = systemLaunchAtLogin
            persist()
        }

        bleDeviceManager.start()
        displaySyncService.configure(preferences.displaySync)
        applyStartupBehavior()
    }

    func refreshPermissions() {
        permissionService.refresh()
        permissionState = permissionService.state
    }

    func openScreenRecordingSettings() {
        permissionService.openScreenRecordingSettings()
    }

    func openBluetoothSettings() {
        permissionService.openBluetoothSettings()
    }

    func setLightingMode(_ mode: LightingMode) {
        guard !preferences.whiteOverrideEnabled else { return }
        guard preferences.lightingMode != mode else { return }
        preferences.lightingMode = mode
        if preferences.brightness > 0.01 {
            preferences.lastLightEnabled = true
        }
        persist()
        applyLightingState()
    }

    func setDynamicAnalysisMode(_ mode: DynamicAnalysisMode) {
        guard preferences.dynamicAnalysisMode != mode else { return }
        preferences.dynamicAnalysisMode = mode
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setStaticHue(_ hue: Double) {
        preferences.staticHue = hue
        if preferences.brightness > 0.01 {
            preferences.lastLightEnabled = true
        }
        persist()
        guard preferences.lightingMode == .static, preferences.lastLightEnabled, !preferences.whiteOverrideEnabled else { return }
        scheduleStaticOrWhiteOutput()
    }

    func setBrightness(_ brightness: Double) {
        preferences.brightness = brightness.clamped(to: 0 ... 1)
        persist()

        guard preferences.brightness > 0.01 else {
            if preferences.lastLightEnabled {
                turnLightOff(preservingIntent: true)
            }
            return
        }

        guard preferences.lastLightEnabled else {
            return
        }

        if preferences.whiteOverrideEnabled {
            scheduleStaticOrWhiteOutput()
        } else if preferences.lightingMode == .static {
            scheduleStaticOrWhiteOutput()
        } else {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setLightEnabled(_ enabled: Bool) {
        preferences.lastLightEnabled = enabled
        persist()

        if enabled {
            applyLightingState(forceEnable: true)
        } else {
            turnLightOff(preservingIntent: false)
        }
    }

    func setWhiteOverrideEnabled(_ enabled: Bool) {
        preferences.whiteOverrideEnabled = enabled
        if enabled {
            preferences.lightingMode = .static
            preferences.lastLightEnabled = true
        }
        persist()
        applyLightingState(forceEnable: preferences.lastLightEnabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        preferences.general.launchAtLogin = enabled
        persist()

        do {
            try launchAtLoginService.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            preferences.general.launchAtLogin = launchAtLoginService.synchronizeFromSystem()
            persist()
        }
    }

    func setAutoTurnOn(_ enabled: Bool) {
        preferences.general.autoTurnOn = enabled
        persist()
    }

    func setAutoTurnOff(_ enabled: Bool) {
        preferences.general.autoTurnOff = enabled
        persist()
    }

    func setUpdateRate(_ value: Double) {
        preferences.dynamic.updateRate = Int(value.rounded()).clamped(to: 1 ... 60)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setSmoothing(_ value: Double) {
        preferences.dynamic.smoothing = value.clamped(to: 0 ... 1)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setCenterSamplingRect(_ rect: NormalizedRect) {
        preferences.calibration.centerSamplingRect = rect.clamped(minimumSize: 0.02)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func selectCenterSamplingArea() {
        centerRegionSelectionService.selectRegion(current: preferences.calibration.centerSamplingRect) { [weak self] rect in
            guard let self, let rect else { return }
            self.setCenterSamplingRect(rect)
        }
    }

    func selectCenterSamplingAreaAndActivateCenter() {
        centerRegionSelectionService.selectRegion(current: preferences.calibration.centerSamplingRect) { [weak self] rect in
            guard let self, let rect else { return }

            self.preferences.calibration.centerSamplingRect = rect.clamped(minimumSize: 0.02)
            self.preferences.whiteOverrideEnabled = false
            self.preferences.lightingMode = .dynamic
            self.preferences.dynamicAnalysisMode = .center
            self.preferences.lastLightEnabled = true
            self.persist()
            self.applyLightingState(forceEnable: true)
        }
    }

    func resetCenterSamplingArea() {
        setCenterSamplingRect(.defaultCenter)
    }

    func setEdgeSamplingWidth(_ value: Double) {
        preferences.dynamic.edgeSamplingWidthPercent = value.clamped(to: 1 ... 30)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setEdgeZoneCount(_ value: Double) {
        preferences.dynamic.edgeZoneCount = Int(value.rounded()).clamped(to: 4 ... 64)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setColorExtractionMethod(_ method: ColorExtractionMethod) {
        preferences.dynamic.colorExtractionMethod = method
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setSaturationWeight(_ value: Double) {
        preferences.dynamic.saturationWeight = value.clamped(to: 0 ... 3)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setSaturationBoost(_ value: Double) {
        preferences.dynamic.saturationBoost = value.clamped(to: 0 ... 1)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setGamma(_ value: Double) {
        preferences.dynamic.gamma = value.clamped(to: 1 ... 4)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setBlackThreshold(_ value: Double) {
        preferences.calibration.blackThreshold = value.clamped(to: 0 ... 0.2)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setMutedDarkOffEnabled(_ enabled: Bool) {
        preferences.calibration.mutedDarkOffEnabled = enabled
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setMutedDarkLuminanceThreshold(_ value: Double) {
        preferences.calibration.mutedDarkLuminanceThreshold = value.clamped(to: 0 ... 0.4)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setMutedDarkSaturationThreshold(_ value: Double) {
        preferences.calibration.mutedDarkSaturationThreshold = value.clamped(to: 0 ... 0.4)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setPureWhiteSnapEnabled(_ enabled: Bool) {
        preferences.calibration.pureWhiteSnapEnabled = enabled
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setPureWhiteLuminanceThreshold(_ value: Double) {
        preferences.calibration.pureWhiteLuminanceThreshold = value.clamped(to: 0.4 ... 1)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setPureWhiteSaturationThreshold(_ value: Double) {
        preferences.calibration.pureWhiteSaturationThreshold = value.clamped(to: 0 ... 0.35)
        persist()
        if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setCalibratedWhiteColor(_ color: RGBColor) {
        preferences.calibration.whiteColor = color.scaled(toBrightness: 1)
        persist()

        if preferences.whiteOverrideEnabled, preferences.lastLightEnabled {
            scheduleStaticOrWhiteOutput()
        } else if isDynamicOutputActive {
            dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
        }
    }

    func setDarkSceneOff(_ enabled: Bool) {
        preferences.sceneRules.darkSceneOffEnabled = enabled
        persist()
        refreshDynamicRulesIfNeeded()
    }

    func setDarkSceneThreshold(_ value: Double) {
        preferences.sceneRules.darkSceneLuminanceThreshold = value.clamped(to: 0 ... 0.3)
        persist()
        refreshDynamicRulesIfNeeded()
    }

    func setDimBrightNeutral(_ enabled: Bool) {
        preferences.sceneRules.dimBrightNeutralEnabled = enabled
        persist()
        refreshDynamicRulesIfNeeded()
    }

    func setBrightNeutralLuminanceThreshold(_ value: Double) {
        preferences.sceneRules.brightNeutralLuminanceThreshold = value.clamped(to: 0.4 ... 1)
        persist()
        refreshDynamicRulesIfNeeded()
    }

    func setBrightNeutralSaturationThreshold(_ value: Double) {
        preferences.sceneRules.brightNeutralSaturationThreshold = value.clamped(to: 0 ... 0.5)
        persist()
        refreshDynamicRulesIfNeeded()
    }

    func setBrightNeutralDimAmount(_ value: Double) {
        preferences.sceneRules.brightNeutralDimAmount = value.clamped(to: 0 ... 0.9)
        persist()
        refreshDynamicRulesIfNeeded()
    }

    func setPreferredDeviceNamePrefix(_ prefix: String) {
        preferences.ble.preferredDeviceNamePrefix = prefix.isEmpty ? "ELK-BLEDOM" : prefix
        persist()
        bleDeviceManager.updateDeviceNamePrefix(preferences.ble.preferredDeviceNamePrefix)
        bleDeviceManager.restartScan()
    }

    func setAutoReconnect(_ enabled: Bool) {
        preferences.ble.autoReconnect = enabled
        persist()
        bleDeviceManager.setAutoReconnect(enabled)
    }

    func retryDeviceConnection() {
        bleDeviceManager.restartScan()
    }

    func disconnectDevice() {
        bleDeviceManager.disconnect()
    }

    func setDisplaySyncEnabled(_ enabled: Bool) {
        preferences.displaySync.isEnabled = enabled
        persist()
        displaySyncService.configure(preferences.displaySync)
    }

    func setDisplaySyncPollingRate(_ value: Double) {
        preferences.displaySync.pollingRateHz = value.clamped(to: 1 ... 10)
        persist()
        displaySyncService.configure(preferences.displaySync)
    }

    func setAwayInput(_ source: DisplayInputSource?, forDisplayID displayID: String) {
        if let source {
            preferences.displaySync.awayInputAssignments[displayID] = source
        } else {
            preferences.displaySync.awayInputAssignments.removeValue(forKey: displayID)
        }

        persist()
        displaySyncService.configure(preferences.displaySync)
    }

    func switchDisplaysAway() {
        displaySyncService.switchAway()
    }

    func refreshDisplaySync() {
        displaySyncService.refreshNow()
    }

    func restartDynamicCapture() {
        preferences.lightingMode = .dynamic
        preferences.whiteOverrideEnabled = false
        preferences.lastLightEnabled = true
        persist()

        dynamicLightingEngine.stop()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run {
                self?.startDynamicOutput()
            }
        }
    }

    func handleSystemSleep() {
        wakeLightingTask?.cancel()
        wakeLightingTask = nil
        displaySyncService.handleSystemSleep()

        guard preferences.general.autoTurnOff else { return }
        turnLightOff(preservingIntent: preferences.general.autoTurnOn)
    }

    func handleSystemWake() {
        bleDeviceManager.handleSystemWake()
        displaySyncService.handleSystemWake()
        wakeLightingTask?.cancel()

        guard preferences.general.autoTurnOn else { return }

        wakeLightingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.preferences.lastLightEnabled = true
                self.persist()
                self.applyLightingState(forceEnable: true)
            }
        }
    }

    func handleApplicationTermination() {
        guard preferences.general.autoTurnOff else { return }
        turnLightOff(preservingIntent: false)
    }

    private func applyStartupBehavior() {
        guard preferences.general.autoTurnOn else { return }
        preferences.lastLightEnabled = true
        persist()
        applyLightingState(forceEnable: true)
    }

    private func applyLightingState(forceEnable: Bool = true) {
        guard forceEnable else {
            turnLightOff(preservingIntent: true)
            return
        }

        guard preferences.lastLightEnabled else {
            turnLightOff(preservingIntent: false)
            return
        }

        guard preferences.brightness > 0.01 else {
            turnLightOff(preservingIntent: true)
            return
        }

        if preferences.whiteOverrideEnabled {
            sendWhiteColor()
        } else if preferences.lightingMode == .dynamic {
            startDynamicOutput()
        } else {
            dynamicLightingEngine.stop()
            sendStaticColor()
        }
    }

    private func refreshDynamicRulesIfNeeded() {
        guard isDynamicOutputActive else { return }
        dynamicLightingEngine.update(configuration: currentDynamicConfiguration)
    }

    private func applyLightingAfterDeviceReconnect() {
        guard preferences.lastLightEnabled, preferences.brightness > 0.01 else { return }
        applyLightingState(forceEnable: true)
    }

    private func startDynamicOutput() {
        permissionService.refresh()
        permissionState = permissionService.state
        if !permissionState.screenRecordingAuthorized {
            dynamicLightingEngine.stop()
            captureDiagnostics.streamState = .idle
            captureDiagnostics.lastError = "Screen Recording permission required. Open Settings to enable it."
            return
        }

        dynamicLightingEngine.start(configuration: currentDynamicConfiguration)
    }

    private func sendStaticColor() {
        pendingStaticOutputTask?.cancel()
        pendingStaticOutputTask = nil
        lastStaticOutputDate = Date()
        performStaticColorSend()
    }

    private func performStaticColorSend() {
        guard preferences.lastLightEnabled else { return }
        guard !preferences.whiteOverrideEnabled else {
            sendWhiteColor()
            return
        }

        let color = currentStaticColor
        if color.isNearlyBlack {
            turnLightOff(preservingIntent: true)
            return
        }

        dynamicLightingEngine.stop()
        bleDeviceManager.send(color: color)
        preferences.lastLightEnabled = true
        captureDiagnostics.screenColor = color
        captureDiagnostics.ledColor = color
        persist()
    }

    private func sendWhiteColor() {
        pendingStaticOutputTask?.cancel()
        pendingStaticOutputTask = nil
        lastStaticOutputDate = Date()
        performWhiteColorSend()
    }

    private func performWhiteColorSend() {
        guard preferences.lastLightEnabled else { return }
        let color = currentWhiteColor

        if color.isNearlyBlack {
            turnLightOff(preservingIntent: true)
            return
        }

        dynamicLightingEngine.stop()
        bleDeviceManager.send(color: color)
        preferences.lastLightEnabled = true
        captureDiagnostics.screenColor = color
        captureDiagnostics.ledColor = color
        persist()
    }

    private func scheduleStaticOrWhiteOutput() {
        pendingStaticOutputTask?.cancel()

        let elapsed = lastStaticOutputDate.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0.0, 0.10 - elapsed)

        pendingStaticOutputTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingStaticOutputTask = nil
                self.lastStaticOutputDate = Date()
                if self.preferences.whiteOverrideEnabled {
                    self.performWhiteColorSend()
                } else if self.preferences.lightingMode == .static {
                    self.performStaticColorSend()
                }
            }
        }
    }

    private func sendDynamicColor(_ color: RGBColor) {
        guard isDynamicOutputActive else { return }

        if color.isNearlyBlack {
            bleDeviceManager.turnOff()
        } else {
            bleDeviceManager.sendDynamic(color: color)
        }
    }

    private func turnLightOff(preservingIntent: Bool) {
        dynamicLightingEngine.stop()
        bleDeviceManager.turnOff()
        if !preservingIntent {
            preferences.lastLightEnabled = false
        }
        persist()
    }

    private func persist() {
        preferencesStore.save(preferences)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
