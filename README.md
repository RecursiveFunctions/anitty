<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty for Windows
</h1>
  <p align="center">
    Fast, native Win32 terminal emulator built on <code>ghostty-org/ghostty</code>.
    <br />
    OpenGL 4.3 · DirectX 11 / WARP · DirectWrite · ConPTY · Native Win32 (`-Dapp-runtime=win32`)
    <br />
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/releases"><img src="https://img.shields.io/github/v/release/RecursiveFunctions/ghostty-windows?label=Release&color=0078d4" alt="Latest Release"></a>
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/release-windows.yml"><img src="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/release-windows.yml/badge.svg" alt="Release Windows"></a>
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/test.yml"><img src="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/test.yml/badge.svg?branch=windows" alt="Tests"></a>
    <a href="#code-signing-policy"><img src="https://img.shields.io/badge/Code%20Signing-SignPath-2ea44f" alt="SignPath Code Signing"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="MIT License"></a>
    <br />
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/releases">Releases</a>
    ·
    <a href="#installation">Installation</a>
    ·
    <a href="#features">Features</a>
    ·
    <a href="#why-this-port">Why This Port?</a>
    ·
    <a href="#roadmap">Roadmap</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="#building-from-source">Building</a>
    ·
    <a href="#code-signing-policy">Code Signing Policy</a>
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

- **Renderer:** Hardware-accelerated OpenGL 4.3 via WGL (`src/renderer/opengl/wgl.zig`) with optional DirectX 11 / DXGI flip-model & Microsoft WARP software fallback presenter (`src/renderer/opengl/d3d11_presenter.zig`)
- **Font Shaping & Discovery:** Native DirectWrite (`IDWriteFontFallback`) + HarfBuzz with bundled JetBrains Mono and Noto Color Emoji fallbacks
- **PTY Backend:** Windows ConPTY (bundles Microsoft's latest `conpty.dll` + `OpenConsole.exe` 1.25+ for accurate resize and cursor synchronization)
- **Windowing & UI:** Pure Win32 (`src/apprt/win32/`) with Windows 11 DWM dark mode, backdrop blur/transparency, tabs, splits, overlays, OLE drag-and-drop, rich `CF_HTML` clipboard, and Dear ImGui terminal inspector

## Requirements

- **OS:** Windows 11 (`x86_64`). Windows 10 (`1809+`) is supported via the bundled ConPTY runtime.
- **GPU:** OpenGL 4.3 capable GPU (NVIDIA, AMD, Intel), with automatic or configurable DirectX 11 + Microsoft WARP software fallback (`GHOSTTY_WIN32_PRESENTER=d3d11|warp`) for GPU-less virtual machines, Windows Sandbox, and Remote Desktop (RDP) sessions.

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
> **In-App Auto-Updates & SignPath Code Signing:** Run **Check for Updates** from the Command Palette (`ctrl+shift+p`) at any time to automatically download, verify (`SHA256SUMS.txt`), and install the latest release for both Installer and Portable ZIP deployments. All official release binaries (`ghostty.exe` and `Ghostty-Windows-Setup-x64.exe`) are signed in CI via [SignPath.io](https://signpath.io/) (see [Code signing policy](#code-signing-policy)).

## Features

| Category                     | Supported on Windows (`win32`)                                                                                                                                                                                                                                                                                                                                |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Windowing & Tabs**         | Multi-window, single-instance IPC (`+new-window`, `+new-tab`), session save/restore (`window-save-state`), custom tab bar with hover tooltips & wheel scrolling, tab overview (`toggle_tab_overview`), live-session `undo`/`redo` (`undo-timeout`), borderless/decorations toggle, fullscreen & maximize, cell-step resize (`window-step-resize`)             |
| **Splits**                   | Horizontal/vertical splits, directional focus navigation, mouse divider dragging, split zoom (`toggle_split_zoom`), equalizing splits, unfocused split dimming (`unfocused-split-opacity`, `unfocused-split-fill`)                                                                                                                                            |
| **Overlays & Inspector**     | Live scrollback search bar (`start_search`), localized fuzzy Command Palette (`toggle_command_palette`), SHA-256 verified in-app auto-updater (`check_for_updates`), live resize dimensions overlay (`resize-overlay`), hyperlink/status pill, surface right-click context menu, `+boo` ghost animation, and multi-dock Dear ImGui Terminal Inspector          |
| **Quick Terminal & Hotkeys** | Global dropdown Quick Terminal (`toggle_quick_terminal`) with slide/fade animations, position/size config, auto-hide, and system-wide `global:` keybindings via `RegisterHotKey`                                                                                                                                                                              |
| **Clipboard & Drag-Drop**    | Dual-format clipboard (`CF_UNICODETEXT` + `CF_HTML` rich HTML copy), `copy-on-select` selection clipboard, middle-click paste, and OLE `IDropTarget` drag-and-drop with automatic PowerShell / `cmd.exe` path quoting                                                                                                                                         |
| **Appearance, Audio & DWM**  | Windows 11 dark/light caption & border theming (`window-theme`), dynamic OSC 10/11 chrome colors, background transparency (`background-opacity`), DWM blur/acrylic backdrop (`background-blur`), custom bell audio (`bell-audio-path`, `bell-audio-volume`) via Media Foundation, bell border flash, and sleep/display-off render throttling                  |
| **Shell, Security & SSH**    | Auto-injection for PowerShell 7 (`pwsh.exe`), Windows PowerShell 5.1 (`powershell.exe`), and `cmd.exe`, native Windows `OSC 7` / `OSC 9;9` / `OSC 1337` CWD tracking, Taskbar Jump Lists with WSL/shell discovery, `ghostty +ssh` remote terminfo auto-installer, screen-capture protection (`toggle_secure_input`), and WinRT Toast notifications         |

## Why This Port?

| Capability                    | Ghostty for Windows (`win32`)                            | C# / WinUI Wrapper Ports     | Windows Terminal             | WezTerm                      | Alacritty                    |
| ----------------------------- | -------------------------------------------------------- | ---------------------------- | ---------------------------- | ---------------------------- | ---------------------------- |
| **UI Architecture**           | **Pure Zig Win32 (`-Dapp-runtime=win32`)**               | C# / .NET P/Invoke wrapper   | C++ / WinUI XAML Islands     | Rust (`window` crate)        | Rust (`winit`)               |
| **Upstream Alignment**        | **Direct `apprt` in `ghostty-org/ghostty` tree (daily sync)** | Out-of-tree C ABI bridge | Separate codebase            | Separate codebase            | Separate codebase            |
| **GPU + VM/RDP Fallback**     | **OpenGL 4.3 + DXGI Flip / D3D11 WARP fallback**         | OpenGL / ANGLE               | AtlasEngine (D3D11 / WARP)   | OpenGL / WebGPU              | OpenGL / ConPTY              |
| **Bundled ConPTY 1.25+**      | **Yes (cursor resync on resize included)**               | Manual / inbox `conhost.exe` | Yes (`OpenConsole.exe`)      | Yes                          | Inbox `conhost.exe`          |
| **Native Tabs & Splits**      | **Yes (with live-session Undo/Redo & Tab Overview)**     | Partial                      | Yes (no closed-tab undo)     | Yes                          | No                           |
| **Built-In Terminal Inspector**| **Yes (Multi-dock Dear ImGui VT/Grid/Screen inspector)**| No                           | No                           | Debug overlay only           | No                           |
| **Quick Terminal (Quake)**    | **Yes (`toggle_quick_terminal` + global hotkeys)**       | No                           | Quake mode (`Win+~`)         | QuickSelect                  | No                           |
| **In-App SHA-256 Updater**    | **Yes (Installer & Portable ZIP)**                       | No                           | MS Store / WinGet            | External                     | External                     |

## Roadmap

### Phase 1 — Signed Installers & Automatic In-App Updates (Shipped)

- [x] **Authenticode Code-Signing Pipeline (`dist/windows/sign-file.ps1`):** Automated signing of `ghostty.exe` and `Ghostty-Windows-Setup-x64.exe` in `.github/workflows/release-windows.yml` supporting both **Azure Trusted Signing OIDC** (`Azure.CodeSigning.Dlib`) and **PFX certificates** (`WINDOWS_PFX_BASE64`), with graceful fallback for fork/community builds.
- [x] **Automatic In-App Updates (`check_for_updates`):** Background `WinHTTP` updater (`src/apprt/win32/updater.zig`) that queries GitHub Releases, downloads `SHA256SUMS.txt` and the matching release asset (`Ghostty-Windows-Setup-x64.exe` or `Ghostty-Windows-x64.zip`), verifies the SHA-256 digest using `std.crypto.hash.sha2.Sha256`, and upgrades + restarts Ghostty in-place.

### Phase 2 — DirectX / WARP Fallback & WinGet (Next)

- [x] **DirectX 11 / DXGI Flip-Model + Microsoft WARP Software Fallback Presenter (`src/renderer/opengl/d3d11_presenter.zig`):** Zero-dependency D3D11 + `IDXGISwapChain1` presenter supporting `WGL_NV_DX_interop2` zero-copy sharing and automatic fallback to `D3D_DRIVER_TYPE_WARP` (`GHOSTTY_WIN32_PRESENTER=d3d11|warp`).
- [ ] **Automated WinGet Package Publishing:** Publish to `microsoft/winget-pkgs` from the release workflow so users can install and update via `winget install`.

### Phase 3 — Deep Windows Shell & Accessibility Integration (Planned)

- [x] **Taskbar Jump Lists & Shell Auto-Discovery (`ICustomDestinationList`):** Right-click Taskbar Jump List tasks (_New Window_, _New Tab_) and auto-discovered profiles for PowerShell 7, Windows PowerShell 5.1, `cmd.exe`, installed WSL distributions (`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`), and Git Bash.
- [x] **Session Restore (`window-save-state`):** Save and restore window positions, tabs, split layouts, and working directories across restarts, OS logoff (`WM_ENDSESSION`), and in-app updates.
- [x] **Secure Input Screen-Capture Protection (`toggle_secure_input`):** Excludes terminal windows from screen capture/recording via `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` with a live lock cursor and `Secure Input` status pill.
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
| `ctrl+shift+v`                  | Paste                      |
| `shift+ins` / middle-click      | Paste selection            |
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

## Code signing policy

Free code signing provided by [SignPath.io](https://signpath.io/), certificate by [SignPath Foundation](https://signpath.org/).

- **Committers and reviewers:** [`@RecursiveFunctions`](https://github.com/RecursiveFunctions) and [repository contributors](https://github.com/RecursiveFunctions/ghostty-windows/graphs/contributors)
- **Approvers:** [`@RecursiveFunctions`](https://github.com/RecursiveFunctions)
- **Privacy policy:** This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it (for example, invoking **Check for Updates** from the Command Palette to query GitHub Releases or initiating an outbound `ghostty +ssh` session). Crash minidumps are written strictly to the local disk (`%LOCALAPPDATA%\ghostty\crash`) and are never transmitted automatically.

## Provenance & AI Assistance Disclosure

In accordance with Ghostty's [`AI_POLICY.md`](AI_POLICY.md), this section documents the provenance and AI assistance involved in this Windows port:

- **Upstream Base:** Built on [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and the Ghostty contributors (daily upstream sync via `.github/workflows/release-windows.yml`).
- **Win32 Runtime Foundation:** Initial Win32 runtime (`src/apprt/win32/`), WGL OpenGL provider (`src/renderer/opengl/wgl.zig`), and Windows packaging scripts were derived from [`phalladar/ghostty-windows`](https://github.com/phalladar/ghostty-windows) by Josh Auriemma.
- **AI Assistance Disclosure:** The Zig 0.17 / Ghostty 1.4.1-dev rebase and port, automated CI release pipeline, and Win32 feature parity implementation (search overlay, command palette, tab overview, quick terminal, global hotkeys, DWM backdrop/transparency, dynamic OSC 10/11 chrome colors, live-session `undo`/`redo`, session save/restore, `check_for_updates`, `ghostty +ssh` remote terminfo auto-install, WinRT toast notifications, Taskbar Jump Lists, OLE drag-and-drop, `CF_HTML` rich clipboard, Media Foundation bell audio, DirectWrite font fallback, D3D11/WARP fallback presenter, Windows `.mo` localization, unfocused split dimming, `bell-features = border`, and Dear ImGui terminal inspector) were developed with AI assistance using **Kilo Code**, with human review, build verification, and runtime testing.

## License

MIT License — see [`LICENSE`](LICENSE).
