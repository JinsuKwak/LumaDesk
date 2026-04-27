import CoreGraphics
import Darwin
import Foundation
import IOKit

private let luminanceVCPCode: UInt8 = 0x10

struct DisplayBrightnessTarget: @unchecked Sendable {
    var id: String
    var name: String
    var service: IOAVService?
}

protocol DisplayBrightnessBackend {
    func discoverExternalDisplays() async -> [DisplayBrightnessTarget]
    func readMaxBrightness(_ target: DisplayBrightnessTarget) async -> UInt16?
    func setBrightness(_ target: DisplayBrightnessTarget, rawValue: UInt16) async -> Bool
}

protocol BuiltInBrightnessProvider {
    func readBuiltInBrightness() async throws -> Double
}

enum DisplayBrightnessError: LocalizedError {
    case unsupportedPlatform
    case noBuiltInDisplay
    case noReadableBrightness

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Apple Silicon required"
        case .noBuiltInDisplay:
            "No built-in display"
        case .noReadableBrightness:
            "Brightness unavailable"
        }
    }
}

final class AppleSiliconDDCDisplayBrightnessBackend: DisplayBrightnessBackend {
    func discoverExternalDisplays() async -> [DisplayBrightnessTarget] {
        await Task.detached(priority: .utility) {
            AppleSiliconDDCMinimal.discoverDisplays().map {
                DisplayBrightnessTarget(id: $0.id, name: $0.displayName, service: $0.service)
            }
        }.value
    }

    func readMaxBrightness(_ target: DisplayBrightnessTarget) async -> UInt16? {
        await Task.detached(priority: .utility) {
            AppleSiliconDDCMinimal.read(service: target.service, command: luminanceVCPCode)?.max
        }.value
    }

    func setBrightness(_ target: DisplayBrightnessTarget, rawValue: UInt16) async -> Bool {
        await Task.detached(priority: .utility) {
            AppleSiliconDDCMinimal.write(service: target.service, command: luminanceVCPCode, value: rawValue)
        }.value
    }
}

final class MacBuiltInBrightnessProvider: BuiltInBrightnessProvider {
    func readBuiltInBrightness() async throws -> Double {
        try await Task.detached(priority: .utility) {
            try Self.readBrightnessSynchronously()
        }.value
    }

    private static func readBrightnessSynchronously() throws -> Double {
        let signatures = builtInDisplaySignatures()
        guard !signatures.isEmpty else {
            throw DisplayBrightnessError.noBuiltInDisplay
        }

        for signature in signatures {
            if let brightness = DisplayServicesBrightnessReader.readBrightness(displayID: signature.displayID) {
                return brightness
            }
        }

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else {
            throw DisplayBrightnessError.noReadableBrightness
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            defer { IOObjectRelease(service) }

            var brightness: Float = 0
            guard IODisplayGetFloatParameter(service, IOOptionBits(0), kIODisplayBrightnessKey as CFString, &brightness) == KERN_SUCCESS else {
                continue
            }

            if signatures.contains(where: { matchesBuiltInSignature(service: service, signature: $0) })
                || ioDisplayServiceLooksBuiltIn(service)
            {
                return Double(brightness).clamped(to: 0 ... 1)
            }
        }

        throw DisplayBrightnessError.noReadableBrightness
    }

    private struct DisplaySignature {
        var displayID: CGDirectDisplayID
        var vendor: UInt32
        var model: UInt32
        var serial: UInt32
        var ioDisplayLocation: String?
    }

    private static func builtInDisplaySignatures() -> [DisplaySignature] {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
            return []
        }

        return displays.prefix(Int(count)).compactMap { display in
            let infoDictionary = CoreDisplay_DisplayCreateInfoDictionary(display)?.takeRetainedValue() as NSDictionary?
            let ioDisplayLocation = infoDictionary?[kIODisplayLocationKey] as? String
                ?? infoDictionary?["IODisplayLocation"] as? String

            guard CGDisplayIsBuiltin(display) != 0 || coreDisplayInfoLooksBuiltIn(infoDictionary) else {
                return nil
            }

            return DisplaySignature(
                displayID: display,
                vendor: CGDisplayVendorNumber(display),
                model: CGDisplayModelNumber(display),
                serial: CGDisplaySerialNumber(display),
                ioDisplayLocation: ioDisplayLocation
            )
        }
    }

    private static func matchesBuiltInSignature(service: io_service_t, signature: DisplaySignature) -> Bool {
        if
            let ioDisplayLocation = signature.ioDisplayLocation,
            let servicePath = ioRegistryPath(for: service),
            (servicePath == ioDisplayLocation || servicePath.contains(ioDisplayLocation) || ioDisplayLocation.contains(servicePath))
        {
            return true
        }

        let vendor = uint32Property(service: service, key: "DisplayVendorID")
        let product = uint32Property(service: service, key: "DisplayProductID")
        let serial = uint32Property(service: service, key: "DisplaySerialNumber")

        guard vendor == signature.vendor, product == signature.model else {
            return false
        }

        return signature.serial == 0 || serial == 0 || serial == signature.serial
    }

    private static func coreDisplayInfoLooksBuiltIn(_ infoDictionary: NSDictionary?) -> Bool {
        guard let infoDictionary else { return false }

        if let location = infoDictionary[kIODisplayLocationKey] as? String ?? infoDictionary["IODisplayLocation"] as? String {
            if location.localizedCaseInsensitiveContains("AppleCLCD2") {
                return true
            }
        }

        return productNameLooksBuiltIn(productName(from: infoDictionary))
    }

    private static func ioDisplayServiceLooksBuiltIn(_ service: io_service_t) -> Bool {
        if let servicePath = ioRegistryPath(for: service), servicePath.localizedCaseInsensitiveContains("AppleCLCD2") {
            return true
        }

        guard
            let unmanaged = IODisplayCreateInfoDictionary(service, IOOptionBits(0))
        else {
            return false
        }

        let infoDictionary = unmanaged.takeRetainedValue() as NSDictionary
        return productNameLooksBuiltIn(productName(from: infoDictionary))
    }

    private static func productName(from infoDictionary: NSDictionary) -> String {
        if let name = infoDictionary["DisplayProductName"] as? String {
            return name
        }

        if let names = infoDictionary["DisplayProductName"] as? [String: String] {
            return names["en_US"] ?? names.first?.value ?? ""
        }

        if let names = infoDictionary[kDisplayProductName] as? [String: String] {
            return names["en_US"] ?? names.first?.value ?? ""
        }

        return ""
    }

    private static func productNameLooksBuiltIn(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.contains("built-in")
            || name.contains("color lcd")
            || name.contains("liquid retina")
    }

    private static func ioRegistryPath(for service: io_service_t) -> String? {
        let pathPointer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { pathPointer.deallocate() }

        guard IORegistryEntryGetPath(service, kIOServicePlane, pathPointer) == KERN_SUCCESS else {
            return nil
        }

        return String(cString: pathPointer)
    }

    private static func uint32Property(service: io_service_t, key: String) -> UInt32 {
        guard
            let unmanaged = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0),
            let number = unmanaged.takeRetainedValue() as? NSNumber
        else {
            return 0
        }

        return number.uint32Value
    }
}

@MainActor
final class DisplaySyncService {
    var snapshotsHandler: (([DisplaySyncSnapshot]) -> Void)?
    var statusHandler: ((String) -> Void)?

    private let brightnessBackend: DisplayBrightnessBackend
    private let builtInBrightnessProvider: BuiltInBrightnessProvider
    private let reconfigurationObserver = DisplayReconfigurationObserver()

    private var settings = DisplaySyncSettings()
    private var pollingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var syncInFlight = false
    private var pendingRescan = false
    private var generation = 0
    private var sessions: [String: ManagedDisplaySession] = [:]
    private var lastBuiltInBrightness: Double?

    init(
        brightnessBackend: DisplayBrightnessBackend = AppleSiliconDDCDisplayBrightnessBackend(),
        builtInBrightnessProvider: BuiltInBrightnessProvider = MacBuiltInBrightnessProvider()
    ) {
        self.brightnessBackend = brightnessBackend
        self.builtInBrightnessProvider = builtInBrightnessProvider
    }

    func configure(_ settings: DisplaySyncSettings) {
        generation += 1
        self.settings = settings

        if settings.isEnabled {
            statusHandler?("Scanning")
            startIfNeeded()
            requestRescan(delay: 0)
        } else {
            stop()
            statusHandler?("Off")
            publishSnapshots()
        }
    }

    func refreshNow() {
        guard settings.isEnabled else { return }
        requestRescan(delay: 0)
    }

    func handleSystemSleep() {
        debounceTask?.cancel()
        pollingTask?.cancel()
        pollingTask = nil
    }

    func handleSystemWake() {
        guard settings.isEnabled else { return }
        startIfNeeded()
        requestRescan(delay: 2.5)
    }

    private func startIfNeeded() {
        guard pollingTask == nil else { return }

        reconfigurationObserver.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestRescan(delay: 1)
            }
        }

        pollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.performSync(forceRescan: false)

                let interval = 1.0 / self.settings.pollingRateHz.clamped(to: 1 ... 10)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stop() {
        generation += 1
        debounceTask?.cancel()
        debounceTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        reconfigurationObserver.stop()
        pendingRescan = false
        lastBuiltInBrightness = nil
        statusHandler?("Off")

        for id in sessions.keys {
            sessions[id]?.state = .disabled
        }
    }

    private func requestRescan(delay: TimeInterval) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            guard !Task.isCancelled else { return }
            await self?.performSync(forceRescan: true)
        }
    }

    private func performSync(forceRescan: Bool) async {
        guard settings.isEnabled else { return }

        if syncInFlight {
            pendingRescan = pendingRescan || forceRescan
            return
        }

        syncInFlight = true
        let syncGeneration = generation

        repeat {
            let shouldRescan = forceRescan || pendingRescan || sessions.isEmpty
            pendingRescan = false
            await performSyncPass(forceRescan: shouldRescan, generation: syncGeneration)
        } while pendingRescan && settings.isEnabled && generation == syncGeneration

        let shouldRunPendingSync = pendingRescan && settings.isEnabled
        syncInFlight = false

        if shouldRunPendingSync {
            pendingRescan = false
            Task { [weak self] in
                await self?.performSync(forceRescan: true)
            }
        }
    }

    private func performSyncPass(forceRescan: Bool, generation syncGeneration: Int) async {
        guard generation == syncGeneration else { return }

        if forceRescan {
            await reconcileDisplays()
        }

        guard generation == syncGeneration else { return }

        let builtInBrightness: Double

        do {
            builtInBrightness = try await builtInBrightnessProvider.readBuiltInBrightness()
        } catch {
            guard generation == syncGeneration else { return }
            updateSourceError(error.localizedDescription)
            return
        }

        guard generation == syncGeneration else { return }
        statusHandler?("Built-in \(builtInBrightness.formatted(.percent.precision(.fractionLength(0))))")

        let shouldWrite = forceRescan
            || lastBuiltInBrightness == nil
            || abs((lastBuiltInBrightness ?? builtInBrightness) - builtInBrightness) >= 0.01

        guard shouldWrite else { return }

        lastBuiltInBrightness = builtInBrightness

        for id in sessions.keys.sorted() {
            guard settings.isEnabled, generation == syncGeneration else { return }
            guard var session = sessions[id], session.isConnected, let target = session.target else { continue }

            session.state = .syncing
            sessions[id] = session
            publishSnapshots()

            if session.maxBrightness == nil {
                session.maxBrightness = await brightnessBackend.readMaxBrightness(target) ?? 100
            }

            guard settings.isEnabled, generation == syncGeneration else { return }

            let maxBrightness = max(session.maxBrightness ?? 100, 1)
            let rawValue = UInt16(Int((builtInBrightness * Double(maxBrightness)).rounded())).clamped(to: 0 ... maxBrightness)
            let didWrite = await brightnessBackend.setBrightness(target, rawValue: rawValue)

            guard settings.isEnabled, generation == syncGeneration else { return }

            session.lastSeen = Date()

            if didWrite {
                session.lastBrightnessPercent = builtInBrightness
                session.state = .connected
                session.lastError = nil
            } else {
                session.state = .error("Write failed")
                session.lastError = "Write failed"
            }

            sessions[id] = session
            publishSnapshots()
        }
    }

    private func reconcileDisplays() async {
        let discoveredDisplays = await brightnessBackend.discoverExternalDisplays()
        let now = Date()
        let connectedIDs = Set(discoveredDisplays.map(\.id))

        for id in sessions.keys where !connectedIDs.contains(id) {
            sessions[id]?.isConnected = false
            sessions[id]?.target = nil
            sessions[id]?.state = .disconnected
        }

        for target in discoveredDisplays {
            if var existing = sessions[target.id] {
                existing.name = target.name
                existing.target = target
                existing.isConnected = true
                existing.lastSeen = now
                existing.state = settings.isEnabled
                    ? (existing.lastBrightnessPercent == nil ? .ready : .connected)
                    : .disabled
                sessions[target.id] = existing
            } else {
                sessions[target.id] = ManagedDisplaySession(
                    id: target.id,
                    name: target.name,
                    target: target,
                    isConnected: true,
                    state: settings.isEnabled ? .ready : .disabled,
                    lastSeen: now
                )
            }
        }

        publishSnapshots()
    }

    private func updateSourceError(_ message: String) {
        statusHandler?(message)

        for id in sessions.keys {
            guard sessions[id]?.isConnected == true else { continue }

            if sessions[id]?.lastBrightnessPercent == nil {
                sessions[id]?.state = .ready
            }
        }

        publishSnapshots()
    }

    private func publishSnapshots() {
        let snapshots = sessions.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                DisplaySyncSnapshot(
                    id: $0.id,
                    name: $0.name,
                    state: $0.state,
                    lastBrightnessPercent: $0.lastBrightnessPercent,
                    lastSeen: $0.lastSeen
                )
            }

        snapshotsHandler?(snapshots)
    }
}

private struct ManagedDisplaySession {
    var id: String
    var name: String
    var target: DisplayBrightnessTarget?
    var isConnected: Bool
    var state: DisplaySyncDisplayState
    var lastBrightnessPercent: Double?
    var lastSeen: Date?
    var maxBrightness: UInt16?
    var lastError: String?
}

private final class DisplayReconfigurationObserver {
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

private extension UInt16 {
    func clamped(to range: ClosedRange<UInt16>) -> UInt16 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private enum DisplayServicesBrightnessReader {
    typealias GetBrightnessFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private static let function: GetBrightnessFunction? = {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
            let symbol = dlsym(handle, "DisplayServicesGetBrightness")
        else {
            return nil
        }

        return unsafeBitCast(symbol, to: GetBrightnessFunction.self)
    }()

    static func readBrightness(displayID: CGDirectDisplayID) -> Double? {
        guard let function else { return nil }

        var brightness: Float = 0
        guard function(displayID, &brightness) == 0 else { return nil }

        return Double(brightness).clamped(to: 0 ... 1)
    }
}
