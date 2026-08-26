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
            var windowsActions = profile.WindowsDisplayBehaviors
                .Where(item => monitors.ContainsKey(item.Key))
                .Select(item => (Monitor: monitors[item.Key], Behavior: item.Value))
                .GroupBy(item => item.Monitor.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.Last())
                .ToList();
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

            // Displays returning to Windows must be active before their monitor
            // input is switched back. A replacement primary must also be ready
            // before any other Windows path is detached.
            ApplyActiveBehaviors(windowsActions, errors);

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

            // Keep the Windows path available long enough for DDC to work, then
            // detach displays handed to another computer and verify that the
            // desktop space really disappeared.
            await ApplyDisabledBehaviorsAsync(windowsActions, errors);

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
            var windowsActions = wireProfile.Monitors
                .Where(item => monitors.ContainsKey(item.SharedID))
                .Select(item => (Monitor: monitors[item.SharedID], Behavior: item.WindowsBehavior))
                .GroupBy(item => item.Monitor.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.Last())
                .ToList();

            ApplyActiveBehaviors(windowsActions, errors);
            await ApplyDisabledBehaviorsAsync(windowsActions, errors);

            StatusChanged?.Invoke(errors.Count == 0
                ? $"{wireProfile.Name} applied"
                : $"{wireProfile.Name}: {string.Join(" · ", errors.Distinct())}");
        }
        finally
        {
            _gate.Release();
        }
    }

    private void ApplyActiveBehaviors(
        IReadOnlyCollection<(MonitorDefinition Monitor, WindowsDisplayBehavior Behavior)> actions,
        ICollection<string> errors)
    {
        foreach (var action in actions.Where(item => item.Behavior == WindowsDisplayBehavior.Extended))
        {
            if (!_topology.EnableExtended(action.Monitor, out var error))
                errors.Add($"{action.Monitor.DisplayLabel}: {error}");
        }

        foreach (var action in actions.Where(item => item.Behavior == WindowsDisplayBehavior.Primary))
        {
            if (!_topology.MakePrimary(action.Monitor, out var error))
                errors.Add($"{action.Monitor.DisplayLabel}: {error}");
        }

        if (actions.Any(item => item.Behavior == WindowsDisplayBehavior.MirrorPrimary) &&
            !_topology.MirrorAll(out var mirrorError))
        {
            errors.Add(mirrorError);
        }
    }

    private async Task ApplyDisabledBehaviorsAsync(
        IReadOnlyCollection<(MonitorDefinition Monitor, WindowsDisplayBehavior Behavior)> actions,
        ICollection<string> errors)
    {
        foreach (var action in actions.Where(item => item.Behavior == WindowsDisplayBehavior.Disabled))
            await DisableAndVerifyAsync(action.Monitor, errors);
    }

    private async Task DisableAndVerifyAsync(MonitorDefinition monitor, ICollection<string> errors)
    {
        const int maximumPolls = 10;
        const int stableInactivePollsRequired = 4;
        var stableInactivePolls = 0;
        var lastError = "";

        for (var poll = 0; poll < maximumPolls; poll++)
        {
            if (_topology.IsActive(monitor))
            {
                stableInactivePolls = 0;
                if (!_topology.Disable(monitor, out var error)) lastError = error;
            }
            else
            {
                stableInactivePolls++;
                if (stableInactivePolls >= stableInactivePollsRequired) return;
            }

            if (poll + 1 < maximumPolls) await Task.Delay(500);
        }

        var detail = _topology.IsActive(monitor)
            ? string.IsNullOrWhiteSpace(lastError)
                ? "Windows kept the display attached to the desktop."
                : lastError
            : "The detached state did not remain stable long enough to verify.";
        errors.Add($"{monitor.DisplayLabel}: {detail}");
    }
}
