<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty for Windows
</h1>
  <p align="center">
    Fast, native Win32 terminal emulator built on <code>ghostty-org/ghostty</code>.
    <br />
    OpenGL 4.3 · DirectWrite · ConPTY · Native Win32 (`-Dapp-runtime=win32`)
    <br />
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/releases">Releases</a>
    ·
    <a href="#installation">Installation</a>
    ·
    <a href="#features">Features</a>
    ·
    <a href="#roadmap">Roadmap</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="#building-from-source">Building</a>
    ·
    <a href="#provenance--ai-assistance-disclosure">Provenance & AI Disclosure</a>
  </p>
</p>

> [!IMPORTANT]
> **Unofficial Community Windows Port (`RecursiveFunctions/ghostty-windows`)**
>
> This repository maintains an experimental, community-driven Windows port (`-Dapp-runtime=win32`) and is **not** an official [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) release.
>
> - **Bug Reports:** Report all Windows-specific issues and crash reports to [`RecursiveFunctions/ghostty-windows/issues`](https://github.com/RecursiveFunctions/ghostty-windows/issues). **Never** report issues from this fork to upstream `ghostty-org/ghostty`.
> - **Windows Documentation & AI Disclosure:** See [`dist/windows/README-windows.md`](dist/windows/README-windows.md) for detailed Windows setup, troubleshooting, provenance, and AI assistance disclosure (in accordance with [`AI_POLICY.md`](AI_POLICY.md)).

## Overview

Ghostty for Windows brings [Ghostty](https://github.com/ghostty-org/ghostty)'s high-performance Zig terminal core (`libghostty-vt`) to Windows as a native Win32 application (`-Dapp-runtime=win32`):

- **Renderer:** Hardware-accelerated OpenGL 4.3 via WGL (`src/renderer/opengl/wgl.zig`)
- **Font Shaping & Discovery:** Native DirectWrite + HarfBuzz with bundled JetBrains Mono and Noto Color Emoji fallbacks
- **PTY Backend:** Windows ConPTY (bundles Microsoft's latest `conpty.dll` + `OpenConsole.exe` for accurate resize and cursor synchronization)
- **Windowing & UI:** Pure Win32 (`src/apprt/win32/`) with Windows 11 DWM dark mode, backdrop blur/transparency, tabs, splits, overlays, and Dear ImGui terminal inspector

## Requirements

- **OS:** Windows 11 (`x86_64`). Windows 10 is untested.
- **GPU:** OpenGL 4.3 capable GPU and driver (any modern NVIDIA, AMD, or Intel GPU). Virtual machines or RDP sessions using the Microsoft Basic Render Driver without GPU acceleration are not supported.

## Installation

For Windows builds, see the [**Releases page**](https://github.com/RecursiveFunctions/ghostty-windows/releases) on this repository (for official macOS/Linux builds, see [ghostty.org/download](https://ghostty.org/download)).

### Installer (Recommended)

Download and run `Ghostty-Windows-Setup-x64.exe` (`ghostty-<version>-windows-x86_64-setup.exe`).

- Installs per-user into `%LOCALAPPDATA%\Programs\Ghostty` (no administrator elevation required; `/ALLUSERS` is also supported).
- Registers the Start Menu shortcut with AppUserModelID `com.mitchellh.ghostty`.
- Optionally adds **"Open Ghostty here"** to folder, background, and drive context menus in Explorer.

Silent install / uninstall:

```powershell
Ghostty-Windows-Setup-x64.exe /VERYSILENT /CURRENTUSER [/DIR="C:\path"] [/TASKS="contextmenu"]
"%LOCALAPPDATA%\Programs\Ghostty\unins000.exe" /VERYSILENT
```

### Portable ZIP

Download `Ghostty-Windows-x64.zip` (`ghostty-<version>-windows-x86_64.zip`), extract it anywhere, and run `ghostty\bin\ghostty.exe`.

Keep the extracted directory structure intact so Ghostty can locate `share\ghostty\themes`, `share\ghostty\shell-integration`, and `share\terminfo`:

```text
ghostty\
  bin\
    ghostty.exe
    conpty.dll
    OpenConsole.exe
  share\
    ghostty\themes\...
    ghostty\shell-integration\...
    terminfo\ghostty.terminfo
  LICENSE
  README-windows.md
```

> [!NOTE]
> **In-App Auto-Updates & Code Signing:** Run **Check for Updates** from the Command Palette (`ctrl+shift+p`) at any time to automatically download, verify (`SHA256SUMS.txt`), and install the latest release for both Installer and Portable ZIP deployments. The CI release pipeline (`dist/windows/sign-file.ps1`) supports Authenticode signing via Azure Trusted Signing OIDC or PFX certificates; if a build was produced without signing credentials configured, Windows SmartScreen may prompt on first launch (**More info** → **Run anyway**).

## Features

| Category                     | Supported on Windows (`win32`)                                                                                                                                                                                                                                       |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Windowing & Tabs**         | Multi-window, single-instance IPC (`+new-window`, `+new-tab`), custom tab bar, tab overview (`toggle_tab_overview`), live-session `undo`/`redo` (`undo-timeout`), borderless/decorations toggle, fullscreen & maximize, cell-step resize (`window-step-resize`)      |
| **Splits**                   | Horizontal/vertical splits, directional focus navigation, mouse divider dragging, split zoom (`toggle_split_zoom`), equalizing splits, unfocused split dimming (`unfocused-split-opacity`, `unfocused-split-fill`)                                                   |
| **Overlays & Inspector**     | Live scrollback search bar (`start_search`), localized fuzzy Command Palette (`toggle_command_palette`), SHA-256 verified in-app auto-updater (`check_for_updates`), resize/hyperlink status pill, and multi-dock Dear ImGui Terminal Inspector (`inspector:toggle`) |
| **Quick Terminal & Hotkeys** | Global dropdown Quick Terminal (`toggle_quick_terminal`) with slide/fade animations, position/size config, auto-hide, and system-wide `global:` keybindings via `RegisterHotKey`                                                                                     |
| **Appearance & DWM**         | Windows 11 dark/light caption & border theming (`window-theme`), dynamic OSC 10/11 chrome colors, background transparency (`background-opacity`), DWM blur/acrylic backdrop (`background-blur`), bell border flash (`bell-features = border`)                        |
| **Shell & SSH Integration**  | Automatic injection for PowerShell 7 (`pwsh.exe`), Windows PowerShell 5.1 (`powershell.exe`), and `cmd.exe`, `ghostty +ssh` remote terminfo auto-installer, WinRT Toast notifications (with tray balloon fallback), and taskbar progress                             |

## Roadmap

### Phase 1 — Signed Installers & Automatic In-App Updates (Shipped)

- [x] **Authenticode Code-Signing Pipeline (`dist/windows/sign-file.ps1`):** Automated signing of `ghostty.exe` and `Ghostty-Windows-Setup-x64.exe` in `.github/workflows/release-windows.yml` supporting both **Azure Trusted Signing OIDC** (`Azure.CodeSigning.Dlib`) and **PFX certificates** (`WINDOWS_PFX_BASE64`), with graceful fallback for fork/community builds.
- [x] **Automatic In-App Updates (`check_for_updates`):** Background `WinHTTP` updater (`src/apprt/win32/updater.zig`) that queries GitHub Releases, downloads `SHA256SUMS.txt` and the matching release asset (`Ghostty-Windows-Setup-x64.exe` or `Ghostty-Windows-x64.zip`), verifies the SHA-256 digest using `std.crypto.hash.sha2.Sha256`, and upgrades + restarts Ghostty in-place.

### Phase 2 — DirectX / WARP Fallback & WinGet (Next)

- [ ] **DirectX 11 / D3D12 + Microsoft WARP Software Fallback Renderer:** Enable Ghostty to run in GPU-less virtual machines (Hyper-V, VMware, QEMU), Windows Sandbox, and Remote Desktop (RDP) sessions where the Microsoft Basic Render Driver lacks OpenGL 4.3, while unlocking native DirectComposition transparency and HDR.
- [ ] **Automated WinGet Package Publishing:** Publish to `microsoft/winget-pkgs` from the release workflow so users can install and update via `winget install`.

### Phase 3 — Deep Windows Shell & Accessibility Integration (Planned)

- [ ] **Taskbar Jump Lists & Shell Auto-Discovery (`ICustomDestinationList`):** Right-click Taskbar Jump List tasks (_New Window_, _New Tab_, _Open Configuration_) and auto-discovered profiles for PowerShell 7, Windows PowerShell 5.1, `cmd.exe`, installed WSL distributions (`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`), Git Bash, and MSYS2.
- [ ] **Session Restore (`window-save-state`):** Save and restore window positions, tabs, split layouts, and working directories across restarts and in-app updates.
- [ ] **Windows UI Automation (`UIAutomationCore.dll`):** Implement `IRawElementProviderSimple` and `ITextProvider` for Windows Narrator and NVDA screen-reader accessibility.

## Configuration

Ghostty reads `%APPDATA%\ghostty\config.ghostty` (or `%APPDATA%\ghostty\config`). On first launch, a commented template is created automatically. If `XDG_CONFIG_HOME` is set, it takes precedence.

- **Open configuration:** `ctrl+,` (opens in your `.ghostty` editor, `%VISUAL%`, `%EDITOR%`, or Notepad)
- **Reload configuration:** `ctrl+shift+,`
- **Validate / inspect from CLI:**
  ```powershell
  ghostty +validate-config
  ghostty +show-config --default --docs
  ghostty +list-themes
  ghostty +list-fonts
  ghostty +list-keybinds --default
  ```

All cross-platform configuration options are documented at [ghostty.org/docs/config](https://ghostty.org/docs/config).

### Default Shell Resolution

If `command` is not set in `config.ghostty`, Ghostty launches the first available shell:

1. `pwsh.exe` (PowerShell 7) on `PATH`
2. Windows PowerShell 5.1 (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`)
3. `cmd.exe` (`%COMSPEC%`)

To configure a custom shell (use forward slashes or the `direct:` prefix):

```ini
command = C:/msys64/usr/bin/fish.exe -l
```

## Default Keybindings

| Keys                            | Action                     |
| ------------------------------- | -------------------------- |
| `ctrl+shift+c` / `ctrl+ins`     | Copy                       |
| `ctrl+shift+v` / `shift+ins`    | Paste                      |
| `ctrl+shift+t`                  | New tab                    |
| `ctrl+shift+n`                  | New window                 |
| `ctrl+shift+w`                  | Close surface / tab        |
| `alt+1` … `alt+8`, `alt+9`      | Switch to tab N / last tab |
| `ctrl+tab` / `ctrl+shift+tab`   | Next / previous tab        |
| `ctrl+shift+o` / `ctrl+shift+e` | Split right / split down   |
| `ctrl+alt+arrow`                | Focus adjacent split       |
| `ctrl+shift+p`                  | Toggle Command Palette     |
| `ctrl+shift+f`                  | Start scrollback search    |
| `ctrl+shift+i`                  | Toggle Terminal Inspector  |
| `ctrl+enter` / `alt+enter`      | Toggle fullscreen          |
| `ctrl+shift+q`                  | Quit                       |

## Building from Source

### Prerequisites

- **Zig:** `0.16.0-dev` (matching `minimum_zig_version` in `build.zig.zon`)
- **Windows SDK & MSVC toolchain** (Visual Studio 2022 Build Tools with C++ & Windows 11 SDK)
- **PowerShell 5.1+**
- **Inno Setup 6** (optional, for building the installer: `winget install --id JRSoftware.InnoSetup -e`)

### Build & Test Commands

```powershell
# Build debug binary (zig-out\bin\ghostty.exe)
zig build -Dapp-runtime=win32

# Run Win32 unit tests
zig build test -Dapp-runtime=win32

# Build optimized release binary
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dcpu=baseline -Dversion-string=1.4.1-windows -p build/release

# Package portable ZIP (automatically downloads & verifies pinned NuGet ConPTY 1.25+)
pwsh -File dist/windows/make-zip.ps1 -Prefix build/release -Version 1.4.1-windows

# Build Inno Setup installer
ISCC.exe /DAppVersion=1.4.1-windows /DSourceDir=dist\windows\out\staging\ghostty /DOutputDir=dist\windows\out dist\windows\installer\ghostty.iss
```

## Contributing & Developing

If you would like to contribute to this Windows fork, open an [issue](https://github.com/RecursiveFunctions/ghostty-windows/issues) or [discussion](https://github.com/RecursiveFunctions/ghostty-windows/discussions) on this repository.

For upstream Ghostty architecture and contribution guidelines, see [`CONTRIBUTING.md`](CONTRIBUTING.md) and [`HACKING.md`](HACKING.md).

## Logs, Crash Reports & Known Issues

- **Capturing Logs:**
  ```powershell
  Start-Process ghostty.exe -RedirectStandardError "$env:TEMP\ghostty.log"
  ```
- **Crash Dumps:** Minidumps (`.dmp`) and panic logs (`.txt`) are written locally to `%LOCALAPPDATA%\ghostty\crash` (never uploaded automatically). Run `ghostty +crash-report` to list them.
- **Detailed Windows Troubleshooting & Known Limitations:** See [`dist/windows/README-windows.md`](dist/windows/README-windows.md) for full details on bundled ConPTY, Explorer context menu registration, code signing, and platform limitations (e.g. OSC 52 read under ConPTY, COLR emoji grayscale, RDP without GPU).

## Provenance & AI Assistance Disclosure

In accordance with Ghostty's [`AI_POLICY.md`](AI_POLICY.md), this section documents the provenance and AI assistance involved in this Windows port:

- **Upstream Base:** Built on [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and the Ghostty contributors (daily upstream sync via `.github/workflows/release-windows.yml`).
- **Win32 Runtime Foundation:** Initial Win32 runtime (`src/apprt/win32/`), WGL OpenGL provider (`src/renderer/opengl/wgl.zig`), and Windows packaging scripts were derived from [`phalladar/ghostty-windows`](https://github.com/phalladar/ghostty-windows) by Josh Auriemma.
- **AI Assistance Disclosure:** The Zig 0.17 / Ghostty 1.4.1-dev rebase and port, automated CI release pipeline, and Win32 feature parity implementation (search overlay, command palette, tab overview, quick terminal, global hotkeys, DWM backdrop/transparency, dynamic OSC 10/11 chrome colors, live-session `undo`/`redo`, `check_for_updates`, `ghostty +ssh` remote terminfo auto-install, WinRT toast notifications, Windows `.mo` localization, unfocused split dimming, `bell-features = border`, and Dear ImGui terminal inspector) were developed with AI assistance using **Kilo Code**, with human review, build verification, and runtime testing.

## License

MIT License — see [`LICENSE`](LICENSE).
