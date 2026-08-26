# DesCon

DesCon contains native macOS and Windows display-switching clients. The macOS client retains the original LumaDesk lighting and brightness-sync features; the Windows client is a lightweight tray utility focused on DDC input routing and display topology.

```text
macos/     SwiftUI/AppKit menu-bar app
windows/   .NET 8 WPF tray app
shared/    profile schema and authenticated LAN protocol
```

Managed profiles coordinate Mac and Windows directly over the local network with multicast discovery, HMAC-authenticated TCP commands, and a prepare/commit transaction. External profiles (Jetson, consoles, or any renamed target) send DDC unilaterally and never require a peer app.

Both clients offer System, Light, and Dark appearance modes while retaining
native translucent materials. Profiles are available from the macOS menu bar or
Windows notification area and can also be assigned global shortcuts. Monitor
settings persist against stable hardware identities instead of display numbers.

## Core Features

- Menu bar first macOS app built with SwiftUI and AppKit interop.
- Compact menu bar controls for power, white mode, center-area selection, lighting mode, dynamic analysis mode, hue, and brightness.
- Separate Settings window for advanced controls, diagnostics, calibration, BLE, and display brightness sync.
- Persistent preferences for lighting state, static color, calibration, dynamic analysis, BLE behavior, and lifecycle behavior.
- Optional launch-at-login support.
- Automatic light-on/light-off lifecycle behavior for app launch, Mac wake, sleep, and quit.

## LED Strip Control

- Designed for BLE LED strips in the duoCo / ELK-BLEDOM ecosystem.
- Known target family uses `FFF0` service with `FFF3` write and `FFF4` notify characteristics.
- Static color writes use the existing ELK-BLEDOM-compatible packet path.
- BLE transport and packet generation are isolated behind backend/protocol layers so other strip protocols can be added later.
- Connection state is modeled as disconnected, scanning, connecting, connected, or error.
- Manual retry and disconnect controls are available in Settings.
- Wake reconnect handling includes a short Bluetooth settle delay for systems that disable Bluetooth during sleep.

## Lighting Modes

### Dynamic

Dynamic mode follows the system primary display content in near real time.

- Captures the true macOS primary display using `CGMainDisplayID`.
- Uses ScreenCaptureKit for frame capture.
- Keeps a one-frame coalescing queue to avoid stale buffered frames and unbounded memory growth.
- Processes the freshest available frame instead of restarting capture on normal setting changes.
- Uses a configurable update rate from 1 to 60 fps.
- Uses temporal smoothing to reduce flicker.
- Uses brightness as a maximum output cap for the LED result.
- Includes compact diagnostics in Settings for capture state, frame count, send count, frame status, sample count, frame size, pixel format, analyzed screen color, and LED output color.

### Static

Static mode keeps the LED strip on a saved user-selected color.

- Uses a single hue spectrum slider in the menu bar UI.
- Persists the last selected static hue between launches.
- Brightness controls final static output brightness.
- Static writes are throttled during slider interaction to avoid excessive BLE writes.

### White

White mode locks the strip to a calibrated white color.

- Overrides Dynamic and Static output while enabled.
- Automatically switches the app into Static-style output behavior.
- Disables Dynamic and hue controls while active.
- Uses the calibrated white color from Settings.

## Dynamic Sampling

LumaDesk supports three dynamic sampling modes:

- Full: representative color from the full primary display.
- Center: representative color from a user-selected normalized region.
- Edge: representative color from the border region of the display.

Center sampling can be calibrated from the menu bar or Settings. The selector opens an overlay on the primary display, lets the user drag a rectangle, and stores the result as normalized coordinates so it remains portable across resolution changes.

Edge sampling supports configurable edge depth and zone count. The analysis path downsamples frames before processing to keep CPU and memory usage low.

## Color Analysis And Calibration

Dynamic output is tuned for visual comfort and desk lighting rather than raw pixel averaging.

- Weighted average extraction can favor brighter and more saturated pixels.
- Dominant color extraction is available as an alternate strategy.
- Saturation boost can compensate for LED strips appearing less vivid than the display.
- Gamma correction helps align monitor brightness perception with LED output.
- Temporal smoothing blends output over time to avoid harsh flicker.
- Black threshold suppresses tiny near-black output.
- Muted dark detection can turn the LED off for low-luminance, low-saturation scenes.
- Pure white detection can snap bright low-saturation scenes to a calibrated white.
- Calibrated white is user-configurable and is shared by White mode and near-white Dynamic output.

## Display Brightness Sync

The Displays settings tab can sync external monitor brightness to the Mac built-in display brightness.

- Uses the built-in display only as the brightness source.
- Does not use the primary display, active display, mouse display, or current window display as a fallback source.
- Detects external display attach/detach via CoreGraphics display reconfiguration callbacks.
- Polls built-in brightness at a user-configurable rate from 1 to 10 Hz.
- Avoids excessive writes by only syncing meaningful brightness changes.
- Keeps a per-app-session monitor list.
- Newly detected monitors are added to the list.
- Disconnected monitors remain visible as disconnected for the current app session.
- Reconnected monitors are restored to connected/synced state.
- Uses a vendored minimal AppleSiliconDDC-derived DDC/CI path for external display luminance writes.
- Uses DDC VCP `0x10` luminance for external display brightness.
- Input switching uses a custom packet source address and VCP code per monitor. Named profiles then assign an independent input value to any subset of connected monitors, with one profile selected as the menu-bar default.
- A switch result of `Sent` confirms that the I²C command was accepted by macOS' transport. It does not claim visual confirmation because switching away from the Mac can immediately remove the monitor's DDC link.
- Includes the upstream AppleSiliconDDC MIT license in `macos/LumaDesk/Vendor/AppleSiliconDDC/LICENSE`.

Display brightness sync depends on monitor, cable, and port support for DDC/CI. Some monitors require DDC/CI to be enabled in the monitor OSD.

## Permissions

LumaDesk needs:

- Bluetooth access for BLE LED strip communication.
- Screen Recording access for Dynamic mode capture.

The app does not repeatedly force permission prompts. Settings provides shortcuts to the relevant macOS privacy panes, and the user grants access manually.

## Architecture

Major areas are kept separate:

- App lifecycle and menu bar controller.
- App state store and settings persistence.
- SwiftUI popover and Settings UI.
- ScreenCaptureKit capture service.
- Color analysis service.
- Dynamic lighting engine.
- BLE device manager and ELK-BLEDOM backend.
- Display brightness sync service.
- Vendored minimal AppleSiliconDDC DDC layer.

This keeps UI state, screen analysis, BLE transport, DDC display control, and persistence from depending directly on each other.

## Build Notes

Open `macos/LumaDesk.xcodeproj` in Xcode and build the `LumaDesk` target.

The project targets macOS 14 or newer. The display brightness sync path links against private macOS display APIs, so this project is intended for local/direct distribution rather than Mac App Store distribution.

For local command-line type checking:

```zsh
env CLANG_MODULE_CACHE_PATH=/tmp/LumaDeskModuleCache \
  xcrun --sdk macosx swiftc -typecheck \
  -target arm64-apple-macos14.0 \
  -import-objc-header macos/LumaDesk/Supporting/LumaDesk-Bridging-Header.h \
  $(find macos/LumaDesk -name '*.swift' -print)
```

On Windows 10/11 with the .NET 8 SDK:

```powershell
dotnet build .\windows\DesCon.Windows.sln -c Release
```

The Windows client uses built-in WPF/Win32 APIs only. Standard DDC goes through DXVA2; nonstandard LG packet source `0x50` goes through the NVIDIA driver-provided `nvapi64.dll` raw I²C API.
