using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class ProfileExecutor
{
    private readonly DdcService _ddc;
    private readonly DisplayTopologyService _topology;
    private readonly Func<AppSettings> _settings;
    private readonly LanPeerService _peer;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public event Action<string>? StatusChanged;

    public ProfileExecutor(DdcService ddc, DisplayTopologyService topology, LanPeerService peer, Func<AppSettings> settings)
    {
        _ddc = ddc;
        _topology = topology;
        _peer = peer;
        _settings = settings;
    }

    public async Task ExecuteAsync(Guid profileID)
    {
        if (!await _gate.WaitAsync(0)) return;
        try
        {
            var settings = _settings();
            var profile = settings.Profiles.FirstOrDefault(item => item.Id == profileID);
            if (profile is null)
            {
                StatusChanged?.Invoke("Profile not found");
                return;
            }

            StatusChanged?.Invoke($"Switching to {profile.Name}…");
            var monitors = settings.Monitors
                .SelectMany(item => new[] { (Key: item.Id, Monitor: item), (Key: item.ProfileStorageKey, Monitor: item) })
                .GroupBy(item => item.Key, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(item => item.Key, item => item.First().Monitor, StringComparer.OrdinalIgnoreCase);
            var errors = new List<string>();
            Guid? transactionID = null;

            if (profile.CoordinationMode == ProfileCoordinationMode.Managed)
            {
                var preparation = await _peer.PrepareAsync(profile);
                if (!preparation.Ready)
                {
                    StatusChanged?.Invoke($"{profile.Name}: {preparation.Detail}");
                    return;
                }
                transactionID = preparation.TransactionID;
            }

            // A safe replacement primary must be established before a DDC input
            // switch can remove the current desktop from Windows.
            foreach (var (monitorID, behavior) in profile.WindowsDisplayBehaviors)
            {
                if (behavior != WindowsDisplayBehavior.Primary || !monitors.TryGetValue(monitorID, out var monitor)) continue;
                if (!_topology.MakePrimary(monitor, out var error)) errors.Add(error);
            }

            var delivered = 0;
            foreach (var (monitorID, value) in profile.InputAssignments)
            {
                if (!monitors.TryGetValue(monitorID, out var monitor)) continue;
                var result = await _ddc.SetInputAsync(monitor, value);
                if (result.Success) delivered++;
                else errors.Add($"{monitor.Name}: {result.Detail}");
            }

            await Task.Delay(600);

            if (transactionID is { } preparedTransaction)
            {
                var commit = await _peer.CommitAsync(preparedTransaction);
                if (!commit.Ok) errors.Add(commit.Detail);
            }

            foreach (var (monitorID, behavior) in profile.WindowsDisplayBehaviors)
            {
                if (!monitors.TryGetValue(monitorID, out var monitor)) continue;
                switch (behavior)
                {
                    case WindowsDisplayBehavior.Disabled:
                        if (!_topology.Disable(monitor, out var disableError)) errors.Add(disableError);
                        break;
                    case WindowsDisplayBehavior.Extended:
                        if (!_topology.EnableExtended(monitor, out var enableError)) errors.Add(enableError);
                        break;
                    case WindowsDisplayBehavior.MirrorPrimary:
                        if (!_topology.MirrorAll(out var mirrorError)) errors.Add(mirrorError);
                        break;
                }
            }

            if (errors.Count > 0)
                StatusChanged?.Invoke($"{profile.Name}: {string.Join(" · ", errors.Distinct())}");
            else if (profile.CoordinationMode == ProfileCoordinationMode.External)
                StatusChanged?.Invoke($"{profile.Name} sent · unverified");
            else
                StatusChanged?.Invoke($"{profile.Name} sent ({delivered} monitor{(delivered == 1 ? "" : "s")})");
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task ApplyRemoteProfileAsync(WireProfile wireProfile)
    {
        await _gate.WaitAsync();
        try
        {
            StatusChanged?.Invoke($"Applying {wireProfile.Name} from Mac…");
            await Task.Delay(900);
            var monitors = _settings().Monitors
                .Where(item => !string.IsNullOrWhiteSpace(item.NetworkIdentity))
                .GroupBy(item => item.NetworkIdentity, StringComparer.OrdinalIgnoreCase)
                .ToDictionary(item => item.Key, item => item.First(), StringComparer.OrdinalIgnoreCase);
            var errors = new List<string>();

            foreach (var action in wireProfile.Monitors.Where(item => item.WindowsBehavior == WindowsDisplayBehavior.Primary))
                if (monitors.TryGetValue(action.SharedID, out var primary) && !_topology.MakePrimary(primary, out var error)) errors.Add(error);

            foreach (var action in wireProfile.Monitors)
            {
                if (!monitors.TryGetValue(action.SharedID, out var monitor)) continue;
                switch (action.WindowsBehavior)
                {
                    case WindowsDisplayBehavior.Disabled:
                        if (!_topology.Disable(monitor, out var disableError)) errors.Add(disableError);
                        break;
                    case WindowsDisplayBehavior.Extended:
                        if (!_topology.EnableExtended(monitor, out var enableError)) errors.Add(enableError);
                        break;
                    case WindowsDisplayBehavior.MirrorPrimary:
                        if (!_topology.MirrorAll(out var mirrorError)) errors.Add(mirrorError);
                        break;
                }
            }

            StatusChanged?.Invoke(errors.Count == 0
                ? $"{wireProfile.Name} applied"
                : $"{wireProfile.Name}: {string.Join(" · ", errors.Distinct())}");
        }
        finally
        {
            _gate.Release();
        }
    }
}
