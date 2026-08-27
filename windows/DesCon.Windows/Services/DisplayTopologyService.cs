using DesCon.Windows.Interop;
using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class DisplayTopologyService
{
    public bool MakePrimary(MonitorDefinition target, out string error)
    {
        error = "";
        var activeModes = CurrentModes();
        if (!activeModes.TryGetValue(target.GdiDeviceName, out var targetMode))
        {
            if (!EnableExtended(target, out error)) return false;
            activeModes = CurrentModes();
            if (!activeModes.TryGetValue(target.GdiDeviceName, out targetMode))
            {
                error = "The requested primary display did not become active.";
                return false;
            }
        }

        var offsetX = targetMode.dmPosition.x;
        var offsetY = targetMode.dmPosition.y;

        foreach (var (deviceName, modeValue) in activeModes)
        {
            var mode = modeValue;
            mode.dmFields |= NativeMethods.DM_POSITION;
            mode.dmPosition.x -= offsetX;
            mode.dmPosition.y -= offsetY;
            var flags = NativeMethods.CDS_UPDATEREGISTRY | NativeMethods.CDS_NORESET;
            if (string.Equals(deviceName, target.GdiDeviceName, StringComparison.OrdinalIgnoreCase))
                flags |= NativeMethods.CDS_SET_PRIMARY;

            var result = NativeMethods.ChangeDisplaySettingsEx(deviceName, ref mode, IntPtr.Zero, flags, IntPtr.Zero);
            if (result != NativeMethods.DISP_CHANGE_SUCCESSFUL)
            {
                error = $"Primary staging failed for {deviceName} ({result}).";
                return false;
            }
        }

        var applyResult = NativeMethods.ApplyDisplaySettings(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
        if (applyResult == NativeMethods.DISP_CHANGE_SUCCESSFUL) return true;
        error = $"Primary apply failed ({applyResult}).";
        return false;
    }

    public bool Disable(IReadOnlyCollection<MonitorDefinition> monitors, out string error)
    {
        error = "";
        if (monitors.Count == 0) return true;
        if (!TryGetActiveConfiguration(out var configuration, out error)) return false;

        var pathsToDisable = new HashSet<int>();
        foreach (var monitor in monitors)
        {
            var matches = MatchingActivePathIndexes(configuration.Paths, monitor);
            var sourcePathCount = SourcePathCount(configuration.Paths, monitor);
            if (matches.Count == 0 && sourcePathCount > 0)
            {
                error = string.IsNullOrWhiteSpace(monitor.DevicePath)
                    ? $"{monitor.DisplayLabel}: the GDI source drives multiple targets, so Windows cannot safely choose a connector."
                    : $"{monitor.DisplayLabel}: the saved monitor path did not match its current Windows target path.";
                return false;
            }
            foreach (var index in matches) pathsToDisable.Add(index);
        }

        // A requested monitor which is no longer in the active path list is
        // already detached (common immediately after its DDC input changes).
        if (pathsToDisable.Count == 0) return true;

        var remainingPaths = configuration.Paths
            .Where(path => !pathsToDisable.Contains(path.Index))
            .Select(path => path.Info)
            .ToArray();
        if (remainingPaths.Length == 0)
        {
            error = "Windows cannot disable every active display path.";
            return false;
        }

        // This is the API equivalent of Windows' "Show only on X": submit an
        // exclusive list of the target paths that must remain active. It is
        // temporary, so the saved extended layout remains available when a
        // later profile hands the monitor back to Windows.
        var applyFlags = NativeMethods.SDC_APPLY |
                         NativeMethods.SDC_USE_SUPPLIED_DISPLAY_CONFIG |
                         NativeMethods.SDC_ALLOW_CHANGES |
                         NativeMethods.SDC_VIRTUAL_MODE_AWARE;
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
            applyFlags |= NativeMethods.SDC_VIRTUAL_REFRESH_RATE_AWARE;

        var status = NativeMethods.SetDisplayConfigWithPaths(
            (uint)remainingPaths.Length,
            remainingPaths,
            (uint)configuration.Modes.Length,
            configuration.Modes,
            applyFlags);
        if (status == NativeMethods.ERROR_SUCCESS) return true;
        error = $"Show-only topology failed ({status}).";
        return false;
    }

    public bool AreInactive(IReadOnlyCollection<MonitorDefinition> monitors, out string error)
    {
        error = "";
        if (monitors.Count == 0) return true;
        if (!TryGetActiveConfiguration(out var configuration, out error)) return false;

        var stillActive = monitors
            .Where(monitor => MatchesActivePath(configuration.Paths, monitor))
            .Select(monitor => monitor.DisplayLabel)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (stillActive.Count == 0) return true;

        error = $"Windows kept these display paths active: {string.Join(", ", stillActive)}.";
        return false;
    }

    public bool AreActive(IReadOnlyCollection<MonitorDefinition> monitors, out string error)
    {
        error = "";
        if (monitors.Count == 0) return true;
        if (!TryGetActiveConfiguration(out var configuration, out error)) return false;

        var inactive = monitors
            .Where(monitor => !MatchesActivePath(configuration.Paths, monitor))
            .Select(monitor => monitor.DisplayLabel)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (inactive.Count == 0) return true;

        error = $"Windows did not restore these display paths: {string.Join(", ", inactive)}.";
        return false;
    }

    public bool EnableExtended(MonitorDefinition monitor, out string error)
    {
        error = "";
        var mode = NativeMethods.DEVMODE.Create();
        if (!NativeMethods.EnumDisplaySettingsEx(monitor.GdiDeviceName, NativeMethods.ENUM_REGISTRY_SETTINGS, ref mode, 0))
        {
            error = "No saved display mode is available for this connector.";
            return false;
        }

        mode.dmFields |= NativeMethods.DM_PELSWIDTH | NativeMethods.DM_PELSHEIGHT | NativeMethods.DM_POSITION;
        var result = NativeMethods.ChangeDisplaySettingsEx(
            monitor.GdiDeviceName,
            ref mode,
            IntPtr.Zero,
            0,
            IntPtr.Zero);
        if (result == NativeMethods.DISP_CHANGE_SUCCESSFUL) return true;
        error = $"Enable failed ({result}).";
        return false;
    }

    public bool MirrorAll(out string error)
    {
        var status = NativeMethods.SetDisplayConfig(
            0,
            IntPtr.Zero,
            0,
            IntPtr.Zero,
            NativeMethods.SDC_TOPOLOGY_CLONE | NativeMethods.SDC_APPLY);
        error = status == 0 ? "" : $"Clone topology failed ({status}).";
        return status == 0;
    }

    private static Dictionary<string, NativeMethods.DEVMODE> CurrentModes()
    {
        var result = new Dictionary<string, NativeMethods.DEVMODE>(StringComparer.OrdinalIgnoreCase);
        for (uint index = 0; ; index++)
        {
            var adapter = NativeMethods.DISPLAY_DEVICE.Create();
            if (!NativeMethods.EnumDisplayDevices(null, index, ref adapter, 0)) break;
            if ((adapter.StateFlags & NativeMethods.DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;

            var mode = NativeMethods.DEVMODE.Create();
            if (NativeMethods.EnumDisplaySettingsEx(adapter.DeviceName, NativeMethods.ENUM_CURRENT_SETTINGS, ref mode, 0))
                result[adapter.DeviceName] = mode;
        }
        return result;
    }

    private static bool TryGetActiveConfiguration(out DisplayConfiguration configuration, out string error)
    {
        configuration = new DisplayConfiguration([], []);
        error = "";
        var queryFlags = NativeMethods.QDC_ONLY_ACTIVE_PATHS | NativeMethods.QDC_VIRTUAL_MODE_AWARE;
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
            queryFlags |= NativeMethods.QDC_VIRTUAL_REFRESH_RATE_AWARE;

        // Microsoft requires retrying when the topology changes between the
        // buffer-size and query calls. This is a bounded API race retry, not a
        // background or verification poll.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            var status = NativeMethods.GetDisplayConfigBufferSizes(queryFlags, out var pathCount, out var modeCount);
            if (status != NativeMethods.ERROR_SUCCESS)
            {
                error = $"Display path sizing failed ({status}).";
                return false;
            }

            var paths = new NativeMethods.DISPLAYCONFIG_PATH_INFO[(int)pathCount];
            var modes = new NativeMethods.DISPLAYCONFIG_MODE_INFO[(int)modeCount];
            status = NativeMethods.QueryDisplayConfig(
                queryFlags,
                ref pathCount,
                paths,
                ref modeCount,
                modes,
                IntPtr.Zero);
            if (status == NativeMethods.ERROR_INSUFFICIENT_BUFFER) continue;
            if (status != NativeMethods.ERROR_SUCCESS)
            {
                error = $"Display path query failed ({status}).";
                return false;
            }

            Array.Resize(ref paths, (int)pathCount);
            Array.Resize(ref modes, (int)modeCount);
            var pathViews = paths
                .Select((path, index) => new DisplayPath(
                    index,
                    path,
                    SourceName(path),
                    TargetDevicePath(path)))
                .ToArray();
            configuration = new DisplayConfiguration(pathViews, modes);
            return true;
        }

        error = "The Windows display topology kept changing while it was read.";
        return false;
    }

    private static string SourceName(NativeMethods.DISPLAYCONFIG_PATH_INFO path)
    {
        var request = NativeMethods.DISPLAYCONFIG_SOURCE_DEVICE_NAME.Create(path.sourceInfo);
        return NativeMethods.DisplayConfigGetSourceDeviceInfo(ref request) == NativeMethods.ERROR_SUCCESS
            ? request.viewGdiDeviceName
            : "";
    }

    private static string TargetDevicePath(NativeMethods.DISPLAYCONFIG_PATH_INFO path)
    {
        var request = NativeMethods.DISPLAYCONFIG_TARGET_DEVICE_NAME.Create(path.targetInfo);
        return NativeMethods.DisplayConfigGetTargetDeviceInfo(ref request) == NativeMethods.ERROR_SUCCESS
            ? request.monitorDevicePath
            : "";
    }

    private static bool MatchesActivePath(IReadOnlyCollection<DisplayPath> paths, MonitorDefinition monitor) =>
        MatchingActivePathIndexes(paths, monitor).Count > 0;

    private static int SourcePathCount(IReadOnlyCollection<DisplayPath> paths, MonitorDefinition monitor) =>
        paths.Count(path =>
            string.Equals(path.SourceName, monitor.GdiDeviceName, StringComparison.OrdinalIgnoreCase));

    private static List<int> MatchingActivePathIndexes(
        IReadOnlyCollection<DisplayPath> paths,
        MonitorDefinition monitor)
    {
        var targetPath = CanonicalDevicePath(monitor.DevicePath);
        if (!string.IsNullOrWhiteSpace(targetPath))
        {
            // monitorDevicePath identifies the DisplayConfig target (the GPU
            // connector path), unlike the transient GDI DISPLAY1/2 number.
            return paths
                .Where(path => CanonicalDevicePath(path.TargetDevicePath) == targetPath)
                .Select(path => path.Index)
                .ToList();
        }

        // Old settings may not yet contain the per-target device path. GDI is a
        // safe fallback only when it resolves to one path; a cloned source can
        // drive several targets and must never be guessed.
        var sourceMatches = paths
            .Where(path => string.Equals(path.SourceName, monitor.GdiDeviceName, StringComparison.OrdinalIgnoreCase))
            .ToList();
        return sourceMatches.Count == 1
            ? new List<int> { sourceMatches[0].Index }
            : [];
    }

    private static string CanonicalDevicePath(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? ""
            : new string(value.ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());

    private sealed record DisplayPath(
        int Index,
        NativeMethods.DISPLAYCONFIG_PATH_INFO Info,
        string SourceName,
        string TargetDevicePath);

    private sealed record DisplayConfiguration(
        DisplayPath[] Paths,
        NativeMethods.DISPLAYCONFIG_MODE_INFO[] Modes);
}
