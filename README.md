<h1>
<p align="center">
  Anitty
</h1>
  <p align="center">
    Unofficial native Win32 terminal emulator forked from <a href="https://github.com/ghostty-org/ghostty">Ghostty</a>.
    <br />
    <a href="https://github.com/RecursiveFunctions/anitty/releases"><img src="https://img.shields.io/github/v/release/RecursiveFunctions/anitty?label=release&color=37B836" alt="Latest Release"></a>
    <a href="https://github.com/RecursiveFunctions/anitty/actions/workflows/release-windows.yml"><img src="https://github.com/RecursiveFunctions/anitty/actions/workflows/release-windows.yml/badge.svg" alt="Release Windows"></a>
    <a href="https://github.com/RecursiveFunctions/anitty/actions/workflows/test.yml"><img src="https://img.shields.io/github/actions/workflow/status/RecursiveFunctions/anitty/test.yml?branch=windows&label=tests" alt="Tests"></a>
    <br />
    <a href="https://github.com/RecursiveFunctions/anitty/releases">Releases</a>
    ·
    <a href="#recent-changes">Recent Changes</a>
    ·
    <a href="#installation">Installation</a>
    ·
    <a href="#configuration">Configuration</a>
    ·
    <a href="#keybindings">Keybindings</a>
    ·
    <a href="#building">Building</a>
    ·
    <a href="CHANGELOG.md">Changelog</a>
    ·
    <a href="dist/windows/README-windows.md">Windows Notes & Known Issues</a>
  </p>
</p>

## Recent Changes

Unreleased tip (`8f6f91bac`, `3a7ab0383`) — Discord/upstream bugfixes after `3fb0cc4dd`:

- Clear stuck right-click / context-menu mouse state so tmux and other mouse-mode apps stop seeing a held right button.
- Command Palette and Tab Overview no longer stack; overlays refresh or close when tabs and surfaces change; UI chrome follows OSC 10/11 colors.
- `window-width` / `window-height` account for the tab bar on first launch and when only one dimension is set.
- OpenGL frame export is top-row-first; color emoji alpha blending fixed (OpenGL + Metal).
- HarfBuzz no longer blanks a whole row when a fallback face fails to load; scrollback search pruning is much cheaper on large match sets.
- libghostty-vt snapshots keep `pending_wrap` and `semantic_prompt` correct under `DECSLRM` left/right margins.

Full history: [`CHANGELOG.md`](CHANGELOG.md).

## Installation

Grab the latest build from the [Releases page](https://github.com/RecursiveFunctions/anitty/releases) (for official macOS and Linux Ghostty builds, see [ghostty.org/download](https://ghostty.org/download)).

### Installer

Run `Anitty-Windows-Setup-x64.exe`. It installs per-user into `%LOCALAPPDATA%\Programs\Anitty` without requiring admin rights, adds a Start menu shortcut, and optionally adds **"Open Anitty here"** to the Explorer context menu.

```powershell
# Silent install / uninstall
Anitty-Windows-Setup-x64.exe /VERYSILENT /CURRENTUSER [/DIR="C:\path"] [/TASKS="contextmenu"]
"%LOCALAPPDATA%\Programs\Anitty\unins000.exe" /VERYSILENT
```

### Portable zip

Extract `Anitty-Windows-x64.zip` anywhere and run `anitty\bin\anitty.exe`. Keep the folder structure intact so Anitty can find its bundled `conpty.dll`, themes, shell integration scripts, and terminfo under `share\`.

### Updating

Open the Command Palette (`ctrl+shift+p`) and run **Check for Updates** to download, verify (`SHA256SUMS.txt`), and install the latest release in place.

## Configuration

Anitty reads `%APPDATA%\ghostty\config.ghostty` (or `%APPDATA%\ghostty\config`) for full configuration compatibility and creates a commented template on first run. If `XDG_CONFIG_HOME` is set, it takes precedence.

- `ctrl+,` — open config in your default editor
- `ctrl+shift+,` — reload config
- Full option reference: [ghostty.org/docs/config](https://ghostty.org/docs/config)

If `command` is not set, Anitty starts the first shell it finds:
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

Run `anitty +list-keybinds --default` from a console for the complete list.

## Building

Requires Zig `0.17.1` (see `build.zig.zon`), Visual Studio 2022 Build Tools (C++ & Windows 11 SDK), PowerShell 5.1+, and [Inno Setup 6](https://jrsoftware.org/isinfo.php) if building the installer.

```powershell
# Debug build (zig-out\bin\anitty.exe)
zig build -Dapp-runtime=win32

# Run Win32 unit tests
zig build test -Dapp-runtime=win32 -Dtest-filter=win32

# Release build + portable zip + installer
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dcpu=baseline -Dversion-string=1.4.1-windows -p build/release
pwsh -File dist/windows/make-zip.ps1 -Prefix build/release -Version 1.4.1-windows
ISCC.exe /DAppVersion=1.4.1-windows /DSourceDir=dist\windows\out\staging\anitty /DOutputDir=dist\windows\out dist\windows\installer\anitty.iss
```

For logs, crash dumps, bundled ConPTY details, [code signing policy](dist/windows/README-windows.md#code-signing-policy), and known platform limitations, see [`dist/windows/README-windows.md`](dist/windows/README-windows.md).

## License

MIT — see [`LICENSE`](LICENSE).

## Credits

- Upstream terminal core: [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors.
- Initial Win32 runtime (`src/apprt/win32/`), WGL setup, and packaging scripts: [`phalladar/ghostty-windows`](https://github.com/phalladar/ghostty-windows) by Josh Auriemma.
- Per [`AI_POLICY.md`](AI_POLICY.md), AI assistance was used for:
  - Zig 0.17 rebase
  - CI release pipeline
  - Additional Win32 features (search overlay, command palette, tab overview, quick terminal, global hotkeys, DWM backdrop/transparency, unfocused split dimming, terminal inspector)
- Tools: [`Kilo Code`](https://github.com/Kilo-Org/kilocode), plus home-grown grass-fed free-range gluten-free local LLMs in a homelab. Human review, builds, and testing throughout.
