using DesCon.Windows.Interop;
using DesCon.Windows.Models;

namespace DesCon.Windows.Services;

public sealed class DdcService
{
    private readonly NvApiI2cService _nvApi = new();

    public Task<(bool Success, string Detail)> SetInputAsync(MonitorDefinition monitor, ushort value)
    {
        return Task.Run(() => SetInput(monitor, value));
    }

    private (bool Success, string Detail) SetInput(MonitorDefinition monitor, ushort value)
    {
        if (monitor.Ddc.SourceAddress != 0x51)
        {
            var success = _nvApi.TryWriteDdcPacket(
                monitor.GdiDeviceName,
                monitor.Ddc.SourceAddress,
                monitor.Ddc.VcpCode,
                value,
                out var error);
            return success
                ? (true, $"Sent 0x{value:X4} through NVIDIA raw I²C")
                : (false, error);
        }

        var physicalMonitors = MonitorDiscoveryService.OpenPhysicalMonitors(monitor.GdiDeviceName);
        try
        {
            if (physicalMonitors.Count == 0) return (false, "No active physical monitor handle.");
            var success = false;
            foreach (var physical in physicalMonitors)
                success |= NativeMethods.SetVCPFeature(physical.Handle, monitor.Ddc.VcpCode, value);
            return success ? (true, $"Sent VCP 0x{monitor.Ddc.VcpCode:X2}") : (false, "SetVCPFeature failed.");
        }
        finally
        {
            MonitorDiscoveryService.ClosePhysicalMonitors(physicalMonitors);
        }
    }
}
