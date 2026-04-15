import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()

    let preferencesStore: PreferencesStore
    let permissionService: PermissionService
    let launchAtLoginService: LaunchAtLoginService
    let bleDeviceManager: BLEDeviceManager
    let screenCaptureService: ScreenCaptureService
    let colorAnalysisService: ColorAnalysisService
    let dynamicLightingEngine: DynamicLightingEngine
    let centerRegionSelectionService: CenterRegionSelectionService
    let appState: AppStateStore

    private init() {
        preferencesStore = PreferencesStore()
        permissionService = PermissionService()
        launchAtLoginService = LaunchAtLoginService()
        bleDeviceManager = BLEDeviceManager()
        screenCaptureService = ScreenCaptureService()
        colorAnalysisService = ColorAnalysisService()
        centerRegionSelectionService = CenterRegionSelectionService()
        dynamicLightingEngine = DynamicLightingEngine(
            captureService: screenCaptureService,
            analyzer: colorAnalysisService
        )
        appState = AppStateStore(
            preferencesStore: preferencesStore,
            permissionService: permissionService,
            launchAtLoginService: launchAtLoginService,
            bleDeviceManager: bleDeviceManager,
            dynamicLightingEngine: dynamicLightingEngine,
            centerRegionSelectionService: centerRegionSelectionService
        )
    }
}
