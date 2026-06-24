import Foundation

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
    private var switchAwayInFlight = false
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
        if settings.isEnabled {
            requestRescan(delay: 0)
        } else {
            Task { [weak self] in
                guard let self else { return }
                self.statusHandler?("Scanning")
                await self.reconcileDisplays()
                self.statusHandler?("Ready")
            }
        }
    }

    func switchAway() {
        guard !switchAwayInFlight else { return }

        switchAwayInFlight = true
        statusHandler?("Switch Away")

        Task { [weak self] in
            await self?.performSwitchAway()
        }
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

        if switchAwayInFlight {
            pendingRescan = pendingRescan || forceRescan
            return
        }

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

            sessions[target.id]?.currentInputCode = await brightnessBackend.readInputSourceCode(target)
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

    private func performSwitchAway() async {
        while syncInFlight, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        await reconcileDisplays()

        let assignments = settings.awayInputAssignments
        let displayIDs = sessions.keys.sorted()
        var attemptedSwitch = false
        var successfulSwitch = false

        for id in displayIDs {
            guard !Task.isCancelled else { break }
            guard let source = assignments[id] else { continue }
            guard var session = sessions[id], session.isConnected, let target = session.target else { continue }

            attemptedSwitch = true
            session.state = .switching
            session.lastError = nil
            sessions[id] = session
            publishSnapshots()

            let currentInputCode = await brightnessBackend.readInputSourceCode(target)
            session.currentInputCode = currentInputCode

            if currentInputCode == source.rawValue {
                session.state = .away
                session.lastSeen = Date()
                session.lastError = nil
                sessions[id] = session
                successfulSwitch = true
                publishSnapshots()
                continue
            }

            let didWrite = await sendInputSwitchCommand(target, code: source.rawValue)

            session.lastSeen = Date()

            if didWrite {
                session.state = .sent
                session.lastError = nil
                successfulSwitch = true
            } else {
                session.state = .error("Input failed")
                session.lastError = "Input failed"
            }

            sessions[id] = session
            publishSnapshots()
        }

        if successfulSwitch {
            statusHandler?("Away sent")
        } else if attemptedSwitch {
            statusHandler?("Away failed")
        } else {
            statusHandler?("Set Away input")
        }

        switchAwayInFlight = false

        if settings.isEnabled, pendingRescan {
            pendingRescan = false
            requestRescan(delay: 1)
        }
    }

    private func sendInputSwitchCommand(_ target: DisplayBrightnessTarget, code: UInt16) async -> Bool {
        for attempt in 0 ..< 2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 450_000_000)
            }

            if await brightnessBackend.setInputSourceCode(target, code: code) {
                return true
            }
        }

        return false
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
                    lastSeen: $0.lastSeen,
                    awayInput: settings.awayInputAssignments[$0.id],
                    currentInputCode: $0.currentInputCode
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
    var currentInputCode: UInt16?
    var lastError: String?
}
