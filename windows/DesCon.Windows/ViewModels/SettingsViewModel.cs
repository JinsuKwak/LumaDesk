using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using DesCon.Windows.Models;
using DesCon.Windows.Services;

namespace DesCon.Windows.ViewModels;

public abstract class ObservableModel : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;
    protected void Changed([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Changed(name);
        return true;
    }
}

public sealed class MonitorEditorViewModel : ObservableModel
{
    public MonitorDefinition Model { get; }
    private string _source;
    private string _vcp;
    private string _pairingId;
    private bool _isLocked = true;

    public MonitorEditorViewModel(MonitorDefinition model)
    {
        Model = model;
        _source = model.Ddc.SourceAddress.ToString("X2");
        _vcp = model.Ddc.VcpCode.ToString("X2");
        _pairingId = model.PairingId;
    }

    public string Name => Model.Name;
    public string Detail => $"{Model.DisplayLabel} · {(Model.IsConnected ? "Connected" : "Offline")}";
    public string Source { get => _source; set => Set(ref _source, value.ToUpperInvariant()); }
    public string Vcp { get => _vcp; set => Set(ref _vcp, value.ToUpperInvariant()); }
    public string PairingId { get => _pairingId; set => Set(ref _pairingId, value); }
    public bool IsLocked
    {
        get => _isLocked;
        set
        {
            if (Set(ref _isLocked, value)) Changed(nameof(LockGlyph));
        }
    }
    public string LockGlyph => IsLocked ? "\uE72E" : "\uE785";

    public void ToggleLock() => IsLocked = !IsLocked;

    public void Refresh()
    {
        Changed(nameof(Name));
        Changed(nameof(Detail));
    }

    public bool Apply(out string error)
    {
        error = "";
        if (!byte.TryParse(Source, System.Globalization.NumberStyles.HexNumber, null, out var source) ||
            !byte.TryParse(Vcp, System.Globalization.NumberStyles.HexNumber, null, out var vcp))
        {
            error = $"{Name}: Source and VCP must be two-digit hexadecimal values.";
            return false;
        }
        Model.Ddc.SourceAddress = source;
        Model.Ddc.VcpCode = vcp;
        Model.PairingId = PairingId.Trim();
        IsLocked = true;
        return true;
    }
}

public sealed class ProfileMonitorRowViewModel : ObservableModel
{
    private bool _isIncluded;
    private bool _inputIncluded;
    private bool _layoutIncluded;
    private bool _isLayoutMode;
    private string _input;
    private MacDisplayBehavior _macBehavior;
    private WindowsDisplayBehavior _behavior;
    private bool _showMacBehavior;
    private bool _showBehaviorControls;
    private bool _showInputControls;

    public string MonitorID => _monitor.Id;
    public string ProfileKey => StorageKey;
    private string StorageKey => _monitor.ProfileStorageKey;
    private readonly MonitorDefinition _monitor;
    private readonly string _initialStorageKey;

    public ProfileMonitorRowViewModel(MonitorDefinition monitor, SwitchingProfile profile)
    {
        _monitor = monitor;
        _initialStorageKey = monitor.ProfileStorageKey;
        _inputIncluded = profile.InputAssignments.TryGetValue(StorageKey, out var value)
            || profile.InputAssignments.TryGetValue(monitor.Id, out value);
        _layoutIncluded = profile.LayoutMonitorIds.Any(item =>
            string.Equals(item, StorageKey, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(item, monitor.Id, StringComparison.OrdinalIgnoreCase));
        _isLayoutMode = profile.CoordinationMode == ProfileCoordinationMode.Restore;
        _isIncluded = _isLayoutMode ? _layoutIncluded : _inputIncluded;
        _input = (_inputIncluded ? value : (ushort)0).ToString("X4");
        _macBehavior = profile.MacDisplayBehaviors.GetValueOrDefault(
            StorageKey,
            profile.MacDisplayBehaviors.GetValueOrDefault(monitor.Id, MacDisplayBehavior.Unchanged));
        _behavior = profile.WindowsDisplayBehaviors.GetValueOrDefault(
            StorageKey,
            profile.WindowsDisplayBehaviors.GetValueOrDefault(monitor.Id, WindowsDisplayBehavior.Unchanged));
        _showMacBehavior = profile.CoordinationMode == ProfileCoordinationMode.Managed;
        _showBehaviorControls = profile.CoordinationMode is not ProfileCoordinationMode.Self
            and not ProfileCoordinationMode.Restore;
        _showInputControls = !_isLayoutMode;
    }

    public bool IsIncluded
    {
        get => _isIncluded;
        set
        {
            if (!Set(ref _isIncluded, value)) return;
            if (_isLayoutMode) _layoutIncluded = value;
            else _inputIncluded = value;
        }
    }
    public string Label => $"{_monitor.DisplayLabel} · {_monitor.Name}";
    public string Input { get => _input; set => Set(ref _input, value.ToUpperInvariant()); }
    public MacDisplayBehavior MacBehavior { get => _macBehavior; set => Set(ref _macBehavior, value); }
    public WindowsDisplayBehavior Behavior { get => _behavior; set => Set(ref _behavior, value); }
    public bool ShowMacBehavior { get => _showMacBehavior; set => Set(ref _showMacBehavior, value); }
    public bool ShowBehaviorControls { get => _showBehaviorControls; set => Set(ref _showBehaviorControls, value); }
    public bool ShowInputControls { get => _showInputControls; set => Set(ref _showInputControls, value); }
    public Array MacBehaviors => Enum.GetValues<MacDisplayBehavior>();
    public Array Behaviors => Enum.GetValues<WindowsDisplayBehavior>();

    public void Refresh() => Changed(nameof(Label));

    public void SetCoordinationMode(ProfileCoordinationMode mode)
    {
        _isLayoutMode = mode == ProfileCoordinationMode.Restore;
        IsIncluded = _isLayoutMode ? _layoutIncluded : _inputIncluded;
        ShowMacBehavior = mode == ProfileCoordinationMode.Managed;
        ShowBehaviorControls = mode is not ProfileCoordinationMode.Self
            and not ProfileCoordinationMode.Restore;
        ShowInputControls = !_isLayoutMode;
    }

    public bool Apply(SwitchingProfile profile, out string error)
    {
        error = "";
        ushort input = 0;
        if (_inputIncluded)
        {
            if (!ushort.TryParse(Input, System.Globalization.NumberStyles.HexNumber, null, out input))
            {
                error = $"{Label}: Input must be a four-digit hexadecimal value.";
                return false;
            }
        }

        profile.InputAssignments.Remove(StorageKey);
        profile.InputAssignments.Remove(_initialStorageKey);
        if (!string.Equals(StorageKey, MonitorID, StringComparison.OrdinalIgnoreCase)) profile.InputAssignments.Remove(MonitorID);
        if (_inputIncluded) profile.InputAssignments[StorageKey] = input;

        profile.LayoutMonitorIds.RemoveAll(item =>
            string.Equals(item, StorageKey, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(item, _initialStorageKey, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(item, MonitorID, StringComparison.OrdinalIgnoreCase));
        if (_layoutIncluded) profile.LayoutMonitorIds.Add(StorageKey);

        if (MacBehavior == MacDisplayBehavior.Unchanged) profile.MacDisplayBehaviors.Remove(StorageKey);
        else profile.MacDisplayBehaviors[StorageKey] = MacBehavior;
        if (Behavior == WindowsDisplayBehavior.Unchanged) profile.WindowsDisplayBehaviors.Remove(StorageKey);
        else profile.WindowsDisplayBehaviors[StorageKey] = Behavior;
        if (!string.Equals(StorageKey, MonitorID, StringComparison.OrdinalIgnoreCase))
        {
            profile.MacDisplayBehaviors.Remove(MonitorID);
            profile.WindowsDisplayBehaviors.Remove(MonitorID);
        }
        if (!string.Equals(_initialStorageKey, StorageKey, StringComparison.OrdinalIgnoreCase))
        {
            profile.MacDisplayBehaviors.Remove(_initialStorageKey);
            profile.WindowsDisplayBehaviors.Remove(_initialStorageKey);
        }
        return true;
    }
}

public sealed class ProfilePrimaryMonitorOption : ObservableModel
{
    private readonly MonitorDefinition _monitor;

    public ProfilePrimaryMonitorOption(MonitorDefinition monitor) => _monitor = monitor;

    public string Id => _monitor.ProfileStorageKey;
    public string LocalId => _monitor.Id;
    public string Label => $"{_monitor.DisplayLabel} · {_monitor.Name}";

    public void Refresh()
    {
        Changed(nameof(Id));
        Changed(nameof(Label));
    }
}

public sealed class ProfileEditorViewModel : ObservableModel
{
    public SwitchingProfile Model { get; }
    private string _name;
    private ProfileCoordinationMode _coordinationMode;
    private bool _isFavorite;
    private bool _restorePeerLayout;
    private string _hotKeyText;
    private WindowsGlobalHotKey? _windowsHotKey;
    private ProfilePrimaryMonitorOption? _selfPrimaryMonitor;
    private ProfilePrimaryMonitorOption? _peerPrimaryMonitor;
    private ProfilePrimaryMonitorOption? _layoutPrimaryMonitor;

    public ProfileEditorViewModel(SwitchingProfile model, IEnumerable<MonitorDefinition> monitors, Guid? favoriteID)
    {
        var monitorList = monitors.ToList();
        Model = model;
        _name = model.Name;
        _coordinationMode = model.CoordinationMode;
        _isFavorite = favoriteID == model.Id;
        _restorePeerLayout = model.RestorePeerLayout;
        _windowsHotKey = model.WindowsHotKey;
        _hotKeyText = model.WindowsHotKey?.DisplayText ?? "Set shortcut";
        Monitors = new ObservableCollection<ProfileMonitorRowViewModel>(monitorList.Select(item => new ProfileMonitorRowViewModel(item, model)));
        PrimaryMonitorOptions = new ObservableCollection<ProfilePrimaryMonitorOption>(
            monitorList.Select(item => new ProfilePrimaryMonitorOption(item)));
        _selfPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
            string.Equals(item.Id, model.SelfPrimaryMonitorId, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(item.LocalId, model.SelfPrimaryMonitorId, StringComparison.OrdinalIgnoreCase));
        _peerPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
            string.Equals(item.Id, model.PeerPrimaryMonitorId, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(item.LocalId, model.PeerPrimaryMonitorId, StringComparison.OrdinalIgnoreCase));
        _layoutPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
            string.Equals(item.Id, model.LayoutPrimaryMonitorId, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(item.LocalId, model.LayoutPrimaryMonitorId, StringComparison.OrdinalIgnoreCase));
        if (_coordinationMode == ProfileCoordinationMode.Self && _selfPrimaryMonitor is null)
        {
            var firstIncluded = Monitors.FirstOrDefault(item => item.IsIncluded)?.ProfileKey;
            _selfPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
                string.Equals(item.Id, firstIncluded, StringComparison.OrdinalIgnoreCase))
                ?? PrimaryMonitorOptions.FirstOrDefault();
        }
        if (_coordinationMode == ProfileCoordinationMode.Self && _peerPrimaryMonitor is null)
            _peerPrimaryMonitor = _selfPrimaryMonitor;
        if (_coordinationMode == ProfileCoordinationMode.Restore && _layoutPrimaryMonitor is null)
        {
            var firstIncluded = Monitors.FirstOrDefault(item => item.IsIncluded)?.ProfileKey;
            _layoutPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
                string.Equals(item.Id, firstIncluded, StringComparison.OrdinalIgnoreCase))
                ?? PrimaryMonitorOptions.FirstOrDefault();
        }
    }

    public Guid Id => Model.Id;
    public string Name { get => _name; set => Set(ref _name, value); }
    public ProfileCoordinationMode CoordinationMode
    {
        get => _coordinationMode;
        set
        {
            if (!Set(ref _coordinationMode, value)) return;
            Changed(nameof(IsExternal));
            Changed(nameof(IsManaged));
            Changed(nameof(IsSelf));
            Changed(nameof(IsRestore));
            Changed(nameof(IsPrimaryMode));
            Changed(nameof(ShowPeerPrimary));
            Changed(nameof(ActivePrimaryMonitor));
            Changed(nameof(DirectionLabel));
            foreach (var monitor in Monitors) monitor.SetCoordinationMode(value);
            if (value == ProfileCoordinationMode.Self && SelfPrimaryMonitor is null)
            {
                var firstIncluded = Monitors.FirstOrDefault(item => item.IsIncluded)?.ProfileKey;
                SelfPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
                    string.Equals(item.Id, firstIncluded, StringComparison.OrdinalIgnoreCase))
                    ?? PrimaryMonitorOptions.FirstOrDefault();
            }
            if (value == ProfileCoordinationMode.Self && PeerPrimaryMonitor is null)
                PeerPrimaryMonitor = SelfPrimaryMonitor;
            if (value == ProfileCoordinationMode.Restore && LayoutPrimaryMonitor is null)
            {
                var firstIncluded = Monitors.FirstOrDefault(item => item.IsIncluded)?.ProfileKey;
                LayoutPrimaryMonitor = PrimaryMonitorOptions.FirstOrDefault(item =>
                    string.Equals(item.Id, firstIncluded, StringComparison.OrdinalIgnoreCase))
                    ?? PrimaryMonitorOptions.FirstOrDefault();
            }
        }
    }
    public bool IsExternal => CoordinationMode == ProfileCoordinationMode.External;
    public bool IsManaged => CoordinationMode == ProfileCoordinationMode.Managed;
    public bool IsSelf => CoordinationMode == ProfileCoordinationMode.Self;
    public bool IsRestore => CoordinationMode == ProfileCoordinationMode.Restore;
    public bool IsPrimaryMode => IsSelf || IsRestore;
    public bool ShowPeerPrimary => IsSelf;
    public string DirectionLabel => CoordinationMode switch
    {
        ProfileCoordinationMode.External => "One-way DDC",
        ProfileCoordinationMode.Self => "All assigned monitors → this PC",
        ProfileCoordinationMode.Restore => "Local Primary + Extended only",
        _ => "Windows → Mac"
    };
    public ProfilePrimaryMonitorOption? SelfPrimaryMonitor
    {
        get => _selfPrimaryMonitor;
        set
        {
            if (Set(ref _selfPrimaryMonitor, value) && IsSelf)
                Changed(nameof(ActivePrimaryMonitor));
        }
    }
    public ProfilePrimaryMonitorOption? PeerPrimaryMonitor
    {
        get => _peerPrimaryMonitor;
        set => Set(ref _peerPrimaryMonitor, value);
    }
    public ProfilePrimaryMonitorOption? LayoutPrimaryMonitor
    {
        get => _layoutPrimaryMonitor;
        set
        {
            if (Set(ref _layoutPrimaryMonitor, value) && IsRestore)
                Changed(nameof(ActivePrimaryMonitor));
        }
    }
    public ProfilePrimaryMonitorOption? ActivePrimaryMonitor
    {
        get => IsRestore ? LayoutPrimaryMonitor : SelfPrimaryMonitor;
        set
        {
            if (IsRestore) LayoutPrimaryMonitor = value;
            else SelfPrimaryMonitor = value;
        }
    }
    public bool IsFavorite
    {
        get => _isFavorite;
        set
        {
            if (Set(ref _isFavorite, value)) Changed(nameof(FavoriteGlyph));
        }
    }
    public string FavoriteGlyph => IsFavorite ? "★" : "☆";
    public bool RestorePeerLayout { get => _restorePeerLayout; set => Set(ref _restorePeerLayout, value); }
    public string HotKeyText { get => _hotKeyText; set => Set(ref _hotKeyText, value); }
    public Array CoordinationModes => Enum.GetValues<ProfileCoordinationMode>();
    public ObservableCollection<ProfileMonitorRowViewModel> Monitors { get; }
    public ObservableCollection<ProfilePrimaryMonitorOption> PrimaryMonitorOptions { get; }

    public void EnsureMonitor(MonitorDefinition monitor)
    {
        var existing = Monitors.FirstOrDefault(item => string.Equals(item.MonitorID, monitor.Id, StringComparison.OrdinalIgnoreCase));
        if (existing is null)
        {
            var row = new ProfileMonitorRowViewModel(monitor, Model);
            row.SetCoordinationMode(CoordinationMode);
            Monitors.Add(row);
            PrimaryMonitorOptions.Add(new ProfilePrimaryMonitorOption(monitor));
        }
        else existing.Refresh();
    }

    public void RefreshMonitorLabels()
    {
        foreach (var monitor in Monitors) monitor.Refresh();
        foreach (var option in PrimaryMonitorOptions) option.Refresh();
    }

    public void ClearHotKey()
    {
        _windowsHotKey = null;
        HotKeyText = "Set shortcut";
    }

    public void SetHotKey(WindowsGlobalHotKey hotKey)
    {
        _windowsHotKey = hotKey;
        HotKeyText = hotKey.DisplayText;
    }

    public bool Apply(out string error)
    {
        error = "";
        if (CoordinationMode == ProfileCoordinationMode.Self && Monitors.Any(item => item.IsIncluded))
        {
            if (!IsIncluded(SelfPrimaryMonitor))
            {
                error = $"{Name}: this PC primary must be one of the enabled monitors.";
                return false;
            }
            if (!IsIncluded(PeerPrimaryMonitor))
            {
                error = $"{Name}: peer fallback primary must be one of the enabled monitors.";
                return false;
            }
        }
        if (CoordinationMode == ProfileCoordinationMode.Restore)
        {
            if (!Monitors.Any(item => item.IsIncluded))
            {
                error = $"{Name}: select at least one monitor to restore.";
                return false;
            }
            if (!IsIncluded(LayoutPrimaryMonitor))
            {
                error = $"{Name}: restore primary must be one of the enabled monitors.";
                return false;
            }
        }

        Model.Name = Name.Trim();
        Model.CoordinationMode = CoordinationMode;
        Model.RestorePeerLayout = RestorePeerLayout;
        foreach (var row in Monitors)
            if (!row.Apply(Model, out error)) return false;
        Model.SelfPrimaryMonitorId = SelfPrimaryMonitor?.Id ?? "";
        Model.PeerPrimaryMonitorId = PeerPrimaryMonitor?.Id ?? Model.SelfPrimaryMonitorId;
        Model.LayoutPrimaryMonitorId = LayoutPrimaryMonitor?.Id ?? "";
        Model.WindowsHotKey = _windowsHotKey;
        return true;
    }

    private bool IsIncluded(ProfilePrimaryMonitorOption? selected) =>
        selected is not null && Monitors.Any(item =>
            item.IsIncluded &&
            (string.Equals(item.ProfileKey, selected.Id, StringComparison.OrdinalIgnoreCase) ||
             string.Equals(item.MonitorID, selected.LocalId, StringComparison.OrdinalIgnoreCase)));
}

public sealed class SettingsViewModel : ObservableModel
{
    private readonly AppSettings _settings;
    private readonly SettingsStore _store;
    private readonly Action _afterSave;
    private readonly Action _rescanPeers;
    private AppTheme _theme;
    private bool _launchAtLogin;
    private bool _networkEnabled;
    private string _deviceName;
    private string _sharedKey;
    private bool _rollbackOnPeerFailure;
    private int _confirmationTimeoutSeconds;
    private string _status = "Ready";

    public SettingsViewModel(AppSettings settings, SettingsStore store, Action afterSave, Action rescanPeers)
    {
        _settings = settings;
        _store = store;
        _afterSave = afterSave;
        _rescanPeers = rescanPeers;
        _theme = settings.Theme;
        _launchAtLogin = settings.LaunchAtLogin;
        _networkEnabled = settings.Network.Enabled;
        _deviceName = settings.Network.DeviceName;
        _sharedKey = settings.Network.SharedKey;
        _rollbackOnPeerFailure = settings.Network.RollbackOnPeerFailure;
        _confirmationTimeoutSeconds = Math.Clamp(settings.Network.ConfirmationTimeoutSeconds, 2, 15);
        Monitors = new ObservableCollection<MonitorEditorViewModel>(settings.Monitors.Select(item => new MonitorEditorViewModel(item)));
        Profiles = new ObservableCollection<ProfileEditorViewModel>(settings.Profiles.Select(item => new ProfileEditorViewModel(item, settings.Monitors, settings.FavoriteProfileId)));
    }

    public Array Themes => Enum.GetValues<AppTheme>();
    public AppTheme Theme { get => _theme; set => Set(ref _theme, value); }
    public bool LaunchAtLogin { get => _launchAtLogin; set => Set(ref _launchAtLogin, value); }
    public bool NetworkEnabled { get => _networkEnabled; set => Set(ref _networkEnabled, value); }
    public string DeviceName { get => _deviceName; set => Set(ref _deviceName, value); }
    public string SharedKey
    {
        get => _sharedKey;
        set
        {
            if (!Set(ref _sharedKey, value)) return;
            Changed(nameof(IsSharedKeyValid));
            Changed(nameof(IsSharedKeyDirty));
        }
    }
    public bool IsSharedKeyValid => SharedKey.Trim().Length >= 8;
    public bool IsSharedKeyDirty => !string.Equals(SharedKey.Trim(), _settings.Network.SharedKey, StringComparison.Ordinal);
    public bool RollbackOnPeerFailure { get => _rollbackOnPeerFailure; set => Set(ref _rollbackOnPeerFailure, value); }
    public int ConfirmationTimeoutSeconds { get => _confirmationTimeoutSeconds; set => Set(ref _confirmationTimeoutSeconds, value); }
    public IReadOnlyList<int> ConfirmationTimeoutOptions { get; } = Enumerable.Range(2, 14).ToArray();
    public string Status { get => _status; set => Set(ref _status, value); }
    public ObservableCollection<MonitorEditorViewModel> Monitors { get; }
    public ObservableCollection<ProfileEditorViewModel> Profiles { get; }

    public void RescanPeers()
    {
        if (!NetworkEnabled)
        {
            Status = "Enable LAN peer before rescanning.";
            return;
        }
        Status = "Searching LAN";
        _rescanPeers();
    }

    public void SavePeerKey()
    {
        if (!IsSharedKeyValid)
        {
            Status = "Pairing key must contain at least 8 characters.";
            return;
        }
        ApplyNetworkDrafts();
        _store.Save(_settings);
        _afterSave();
        Changed(nameof(IsSharedKeyDirty));
        Status = "Pairing key saved";
    }

    public void AddProfile()
    {
        var number = 1;
        var names = Profiles.Select(item => item.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        while (names.Contains($"Profile {number}")) number++;
        var model = new SwitchingProfile { Name = $"Profile {number}" };
        _settings.Profiles.Add(model);
        Profiles.Add(new ProfileEditorViewModel(model, _settings.Monitors, _settings.FavoriteProfileId));
    }

    public void RemoveProfile(ProfileEditorViewModel profile)
    {
        var removedFavorite = profile.IsFavorite;
        Profiles.Remove(profile);
        _settings.Profiles.Remove(profile.Model);
        if (removedFavorite && Profiles.FirstOrDefault() is { } replacement)
            MakeFavorite(replacement);
    }

    public void MakeFavorite(ProfileEditorViewModel profile)
    {
        foreach (var item in Profiles) item.IsFavorite = item == profile;
    }

    public void RefreshMonitors()
    {
        foreach (var monitor in _settings.Monitors)
        {
            var existing = Monitors.FirstOrDefault(item => string.Equals(item.Model.Id, monitor.Id, StringComparison.OrdinalIgnoreCase));
            if (existing is null) Monitors.Add(new MonitorEditorViewModel(monitor));
            else existing.Refresh();

            foreach (var profile in Profiles) profile.EnsureMonitor(monitor);
        }
    }

    public bool Save()
    {
        var names = Profiles.Select(item => item.Name.Trim()).ToList();
        if (names.Any(string.IsNullOrWhiteSpace) || names.Distinct(StringComparer.OrdinalIgnoreCase).Count() != names.Count)
        {
            Status = "Profile names must be unique and cannot be empty.";
            return false;
        }

        if (NetworkEnabled && !IsSharedKeyValid)
        {
            Status = "Pairing key must contain at least 8 characters.";
            return false;
        }

        var pairingIDs = Monitors
            .Select(item => item.PairingId.Trim())
            .Where(item => !string.IsNullOrWhiteSpace(item))
            .ToList();
        if (pairingIDs.Distinct(StringComparer.OrdinalIgnoreCase).Count() != pairingIDs.Count)
        {
            Status = "Pairing IDs must be unique on this device.";
            return false;
        }

        foreach (var monitor in Monitors)
        {
            if (monitor.Apply(out var monitorError)) { continue; }
            Status = monitorError;
            return false;
        }

        foreach (var profile in Profiles)
        {
            if (profile.Apply(out var profileError)) { continue; }
            Status = profileError;
            return false;
        }

        _settings.Theme = Theme;
        _settings.LaunchAtLogin = LaunchAtLogin;
        ApplyNetworkDrafts();
        _settings.FavoriteProfileId = Profiles.FirstOrDefault(item => item.IsFavorite)?.Id;
        _store.Save(_settings);
        _afterSave();
        foreach (var monitor in Monitors) monitor.Refresh();
        foreach (var profile in Profiles) profile.RefreshMonitorLabels();
        Changed(nameof(IsSharedKeyDirty));
        Status = "Saved";
        return true;
    }

    private void ApplyNetworkDrafts()
    {
        _settings.Network.Enabled = NetworkEnabled;
        _settings.Network.DeviceName = string.IsNullOrWhiteSpace(DeviceName) ? Environment.MachineName : DeviceName.Trim();
        _settings.Network.SharedKey = SharedKey.Trim();
        _settings.Network.RollbackOnPeerFailure = RollbackOnPeerFailure;
        _settings.Network.ConfirmationTimeoutSeconds = Math.Clamp(ConfirmationTimeoutSeconds, 2, 15);
    }
}
