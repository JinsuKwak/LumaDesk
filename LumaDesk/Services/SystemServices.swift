import AppKit
import CoreBluetooth
import CoreGraphics
import Foundation
import ServiceManagement

final class PreferencesStore {
    private let defaults: UserDefaults
    private let key = "LumaDesk.Preferences"
    private let legacyKey = "DesCon.Preferences"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppPreferences {
        if
            let data = defaults.data(forKey: key),
            let preferences = try? decoder.decode(AppPreferences.self, from: data)
        {
            return preferences
        }

        if
            let legacyData = defaults.data(forKey: legacyKey),
            let preferences = try? decoder.decode(AppPreferences.self, from: legacyData)
        {
            save(preferences)
            return preferences
        }

        return AppPreferences()
    }

    func save(_ preferences: AppPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var state = PermissionState()

    func refresh() {
        state = PermissionState(
            bluetoothAuthorized: bluetoothAuthorized,
            screenRecordingAuthorized: screenRecordingAuthorized
        )
    }

    func openBluetoothSettings() {
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }

    func openScreenRecordingSettings() {
        openPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private var bluetoothAuthorized: Bool {
        switch CBManager.authorization {
        case .allowedAlways:
            true
        case .denied, .restricted, .notDetermined:
            false
        @unknown default:
            false
        }
    }

    private var screenRecordingAuthorized: Bool {
        CGPreflightScreenCaptureAccess()
    }

    private func openPane(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class LaunchAtLoginService {
    func synchronizeFromSystem() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class CenterRegionSelectionService {
    private var overlayWindow: NSWindow?

    func selectRegion(current: NormalizedRect, completion: @escaping (NormalizedRect?) -> Void) {
        guard let screen = primaryScreen() else {
            completion(nil)
            return
        }

        dismissOverlay()

        let overlayView = CenterRegionSelectionOverlayView(currentRect: current)
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        overlayView.completion = { [weak self] rect in
            self?.dismissOverlay()
            completion(rect)
        }

        window.contentView = overlayView
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        overlayWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(overlayView)
    }

    private func primaryScreen() -> NSScreen? {
        let primaryDisplayID = CGMainDisplayID()
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

        return NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(screenNumber.uint32Value) == primaryDisplayID
        }
    }

    private func dismissOverlay() {
        guard let overlayWindow else { return }
        overlayWindow.orderOut(nil)
        overlayWindow.contentView = nil
        self.overlayWindow = nil
    }
}

private final class CenterRegionSelectionOverlayView: NSView {
    var completion: ((NormalizedRect?) -> Void)?

    private let initialRect: NormalizedRect
    private var dragStart: CGPoint?
    private var selectionRect: CGRect?
    private var pendingRect: NormalizedRect?
    private var confirmButtonRect = CGRect.zero
    private var cancelButtonRect = CGRect.zero
    private var mouseDownAction: OverlayAction?

    init(currentRect: NormalizedRect) {
        self.initialRect = currentRect.clamped(minimumSize: 0.02)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let activeRect = selectionRect ?? displayRect(for: pendingRect ?? initialRect)
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.append(NSBezierPath(roundedRect: activeRect, xRadius: 14, yRadius: 14))
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.48).setFill()
        dimPath.fill()

        NSColor.white.withAlphaComponent(0.92).setStroke()
        let border = NSBezierPath(roundedRect: activeRect, xRadius: 14, yRadius: 14)
        border.lineWidth = 2
        border.stroke()

        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: activeRect, xRadius: 14, yRadius: 14).fill()

        drawInstruction()

        if pendingRect != nil {
            drawActionButtons(near: activeRect)
        } else {
            confirmButtonRect = .zero
            cancelButtonRect = .zero
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if pendingRect != nil, confirmButtonRect.contains(point) {
            mouseDownAction = .confirm
            return
        }

        if pendingRect != nil, cancelButtonRect.contains(point) {
            mouseDownAction = .cancel
            return
        }

        mouseDownAction = nil
        pendingRect = nil
        dragStart = point
        selectionRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }

        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(dragStart.x, point.x),
            y: min(dragStart.y, point.y),
            width: abs(point.x - dragStart.x),
            height: abs(point.y - dragStart.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if mouseDownAction == .confirm, confirmButtonRect.contains(point), let pendingRect {
            completion?(pendingRect)
            return
        }

        if mouseDownAction == .cancel, cancelButtonRect.contains(point) {
            completion?(nil)
            return
        }

        mouseDownAction = nil

        guard let selectionRect,
              let normalizedRect = normalizedRect(for: selectionRect)
        else {
            dragStart = nil
            self.selectionRect = displayRect(for: pendingRect ?? initialRect)
            needsDisplay = true
            return
        }

        pendingRect = normalizedRect
        self.selectionRect = displayRect(for: normalizedRect)
        dragStart = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        completion?(nil)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:
            completion?(pendingRect ?? initialRect)
        case 53:
            completion?(nil)
        default:
            super.keyDown(with: event)
        }
    }

    private func normalizedRect(for rect: CGRect) -> NormalizedRect? {
        let boundedRect = rect.standardized.intersection(bounds)
        guard !boundedRect.isNull,
              boundedRect.width >= 12,
              boundedRect.height >= 12,
              bounds.width > 0,
              bounds.height > 0
        else {
            return nil
        }

        return NormalizedRect(
            x: boundedRect.minX / bounds.width,
            y: (bounds.height - boundedRect.maxY) / bounds.height,
            width: boundedRect.width / bounds.width,
            height: boundedRect.height / bounds.height
        )
    }

    private func displayRect(for normalizedRect: NormalizedRect) -> CGRect {
        let rect = normalizedRect.clamped(minimumSize: 0.02)
        return CGRect(
            x: rect.x * bounds.width,
            y: bounds.height - ((rect.y + rect.height) * bounds.height),
            width: rect.width * bounds.width,
            height: rect.height * bounds.height
        )
    }

    private func drawInstruction() {
        let text = pendingRect == nil ? "Drag center area - Esc cancels" : "Confirm selection or drag again"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph
        ]
        let size = text.size(withAttributes: attributes)
        let pillRect = CGRect(
            x: bounds.midX - (size.width + 34) / 2,
            y: bounds.maxY - size.height - 56,
            width: size.width + 34,
            height: size.height + 18
        )

        NSColor.black.withAlphaComponent(0.38).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height / 2, yRadius: pillRect.height / 2).fill()

        text.draw(
            in: CGRect(
                x: pillRect.minX + 17,
                y: pillRect.minY + 9,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    private func drawActionButtons(near activeRect: CGRect) {
        let height: CGFloat = 34
        let gap: CGFloat = 8
        let confirmWidth: CGFloat = 92
        let cancelWidth: CGFloat = 82
        let totalWidth = confirmWidth + cancelWidth + gap

        let x = (activeRect.midX - (totalWidth / 2)).clamped(to: 24 ... max(24, bounds.maxX - totalWidth - 24))
        let preferredY = activeRect.minY - height - 14
        let fallbackY = activeRect.maxY + 14
        let y = preferredY >= 24
            ? preferredY
            : min(max(24, fallbackY), max(24, bounds.maxY - height - 24))

        confirmButtonRect = CGRect(x: x, y: y, width: confirmWidth, height: height)
        cancelButtonRect = CGRect(x: confirmButtonRect.maxX + gap, y: y, width: cancelWidth, height: height)

        drawButton(title: "Confirm", rect: confirmButtonRect, primary: true)
        drawButton(title: "Cancel", rect: cancelButtonRect, primary: false)
    }

    private func drawButton(title: String, rect: CGRect, primary: Bool) {
        if primary {
            NSColor.white.withAlphaComponent(0.92).setFill()
        } else {
            NSColor.black.withAlphaComponent(0.42).setFill()
        }
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()

        NSColor.white.withAlphaComponent(primary ? 0.18 : 0.28).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        border.lineWidth = 1
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: primary ? NSColor.black.withAlphaComponent(0.88) : NSColor.white.withAlphaComponent(0.90),
            .paragraphStyle: paragraph
        ]
        title.draw(
            in: CGRect(x: rect.minX + 10, y: rect.midY - 8, width: rect.width - 20, height: 17),
            withAttributes: attributes
        )
    }
}

private enum OverlayAction {
    case confirm
    case cancel
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
