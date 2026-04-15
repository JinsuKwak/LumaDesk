import SwiftUI

struct GlassSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}

struct CompactSegmentedControl<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(selection == option ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                        .background {
                            Capsule(style: .continuous)
                                .fill(selection == option ? Color.white.opacity(0.22) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.045))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
        }
    }
}

struct MinimalAnalysisSelector: View {
    @Binding var selection: DynamicAnalysisMode

    var body: some View {
        HStack(spacing: 13) {
            ForEach(DynamicAnalysisMode.allCases) { option in
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 3) {
                        Text(option.title)
                            .font(.system(size: 11.5, weight: selection == option ? .semibold : .medium))
                            .foregroundStyle(selection == option ? Color.primary : Color.secondary.opacity(0.82))
                            .lineLimit(1)

                        Capsule(style: .continuous)
                            .fill(selection == option ? Color.primary.opacity(0.52) : Color.clear)
                            .frame(width: 16, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 24)
    }
}

struct MinimalValueSlider: View {
    @Binding var value: Double
    var tint: LinearGradient

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let clamped = value.clamped(to: 0 ... 1)
            let knobOffset = width * clamped

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 5)

                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(8, knobOffset), height: 5)

                Circle()
                    .fill(.white.opacity(0.82))
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
                    .offset(x: max(0, min(width - 11, knobOffset - 5.5)))
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = (gesture.location.x / width).clamped(to: 0 ... 1)
                    }
            )
        }
        .frame(height: 18)
    }
}

struct HueSpectrumSlider: View {
    @Binding var hue: Double

    private let spectrum = [
        Color(red: 1.0, green: 0.15, blue: 0.15),
        Color(red: 1.0, green: 0.6, blue: 0.15),
        Color(red: 0.95, green: 0.9, blue: 0.2),
        Color(red: 0.2, green: 0.85, blue: 0.35),
        Color(red: 0.2, green: 0.7, blue: 1.0),
        Color(red: 0.45, green: 0.35, blue: 1.0),
        Color(red: 1.0, green: 0.15, blue: 0.65),
        Color(red: 1.0, green: 0.15, blue: 0.15)
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let knobOffset = width * hue.clamped(to: 0 ... 1)

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: spectrum, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 7)

                Circle()
                    .fill(RGBColor(hue: hue).swiftUIColor)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.95), lineWidth: 1.5)
                    }
                    .frame(width: 13, height: 13)
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
                    .offset(x: max(0, min(width - 13, knobOffset - 6.5)))
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        hue = (gesture.location.x / width).clamped(to: 0 ... 1)
                    }
            )
        }
        .frame(height: 18)
    }
}

struct ColorWheelPicker: View {
    @Binding var color: RGBColor

    private let wheelColors = [
        Color(red: 1, green: 0, blue: 0),
        Color(red: 1, green: 1, blue: 0),
        Color(red: 0, green: 1, blue: 0),
        Color(red: 0, green: 1, blue: 1),
        Color(red: 0, green: 0, blue: 1),
        Color(red: 1, green: 0, blue: 1),
        Color(red: 1, green: 0, blue: 0)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = max(Double(size) / 2, 1)
            let hsb = color.hueSaturationBrightness
            let angle = hsb.hue * .pi * 2
            let knobRadius = hsb.saturation.clamped(to: 0 ... 1) * radius
            let knobX = CGFloat(radius + cos(angle) * knobRadius)
            let knobY = CGFloat(radius + sin(angle) * knobRadius)

            ZStack {
                Circle()
                    .fill(AngularGradient(colors: wheelColors, center: .center))
                    .overlay {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [.white, .white.opacity(0.15), .white.opacity(0)],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: CGFloat(radius)
                                )
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    }

                Circle()
                    .fill(color.swiftUIColor)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
                    .position(x: knobX, y: knobY)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        updateColor(from: gesture.location, radius: radius)
                    }
            )
        }
        .frame(width: 118, height: 118)
    }

    private func updateColor(from location: CGPoint, radius: Double) {
        let dx = Double(location.x) - radius
        let dy = Double(location.y) - radius
        let distance = min(sqrt((dx * dx) + (dy * dy)), radius)
        let saturation = (distance / radius).clamped(to: 0 ... 1)
        var hue = atan2(dy, dx) / (.pi * 2)
        if hue < 0 {
            hue += 1
        }

        color = RGBColor(hue: hue, saturation: saturation, brightness: 1)
    }
}

struct ConnectionStatusView: View {
    let state: ConnectionState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.tint)
                .frame(width: 6, height: 6)

            Text(state.compactLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(height: 20)
    }
}

struct RoundIconToggle: View {
    let systemImage: String
    let isOn: Bool
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(isOn ? Color.primary : Color.secondary)
            .frame(width: 24, height: 24)
            .background {
                Circle()
                    .fill(isOn ? Color.white.opacity(0.18) : Color.white.opacity(0.045))
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(isOn ? 0.13 : 0.05), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct RoundIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 24, height: 24)
                .background {
                    Circle()
                        .fill(Color.white.opacity(0.045))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
