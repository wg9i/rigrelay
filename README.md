# RigRelay

RigRelay is a lightweight bridge application for macOS that connects radio control and logging software across three ecosystems.

Why does it exist?

I needed something that would allow me to use RUMLogNG's fantastic rig control capabilities and at the same time allow applications like POTACAT, HamRS Pro, fldigi, and HamClock to control the rig.

RigRelay translates between:

```text
N1MM / RUMLogNG RadioInfo UDP broadcasts  ←→  RUMlogNG / DXLab Commander TCP commands  ←→  flrig-compatible XML-RPC clients
```

Purpose:

- Accept live radio state from N1MM / RUMLogNG via UDP RadioInfo packets
- Control a radio through DXLab Commander TCP commands
- Expose a flrig-compatible XML-RPC server so logging/contest software can operate as if it were talking to flrig

The Commander interface was tested with RUMLogNG configured to control an IC-7300. It should work with DXLab Commander as well.
Only basic functionality is supported, primarily setting frequency, mode, and split, and toggling PTT.

The flrig-compatible XML-RPC server was tested to some degree or another with POTACAT, HamRS Pro, fldigi, and HamClock.

This works for my purposes. I'm not actively developing or maintaining it.
Anything related to VFO B should be suspect. Some flrig methods are simply faked, such as anything related to the S meter or IF bandwidth.
Trying to change frequencies with fldigi active is an adventure.
Also, I'm not a Swift developer. There are assuredly other bugs.

## License

Copyright (c) 2026 Scott Reynolds. Released under the [BSD 2-Clause License](LICENSE).

## Requirements

- macOS 13 Ventura or later
- Swift toolchain — the Xcode Command Line Tools are sufficient:

```bash
xcode-select --install
```

Verify:
```bash
swift --version   # should report 5.9 or later
```

## Quick start (development)

```bash
cd RigRelay
swift run
```

This builds and launches the app in one step. Delete `.build` if you see stale UI after pulling changes.

## Building the .app bundle

The project includes `Info.plist` at the repository root.

### Build with VS Code

Use `Shift-Cmd-B` or click `Terminal` > `Run Build Task`.
This:

- Cleans the build environment;
- Performs a release build;
- Builds the app bundle with appropriate entitlements; and
- Signs the app bundle.

You can find the app bundle in the repository root folder.

### Manual method

The script below uses it to assemble a proper `.app` bundle and signs it ad-hoc so macOS will launch it.

```bash
cd RigRelay

# 1. Compile
swift build -c release

# 2. Assemble the bundle
APP=RigRelay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RigRelay "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"

# 3. Sign ad-hoc (required for network entitlements on macOS 13+)
codesign --sign - --force --deep "$APP"

# 4. Launch
open "$APP"
```

#### Network permissions

If macOS blocks UDP multicast or TCP binding, add entitlements before signing:

```bash
cat > RigRelay.entitlements << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.server</key><true/>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
EOF

codesign --sign - --entitlements RigRelay.entitlements --force --deep RigRelay.app
```

### Install for all users

To install the app bundle system-wide, move it to `/Applications`:

```bash
mv RigRelay.app /Applications/
```

## Configuration

All settings persist across restarts via `UserDefaults`.

| Setting | Default | Description |
|---|---|---|
| Commander host | 192.168.123.57 | RUMLogNG / DXLab Commander TCP host |
| Commander port | 50000 | Commander TCP port |
| N1MM host | 0.0.0.0 | UDP listen address (use 224.0.0.1 for multicast UDP group) |
| N1MM port | 12060 | UDP port for RadioInfo broadcasts |
| flrig bind address | 0.0.0.0 | XML-RPC server listen address |
| flrig port | 12345 | XML-RPC server listen port |
| Rig name | IC-7300 | Returned by `rig.get_xcvr` |
| Power (W) | 100 | Returned by `rig.get_power` |

Mode mappings (N1MM→flrig and flrig→Commander) are editable in the **Modes** tab.

## Implemented flrig methods

| Method | Notes |
|---|---|
| `main.get_version` | Reports `2.0.10` |
| `rig.get_xcvr` | Returns configured rig name |
| `rig.get_freq` / `rig.get_vfo` / `rig.get_vfoA` | RX frequency from Commander |
| `rig.get_vfoB` | TX frequency from Commander |
| `rig.set_freq` / `rig.set_vfo` / `rig.set_vfoA` | Set RX frequency |
| `rig.set_vfoB` | Set TX split frequency |
| `rig.set_verify_frequency` | Set and poll until confirmed |
| `rig.get_mode` / `rig.get_modeA` | RX mode from Commander |
| `rig.get_modeB` | TX mode (tracked locally; falls back to RX mode) |
| `rig.set_mode` / `rig.set_modeA` | Set RX mode |
| `rig.set_modeB` | Set TX mode (applied on next `set_vfoB`) |
| `rig.get_ptt` / `rig.set_ptt` | PTT via Commander CmdTX/CmdRX |
| `rig.get_split` / `rig.set_split` | Split via Commander CmdSplit |
| `rig.get_modes` | List of supported modes |
| `rig.get_power` | Configured power level |
| `rig.get_pwrmeter` | Always 0 (no live meter) |
| `rig.get_pwrmeter_scale` | Configured power level as full-scale |
| `system.listMethods` | Full method list |

## UI overview

| Tab | Purpose |
|---|---|
| **Dashboard** | Start/stop, connection status, live freq/mode/split/PTT readout |
| **Settings** | All host/port/rig-name/power configuration |
| **Modes** | Editable N1MM→flrig and flrig→Commander mode mapping tables |
| **Log** | Scrolling console with debug/info/warn/error filter and auto-scroll |

The **menu bar extra** shows running state and current frequency, with a quick start/stop toggle.

## Architecture

```
BridgeCore (library target)
├── BridgeConfig.swift      — ObservableObject, UserDefaults-backed settings
├── RadioInfo.swift         — N1MM XML packet model + SAX parser
├── CommanderClient.swift   — NWConnection TCP actor, ADIF response parser
├── N1MMListener.swift      — NWListener UDP actor
├── XmlRpcServer.swift      — NWListener TCP, HTTP + XML-RPC server
└── BridgeEngine.swift      — @MainActor coordinator, publishes state to SwiftUI

BridgeApp (executable target)
├── RigRelayApp.swift       — @main, WindowGroup + MenuBarExtra
├── ContentView.swift       — TabView shell
├── DashboardView.swift     — Status cards, radio readout, start/stop
├── ConfigView.swift        — All settings
├── ModeMappingsView.swift  — Editable mode mapping tables
└── LogView.swift           — Filtered, auto-scrolling log console
```

## FAQ

### I really like/love/can't live without this app! How can I repay you?

I'm thrilled. Really! Don't buy me a coffee.
Well, if you insist, fine, but a simple thank you is really quite enough.
Hope to talk to you on the air!

### What if I have an idea for an improvement?

Fork the repository and have at it.
If you think of it, send a pull request back my way and share the joy.

### Um, okay, but what if I don't write code?

Maybe spring for a Claude Code subscription?
In any case, I'm very sorry, but my XYL thinks I already spend too much time on computers.

### How can I contact you to express my ire over your inability to accept responsibility for this?

If you're an amateur radio operator (ham), my email is on QRZ.
I'm on HF most days for at least a little while.
Or, send a message via WinLink. I'll probably get it eventually.