using System.Windows.Interop;
using DesCon.Windows.Interop;
using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class GlobalHotKeyService : IDisposable
{
    private const int WmHotKey = 0x0312;
    private readonly HwndSource _source;
    private readonly Dictionary<int, Guid> _profileById = [];
    private Action<Guid>? _onProfile;

    public GlobalHotKeyService()
    {
        _source = new HwndSource(new HwndSourceParameters("DesCon.HotKeys")
        {
            Width = 0,
            Height = 0,
            WindowStyle = 0
        });
        _source.AddHook(WindowProc);
    }

    public IReadOnlyList<string> Register(IEnumerable<SwitchingProfile> profiles, Action<Guid> onProfile)
    {
        Clear();
        _onProfile = onProfile;
        var errors = new List<string>();
        var id = 1;
        foreach (var profile in profiles)
        {
            var hotKey = profile.WindowsHotKey;
            if (hotKey is null) continue;
            if (NativeMethods.RegisterHotKey(_source.Handle, id, hotKey.Modifiers, hotKey.VirtualKey))
                _profileById[id] = profile.Id;
            else
                errors.Add($"{profile.Name}: {hotKey.DisplayText}");
            id++;
        }
        return errors;
    }

    public void Suspend() => Clear();

    public void Dispose()
    {
        Clear();
        _source.RemoveHook(WindowProc);
        _source.Dispose();
    }

    private void Clear()
    {
        foreach (var id in _profileById.Keys) NativeMethods.UnregisterHotKey(_source.Handle, id);
        _profileById.Clear();
    }

    private IntPtr WindowProc(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message != WmHotKey || !_profileById.TryGetValue(wParam.ToInt32(), out var profileID)) return IntPtr.Zero;
        handled = true;
        _onProfile?.Invoke(profileID);
        return IntPtr.Zero;
    }
}
