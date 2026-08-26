import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var hotKey: MacGlobalHotKey?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.onCapture = { captured in
            hotKey = captured
        }
        return button
    }

    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {
        nsView.capturedHotKey = hotKey
        nsView.refreshTitle()
    }
}

final class ShortcutRecorderButton: NSButton {
    var capturedHotKey: MacGlobalHotKey?
    var onCapture: ((MacGlobalHotKey?) -> Void)?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .small
        font = .systemFont(ofSize: 11.5, weight: .medium)
        target = self
        action = #selector(beginRecording)
        setButtonType(.momentaryPushIn)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Press shortcut…"
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            isRecording = false
            refreshTitle()
        }
        return didResign
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, flags.isEmpty {
            capturedHotKey = nil
            onCapture?(nil)
            window?.makeFirstResponder(nil)
            return
        }

        guard !flags.isEmpty else {
            NSSound.beep()
            return
        }

        let label = Self.shortcutLabel(event: event, flags: flags)
        let captured = MacGlobalHotKey(
            keyCode: UInt32(event.keyCode),
            carbonModifiers: Self.carbonModifiers(flags),
            displayText: label
        )
        capturedHotKey = captured
        onCapture?(captured)
        window?.makeFirstResponder(nil)
    }

    func refreshTitle() {
        guard !isRecording else { return }
        title = capturedHotKey?.displayText ?? "Set Shortcut"
        toolTip = capturedHotKey == nil ? "Record a global shortcut" : "Press Delete while recording to clear"
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func shortcutLabel(event: NSEvent, flags: NSEvent.ModifierFlags) -> String {
        var label = ""
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }

        let key = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        return label + (key == " " ? "Space" : key)
    }
}
