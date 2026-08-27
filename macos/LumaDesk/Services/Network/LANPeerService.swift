import CryptoKit
import Foundation
import Network

struct WireMonitorAction: Codable, Equatable {
    var sharedID: String
    var inputValue: UInt16?
    var macBehavior: String
    var windowsBehavior: WindowsDisplayBehavior
}

struct WireProfile: Codable, Equatable {
    var id: UUID
    var name: String
    var coordinationMode: ProfileCoordinationMode
    var managedTarget: ManagedProfileTarget
    var monitors: [WireMonitorAction]
}

@MainActor
final class LANPeerService {
    var statusHandler: ((String) -> Void)?
    var profileCommittedHandler: ((WireProfile) async -> Void)?

    private let queue = DispatchQueue(label: "DesCon.LANPeer")
    private let instanceID = UUID()
    private let multicastHost = NWEndpoint.Host("239.255.77.77")
    private let discoveryPort = NWEndpoint.Port(rawValue: 47_830)!
    private var settings = LANPeerSettings()
    private var listener: NWListener?
    private var multicastGroup: NWConnectionGroup?
    private var discoveryTask: Task<Void, Never>?
    private var peers: [UUID: Peer] = [:]
    private var pendingProfiles: [UUID: WireProfile] = [:]
    private var seenNonces: [String: Date] = [:]

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    var rollbackOnPeerFailure: Bool { settings.rollbackOnPeerFailure }

    func configure(_ settings: LANPeerSettings) {
        let requiresRestart = self.settings.isEnabled != settings.isEnabled
            || self.settings.commandPort != settings.commandPort
        self.settings = settings
        guard requiresRestart || (settings.isEnabled && listener == nil) else { return }
        stop()
        guard settings.isEnabled else {
            statusHandler?("LAN peer off")
            return
        }
        startTCPListener()
        startDiscovery()
    }

    func prepare(profile: WireProfile) async -> (ready: Bool, transactionID: UUID?, detail: String) {
        guard settings.isEnabled else { return (false, nil, "LAN peer communication is disabled.") }
        guard settings.sharedKey.count >= 8 else { return (false, nil, "Set the same LAN pairing key on both computers.") }
        guard let peer = await peerOrDiscover() else { return (false, nil, "Mac could not find the Windows peer on this LAN.") }

        let transactionID = UUID()
        let payload = PreparePayload(transactionID: transactionID, profile: profile)
        guard let data = try? encoder.encode(payload) else { return (false, nil, "Could not encode profile.") }
        var response = await send(type: "prepare", payload: data, to: peer)
        if !response.ok {
            peers.removeValue(forKey: peer.id)
            if let rediscoveredPeer = await peerOrDiscover() {
                response = await send(type: "prepare", payload: data, to: rediscoveredPeer)
            }
        }
        return response.ok ? (true, transactionID, response.detail) : (false, nil, response.detail)
    }

    func commit(transactionID: UUID) async -> (ok: Bool, detail: String) {
        guard let peer = bestPeer() else { return (false, "Windows peer disappeared before commit.") }
        guard let data = try? encoder.encode(CommitPayload(transactionID: transactionID)) else {
            return (false, "Could not encode commit.")
        }
        let response = await send(type: "commit", payload: data, to: peer)
        return (response.ok, response.detail)
    }

    func revert(profile: WireProfile) async -> (ok: Bool, detail: String) {
        guard let peer = bestPeer() else { return (false, "Windows peer is unavailable for rollback.") }
        guard let data = try? encoder.encode(profile) else {
            return (false, "Could not encode rollback profile.")
        }
        let response = await send(type: "revert", payload: data, to: peer)
        return (response.ok, response.detail)
    }

    func rescan() {
        guard settings.isEnabled, multicastGroup != nil else {
            statusHandler?(settings.isEnabled ? "LAN discovery unavailable" : "LAN peer off")
            return
        }

        discoveryTask?.cancel()
        peers.removeAll()
        statusHandler?("Searching LAN")
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0 ..< 3 where !Task.isCancelled {
                self.sendAnnouncement(kind: "probe")
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, self.peers.isEmpty else { return }
            self.statusHandler?("No Windows peer found")
        }
    }

    func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        listener?.cancel()
        listener = nil
        multicastGroup?.cancel()
        multicastGroup = nil
        peers.removeAll()
    }

    private func startTCPListener() {
        guard let port = NWEndpoint.Port(rawValue: settings.commandPort),
              let listener = try? NWListener(using: .tcp, on: port)
        else {
            statusHandler?("LAN port unavailable")
            return
        }

        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready: self?.statusHandler?("Searching LAN")
                case .failed(let error): self?.statusHandler?("LAN error: \(error.localizedDescription)")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handle(connection: connection)
            }
        }
        listener.start(queue: queue)
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveLine(connection: connection, accumulated: Data()) { [weak self] data in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = await self.process(data: data)
                guard let responseData = try? self.encoder.encode(response),
                      let envelope = self.makeEnvelope(type: "response", payload: responseData),
                      var encoded = try? self.encoder.encode(envelope)
                else {
                    connection.cancel()
                    return
                }
                encoded.append(0x0A)
                connection.send(content: encoded, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func process(data: Data) async -> PeerResponse {
        guard settings.isEnabled else { return PeerResponse(ok: false, detail: "LAN peer communication is disabled.") }
        guard let envelope = try? decoder.decode(Envelope.self, from: data), verify(envelope) else {
            return PeerResponse(ok: false, detail: "Authentication failed.")
        }
        guard let payload = Data(base64Encoded: envelope.payload) else {
            return PeerResponse(ok: false, detail: "Invalid payload.")
        }

        switch envelope.type {
        case "prepare":
            guard let prepare = try? decoder.decode(PreparePayload.self, from: payload) else {
                return PeerResponse(ok: false, detail: "Invalid profile payload.")
            }
            guard prepare.profile.coordinationMode == .managed,
                  prepare.profile.managedTarget == .macOS
            else {
                return PeerResponse(ok: false, detail: "This profile does not target Mac.")
            }
            pendingProfiles[prepare.transactionID] = prepare.profile
            return PeerResponse(ok: true, detail: "Ready")
        case "commit":
            guard let commit = try? decoder.decode(CommitPayload.self, from: payload),
                  let profile = pendingProfiles.removeValue(forKey: commit.transactionID)
            else {
                return PeerResponse(ok: false, detail: "Unknown or expired transaction.")
            }
            await profileCommittedHandler?(profile)
            return PeerResponse(ok: true, detail: "Applied")
        case "revert":
            guard let profile = try? decoder.decode(WireProfile.self, from: payload),
                  profile.coordinationMode == .managed,
                  profile.managedTarget == .macOS
            else {
                return PeerResponse(ok: false, detail: "Invalid Mac rollback profile.")
            }
            await profileCommittedHandler?(profile)
            return PeerResponse(ok: true, detail: "Reverted")
        default:
            return PeerResponse(ok: false, detail: "Unknown command.")
        }
    }

    private func startDiscovery() {
        guard let descriptor = try? NWMulticastGroup(for: [.hostPort(host: multicastHost, port: discoveryPort)]) else {
            statusHandler?("Multicast unavailable")
            return
        }
        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        let group = NWConnectionGroup(with: descriptor, using: parameters)
        multicastGroup = group

        group.setReceiveHandler(maximumMessageSize: 65_535, rejectOversizedMessages: true) { [weak self] message, content, _ in
            guard let content, case .hostPort(let host, _) = message.remoteEndpoint else { return }
            Task { @MainActor [weak self] in
                self?.handleAnnouncement(content, host: host)
            }
        }
        group.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor [weak self] in self?.rescan() }
        }
        group.start(queue: queue)
    }

    private func handleAnnouncement(_ data: Data, host: NWEndpoint.Host) {
        guard let announcement = try? decoder.decode(DiscoveryAnnouncement.self, from: data),
              announcement.instanceID != instanceID,
              announcement.platform == "windows",
              let port = NWEndpoint.Port(rawValue: UInt16(announcement.commandPort))
        else { return }

        peers[announcement.instanceID] = Peer(
            id: announcement.instanceID,
            deviceName: announcement.deviceName,
            host: host,
            port: port,
            lastSeen: Date()
        )
        statusHandler?("Connected to \(announcement.deviceName)")
        if announcement.kind == "probe" {
            sendAnnouncement(kind: "presence")
        }
    }

    private func bestPeer() -> Peer? {
        return peers.values.max(by: { $0.lastSeen < $1.lastSeen })
    }

    private func peerOrDiscover() async -> Peer? {
        if let peer = bestPeer() { return peer }
        rescan()
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        return bestPeer()
    }

    private func sendAnnouncement(kind: String) {
        guard let data = try? encoder.encode(
            DiscoveryAnnouncement(
                version: 2,
                instanceID: instanceID,
                deviceName: settings.deviceName,
                platform: "macOS",
                commandPort: Int(settings.commandPort),
                kind: kind
            )
        ) else { return }
        multicastGroup?.send(content: data) { _ in }
    }

    private func send(type: String, payload: Data, to peer: Peer) async -> PeerResponse {
        guard let envelope = makeEnvelope(type: type, payload: payload),
              var data = try? encoder.encode(envelope)
        else { return PeerResponse(ok: false, detail: "Could not encode LAN request.") }
        data.append(0x0A)
        let requestData = data

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: peer.host, port: peer.port, using: .tcp)
            var didFinish = false
            func finish(_ response: PeerResponse) {
                guard !didFinish else { return }
                didFinish = true
                connection.cancel()
                continuation.resume(returning: response)
            }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        guard error == nil else {
                            finish(PeerResponse(ok: false, detail: error!.localizedDescription))
                            return
                        }
                        self?.receiveLine(connection: connection, accumulated: Data()) { responseData in
                            Task { @MainActor [weak self] in
                                guard let self,
                                      let envelope = try? self.decoder.decode(Envelope.self, from: responseData),
                                      envelope.type == "response",
                                      self.verify(envelope),
                                      let payload = Data(base64Encoded: envelope.payload),
                                      let response = try? self.decoder.decode(PeerResponse.self, from: payload)
                                else {
                                    finish(PeerResponse(ok: false, detail: "Invalid peer response."))
                                    return
                                }
                                finish(response)
                            }
                        }
                    })
                case .failed(let error): finish(PeerResponse(ok: false, detail: error.localizedDescription))
                case .cancelled: finish(PeerResponse(ok: false, detail: "Connection cancelled."))
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(min(max(settings.confirmationTimeoutSeconds, 2), 15))) {
                finish(PeerResponse(ok: false, detail: "Peer timed out."))
            }
        }
    }

    nonisolated private func receiveLine(
        connection: NWConnection,
        accumulated: Data,
        completion: @escaping (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            var combined = accumulated
            if let data { combined.append(data) }
            if let newline = combined.firstIndex(of: 0x0A) {
                completion(Data(combined[..<newline]))
            } else if isComplete || error != nil {
                completion(combined)
            } else {
                self?.receiveLine(connection: connection, accumulated: combined, completion: completion)
            }
        }
    }

    private func makeEnvelope(type: String, payload: Data) -> Envelope? {
        var envelope = Envelope(
            version: 1,
            id: UUID(),
            timestamp: Int64(Date().timeIntervalSince1970),
            nonce: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            type: type,
            payload: payload.base64EncodedString(),
            signature: ""
        )
        envelope.signature = signature(envelope)
        return envelope
    }

    private func verify(_ envelope: Envelope) -> Bool {
        guard settings.sharedKey.count >= 8,
              abs(Int64(Date().timeIntervalSince1970) - envelope.timestamp) <= 30,
              seenNonces[envelope.nonce] == nil,
              let signatureData = Data(hex: envelope.signature)
        else { return false }
        seenNonces[envelope.nonce] = Date()
        seenNonces = seenNonces.filter { $0.value > Date().addingTimeInterval(-120) }

        var unsigned = envelope
        unsigned.signature = ""
        let key = SymmetricKey(data: Data(settings.sharedKey.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(signatureData, authenticating: Data(canonical(unsigned).utf8), using: key)
    }

    private func signature(_ envelope: Envelope) -> String {
        let key = SymmetricKey(data: Data(settings.sharedKey.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data(canonical(envelope).utf8), using: key)).hex
    }

    private func canonical(_ envelope: Envelope) -> String {
        "\(envelope.version)|\(envelope.id.uuidString.lowercased())|\(envelope.timestamp)|\(envelope.nonce)|\(envelope.type)|\(envelope.payload)"
    }
}

private struct Peer {
    var id: UUID
    var deviceName: String
    var host: NWEndpoint.Host
    var port: NWEndpoint.Port
    var lastSeen: Date
}

private struct DiscoveryAnnouncement: Codable {
    var version: Int
    var instanceID: UUID
    var deviceName: String
    var platform: String
    var commandPort: Int
    var kind: String?
}

private struct Envelope: Codable {
    var version: Int
    var id: UUID
    var timestamp: Int64
    var nonce: String
    var type: String
    var payload: String
    var signature: String
}

private struct PreparePayload: Codable {
    var transactionID: UUID
    var profile: WireProfile
}

private struct CommitPayload: Codable {
    var transactionID: UUID
}

private struct PeerResponse: Codable {
    var ok: Bool
    var detail: String
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
