<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty for Windows
</h1>
  <p align="center">
    Unofficial native Win32 port of <a href="https://github.com/ghostty-org/ghostty">Ghostty</a>.
    <br />
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/releases"><img src="https://img.shields.io/github/v/release/RecursiveFunctions/ghostty-windows?label=release&color=0078d4" alt="Latest Release"></a>
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/release-windows.yml"><img src="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/release-windows.yml/badge.svg" alt="Release Windows"></a>
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/test.yml"><img src="https://github.com/RecursiveFunctions/ghostty-windows/actions/workflows/test.yml/badge.svg?branch=windows" alt="Tests"></a>
    <br />
    <a href="https://github.com/RecursiveFunctions/ghostty-windows/releases">Releases</a>
    ·
    <a href="#installation">Installation</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="#keybindings">Keybindings</a>
    ·
    <a href="#building">Building</a>
    ·
    <a href="dist/windows/README-windows.md">Windows Notes & Known Issues</a>
  </p>
</p>

> [!IMPORTANT]
> This is an **unofficial community port** (`-Dapp-runtime=win32`), not an official [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) release. Report Windows bugs at [`RecursiveFunctions/ghostty-windows/issues`](https://github.com/RecursiveFunctions/ghostty-windows/issues), not upstream.

## Installation

Grab the latest build from the [Releases page](https://github.com/RecursiveFunctions/ghostty-windows/releases) (for macOS and Linux, see [ghostty.org/download](https://ghostty.org/download)).

### Installer

Run `Ghostty-Windows-Setup-x64.exe`. It installs per-user into `%LOCALAPPDATA%\Programs\Ghostty` without requiring admin rights, adds a Start menu shortcut, and optionally adds **"Open Ghostty here"** to the Explorer context menu.

```powershell
# Silent install / uninstall
Ghostty-Windows-Setup-x64.exe /VERYSILENT /CURRENTUSER [/DIR="C:\path"] [/TASKS="contextmenu"]
"%LOCALAPPDATA%\Programs\Ghostty\unins000.exe" /VERYSILENT
```

### Portable zip

Extract `Ghostty-Windows-x64.zip` anywhere and run `ghostty\bin\ghostty.exe`. Keep the folder structure intact so Ghostty can find its bundled `conpty.dll`, themes, shell integration scripts, and terminfo under `share\`.

### Updating

Open the Command Palette (`ctrl+shift+p`) and run **Check for Updates** to download, verify (`SHA256SUMS.txt`), and install the latest release in place.

## Configuration

Ghostty reads `%APPDATA%\ghostty\config.ghostty` (or `%APPDATA%\ghostty\config`) and creates a commented template on first run. If `XDG_CONFIG_HOME` is set, it takes precedence.

- `ctrl+,` — open config in your default editor
- `ctrl+shift+,` — reload config
- Full option reference: [ghostty.org/docs/config](https://ghostty.org/docs/config)

If `command` is not set, Ghostty starts the first shell it finds:
1. `pwsh.exe` (PowerShell 7)
2. `powershell.exe` (Windows PowerShell 5.1)
3. `cmd.exe`

Shell integration is injected automatically for PowerShell and `cmd.exe`. To use another shell, set `command` using forward slashes (or the `direct:` prefix):

```ini
command = C:/msys64/usr/bin/fish.exe -l
```

## Keybindings

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
| `ctrl+shift+p`                  | Command Palette            |
| `ctrl+shift+f`                  | Search scrollback          |
| `ctrl+shift+i`                  | Terminal Inspector         |
| `ctrl+enter` / `alt+enter`      | Toggle fullscreen          |
| `ctrl+shift+q`                  | Quit                       |

Run `ghostty +list-keybinds --default` from a console for the complete list.

## Building

Requires Zig `0.16.0-dev` (see `build.zig.zon`), Visual Studio 2022 Build Tools (C++ & Windows 11 SDK), PowerShell 5.1+, and [Inno Setup 6](https://jrsoftware.org/isinfo.php) if building the installer.

```powershell
# Debug build (zig-out\bin\ghostty.exe)
zig build -Dapp-runtime=win32

# Run Win32 unit tests
zig build test -Dapp-runtime=win32 -Dtest-filter=win32

# Release build + portable zip + installer
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dcpu=baseline -Dversion-string=1.4.1-windows -p build/release
pwsh -File dist/windows/make-zip.ps1 -Prefix build/release -Version 1.4.1-windows
ISCC.exe /DAppVersion=1.4.1-windows /DSourceDir=dist\windows\out\staging\ghostty /DOutputDir=dist\windows\out dist\windows\installer\ghostty.iss
```

For logs, crash dumps, bundled ConPTY details, [code signing policy](dist/windows/README-windows.md#code-signing-policy), and known platform limitations, see [`dist/windows/README-windows.md`](dist/windows/README-windows.md).

## Provenance & AI Disclosure

- Upstream terminal core: [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors.
- Initial Win32 runtime (`src/apprt/win32/`), WGL setup, and packaging scripts: [`phalladar/ghostty-windows`](https://github.com/phalladar/ghostty-windows) by Josh Auriemma.
- Per [`AI_POLICY.md`](AI_POLICY.md): the Zig 0.17 rebase, CI release pipeline, and additional Win32 runtime features in this fork were developed with AI assistance (Kilo Code).

## License

MIT — see [`LICENSE`](LICENSE).
