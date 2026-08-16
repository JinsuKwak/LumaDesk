import Foundation

@MainActor
final class DisplaySyncService {
    var snapshotsHandler: (([DisplaySyncSnapshot]) -> Void)?
    var statusHandler: ((String) -> Void)?

    private let brightnessBackend: DisplayBrightnessBackend
    private let builtInBrightnessProvider: BuiltInBrightnessProvider
    private let inputSwitchingService: DisplayInputSwitchingService
    private let reconfigurationObserver = DisplayReconfigurationObserver()

    private var settings = DisplaySyncSettings()
    private var pollingTask: Task<Void, Never>?
    private var inputPollingTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var syncInFlight = false
    private var switchAwayInFlight = false
    private var pendingRescan = false
    private var generation = 0
    private var sessions: [String: ManagedDisplaySession] = [:]
    private var lastBuiltInBrightness: Double?

    init(
        brightnessBackend: DisplayBrightnessBackend = AppleSiliconDDCDisplayBrightnessBackend(),
        inputSwitchBackend: DisplayInputSwitchBackend = AppleSiliconDDCDisplayBrightnessBackend(),
        builtInBrightnessProvider: BuiltInBrightnessProvider = MacBuiltInBrightnessProvider()
    ) {
        self.brightnessBackend = brightnessBackend
        inputSwitchingService = DisplayInputSwitchingService(backend: inputSwitchBackend)
        self.builtInBrightnessProvider = builtInBrightnessProvider
    }

    func configure(_ settings: DisplaySyncSettings) {
        generation += 1
        self.settings = settings
        startInputPollingIfNeeded()

        if settings.isEnabled {
            statusHandler?("Scanning")
            startIfNeeded()
            requestRescan(delay: 0)
        } else {
            stop()
            statusHandler?("Off")
            Task { [weak self] in
                await self?.reconcileDisplays()
            }
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

    func switchAway(profileID: UUID? = nil) {
        guard !switchAwayInFlight else { return }

        switchAwayInFlight = true
        let selectedProfileID = profileID ?? settings.defaultSwitchingProfileID
        statusHandler?("Switching")

        Task { [weak self] in
            await self?.performSwitchProfile(profileID: selectedProfileID)
        }
    }

    func handleSystemSleep() {
        debounceTask?.cancel()
        pollingTask?.cancel()
        pollingTask = nil
        inputPollingTask?.cancel()
        inputPollingTask = nil
    }

    func handleSystemWake() {
        startInputPollingIfNeeded()
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

    /// Input state uses a fixed, read-only 1 Hz refresh independently from the
    /// brightness-sync rate. A monitor switched to another host can stop
    /// answering DDC, in which case its input is simply unknown.
    private func startInputPollingIfNeeded() {
        guard inputPollingTask == nil else { return }

        inputPollingTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileDisplays()
            while !Task.isCancelled {
                await self.refreshCurrentInputs()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
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

    private func refreshCurrentInputs() async {
        guard !switchAwayInFlight else { return }

        for id in sessions.keys.sorted() {
            guard let session = sessions[id], session.isConnected, let target = session.target else { continue }
            let currentInputCode = await inputSwitchingService.readCurrentStandardInput(on: target)

            // Another actor task can update this session while the DDC read is
            // suspended. Re-fetch it instead of writing back a stale full copy.
            guard var latestSession = sessions[id], latestSession.isConnected else { continue }
            latestSession.currentInputCode = currentInputCode
            sessions[id] = latestSession
        }
        publishSnapshots()
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
                existing.displayNumber = target.displayNumber
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
                    displayNumber: target.displayNumber,
                    target: target,
                    isConnected: true,
                    state: settings.isEnabled ? .ready : .disabled,
                    lastSeen: now
                )
            }

            // Never keep Dictionary.subscript's modify access alive across an
            // await. The independent 1 Hz input poll can otherwise re-enter this
            // actor and mutate `sessions`, invalidating the dictionary storage.
            let currentInputCode = await inputSwitchingService.readCurrentStandardInput(on: target)
            if var latestSession = sessions[target.id], latestSession.isConnected {
                latestSession.currentInputCode = currentInputCode
                sessions[target.id] = latestSession
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

    private func performSwitchProfile(profileID: UUID?) async {
        while syncInFlight, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        await reconcileDisplays()

        guard let profileID,
              let profile = settings.switchingProfiles.first(where: { $0.id == profileID })
        else {
            statusHandler?("Set a default profile")
            switchAwayInFlight = false
            return
        }

        let displayIDs = profile.inputAssignments.keys.sorted()
        var attemptedSwitch = false
        var successfulSwitch = false

        for id in displayIDs {
            guard !Task.isCancelled else { break }
            guard let inputValue = profile.inputAssignments[id] else { continue }
            guard var session = sessions[id], session.isConnected, let target = session.target else { continue }

            attemptedSwitch = true
            session.state = .switching
            session.lastError = nil
            sessions[id] = session
            publishSnapshots()

            let configuration = settings.monitorDDCConfigurations[id] ?? .standardDefault
            let result = await inputSwitchingService.switchInput(on: target, configuration: configuration, value: inputValue)

            session.lastSeen = Date()

            switch result {
            case .alreadySelected:
                session.state = .away
                session.lastError = nil
                successfulSwitch = true
            case .sent:
                session.state = .sent
                session.lastError = nil
                successfulSwitch = true
            case .failed:
                session.state = .error("Input failed")
                session.lastError = "Input failed"
            }

            sessions[id] = session
            publishSnapshots()
        }

        if successfulSwitch {
            statusHandler?("\(profile.name) sent")
        } else if attemptedSwitch {
            statusHandler?("\(profile.name) failed")
        } else {
            statusHandler?("No monitors in \(profile.name)")
        }

        switchAwayInFlight = false

        if settings.isEnabled, pendingRescan {
            pendingRescan = false
            requestRescan(delay: 1)
        }
    }

    private func publishSnapshots() {
        let snapshots = sessions.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map {
                DisplaySyncSnapshot(
                    id: $0.id,
                    name: $0.name,
                    displayNumber: $0.displayNumber,
                    state: $0.state,
                    lastBrightnessPercent: $0.lastBrightnessPercent,
                    lastSeen: $0.lastSeen,
                    ddcConfiguration: settings.monitorDDCConfigurations[$0.id] ?? .standardDefault,
                    currentInputCode: $0.currentInputCode
                )
            }

        snapshotsHandler?(snapshots)
    }
}

private struct ManagedDisplaySession {
    var id: String
    var name: String
    var displayNumber: Int
    var target: DisplayBrightnessTarget?
    var isConnected: Bool
    var state: DisplaySyncDisplayState
    var lastBrightnessPercent: Double?
    var lastSeen: Date?
    var maxBrightness: UInt16?
    var currentInputCode: UInt16?
    var lastError: String?
}
