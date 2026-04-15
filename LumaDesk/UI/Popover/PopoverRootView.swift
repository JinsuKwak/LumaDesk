import SwiftUI

struct PopoverRootView: View {
    @EnvironmentObject private var appState: AppStateStore

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                ConnectionStatusView(state: appState.connectionState)

                Spacer(minLength: 8)

                RoundIconToggle(
                    systemImage: "power",
                    isOn: appState.preferences.lastLightEnabled,
                    accessibilityLabel: appState.preferences.lastLightEnabled ? "Turn off" : "Turn on"
                ) {
                    appState.setLightEnabled(!appState.preferences.lastLightEnabled)
                }

                RoundIconToggle(
                    systemImage: "sun.max.fill",
                    isOn: appState.preferences.whiteOverrideEnabled,
                    accessibilityLabel: "White"
                ) {
                    appState.setWhiteOverrideEnabled(!appState.preferences.whiteOverrideEnabled)
                }

                RoundIconButton(
                    systemImage: "viewfinder",
                    accessibilityLabel: "Select center area"
                ) {
                    appState.selectCenterSamplingAreaAndActivateCenter()
                }
            }

            subtleDivider

            HStack(spacing: 10) {
                CompactSegmentedControl(
                    options: LightingMode.allCases,
                    selection: Binding(
                        get: { appState.preferences.lightingMode },
                        set: appState.setLightingMode
                    ),
                    title: \.title
                )
                .frame(width: 126)
                .disabled(appState.preferences.whiteOverrideEnabled)

                ZStack {
                    if appState.preferences.lightingMode == .dynamic {
                        MinimalAnalysisSelector(
                            selection: Binding(
                                get: { appState.preferences.dynamicAnalysisMode },
                                set: appState.setDynamicAnalysisMode
                            )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else {
                        HueSpectrumSlider(
                            hue: Binding(
                                get: { appState.preferences.staticHue },
                                set: appState.setStaticHue
                            )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
                .frame(width: 168, height: 28)
                .disabled(appState.preferences.whiteOverrideEnabled)
                .opacity(appState.preferences.whiteOverrideEnabled ? 0.34 : 1)
            }
            .opacity(appState.preferences.whiteOverrideEnabled ? 0.62 : 1)

            subtleDivider

            HStack(spacing: 12) {
                Text("Brightness")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)

                MinimalValueSlider(
                    value: Binding(
                        get: { appState.preferences.brightness },
                        set: appState.setBrightness
                    ),
                    tint: LinearGradient(
                        colors: [Color.white.opacity(0.32), Color.white.opacity(0.72)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 330)
        .animation(.easeOut(duration: 0.16), value: appState.preferences.lightingMode)
        .animation(.easeOut(duration: 0.16), value: appState.preferences.whiteOverrideEnabled)
    }

    private var subtleDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.03))
            .frame(height: 1)
    }
}
