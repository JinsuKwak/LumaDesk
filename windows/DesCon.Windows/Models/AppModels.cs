namespace DesCon.Windows.Models;

public enum AppTheme { System, Light, Dark }

public enum ProfileCoordinationMode { Managed, External }

public enum ManagedProfileTarget { MacOS, Windows }

public enum MacDisplayBehavior { Unchanged, Primary, Extended, MirrorPrimary, HandedOff }

public enum WindowsDisplayBehavior { Unchanged, Primary, Extended, MirrorPrimary, Disabled }

public sealed class DdcConfiguration
{
    public byte SourceAddress { get; set; } = 0x51;
    public byte VcpCode { get; set; } = 0x60;
}

public sealed class MonitorDefinition
{
    public string Id { get; set; } = "";
    public string SharedId { get; set; } = "";
    public string Name { get; set; } = "External display";
    public int DisplayNumber { get; set; }
    public string GdiDeviceName { get; set; } = "";
    public string DevicePath { get; set; } = "";
    public bool IsConnected { get; set; }
    public DdcConfiguration Ddc { get; set; } = new();
}

public sealed class WindowsGlobalHotKey
{
    public uint VirtualKey { get; set; }
    public uint Modifiers { get; set; }
    public string DisplayText { get; set; } = "";
}

public sealed class SwitchingProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Profile";
    public ProfileCoordinationMode CoordinationMode { get; set; } = ProfileCoordinationMode.Managed;
    public ManagedProfileTarget ManagedTarget { get; set; } = ManagedProfileTarget.MacOS;
    public string ExternalTargetName { get; set; } = "External device";
    public Dictionary<string, ushort> InputAssignments { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, MacDisplayBehavior> MacDisplayBehaviors { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public Dictionary<string, WindowsDisplayBehavior> WindowsDisplayBehaviors { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    public WindowsGlobalHotKey? WindowsHotKey { get; set; }
}

public sealed class NetworkSettings
{
    public bool Enabled { get; set; } = true;
    public string DeviceName { get; set; } = Environment.MachineName;
    public string SharedKey { get; set; } = "";
    public int CommandPort { get; set; } = 47831;
}

public sealed class AppSettings
{
    public int SchemaVersion { get; set; } = 1;
    public long Revision { get; set; }
    public AppTheme Theme { get; set; } = AppTheme.System;
    public bool LaunchAtLogin { get; set; } = true;
    public Guid? FavoriteProfileId { get; set; }
    public List<MonitorDefinition> Monitors { get; set; } = [];
    public List<SwitchingProfile> Profiles { get; set; } = [];
    public NetworkSettings Network { get; set; } = new();
}
