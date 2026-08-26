import CoreGraphics
import Foundation

final class DisplayReconfigurationObserver {
    private var isRunning = false
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange

        guard !isRunning else { return }
        isRunning = true

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, pointer)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayReconfigurationCallback, pointer)
        onChange = nil
    }

    fileprivate func handleDisplayChange(flags: CGDisplayChangeSummaryFlags) {
        guard flags.contains(.addFlag)
            || flags.contains(.removeFlag)
            || flags.contains(.enabledFlag)
            || flags.contains(.disabledFlag)
            || flags.contains(.setMainFlag)
        else {
            return
        }

        onChange?()
    }
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo else { return }
    let observer = Unmanaged<DisplayReconfigurationObserver>.fromOpaque(userInfo).takeUnretainedValue()
    observer.handleDisplayChange(flags: flags)
}
