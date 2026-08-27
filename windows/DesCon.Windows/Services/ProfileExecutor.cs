using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class ProfileExecutor
{
    private readonly DdcService _ddc;
    private readonly DisplayTopologyService _topology;
    private readonly Func<AppSettings> _settings;
    private readonly LanPeerService _peer;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private Guid? _lastSuccessfulLocalProfileID;

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
            var previousProfile = settings.Profiles.FirstOrDefault(item =>
                item.Id == _lastSuccessfulLocalProfileID);
            var windowsActions = ResolveWindowsActions(profile, monitors);
            var errors = new List<string>();
            Guid? transactionID = null;

            if (profile.CoordinationMode == ProfileCoordinationMode.Restore)
            {
                await RecoverActiveBehaviorsAsync(windowsActions, errors);
                if (errors.Count == 0)
                {
                    _lastSuccessfulLocalProfileID = profile.Id;
                    StatusChanged?.Invoke($"{profile.Name} restored");
                }
                else
                {
                    StatusChanged?.Invoke($"{profile.Name}: {string.Join(" · ", errors.Distinct())}");
                }
                return;
            }

            if (RequiresPeer(profile.CoordinationMode))
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
            var preSwitchTopologyErrors = new List<string>();
            ApplyActiveBehaviors(windowsActions, preSwitchTopologyErrors);

            var delivered = 0;
            foreach (var (monitorID, value) in profile.InputAssignments)
            {
                if (!monitors.TryGetValue(monitorID, out var monitor)) continue;
                var result = await _ddc.SetInputAsync(monitor, value);
                if (result.Success) delivered++;
                else errors.Add($"{monitor.Name}: {result.Detail}");
            }

            await Task.Delay(600);

            // A monitor handed back from Mac may not expose an active Windows
            // path until after its DDC input changes. Reapply any requested
            // Primary/Extended layout with a short bounded retry, including
            // managed profiles which restore a previously disabled display.
            await RecoverActiveBehaviorsAsync(windowsActions, errors);

            if (transactionID is { } preparedTransaction)
            {
                var commit = await _peer.CommitAsync(preparedTransaction);
                if (!commit.Ok)
                {
                    if (settings.Network.RollbackOnPeerFailure && previousProfile is not null)
                    {
                        var rollbackErrors = await RestorePreviousProfileAsync(previousProfile, monitors);
                        if (RequiresPeer(previousProfile.CoordinationMode))
                        {
                            var peerRollback = await _peer.RevertAsync(previousProfile);
                            if (!peerRollback.Ok) rollbackErrors.Add($"Peer rollback: {peerRollback.Detail}");
                        }

                        _lastSuccessfulLocalProfileID = previousProfile.Id;
                        StatusChanged?.Invoke(rollbackErrors.Count == 0
                            ? $"{profile.Name}: peer did not confirm · restored {previousProfile.Name}"
                            : $"{profile.Name}: peer did not confirm · rollback incomplete: {string.Join(" · ", rollbackErrors.Distinct())}");
                        return;
                    }

                    if (settings.Network.RollbackOnPeerFailure)
                    {
                        StatusChanged?.Invoke($"{profile.Name}: {commit.Detail} No previous successful profile is available to restore.");
                        return;
                    }

                    errors.Add(commit.Detail);
                }
            }

            // Keep the Windows path available long enough for DDC to work, then
            // detach displays handed to another computer and verify that the
            // desktop space really disappeared.
            await ApplyDisabledBehaviorsAsync(windowsActions, errors);

            if (errors.Count == 0) _lastSuccessfulLocalProfileID = profile.Id;

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
            if (wireProfile.CoordinationMode == ProfileCoordinationMode.Managed &&
                wireProfile.RestorePeerLayout == false)
            {
                StatusChanged?.Invoke($"{wireProfile.Name} received · layout unchanged");
                return;
            }

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

            await RecoverActiveBehaviorsAsync(windowsActions, errors);
            await ApplyDisabledBehaviorsAsync(windowsActions, errors);

            if (errors.Count == 0) _lastSuccessfulLocalProfileID = null;

            StatusChanged?.Invoke(errors.Count == 0
                ? $"{wireProfile.Name} applied"
                : $"{wireProfile.Name}: {string.Join(" · ", errors.Distinct())}");
        }
        finally
        {
            _gate.Release();
        }
    }

    private static List<(MonitorDefinition Monitor, WindowsDisplayBehavior Behavior)> ResolveWindowsActions(
        SwitchingProfile profile,
        IReadOnlyDictionary<string, MonitorDefinition> monitors)
    {
        if (profile.CoordinationMode is ProfileCoordinationMode.Self or ProfileCoordinationMode.Restore)
        {
            IEnumerable<string> includedIDs = profile.CoordinationMode == ProfileCoordinationMode.Restore
                ? profile.LayoutMonitorIds
                : profile.InputAssignments.Keys;
            var includedMonitors = includedIDs
                .Where(monitors.ContainsKey)
                .Select(key => monitors[key])
                .GroupBy(monitor => monitor.Id, StringComparer.OrdinalIgnoreCase)
                .Select(group => group.First())
                .OrderBy(monitor => monitor.DisplayNumber)
                .ToList();
            var primaryID = profile.CoordinationMode == ProfileCoordinationMode.Restore
                ? profile.LayoutPrimaryMonitorId
                : profile.SelfPrimaryMonitorId;
            var primary = includedMonitors.FirstOrDefault(monitor =>
                    string.Equals(monitor.ProfileStorageKey, primaryID, StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(monitor.Id, primaryID, StringComparison.OrdinalIgnoreCase))
                ?? includedMonitors.FirstOrDefault();

            return includedMonitors
                .Select(monitor => (
                    Monitor: monitor,
                    Behavior: monitor == primary
                        ? WindowsDisplayBehavior.Primary
                        : WindowsDisplayBehavior.Extended))
                .ToList();
        }

        return profile.WindowsDisplayBehaviors
            .Where(item => monitors.ContainsKey(item.Key))
            .Select(item => (Monitor: monitors[item.Key], Behavior: item.Value))
            .GroupBy(item => item.Monitor.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.Last())
            .ToList();
    }

    private static bool RequiresPeer(ProfileCoordinationMode mode) =>
        mode is ProfileCoordinationMode.Managed or ProfileCoordinationMode.Self;

    private async Task<List<string>> RestorePreviousProfileAsync(
        SwitchingProfile profile,
        IReadOnlyDictionary<string, MonitorDefinition> monitors)
    {
        var errors = new List<string>();
        var actions = ResolveWindowsActions(profile, monitors);
        if (profile.CoordinationMode == ProfileCoordinationMode.Restore)
        {
            await RecoverActiveBehaviorsAsync(actions, errors);
            return errors;
        }
        var preSwitchTopologyErrors = new List<string>();
        ApplyActiveBehaviors(actions, preSwitchTopologyErrors);

        foreach (var (monitorID, value) in profile.InputAssignments)
        {
            if (!monitors.TryGetValue(monitorID, out var monitor)) continue;
            var result = await _ddc.SetInputAsync(monitor, value);
            if (!result.Success) errors.Add($"{monitor.Name}: {result.Detail}");
        }

        await Task.Delay(600);
        await RecoverActiveBehaviorsAsync(actions, errors);
        await ApplyDisabledBehaviorsAsync(actions, errors);
        return errors;
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

    private async Task RecoverActiveBehaviorsAsync(
        IReadOnlyCollection<(MonitorDefinition Monitor, WindowsDisplayBehavior Behavior)> actions,
        ICollection<string> errors)
    {
        var activeMonitors = actions
            .Where(item => item.Behavior is WindowsDisplayBehavior.Primary
                or WindowsDisplayBehavior.Extended
                or WindowsDisplayBehavior.MirrorPrimary)
            .Select(item => item.Monitor)
            .DistinctBy(item => item.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (activeMonitors.Count == 0) return;

        List<string> lastErrors = [];
        for (var attempt = 0; attempt < 3; attempt++)
        {
            lastErrors = [];
            ApplyActiveBehaviors(actions, lastErrors);
            var verificationError = "";
            var activeVerified = lastErrors.Count == 0 &&
                _topology.AreActive(activeMonitors, out verificationError);
            if (activeVerified)
                return;
            if (!string.IsNullOrWhiteSpace(verificationError)) lastErrors.Add(verificationError);
            if (attempt < 2) await Task.Delay(attempt == 0 ? 650 : 900);
        }

        foreach (var error in lastErrors.Distinct()) errors.Add(error);
    }

    private async Task ApplyDisabledBehaviorsAsync(
        IReadOnlyCollection<(MonitorDefinition Monitor, WindowsDisplayBehavior Behavior)> actions,
        ICollection<string> errors)
    {
        var disabledMonitors = actions
            .Where(item => item.Behavior == WindowsDisplayBehavior.Disabled)
            .Select(item => item.Monitor)
            .DistinctBy(item => item.Id, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (disabledMonitors.Count == 0) return;

        if (!_topology.Disable(disabledMonitors, out var disableError))
        {
            errors.Add(disableError);
            return;
        }

        // SetDisplayConfig is synchronous; allow only a short event-settling
        // window, then perform one fresh path query. There is no repeated poll.
        await Task.Delay(350);
        if (!_topology.AreInactive(disabledMonitors, out var verificationError))
            errors.Add(verificationError);
    }
}
