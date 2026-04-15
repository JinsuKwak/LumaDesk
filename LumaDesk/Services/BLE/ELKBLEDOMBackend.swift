import CoreBluetooth
import Foundation

protocol ELKPacketAdapter {
    func colorPacket(for color: RGBColor) -> Data
    func powerPacket(isOn: Bool) -> Data
}

struct ELKBLEDOMProtocolAdapter: ELKPacketAdapter {
    func colorPacket(for color: RGBColor) -> Data {
        let red = UInt8((color.red * 255).rounded())
        let green = UInt8((color.green * 255).rounded())
        let blue = UInt8((color.blue * 255).rounded())

        // ELK-BLEDOM/BLEDOB RGB writes use the captured Android/LotusLamp envelope.
        return Data([0x7E, 0x07, 0x05, 0x03, red, green, blue, 0x10, 0xEF])
    }

    func powerPacket(isOn: Bool) -> Data {
        if isOn {
            Data([0x7E, 0x07, 0x04, 0xFF, 0x00, 0x01, 0x02, 0x01, 0xEF])
        } else {
            Data([0x7E, 0x07, 0x04, 0x00, 0x00, 0x00, 0x02, 0x01, 0xEF])
        }
    }
}

final class ELKBLEDOMBackend: NSObject, LEDStripBackend {
    var connectionStateHandler: ((ConnectionState) -> Void)?

    private let serviceUUID = CBUUID(string: "FFF0")
    private let writeCharacteristicUUID = CBUUID(string: "FFF3")
    private let notifyCharacteristicUUID = CBUUID(string: "FFF4")
    private let adapter: ELKPacketAdapter

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var preferredDeviceNamePrefix = "ELK-BLEDOM"
    private var autoReconnect = true
    private var isPowered = false
    private var isScanning = false
    private var pendingDynamicColor: RGBColor?
    private var dynamicFlushWorkItem: DispatchWorkItem?
    private var lastDynamicWriteDate: Date?
    private let dynamicMinimumWriteInterval: TimeInterval = 0.20
    private var writeGeneration = 0
    private var powerReadyDate: Date?
    private var manualDisconnectRequested = false

    override init() {
        adapter = ELKBLEDOMProtocolAdapter()
        super.init()
    }

    func start() {
        manualDisconnectRequested = false
        guard centralManager.state == .poweredOn else { return }
        startScanning()
    }

    func stop() {
        manualDisconnectRequested = true
        isScanning = false
        cancelPendingDynamicColor()
        centralManager.stopScan()
        if let connectedPeripheral {
            centralManager.cancelPeripheralConnection(connectedPeripheral)
        }
    }

    func restartScan() {
        manualDisconnectRequested = false
        cancelPendingDynamicColor()
        connectedPeripheral = nil
        writeCharacteristic = nil
        isPowered = false
        powerReadyDate = nil
        startScanning()
    }

    func disconnect() {
        manualDisconnectRequested = true
        isScanning = false
        cancelPendingDynamicColor()
        centralManager.stopScan()

        guard let connectedPeripheral else {
            writeCharacteristic = nil
            isPowered = false
            powerReadyDate = nil
            connectionStateHandler?(.disconnected)
            return
        }

        centralManager.cancelPeripheralConnection(connectedPeripheral)
    }

    func updateDeviceNamePrefix(_ prefix: String) {
        preferredDeviceNamePrefix = prefix
    }

    func setAutoReconnect(_ enabled: Bool) {
        autoReconnect = enabled
    }

    func send(color: RGBColor) {
        cancelPendingDynamicColor()
        guard let peripheral = connectedPeripheral, let writeCharacteristic else { return }
        writeColor(color, peripheral: peripheral, characteristic: writeCharacteristic)
    }

    func sendDynamic(color: RGBColor) {
        pendingDynamicColor = color
        scheduleDynamicColorFlush()
    }

    func sendWhite(level: Double) {
        cancelPendingDynamicColor()
        guard let peripheral = connectedPeripheral, let writeCharacteristic else { return }
        let clampedLevel = level.clamped(to: 0 ... 1)
        let color = RGBColor(red: clampedLevel, green: clampedLevel, blue: clampedLevel)
        writeColor(color, peripheral: peripheral, characteristic: writeCharacteristic)
    }

    func turnOff() {
        cancelPendingDynamicColor()
        guard let peripheral = connectedPeripheral, let writeCharacteristic else { return }
        peripheral.writeValue(adapter.powerPacket(isOn: false), for: writeCharacteristic, type: .withoutResponse)
        isPowered = false
        powerReadyDate = nil
    }

    private func scheduleDynamicColorFlush() {
        guard dynamicFlushWorkItem == nil else { return }

        let elapsed = lastDynamicWriteDate.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(0, dynamicMinimumWriteInterval - elapsed)
        let workItem = DispatchWorkItem { [weak self] in
            self?.dynamicFlushWorkItem = nil
            self?.flushDynamicColor()
        }

        dynamicFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func flushDynamicColor() {
        guard let color = pendingDynamicColor else { return }
        pendingDynamicColor = nil

        guard let peripheral = connectedPeripheral, let writeCharacteristic else { return }
        writeColor(color, peripheral: peripheral, characteristic: writeCharacteristic)
        lastDynamicWriteDate = Date()
    }

    private func cancelPendingDynamicColor() {
        writeGeneration += 1
        dynamicFlushWorkItem?.cancel()
        dynamicFlushWorkItem = nil
        pendingDynamicColor = nil
    }

    private func writeColor(_ color: RGBColor, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        writeGeneration += 1
        let generation = writeGeneration
        let packet = adapter.colorPacket(for: color)

        if !isPowered {
            peripheral.writeValue(adapter.powerPacket(isOn: true), for: characteristic, type: .withoutResponse)
            isPowered = true
            powerReadyDate = Date().addingTimeInterval(0.10)
            writeColorPacket(packet, generation: generation, peripheral: peripheral, characteristic: characteristic, delay: 0.10)
            return
        }

        if let powerReadyDate {
            let delay = powerReadyDate.timeIntervalSinceNow
            if delay > 0 {
                writeColorPacket(packet, generation: generation, peripheral: peripheral, characteristic: characteristic, delay: delay)
                return
            }

            self.powerReadyDate = nil
        }

        peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
    }

    private func writeColorPacket(
        _ packet: Data,
        generation: Int,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        delay: TimeInterval
    ) {
        guard delay > 0 else {
            peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak peripheral, weak characteristic] in
            guard let self,
                  self.writeGeneration == generation,
                  let peripheral,
                  let characteristic,
                  self.connectedPeripheral === peripheral,
                  self.writeCharacteristic === characteristic
            else {
                return
            }

            self.powerReadyDate = nil
            peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
        }
    }

    private func startScanning() {
        guard centralManager.state == .poweredOn else {
            connectionStateHandler?(.error("Bluetooth unavailable"))
            return
        }

        guard !isScanning else { return }
        isScanning = true
        connectionStateHandler?(.scanning)
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func matchesTargetDevice(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        let names = [
            peripheral.name,
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
        ].compactMap { $0?.lowercased() }

        return names.contains { $0.hasPrefix(preferredDeviceNamePrefix.lowercased()) }
    }
}

extension ELKBLEDOMBackend: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            connectionStateHandler?(.error("Bluetooth off"))
        case .unauthorized:
            connectionStateHandler?(.error("Bluetooth denied"))
        case .unsupported:
            connectionStateHandler?(.error("Bluetooth unsupported"))
        case .resetting:
            connectionStateHandler?(.connecting(nil))
        case .unknown:
            connectionStateHandler?(.disconnected)
        @unknown default:
            connectionStateHandler?(.error("Bluetooth unknown"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard matchesTargetDevice(peripheral: peripheral, advertisementData: advertisementData) else { return }

        isScanning = false
        centralManager.stopScan()
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionStateHandler?(.connecting(peripheral.name))
        centralManager.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStateHandler?(.error(error?.localizedDescription ?? "Connect failed"))
        if autoReconnect, !manualDisconnectRequested {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startScanning()
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelPendingDynamicColor()
        connectedPeripheral = nil
        writeCharacteristic = nil
        isPowered = false
        powerReadyDate = nil

        if let error {
            connectionStateHandler?(.error(error.localizedDescription))
        } else {
            connectionStateHandler?(.disconnected)
        }

        let shouldReconnect = autoReconnect && !manualDisconnectRequested
        manualDisconnectRequested = false

        guard shouldReconnect else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.startScanning()
        }
    }
}

extension ELKBLEDOMBackend: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            connectionStateHandler?(.error(error.localizedDescription))
            return
        }

        peripheral.services?
            .filter { $0.uuid == serviceUUID }
            .forEach { peripheral.discoverCharacteristics([writeCharacteristicUUID, notifyCharacteristicUUID], for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            connectionStateHandler?(.error(error.localizedDescription))
            return
        }

        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == writeCharacteristicUUID {
                writeCharacteristic = characteristic
            }

            if characteristic.uuid == notifyCharacteristicUUID, characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        if let name = peripheral.name, writeCharacteristic != nil {
            connectionStateHandler?(.connected(name))
        }
    }
}
