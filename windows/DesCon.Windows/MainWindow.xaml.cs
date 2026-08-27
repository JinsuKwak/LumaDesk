using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using DesCon.Windows.Models;
using DesCon.Windows.Services;
using DesCon.Windows.ViewModels;

namespace DesCon.Windows;

public partial class MainWindow : Window
{
    private readonly SettingsViewModel _viewModel;

    public MainWindow(SettingsViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
        Loaded += (_, _) => ThemeManager.ApplyBackdrop(this, viewModel.Theme);
        Closing += WindowClosing;
    }

    private void SaveClicked(object sender, RoutedEventArgs e) => _viewModel.Save();
    private void AddProfileClicked(object sender, RoutedEventArgs e) => _viewModel.AddProfile();
    private void RescanPeerClicked(object sender, RoutedEventArgs e) => _viewModel.RescanPeers();
    private void SavePeerKeyClicked(object sender, RoutedEventArgs e) => _viewModel.SavePeerKey();

    private void LockMonitorClicked(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is MonitorEditorViewModel monitor)
            monitor.ToggleLock();
    }

    private void DeleteProfileClicked(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is ProfileEditorViewModel profile)
            _viewModel.RemoveProfile(profile);
    }

    private void FavoriteClicked(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is ProfileEditorViewModel profile)
            _viewModel.MakeFavorite(profile);
    }

    private void ThemeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!IsLoaded) return;
        ThemeManager.Apply(_viewModel.Theme);
        ThemeManager.ApplyBackdrop(this, _viewModel.Theme);
    }

    private void ShortcutKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is not ProfileEditorViewModel profile) return;
        e.Handled = true;

        if (e.Key == Key.Escape)
        {
            Keyboard.ClearFocus();
            return;
        }

        if (e.Key == Key.Back)
        {
            profile.ClearHotKey();
            Keyboard.ClearFocus();
            return;
        }

        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (modifiers == ModifierKeys.None || key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }

        uint nativeModifiers = 0x4000; // MOD_NOREPEAT
        if (modifiers.HasFlag(ModifierKeys.Alt)) nativeModifiers |= 0x0001;
        if (modifiers.HasFlag(ModifierKeys.Control)) nativeModifiers |= 0x0002;
        if (modifiers.HasFlag(ModifierKeys.Shift)) nativeModifiers |= 0x0004;
        if (modifiers.HasFlag(ModifierKeys.Windows)) nativeModifiers |= 0x0008;

        var label = ShortcutLabel(modifiers, key);
        profile.SetHotKey(new WindowsGlobalHotKey
        {
            VirtualKey = (uint)KeyInterop.VirtualKeyFromKey(key),
            Modifiers = nativeModifiers,
            DisplayText = label
        });
        Keyboard.ClearFocus();
    }

    private void ShortcutRecordingStarted(object sender, KeyboardFocusChangedEventArgs e) =>
        App.CurrentApp.SetHotKeyRecordingActive(true);

    private void ShortcutRecordingEnded(object sender, KeyboardFocusChangedEventArgs e) =>
        App.CurrentApp.SetHotKeyRecordingActive(false);

    private static string ShortcutLabel(ModifierKeys modifiers, Key key)
    {
        var parts = new List<string>();
        if (modifiers.HasFlag(ModifierKeys.Control)) parts.Add("Ctrl");
        if (modifiers.HasFlag(ModifierKeys.Alt)) parts.Add("Alt");
        if (modifiers.HasFlag(ModifierKeys.Shift)) parts.Add("Shift");
        if (modifiers.HasFlag(ModifierKeys.Windows)) parts.Add("Win");
        parts.Add(key.ToString());
        return string.Join("+", parts);
    }

    private void WindowClosing(object? sender, CancelEventArgs e)
    {
        if (App.CurrentApp.IsShuttingDown) return;
        App.CurrentApp.SetHotKeyRecordingActive(false);
        e.Cancel = true;
        Hide();
    }
}
