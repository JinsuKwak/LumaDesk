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

    public bool Disable(MonitorDefinition monitor, out string error)
    {
        error = "";
        var mode = NativeMethods.DEVMODE.Create();
        if (!NativeMethods.EnumDisplaySettingsEx(monitor.GdiDeviceName, NativeMethods.ENUM_CURRENT_SETTINGS, ref mode, 0))
            return true; // Already absent or disabled.

        // Microsoft documents DM_POSITION with a zero width/height as the
        // detach operation. Keep this temporary so ENUM_REGISTRY_SETTINGS
        // remains a reliable restore point when the profile hands it back.
        mode.dmFields = NativeMethods.DM_POSITION;
        mode.dmPelsWidth = 0;
        mode.dmPelsHeight = 0;
        var result = NativeMethods.ChangeDisplaySettingsEx(
            monitor.GdiDeviceName,
            ref mode,
            IntPtr.Zero,
            0,
            IntPtr.Zero);
        if (result == NativeMethods.DISP_CHANGE_SUCCESSFUL) return true;
        error = $"Disable failed ({result}).";
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
}
