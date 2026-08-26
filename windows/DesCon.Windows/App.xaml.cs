using System.Windows;
using DesCon.Windows.Models;
using DesCon.Windows.Services;
using DesCon.Windows.ViewModels;
using Microsoft.Win32;

namespace DesCon.Windows;

public partial class App : Application
{
    public static App CurrentApp => (App)Current;
    public bool IsShuttingDown { get; private set; }

    private readonly SettingsStore _store = new();
    private readonly MonitorDiscoveryService _monitorDiscovery = new();
    private readonly GlobalHotKeyService _hotKeys = new();
    private AppSettings _settings = new();
    private ProfileExecutor? _executor;
    private LanPeerService? _peer;
    private TrayIconService? _tray;
    private MainWindow? _settingsWindow;
    private SettingsViewModel? _viewModel;
    private CancellationTokenSource? _displayRefresh;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _settings = _store.Load();
        SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
        SystemEvents.UserPreferenceChanged += UserPreferenceChanged;
        MergeDiscoveredMonitors();
        EnsureInitialProfile();
        ThemeManager.Apply(_settings.Theme);

        _peer = new LanPeerService(() => _settings);
        _peer.StatusChanged += status => Dispatcher.Invoke(() =>
        {
            if (_viewModel is not null) _viewModel.Status = status;
            _tray?.SetStatus(status);
        });
        _executor = new ProfileExecutor(new DdcService(), new DisplayTopologyService(), _peer, () => _settings);
        _executor.StatusChanged += status => Dispatcher.Invoke(() =>
        {
            if (_viewModel is not null) _viewModel.Status = status;
            _tray?.SetStatus(status);
        });
        _peer.ProfileCommitted = profile => _executor.ApplyRemoteProfileAsync(profile);
        _peer.Start();

        _viewModel = new SettingsViewModel(_settings, _store, ApplySavedSettings);
        _viewModel.Status = _peer.PeerStatus;
        _settingsWindow = new MainWindow(_viewModel);
        _tray = new TrayIconService(ShowSettings, Quit, profileID => _executor.ExecuteAsync(profileID));
        ApplySavedSettings();

        if (!e.Args.Contains("--background", StringComparer.OrdinalIgnoreCase)) ShowSettings();
    }

    private void MergeDiscoveredMonitors()
    {
        foreach (var saved in _settings.Monitors) saved.IsConnected = false;
        foreach (var discovered in _monitorDiscovery.Discover())
        {
            var saved = _settings.Monitors.FirstOrDefault(item => string.Equals(item.Id, discovered.Id, StringComparison.OrdinalIgnoreCase));
            if (saved is null)
            {
                _settings.Monitors.Add(discovered);
                continue;
            }

            saved.Name = discovered.Name;
            saved.SharedId = discovered.SharedId;
            saved.DisplayNumber = discovered.DisplayNumber;
            saved.GdiDeviceName = discovered.GdiDeviceName;
            saved.DevicePath = discovered.DevicePath;
            saved.IsConnected = true;
        }
    }

    private async void DisplaySettingsChanged(object? sender, EventArgs e)
    {
        _displayRefresh?.Cancel();
        _displayRefresh = new CancellationTokenSource();
        try
        {
            await Task.Delay(900, _displayRefresh.Token);
            await Dispatcher.InvokeAsync(() =>
            {
                MergeDiscoveredMonitors();
                _viewModel?.RefreshMonitors();
            });
        }
        catch (OperationCanceledException) { }
    }

    private void UserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (_settings.Theme != AppTheme.System) return;
        Dispatcher.Invoke(() =>
        {
            ThemeManager.Apply(AppTheme.System);
            if (_settingsWindow is not null) ThemeManager.ApplyBackdrop(_settingsWindow, AppTheme.System);
        });
    }

    private void EnsureInitialProfile()
    {
        if (_settings.Profiles.Count > 0) return;
        var profile = new SwitchingProfile { Name = "Default" };
        _settings.Profiles.Add(profile);
        _settings.FavoriteProfileId = profile.Id;
    }

    private void ApplySavedSettings()
    {
        ThemeManager.Apply(_settings.Theme);
        if (_settingsWindow is not null) ThemeManager.ApplyBackdrop(_settingsWindow, _settings.Theme);
        try { StartupService.SetEnabled(_settings.LaunchAtLogin); }
        catch (Exception error) { if (_viewModel is not null) _viewModel.Status = error.Message; }

        var failures = _hotKeys.Register(_settings.Profiles, profileID => _ = _executor?.ExecuteAsync(profileID));
        if (failures.Count > 0 && _viewModel is not null)
            _viewModel.Status = $"Shortcuts already in use: {string.Join(", ", failures)}";
        _tray?.Rebuild(_settings);
        _peer?.Start();
    }

    private void ShowSettings()
    {
        if (_settingsWindow is null) return;
        _settingsWindow.Show();
        if (_settingsWindow.WindowState == WindowState.Minimized) _settingsWindow.WindowState = WindowState.Normal;
        _settingsWindow.Activate();
    }

    private void Quit()
    {
        IsShuttingDown = true;
        SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
        SystemEvents.UserPreferenceChanged -= UserPreferenceChanged;
        _displayRefresh?.Cancel();
        _tray?.Dispose();
        _peer?.Dispose();
        _hotKeys.Dispose();
        _settingsWindow?.Close();
        Shutdown();
    }
}
