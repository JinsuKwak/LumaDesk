import Foundation

protocol LEDStripBackend: AnyObject {
    var connectionStateHandler: ((ConnectionState) -> Void)? { get set }
    func start()
    func stop()
    func restartScan()
    func disconnect()
    func updateDeviceNamePrefix(_ prefix: String)
    func setAutoReconnect(_ enabled: Bool)
    func send(color: RGBColor)
    func sendDynamic(color: RGBColor)
    func sendWhite(level: Double)
    func turnOff()
}

@MainActor
final class BLEDeviceManager {
    var connectionStateHandler: ((ConnectionState) -> Void)? {
        didSet { backend.connectionStateHandler = connectionStateHandler }
    }

    private let backend: LEDStripBackend

    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--mock-led")
        {
            backend = MockLEDStripBackend()
        } else {
            backend = ELKBLEDOMBackend()
        }
    }

    func start() {
        backend.start()
    }

    func stop() {
        backend.stop()
    }

    func restartScan() {
        backend.restartScan()
    }

    func disconnect() {
        backend.disconnect()
    }

    func updateDeviceNamePrefix(_ prefix: String) {
        backend.updateDeviceNamePrefix(prefix)
    }

    func setAutoReconnect(_ enabled: Bool) {
        backend.setAutoReconnect(enabled)
    }

    func send(color: RGBColor) {
        backend.send(color: color)
    }

    func sendDynamic(color: RGBColor) {
        backend.sendDynamic(color: color)
    }

    func sendWhite(level: Double) {
        backend.sendWhite(level: level)
    }

    func turnOff() {
        backend.turnOff()
    }
}

final class MockLEDStripBackend: LEDStripBackend {
    var connectionStateHandler: ((ConnectionState) -> Void)?
    private var latestColor = RGBColor.black

    func start() {
        connectionStateHandler?(.connected("Mock Strip"))
    }

    func stop() {}

    func restartScan() {
        connectionStateHandler?(.connected("Mock Strip"))
    }

    func disconnect() {
        connectionStateHandler?(.disconnected)
    }

    func updateDeviceNamePrefix(_ prefix: String) {}

    func setAutoReconnect(_ enabled: Bool) {}

    func send(color: RGBColor) {
        latestColor = color
    }

    func sendDynamic(color: RGBColor) {
        latestColor = color
    }

    func sendWhite(level: Double) {
        latestColor = RGBColor(red: level, green: level, blue: level)
    }

    func turnOff() {
        latestColor = .black
    }
}
