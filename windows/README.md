# DesCon for Windows

Native Windows 10/11 tray client for DesCon switching profiles.

- System, Light, and Dark appearance with Windows 11 Mica and a translucent
  fallback on Windows 10
- Favorite tray action, complete profile submenu, and per-profile global hotkeys
- Persistent EDID identities so Windows display numbers can change safely
- Standard DXVA2 DDC plus NVIDIA raw I²C for custom LG packet-source commands
- Managed Mac/Windows LAN transactions and one-way named external profiles
- Reversible session-only display disable, extended restore, primary selection,
  and clone topology

## Requirements

- x64 Windows 10 2004 or newer
- .NET 8 Desktop Runtime (or publish self-contained)
- NVIDIA display driver for LG DDC2AB/raw packet-source commands

## Build

```powershell
dotnet build .\DesCon.Windows.sln -c Release
dotnet publish .\DesCon.Windows\DesCon.Windows.csproj -c Release -r win-x64 --self-contained true
```

No third-party package is required. `nvapi64.dll` comes from the installed NVIDIA
driver; the app resolves NVIDIA's public NVAPI functions dynamically.

The first LAN discovery may trigger Windows Defender Firewall. Allow DesCon on
Private networks only. Enter the same pairing key in the Mac and Windows apps.

## Switching order

1. Managed profile asks the Mac peer to prepare.
2. Windows establishes a fallback primary if necessary.
3. Windows sends DDC while the monitor path is still available.
4. Windows commits the peer transaction.
5. Windows applies post-switch `Disabled`, `Extended`, or mirror behavior.

External profiles skip steps 1 and 4 and report `sent · unverified`.
