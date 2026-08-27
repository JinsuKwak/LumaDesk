using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class LanPeerService : IDisposable
{
    private const int DiscoveryPort = 47830;
    private const string MulticastAddress = "239.255.77.77";
    private readonly Func<AppSettings> _settings;
    private readonly Guid _instanceID = Guid.NewGuid();
    private readonly object _lifecycle = new();
    private readonly ConcurrentDictionary<Guid, WireProfile> _pending = [];
    private readonly ConcurrentDictionary<string, DateTimeOffset> _nonces = [];
    private readonly ConcurrentDictionary<Guid, Peer> _peers = [];
    private readonly ConcurrentDictionary<Guid, byte> _helloInFlight = [];
    private readonly ConcurrentDictionary<Guid, byte> _helloConfirmed = [];
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private readonly JsonSerializerOptions _json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
    private TcpListener? _listener;
    private UdpClient? _discoveryReceiver;
    private CancellationTokenSource? _sessionStop;
    private string _lastStatus = "LAN peer off";

    public Func<WireProfile, Task>? ProfileCommitted { get; set; }
    public event Action<string>? StatusChanged;
    public string PeerStatus => !_settings().Network.Enabled
        ? "LAN peer off"
        : BestPeer() is { } peer ? $"Connected to {peer.DeviceName}" : "Searching LAN";

    public LanPeerService(Func<AppSettings> settings) => _settings = settings;

    public void Start()
    {
        lock (_lifecycle)
        {
            if (!_settings().Network.Enabled)
            {
                StopLocked();
                return;
            }
            if (_sessionStop is not null) return;

            _sessionStop = new CancellationTokenSource();
            PublishStatus("Searching LAN");
            _ = RunTcpListener(_sessionStop.Token);
            _ = RunDiscovery(_sessionStop.Token);
        }
    }

    public async Task<(bool Ready, Guid TransactionID, string Detail)> PrepareAsync(SwitchingProfile profile)
    {
        var settings = _settings();
        if (!settings.Network.Enabled) return (false, Guid.Empty, "LAN peer communication is disabled.");
        if (settings.Network.SharedKey.Length < 8) return (false, Guid.Empty, "Set the same LAN pairing key on both computers.");
        var cancellationToken = _sessionStop?.Token ?? CancellationToken.None;
        var peer = await PeerOrDiscover(cancellationToken);
        if (peer is null) return (false, Guid.Empty, "Windows could not find the Mac peer on this LAN.");

        var transactionID = Guid.NewGuid();
        var wireProfile = WireProfile.From(profile, settings.Monitors);
        var payload = JsonSerializer.SerializeToUtf8Bytes(new PreparePayload(transactionID, wireProfile), _json);
        var response = await Send(peer, "prepare", payload, cancellationToken);
        if (!response.Ok)
        {
            _peers.TryRemove(peer.ID, out _);
            if (await PeerOrDiscover(cancellationToken) is { } rediscoveredPeer)
                response = await Send(rediscoveredPeer, "prepare", payload, cancellationToken);
        }
        return response.Ok
            ? (true, transactionID, response.Detail)
            : (false, Guid.Empty, response.Detail);
    }

    public async Task<(bool Ok, string Detail)> CommitAsync(Guid transactionID)
    {
        var peer = BestPeer();
        if (peer is null) return (false, "Mac peer disappeared before commit.");
        var payload = JsonSerializer.SerializeToUtf8Bytes(new CommitPayload(transactionID), _json);
        var cancellationToken = _sessionStop?.Token ?? CancellationToken.None;
        return await Send(peer, "commit", payload, cancellationToken);
    }

    public async Task<(bool Ok, string Detail)> RevertAsync(SwitchingProfile profile)
    {
        var peer = BestPeer();
        if (peer is null) return (false, "Mac peer is unavailable for rollback.");
        var wireProfile = WireProfile.From(profile, _settings().Monitors);
        var payload = JsonSerializer.SerializeToUtf8Bytes(wireProfile, _json);
        var cancellationToken = _sessionStop?.Token ?? CancellationToken.None;
        return await Send(peer, "revert", payload, cancellationToken);
    }

    public void Rescan()
    {
        if (!_settings().Network.Enabled)
        {
            PublishStatus("LAN peer off");
            return;
        }
        var cancellationToken = _sessionStop?.Token ?? CancellationToken.None;
        _ = ScanForPeers(cancellationToken, clearExisting: true);
    }

    public void Dispose()
    {
        lock (_lifecycle) StopLocked();
    }

    private void StopLocked()
    {
        var stop = _sessionStop;
        _sessionStop = null;
        stop?.Cancel();
        _listener?.Stop();
        _listener = null;
        _discoveryReceiver?.Dispose();
        _discoveryReceiver = null;
        _peers.Clear();
        _helloInFlight.Clear();
        _helloConfirmed.Clear();
        _pending.Clear();
        stop?.Dispose();
        PublishStatus("LAN peer off");
    }

    private async Task RunTcpListener(CancellationToken cancellationToken)
    {
        try
        {
            _listener = new TcpListener(IPAddress.Any, _settings().Network.CommandPort);
            _listener.Start();
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(cancellationToken);
                _ = HandleClient(client, cancellationToken);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException error) { PublishStatus($"LAN error: {error.Message}"); }
    }

    private async Task HandleClient(TcpClient client, CancellationToken cancellationToken)
    {
        try
        {
            using (client)
            using (var stream = client.GetStream())
            using (var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true })
            {
                var remoteAddress = (client.Client.RemoteEndPoint as IPEndPoint)?.Address;
                var line = await reader.ReadLineAsync(cancellationToken);
                var response = await Process(line, remoteAddress);
                await writer.WriteLineAsync(CreateEnvelope("response", JsonSerializer.SerializeToUtf8Bytes(response, _json)));
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        catch (SocketException) { }
    }

    private async Task<PeerResponse> Process(string? line, IPAddress? remoteAddress)
    {
        if (!_settings().Network.Enabled) return new PeerResponse(false, "LAN peer communication is disabled.");
        if (string.IsNullOrWhiteSpace(line)) return new PeerResponse(false, "Empty request.");
        Envelope? envelope;
        try { envelope = JsonSerializer.Deserialize<Envelope>(line, _json); }
        catch { return new PeerResponse(false, "Invalid request JSON."); }
        if (envelope is null || !Verify(envelope)) return new PeerResponse(false, "Authentication failed.");

        try
        {
            var payload = Convert.FromBase64String(envelope.Payload);
            switch (envelope.Type)
            {
                case "hello":
                    var hello = JsonSerializer.Deserialize<DiscoveryAnnouncement>(payload, _json);
                    if (hello is null ||
                        hello.InstanceID == _instanceID ||
                        hello.Platform != "macOS" ||
                        remoteAddress is null ||
                        hello.CommandPort is < 1 or > 65535)
                        return new PeerResponse(false, "Invalid Mac hello.");
                    _peers[hello.InstanceID] = new Peer(
                        hello.InstanceID,
                        hello.DeviceName,
                        remoteAddress,
                        hello.CommandPort,
                        DateTimeOffset.UtcNow);
                    _helloConfirmed[hello.InstanceID] = 0;
                    PublishStatus($"Connected to {hello.DeviceName}");
                    return new PeerResponse(true, "Hello");
                case "prepare":
                    var prepare = JsonSerializer.Deserialize<PreparePayload>(payload, _json);
                    if (prepare is null) return new PeerResponse(false, "Invalid profile payload.");
                    if (!RequiresPeer(prepare.Profile.CoordinationMode) ||
                        prepare.Profile.ManagedTarget != ManagedProfileTarget.Windows)
                        return new PeerResponse(false, "This profile does not target Windows.");
                    _pending[prepare.TransactionID] = prepare.Profile;
                    return new PeerResponse(true, "Ready");
                case "commit":
                    var commit = JsonSerializer.Deserialize<CommitPayload>(payload, _json);
                    if (commit is null || !_pending.TryRemove(commit.TransactionID, out var profile))
                        return new PeerResponse(false, "Unknown or expired transaction.");
                    if (ProfileCommitted is not null) await ProfileCommitted(profile);
                    return new PeerResponse(true, "Applied");
                case "revert":
                    var previousProfile = JsonSerializer.Deserialize<WireProfile>(payload, _json);
                    if (previousProfile is null ||
                        !RequiresPeer(previousProfile.CoordinationMode) ||
                        previousProfile.ManagedTarget != ManagedProfileTarget.Windows)
                        return new PeerResponse(false, "Invalid Windows rollback profile.");
                    if (ProfileCommitted is not null) await ProfileCommitted(previousProfile);
                    return new PeerResponse(true, "Reverted");
                default:
                    return new PeerResponse(false, "Unknown command.");
            }
        }
        catch (Exception error)
        {
            return new PeerResponse(false, error.Message);
        }
    }

    private async Task<(bool Ok, string Detail)> Send(Peer peer, string type, byte[] payload, CancellationToken cancellationToken)
    {
        try
        {
            using var client = new TcpClient();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(Math.Clamp(
                _settings().Network.ConfirmationTimeoutSeconds,
                2,
                15)));
            await client.ConnectAsync(peer.Address, peer.CommandPort, timeout.Token);
            await using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            await using var writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
            await writer.WriteLineAsync(CreateEnvelope(type, payload));
            var responseLine = await reader.ReadLineAsync(timeout.Token);
            var responseEnvelope = JsonSerializer.Deserialize<Envelope>(responseLine ?? "", _json);
            if (responseEnvelope is null || responseEnvelope.Type != "response" || !Verify(responseEnvelope))
                return (false, "Invalid peer response.");
            var response = JsonSerializer.Deserialize<PeerResponse>(Convert.FromBase64String(responseEnvelope.Payload), _json);
            return response is null ? (false, "Empty peer response.") : (response.Ok, response.Detail);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return (false, "Peer timed out.");
        }
        catch (Exception error)
        {
            return (false, error.Message);
        }
    }

    private async Task RunDiscovery(CancellationToken cancellationToken)
    {
        try
        {
            _discoveryReceiver = new UdpClient(AddressFamily.InterNetwork);
            _discoveryReceiver.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _discoveryReceiver.Client.Bind(new IPEndPoint(IPAddress.Any, DiscoveryPort));
            var multicastAddress = IPAddress.Parse(MulticastAddress);
            var joinedInterface = false;
            foreach (var localAddress in ActiveMulticastIPv4Addresses())
            {
                try
                {
                    _discoveryReceiver.JoinMulticastGroup(multicastAddress, localAddress);
                    joinedInterface = true;
                }
                catch (SocketException) { }
            }
            if (!joinedInterface) _discoveryReceiver.JoinMulticastGroup(multicastAddress);
            _ = ScanForPeers(cancellationToken, clearExisting: true);

            while (!cancellationToken.IsCancellationRequested)
            {
                var packet = await _discoveryReceiver.ReceiveAsync(cancellationToken);
                DiscoveryAnnouncement? announcement;
                try { announcement = JsonSerializer.Deserialize<DiscoveryAnnouncement>(packet.Buffer, _json); }
                catch (JsonException) { continue; }
                if (announcement is null ||
                    announcement.InstanceID == _instanceID ||
                    announcement.Platform != "macOS" ||
                    announcement.CommandPort is < 1 or > 65535) continue;
                var peer = new Peer(
                    announcement.InstanceID,
                    announcement.DeviceName,
                    packet.RemoteEndPoint.Address,
                    announcement.CommandPort,
                    DateTimeOffset.UtcNow);
                _peers[announcement.InstanceID] = peer;
                PublishStatus($"Connected to {announcement.DeviceName}");
                _ = SynchronizePeer(peer, cancellationToken);
                if (string.Equals(announcement.Kind, "probe", StringComparison.OrdinalIgnoreCase))
                    _ = SendDiscoveryAnnouncement("presence", cancellationToken);
            }
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) { }
        catch (SocketException error) { PublishStatus($"LAN error: {error.Message}"); }
    }

    private void PublishStatus(string status)
    {
        if (string.Equals(_lastStatus, status, StringComparison.Ordinal)) return;
        _lastStatus = status;
        StatusChanged?.Invoke(status);
    }

    private Peer? BestPeer()
    {
        return _peers.Values.OrderByDescending(item => item.LastSeen).FirstOrDefault();
    }

    private async Task<Peer?> PeerOrDiscover(CancellationToken cancellationToken)
    {
        if (BestPeer() is { } cached) return cached;
        await ScanForPeers(cancellationToken, clearExisting: false);
        return BestPeer();
    }

    private async Task ScanForPeers(CancellationToken cancellationToken, bool clearExisting)
    {
        await _scanGate.WaitAsync(cancellationToken);
        try
        {
            if (!clearExisting && BestPeer() is not null) return;
            if (clearExisting)
            {
                _peers.Clear();
                _helloInFlight.Clear();
                _helloConfirmed.Clear();
            }
            PublishStatus("Searching LAN");
            for (var attempt = 0; attempt < 3; attempt++)
            {
                await SendDiscoveryAnnouncement("probe", cancellationToken);
                await Task.Delay(TimeSpan.FromMilliseconds(250), cancellationToken);
            }
            await Task.Delay(TimeSpan.FromMilliseconds(350), cancellationToken);
            if (_peers.IsEmpty) PublishStatus("No Mac peer found");
        }
        catch (OperationCanceledException) { }
        catch (SocketException error) { PublishStatus($"LAN discovery error: {error.Message}"); }
        finally
        {
            _scanGate.Release();
        }
    }

    private async Task SendDiscoveryAnnouncement(string kind, CancellationToken cancellationToken)
    {
        var endpoint = new IPEndPoint(IPAddress.Parse(MulticastAddress), DiscoveryPort);
        var announcement = new DiscoveryAnnouncement(
            2,
            _instanceID,
            _settings().Network.DeviceName,
            "windows",
            _settings().Network.CommandPort,
            kind);
        var data = JsonSerializer.SerializeToUtf8Bytes(announcement, _json);
        var sent = false;
        foreach (var localAddress in ActiveMulticastIPv4Addresses())
        {
            try
            {
                using var sender = new UdpClient(new IPEndPoint(localAddress, 0));
                sender.MulticastLoopback = false;
                sender.Client.SetSocketOption(
                    SocketOptionLevel.IP,
                    SocketOptionName.MulticastInterface,
                    localAddress.GetAddressBytes());
                await sender.SendAsync(data, endpoint, cancellationToken);
                sent = true;
            }
            catch (SocketException) { }
        }

        if (sent) return;
        using var fallbackSender = new UdpClient(AddressFamily.InterNetwork);
        fallbackSender.MulticastLoopback = false;
        await fallbackSender.SendAsync(data, endpoint, cancellationToken);
    }

    private async Task SynchronizePeer(Peer peer, CancellationToken cancellationToken)
    {
        if (_settings().Network.SharedKey.Length < 8 ||
            _helloConfirmed.ContainsKey(peer.ID) ||
            !_helloInFlight.TryAdd(peer.ID, 0)) return;

        try
        {
            var hello = new DiscoveryAnnouncement(
                2,
                _instanceID,
                _settings().Network.DeviceName,
                "windows",
                _settings().Network.CommandPort,
                "direct");
            var payload = JsonSerializer.SerializeToUtf8Bytes(hello, _json);
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var response = await Send(peer, "hello", payload, cancellationToken);
                if (response.Ok)
                {
                    _helloConfirmed[peer.ID] = 0;
                    return;
                }
                if (attempt == 0) await Task.Delay(350, cancellationToken);
            }
            if (!_helloConfirmed.ContainsKey(peer.ID))
                PublishStatus($"Found {peer.DeviceName} · reverse connection failed");
        }
        catch (OperationCanceledException) { }
        finally
        {
            _helloInFlight.TryRemove(peer.ID, out _);
        }
    }

    private static IReadOnlyList<IPAddress> ActiveMulticastIPv4Addresses()
    {
        return NetworkInterface.GetAllNetworkInterfaces()
            .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up
                && adapter.SupportsMulticast
                && adapter.NetworkInterfaceType is not NetworkInterfaceType.Loopback
                && adapter.NetworkInterfaceType is not NetworkInterfaceType.Tunnel)
            .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses)
            .Select(address => address.Address)
            .Where(address => address.AddressFamily == AddressFamily.InterNetwork
                && !IPAddress.IsLoopback(address)
                && !address.ToString().StartsWith("169.254.", StringComparison.Ordinal))
            .Distinct()
            .ToList();
    }

    private string CreateEnvelope(string type, byte[] payload)
    {
        var envelope = new Envelope(
            1,
            Guid.NewGuid(),
            DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            Guid.NewGuid().ToString("N"),
            type,
            Convert.ToBase64String(payload),
            "");
        return JsonSerializer.Serialize(envelope with { Signature = Signature(envelope) }, _json);
    }

    private bool Verify(Envelope envelope)
    {
        try
        {
            if (_settings().Network.SharedKey.Length < 8) return false;
            if (Math.Abs(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - envelope.Timestamp) > 30) return false;
            if (!_nonces.TryAdd(envelope.Nonce, DateTimeOffset.UtcNow)) return false;
            foreach (var stale in _nonces.Where(item => item.Value < DateTimeOffset.UtcNow.AddMinutes(-2)).Select(item => item.Key))
                _nonces.TryRemove(stale, out _);
            var expected = Signature(envelope with { Signature = "" });
            return CryptographicOperations.FixedTimeEquals(Convert.FromHexString(expected), Convert.FromHexString(envelope.Signature));
        }
        catch
        {
            return false;
        }
    }

    private string Signature(Envelope envelope)
    {
        var canonical = $"{envelope.Version}|{envelope.ID:D}|{envelope.Timestamp}|{envelope.Nonce}|{envelope.Type}|{envelope.Payload}";
        var key = Encoding.UTF8.GetBytes(_settings().Network.SharedKey);
        return Convert.ToHexString(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    }

    private static bool RequiresPeer(ProfileCoordinationMode mode) =>
        mode is ProfileCoordinationMode.Managed or ProfileCoordinationMode.Self;

    private sealed record Peer(Guid ID, string DeviceName, IPAddress Address, int CommandPort, DateTimeOffset LastSeen);
    private sealed record DiscoveryAnnouncement(int Version, Guid InstanceID, string DeviceName, string Platform, int CommandPort, string? Kind);
    private sealed record Envelope(int Version, Guid ID, long Timestamp, string Nonce, string Type, string Payload, string Signature);
    private sealed record PreparePayload(Guid TransactionID, WireProfile Profile);
    private sealed record CommitPayload(Guid TransactionID);
    private sealed record PeerResponse(bool Ok, string Detail);
}

public sealed record WireMonitorAction(
    string SharedID,
    ushort? InputValue,
    MacDisplayBehavior MacBehavior,
    WindowsDisplayBehavior WindowsBehavior);

public sealed record WireProfile(
    Guid ID,
    string Name,
    ProfileCoordinationMode CoordinationMode,
    ManagedProfileTarget ManagedTarget,
    bool? RestorePeerLayout,
    IReadOnlyList<WireMonitorAction> Monitors)
{
    public static WireProfile From(SwitchingProfile profile, IReadOnlyCollection<MonitorDefinition> monitors)
    {
        if (profile.CoordinationMode == ProfileCoordinationMode.Self)
        {
            var included = monitors
                .Select(monitor => new
                {
                    Monitor = monitor,
                    Input = profile.InputAssignments.TryGetValue(monitor.ProfileStorageKey, out var value) ||
                            profile.InputAssignments.TryGetValue(monitor.Id, out value)
                        ? value
                        : (ushort?)null
                })
                .Where(item => item.Input is not null)
                .OrderBy(item => item.Monitor.DisplayNumber)
                .ToList();
            var selfPrimary = included.FirstOrDefault(item =>
                    string.Equals(item.Monitor.ProfileStorageKey, profile.SelfPrimaryMonitorId, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(item.Monitor.Id, profile.SelfPrimaryMonitorId, StringComparison.OrdinalIgnoreCase))
                ?? included.FirstOrDefault();
            var peerPrimary = included.FirstOrDefault(item =>
                    string.Equals(item.Monitor.ProfileStorageKey, profile.PeerPrimaryMonitorId, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(item.Monitor.Id, profile.PeerPrimaryMonitorId, StringComparison.OrdinalIgnoreCase))
                ?? selfPrimary;
            var selfActions = included
                .Select(item => new WireMonitorAction(
                    item.Monitor.NetworkIdentity,
                    item.Input,
                    item == peerPrimary ? MacDisplayBehavior.Primary : MacDisplayBehavior.HandedOff,
                    item == selfPrimary ? WindowsDisplayBehavior.Primary : WindowsDisplayBehavior.Extended))
                .ToList();
            return new WireProfile(profile.Id, profile.Name, profile.CoordinationMode, ManagedProfileTarget.MacOS, null, selfActions);
        }

        var actions = new List<WireMonitorAction>();
        foreach (var monitor in monitors)
        {
            var input = profile.InputAssignments.TryGetValue(monitor.ProfileStorageKey, out var inputValue)
                || profile.InputAssignments.TryGetValue(monitor.Id, out inputValue)
                ? inputValue : (ushort?)null;
            var mac = profile.MacDisplayBehaviors.GetValueOrDefault(
                monitor.ProfileStorageKey,
                profile.MacDisplayBehaviors.GetValueOrDefault(monitor.Id, MacDisplayBehavior.Unchanged));
            var windows = profile.WindowsDisplayBehaviors.GetValueOrDefault(
                monitor.ProfileStorageKey,
                profile.WindowsDisplayBehaviors.GetValueOrDefault(monitor.Id, WindowsDisplayBehavior.Unchanged));
            if (input is null && mac == MacDisplayBehavior.Unchanged && windows == WindowsDisplayBehavior.Unchanged) continue;
            actions.Add(new WireMonitorAction(monitor.NetworkIdentity, input, mac, windows));
        }
        return new WireProfile(
            profile.Id,
            profile.Name,
            profile.CoordinationMode,
            ManagedProfileTarget.MacOS,
            profile.CoordinationMode == ProfileCoordinationMode.Managed ? profile.RestorePeerLayout : null,
            actions);
    }
}
