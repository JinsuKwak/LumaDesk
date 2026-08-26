using System.Text.RegularExpressions;
using DesCon.Windows.Interop;
using DesCon.Windows.Models;
using Microsoft.Win32;

namespace DesCon.Windows.Services;

public sealed class MonitorDiscoveryService
{
    public List<MonitorDefinition> Discover()
    {
        var physicalNames = EnumeratePhysicalDescriptions();
        var edids = ReadRegistryEdids();
        var usedEdids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var displays = new List<MonitorDefinition>();

        for (uint adapterIndex = 0; ; adapterIndex++)
        {
            var adapter = NativeMethods.DISPLAY_DEVICE.Create();
            if (!NativeMethods.EnumDisplayDevices(null, adapterIndex, ref adapter, 0)) break;
            if ((adapter.StateFlags & NativeMethods.DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) == 0) continue;

            for (uint monitorIndex = 0; ; monitorIndex++)
            {
                var monitor = NativeMethods.DISPLAY_DEVICE.Create();
                if (!NativeMethods.EnumDisplayDevices(
                        adapter.DeviceName,
                        monitorIndex,
                        ref monitor,
                        NativeMethods.EDD_GET_DEVICE_INTERFACE_NAME)) break;

                var stableID = StableId(monitor.DeviceID, monitor.DeviceKey, adapter.DeviceName, monitorIndex);
                var edid = MatchEdid(monitor.DeviceID, edids, usedEdids);
                var name = physicalNames.TryGetValue(adapter.DeviceName, out var physicalName) && !string.IsNullOrWhiteSpace(physicalName)
                    ? physicalName
                    : string.IsNullOrWhiteSpace(monitor.DeviceString) ? "External display" : monitor.DeviceString;

                displays.Add(new MonitorDefinition
                {
                    Id = stableID,
                    SharedId = edid?.SharedID ?? $"LOCAL:{stableID}",
                    Name = name,
                    GdiDeviceName = adapter.DeviceName,
                    DevicePath = monitor.DeviceID ?? monitor.DeviceKey ?? "",
                    DisplayNumber = DisplayNumber(adapter.DeviceName),
                    IsConnected = true
                });
            }
        }

        return displays
            .GroupBy(display => display.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .OrderBy(display => display.DisplayNumber)
            .ToList();
    }

    internal static List<NativeMethods.PHYSICAL_MONITOR> OpenPhysicalMonitors(string gdiDeviceName)
    {
        var result = new List<NativeMethods.PHYSICAL_MONITOR>();
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, _, _, _) =>
        {
            var info = new NativeMethods.MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.MONITORINFOEX>() };
            if (!NativeMethods.GetMonitorInfo(monitor, ref info) ||
                !string.Equals(info.szDevice, gdiDeviceName, StringComparison.OrdinalIgnoreCase)) return true;

            if (!NativeMethods.GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out var count) || count == 0) return true;
            var physical = new NativeMethods.PHYSICAL_MONITOR[count];
            if (NativeMethods.GetPhysicalMonitorsFromHMONITOR(monitor, count, physical)) result.AddRange(physical);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    internal static void ClosePhysicalMonitors(IReadOnlyCollection<NativeMethods.PHYSICAL_MONITOR> monitors)
    {
        if (monitors.Count == 0) return;
        NativeMethods.DestroyPhysicalMonitors((uint)monitors.Count, monitors.ToArray());
    }

    private static Dictionary<string, string> EnumeratePhysicalDescriptions()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, _, _, _) =>
        {
            var info = new NativeMethods.MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.MONITORINFOEX>() };
            if (!NativeMethods.GetMonitorInfo(monitor, ref info)) return true;
            if (!NativeMethods.GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out var count) || count == 0) return true;

            var physical = new NativeMethods.PHYSICAL_MONITOR[count];
            if (NativeMethods.GetPhysicalMonitorsFromHMONITOR(monitor, count, physical))
            {
                result[info.szDevice] = physical.FirstOrDefault().Description ?? "";
                NativeMethods.DestroyPhysicalMonitors(count, physical);
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    private static string StableId(string? deviceID, string? deviceKey, string adapter, uint index)
    {
        var value = !string.IsNullOrWhiteSpace(deviceID)
            ? deviceID
            : !string.IsNullOrWhiteSpace(deviceKey) ? deviceKey : $"{adapter}:{index}";
        return value.Trim().ToUpperInvariant();
    }

    private static int DisplayNumber(string deviceName)
    {
        var match = Regex.Match(deviceName, @"DISPLAY(?<number>\d+)$", RegexOptions.IgnoreCase);
        return match.Success && int.TryParse(match.Groups["number"].Value, out var number) ? number : 0;
    }

    private static EdidIdentity? MatchEdid(
        string? deviceID,
        IReadOnlyList<EdidIdentity> edids,
        ISet<string> used)
    {
        var match = edids.FirstOrDefault(item =>
            !used.Contains(item.RegistryPath) &&
            (string.IsNullOrWhiteSpace(deviceID) || deviceID.Contains(item.HardwareCode, StringComparison.OrdinalIgnoreCase)));
        if (match is not null) used.Add(match.RegistryPath);
        return match;
    }

    private static List<EdidIdentity> ReadRegistryEdids()
    {
        var result = new List<EdidIdentity>();
        using var displayRoot = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\DISPLAY");
        if (displayRoot is null) return result;

        foreach (var hardwareCode in displayRoot.GetSubKeyNames())
        {
            using var hardware = displayRoot.OpenSubKey(hardwareCode);
            if (hardware is null) continue;
            foreach (var instanceName in hardware.GetSubKeyNames())
            {
                using var parameters = hardware.OpenSubKey(instanceName + @"\Device Parameters");
                if (parameters?.GetValue("EDID") is not byte[] edid || edid.Length < 128) continue;
                var identity = ParseEdid(edid, hardwareCode, @$"{hardwareCode}\{instanceName}");
                if (identity is not null) result.Add(identity);
            }
        }
        return result;
    }

    private static EdidIdentity? ParseEdid(byte[] edid, string hardwareCode, string registryPath)
    {
        var manufacturer = string.Concat(
            (char)(((edid[8] >> 2) & 0x1F) + 64),
            (char)((((edid[8] & 0x03) << 3) | (edid[9] >> 5)) + 64),
            (char)((edid[9] & 0x1F) + 64));
        var productName = DescriptorText(edid, 0xFC);
        var serialText = DescriptorText(edid, 0xFF);
        if (string.IsNullOrWhiteSpace(serialText))
        {
            var serial = BitConverter.ToUInt32(edid, 12);
            if (serial != 0) serialText = serial.ToString();
        }
        if (string.IsNullOrWhiteSpace(productName) || string.IsNullOrWhiteSpace(serialText)) return null;

        static string Canonical(string value) => new(value.ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());
        return new EdidIdentity(
            hardwareCode,
            registryPath,
            $"EDID:{Canonical(manufacturer)}:{Canonical(productName)}:{Canonical(serialText)}");
    }

    private static string DescriptorText(byte[] edid, byte tag)
    {
        for (var offset = 54; offset + 18 <= edid.Length && offset <= 108; offset += 18)
        {
            if (edid[offset] != 0 || edid[offset + 1] != 0 || edid[offset + 2] != 0 || edid[offset + 3] != tag) continue;
            return System.Text.Encoding.ASCII.GetString(edid, offset + 5, 13).Trim('\0', '\r', '\n', ' ');
        }
        return "";
    }

    private sealed record EdidIdentity(string HardwareCode, string RegistryPath, string SharedID);
}
