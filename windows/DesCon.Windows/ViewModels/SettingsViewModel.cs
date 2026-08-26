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
    public string Detail => $"Display {Model.DisplayNumber} · {(Model.IsConnected ? "Connected" : "Offline")}";
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
    private string _input;
    private MacDisplayBehavior _macBehavior;
    private WindowsDisplayBehavior _behavior;
    private bool _showMacBehavior;

    public string MonitorID { get; }
    private readonly MonitorDefinition _monitor;

    public ProfileMonitorRowViewModel(MonitorDefinition monitor, SwitchingProfile profile)
    {
        _monitor = monitor;
        MonitorID = monitor.Id;
        _isIncluded = profile.InputAssignments.TryGetValue(monitor.Id, out var value);
        _input = (_isIncluded ? value : (ushort)0).ToString("X4");
        _macBehavior = profile.MacDisplayBehaviors.GetValueOrDefault(monitor.Id, MacDisplayBehavior.Unchanged);
        _behavior = profile.WindowsDisplayBehaviors.GetValueOrDefault(monitor.Id, WindowsDisplayBehavior.Unchanged);
        _showMacBehavior = profile.CoordinationMode == ProfileCoordinationMode.Managed;
    }

    public bool IsIncluded { get => _isIncluded; set => Set(ref _isIncluded, value); }
    public string Label => $"Display {_monitor.DisplayNumber} · {_monitor.Name}";
    public string Input { get => _input; set => Set(ref _input, value.ToUpperInvariant()); }
    public MacDisplayBehavior MacBehavior { get => _macBehavior; set => Set(ref _macBehavior, value); }
    public WindowsDisplayBehavior Behavior { get => _behavior; set => Set(ref _behavior, value); }
    public bool ShowMacBehavior { get => _showMacBehavior; set => Set(ref _showMacBehavior, value); }
    public Array MacBehaviors => Enum.GetValues<MacDisplayBehavior>();
    public Array Behaviors => Enum.GetValues<WindowsDisplayBehavior>();

    public void Refresh() => Changed(nameof(Label));

    public bool Apply(SwitchingProfile profile, out string error)
    {
        error = "";
        if (IsIncluded)
        {
            if (!ushort.TryParse(Input, System.Globalization.NumberStyles.HexNumber, null, out var input))
            {
                error = $"{Label}: Input must be a four-digit hexadecimal value.";
                return false;
            }
            profile.InputAssignments[MonitorID] = input;
        }
        else
        {
            profile.InputAssignments.Remove(MonitorID);
        }

        if (MacBehavior == MacDisplayBehavior.Unchanged) profile.MacDisplayBehaviors.Remove(MonitorID);
        else profile.MacDisplayBehaviors[MonitorID] = MacBehavior;
        if (Behavior == WindowsDisplayBehavior.Unchanged) profile.WindowsDisplayBehaviors.Remove(MonitorID);
        else profile.WindowsDisplayBehaviors[MonitorID] = Behavior;
        return true;
    }
}

public sealed class ProfileEditorViewModel : ObservableModel
{
    public SwitchingProfile Model { get; }
    private string _name;
    private ProfileCoordinationMode _coordinationMode;
    private bool _isFavorite;
    private string _hotKeyText;

    public ProfileEditorViewModel(SwitchingProfile model, IEnumerable<MonitorDefinition> monitors, Guid? favoriteID)
    {
        Model = model;
        _name = model.Name;
        _coordinationMode = model.CoordinationMode;
        _isFavorite = favoriteID == model.Id;
        _hotKeyText = model.WindowsHotKey?.DisplayText ?? "Set shortcut";
        Monitors = new ObservableCollection<ProfileMonitorRowViewModel>(monitors.Select(item => new ProfileMonitorRowViewModel(item, model)));
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
            Changed(nameof(DirectionLabel));
            foreach (var monitor in Monitors) monitor.ShowMacBehavior = value == ProfileCoordinationMode.Managed;
        }
    }
    public bool IsExternal => CoordinationMode == ProfileCoordinationMode.External;
    public string DirectionLabel => IsExternal ? "One-way DDC" : "Windows → Mac";
    public bool IsFavorite
    {
        get => _isFavorite;
        set
        {
            if (Set(ref _isFavorite, value)) Changed(nameof(FavoriteGlyph));
        }
    }
    public string FavoriteGlyph => IsFavorite ? "★" : "☆";
    public string HotKeyText { get => _hotKeyText; set => Set(ref _hotKeyText, value); }
    public Array CoordinationModes => Enum.GetValues<ProfileCoordinationMode>();
    public ObservableCollection<ProfileMonitorRowViewModel> Monitors { get; }

    public void EnsureMonitor(MonitorDefinition monitor)
    {
        var existing = Monitors.FirstOrDefault(item => string.Equals(item.MonitorID, monitor.Id, StringComparison.OrdinalIgnoreCase));
        if (existing is null)
        {
            var row = new ProfileMonitorRowViewModel(monitor, Model) { ShowMacBehavior = CoordinationMode == ProfileCoordinationMode.Managed };
            Monitors.Add(row);
        }
        else existing.Refresh();
    }

    public bool Apply(out string error)
    {
        error = "";
        Model.Name = Name.Trim();
        Model.CoordinationMode = CoordinationMode;
        foreach (var row in Monitors)
            if (!row.Apply(Model, out error)) return false;
        return true;
    }
}

public sealed class SettingsViewModel : ObservableModel
{
    private readonly AppSettings _settings;
    private readonly SettingsStore _store;
    private readonly Action _afterSave;
    private AppTheme _theme;
    private bool _launchAtLogin;
    private bool _networkEnabled;
    private string _deviceName;
    private string _sharedKey;
    private string _status = "Ready";

    public SettingsViewModel(AppSettings settings, SettingsStore store, Action afterSave)
    {
        _settings = settings;
        _store = store;
        _afterSave = afterSave;
        _theme = settings.Theme;
        _launchAtLogin = settings.LaunchAtLogin;
        _networkEnabled = settings.Network.Enabled;
        _deviceName = settings.Network.DeviceName;
        _sharedKey = settings.Network.SharedKey;
        Monitors = new ObservableCollection<MonitorEditorViewModel>(settings.Monitors.Select(item => new MonitorEditorViewModel(item)));
        Profiles = new ObservableCollection<ProfileEditorViewModel>(settings.Profiles.Select(item => new ProfileEditorViewModel(item, settings.Monitors, settings.FavoriteProfileId)));
    }

    public Array Themes => Enum.GetValues<AppTheme>();
    public AppTheme Theme { get => _theme; set => Set(ref _theme, value); }
    public bool LaunchAtLogin { get => _launchAtLogin; set => Set(ref _launchAtLogin, value); }
    public bool NetworkEnabled { get => _networkEnabled; set => Set(ref _networkEnabled, value); }
    public string DeviceName { get => _deviceName; set => Set(ref _deviceName, value); }
    public string SharedKey { get => _sharedKey; set => Set(ref _sharedKey, value); }
    public string Status { get => _status; set => Set(ref _status, value); }
    public ObservableCollection<MonitorEditorViewModel> Monitors { get; }
    public ObservableCollection<ProfileEditorViewModel> Profiles { get; }

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
        _settings.Network.Enabled = NetworkEnabled;
        _settings.Network.DeviceName = string.IsNullOrWhiteSpace(DeviceName) ? Environment.MachineName : DeviceName.Trim();
        _settings.Network.SharedKey = SharedKey.Trim();
        _settings.FavoriteProfileId = Profiles.FirstOrDefault(item => item.IsFavorite)?.Id;
        _store.Save(_settings);
        _afterSave();
        Status = "Saved";
        return true;
    }
}
