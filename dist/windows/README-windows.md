# Ghostty for Windows

> [!IMPORTANT]
>
> This is an **unofficial community build** maintained at [`RecursiveFunctions/ghostty-windows`](https://github.com/RecursiveFunctions/ghostty-windows). Report all Windows issues and crash reports to [`RecursiveFunctions/ghostty-windows/issues`](https://github.com/RecursiveFunctions/ghostty-windows/issues) — **never** to upstream `ghostty-org/ghostty`.

Ghostty on Windows is a native Win32 application (`-Dapp-runtime=win32`)
that renders with OpenGL and runs shells through ConPTY. It is
experimental: the features below work, but see
[Known issues](#known-issues) before relying on it.

## Provenance & AI Assistance Disclosure

In accordance with Ghostty's [`AI_POLICY.md`](../../AI_POLICY.md), this section documents the provenance and AI assistance involved in this Windows port:

- **Upstream Base:** Built on [`ghostty-org/ghostty`](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors.
- **Win32 Runtime Foundation:** Initial Win32 runtime (`src/apprt/win32/`), WGL OpenGL provider (`src/renderer/opengl/wgl.zig`), and Windows packaging scripts were derived from [`phalladar/ghostty-windows`](https://github.com/phalladar/ghostty-windows) by Josh Auriemma.
- **AI Assistance Disclosure:** The Zig 0.17 / Ghostty 1.4.1-dev rebase and port, automated CI release pipeline, and Win32 feature parity implementation (search overlay, command palette, tab overview, quick terminal, global hotkeys, DWM backdrop/transparency, dynamic OSC 10/11 chrome colors, live-session `undo`/`redo`, `check_for_updates`, `ghostty +ssh` remote terminfo auto-install, WinRT toast notifications, Windows `.mo` localization, unfocused split dimming, `bell-features = border`, and Dear ImGui terminal inspector) were developed with AI assistance using **Kilo Code**, with human review, build verification, and runtime testing.

## Requirements

- Windows 11 (x86_64). Windows 10 is not tested.
- A GPU and driver that provide **OpenGL 4.3**. Any current NVIDIA, AMD or
  Intel driver does. Virtual machines without GPU acceleration and remote
  sessions that fall back to the Microsoft Basic Render Driver do not; see
  [Known issues](#known-issues).

## Portable zip

Extract `ghostty-<version>-windows-x86_64.zip` anywhere and run
`ghostty\bin\ghostty.exe`. Keep the folder layout intact: Ghostty finds its
themes, shell integration and terminfo by walking up from `bin\` to
`share\ghostty` (it looks for `share\terminfo\ghostty.terminfo`). Setting
`GHOSTTY_RESOURCES_DIR` overrides the lookup.

```
ghostty\
  bin\ghostty.exe
  share\ghostty\themes\...
  share\ghostty\shell-integration\...
  share\locale\...\LC_MESSAGES\com.mitchellh.ghostty.mo
  share\terminfo\ghostty.terminfo
  LICENSE
  README-windows.md
```

The portable build does not create a Start menu shortcut, so some taskbar
pinning behaviour only works with the installer.

### "Open Ghostty here" without the installer

The installer adds the context menu entry for you. For the portable build,
run this in PowerShell (no elevation needed), with `$exe` pointing at your
copy of `ghostty.exe`:

```powershell
$exe = "C:\Tools\ghostty\bin\ghostty.exe"
foreach ($key in "Directory\shell", "Directory\Background\shell", "Drive\shell") {
    $k = "HKCU:\Software\Classes\$key\Ghostty"
    New-Item -Path "$k\command" -Force | Out-Null
    Set-ItemProperty -Path $k -Name "(default)" -Value "Open Ghostty here"
    Set-ItemProperty -Path $k -Name Icon -Value "`"$exe`",0"
    Set-ItemProperty -Path "$k\command" -Name "(default)" -Value "`"$exe`" `"--working-directory=%V\.`""
}
```

The trailing `\.` keeps drive roots such as `C:\` from escaping the closing
quote. To remove the entries:

```powershell
foreach ($key in "Directory\shell", "Directory\Background\shell", "Drive\shell") {
    Remove-Item "HKCU:\Software\Classes\$key\Ghostty" -Recurse
}
```

## Installer

`ghostty-<version>-windows-x86_64-setup.exe` installs per user into
`%LOCALAPPDATA%\Programs\Ghostty` without UAC. It creates a Start menu
shortcut carrying the AppUserModelID `com.mitchellh.ghostty` and, unless
the task is unticked, an "Open Ghostty here" entry on the folder, folder
background and drive context menus. An all-users install into
`Program Files` is available from the elevation dialog or with
`/ALLUSERS`.

Silent install and uninstall:

```
ghostty-<version>-windows-x86_64-setup.exe /VERYSILENT /CURRENTUSER [/DIR="C:\path"] [/TASKS="contextmenu"]
"%LOCALAPPDATA%\Programs\Ghostty\unins000.exe" /VERYSILENT
```

Uninstalling removes the program files, shortcuts, context menu keys and
the uninstall entry. It leaves your configuration
(`%LOCALAPPDATA%\ghostty`, `%APPDATA%\ghostty`) in place.

Windows 11 shows "Open Ghostty here" under "Show more options"; the
top-level Windows 11 menu requires a packaged (MSIX) app.

## Configuration

The configuration file is `%APPDATA%\ghostty\config.ghostty`. Ghostty
creates it with a commented template on first run. A file named `config`
in the same folder is also read. `XDG_CONFIG_HOME`, if set, takes
precedence over `%APPDATA%`. Older builds used `%LOCALAPPDATA%\ghostty`;
files there are still read when nothing exists in `%APPDATA%\ghostty`.

`ctrl+,` opens the file (with the `.ghostty` file association if there is
one, otherwise `%VISUAL%`, `%EDITOR%` or Notepad) and `ctrl+shift+,`
reloads it. Errors are shown in a dialog at startup and on reload.
`ghostty +validate-config` checks the file from a console, and
`ghostty +show-config --default --docs` prints every option with its
documentation.

All options are documented on the
[Ghostty website](https://ghostty.org/docs/config). Options that only
apply to macOS or GTK are ignored.

## Shells

Without a `command` setting Ghostty starts the first of:

1. `pwsh.exe` (PowerShell 7) if it is on `PATH`,
2. Windows PowerShell 5.1
   (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`),
3. `cmd.exe` (`%COMSPEC%`).

To use something else set `command`, for example `command = cmd.exe`. The
value is split on whitespace and backslashes act as escape characters, so
write paths with forward slashes (`command = C:/msys64/usr/bin/fish.exe -l`)
or use the `direct:` prefix.

Shells see `TERM=xterm-256color` locally. When connecting to remote hosts via
`ghostty +ssh` (or via `ssh` in PowerShell, Bash, Zsh, Fish, Elvish, or Nushell
with `shell-integration-features = ssh-env,ssh-terminfo`), Ghostty automatically
compiles and caches the `xterm-ghostty` terminfo entry on the remote machine.

Shell integration is injected automatically for PowerShell 7, Windows
PowerShell 5.1 and `cmd.exe`. PowerShell gets prompt marks, exit codes,
working directory reporting (new tabs and splits open in the same folder)
and titles; `cmd.exe` gets prompt marks only. See
`src/shell-integration/README.md` in the Ghostty source for details and for
loading it manually. Set `shell-integration = none` to turn it off.

## Keybindings

The defaults match Ghostty on Linux. The most used ones:

| Keys                            | Action                |
| ------------------------------- | --------------------- |
| `ctrl+shift+c` / `ctrl+ins`     | Copy                  |
| `ctrl+shift+v`                  | Paste                 |
| `ctrl+shift+t`                  | New tab               |
| `ctrl+shift+n`                  | New window            |
| `ctrl+shift+w`                  | Close tab             |
| `alt+1` … `alt+8`, `alt+9`      | Go to tab N, last tab |
| `ctrl+tab`, `ctrl+pgdn`         | Next tab              |
| `ctrl+shift+o` / `ctrl+shift+e` | Split right / down    |
| `ctrl+alt+arrow`                | Move between splits   |
| `ctrl+enter`                    | Toggle fullscreen     |
| `ctrl+shift+q`                  | Quit                  |

`ghostty +list-keybinds --default` prints the full list.

## Logs

Ghostty is a GUI program, so it has no console of its own. To capture its
log, start it with standard error redirected to a file. From PowerShell:

```powershell
Start-Process ghostty.exe -RedirectStandardError "$env:TEMP\ghostty.log"
```

From `cmd.exe`:

```
ghostty.exe 2> %TEMP%\ghostty.log
```

Release builds log at `info` level and above; debug builds also log
`debug` messages and attach to the console they were started from.
`GHOSTTY_LOG=false` disables logging and `GHOSTTY_LOG=stderr` turns it back
on (see "Logging" in `HACKING.md`).

## Crash reports

When Ghostty crashes it writes a minidump (`.dmp`) to
`%LOCALAPPDATA%\ghostty\crash` (or `%XDG_STATE_HOME%\ghostty\crash` when
`XDG_STATE_HOME` is set). A Zig panic also writes a `.txt` file with the
panic message next to the dump. Nothing is sent anywhere.

List the reports from a console:

```
ghostty +crash-report
```

When reporting a crash, attach the `.dmp` (and `.txt`, if present) and
say which build you ran. Dumps are symbolised with the `ghostty.pdb` from
the same build, so keep it if you build Ghostty yourself.

> [!WARNING]
>
> A minidump contains the stack of every thread at the time of the crash
> and the memory those stacks point to, which can include terminal contents
> or other sensitive data. Review before sharing it publicly.

## Troubleshooting

- **SmartScreen warns about the installer or `ghostty.exe`.** If a build was
  produced without code-signing secrets configured (see
  [Code signing & automatic in-app updates](#code-signing--automatic-in-app-updates)),
  choose "More info", then "Run anyway".
- **Ghostty exits at start or shows no window.** Capture a log (see
  [Logs](#logs)) and look for OpenGL errors. Ghostty needs OpenGL 4.3; update
  the GPU driver, or see the remote desktop entry under
  [Known issues](#known-issues).
- **Themes or shell integration are missing.** The `share` folder is not
  where Ghostty expects it. Keep the zip layout intact or set
  `GHOSTTY_RESOURCES_DIR` to the `share\ghostty` folder.
  `ghostty +list-themes` is a quick check.
- **A font is not found.** `ghostty +list-fonts` lists the families
  Ghostty sees, from both the system and the per-user font folders.
- **`ghostty +new-tab` or `+new-window` does nothing or opens a separate
  instance.** The command talks to a running Ghostty with the same `class`.
  It cannot reach a Ghostty running elevated ("as administrator") from a
  non-elevated console, and the reverse.
- **Ctrl+C does not interrupt programs.** This happens when Ghostty itself
  was started by a process that ignores Ctrl+C; the setting is inherited
  by the shell. Start Ghostty from the Start menu, Explorer or a normal
  shell.

## Known issues

Platform limitations:

- **Remote desktop and virtual machines.** Without a GPU that provides
  OpenGL 4.3 (RDP sessions using the Microsoft Basic Render Driver, VMs
  without GPU acceleration) the renderer cannot start.
- **OSC 52 clipboard read** does not work: ConPTY does not forward the
  query to the terminal. OSC 52 clipboard writes work.
- **`copy-on-select = primary`**, the default outside Linux, does nothing
  because Windows has no selection clipboard. Set `copy-on-select =
clipboard` to copy selections to the clipboard.
- **win32-input-mode** (`CSI ? 9001 h`), which ConPTY requests at startup,
  is not supported. Input is sent as VT sequences instead.
- **Elevated and non-elevated instances** cannot talk to each other
  (`+new-tab`, `+new-window`), because Windows blocks the message from a
  lower integrity level.
- **Secure Input (`toggle_secure_input` / `auto-secure-input`)** is not
  available on Windows: unlike macOS (`EnableSecureEventInput`), standard
  user-mode Win32 processes cannot block same-integrity-level `WH_KEYBOARD_LL`
  hooks or `GetAsyncKeyState` polling without an Authenticode-signed
  `uiAccess="true"` manifest installed under `Program Files` or a kernel
  driver.
- The "Open Ghostty here" entry only appears under "Show more options".
- **Resizing without the bundled ConPTY** (`conpty.dll` and
  `OpenConsole.exe` missing from the `bin` folder) loses lines at the top
  and can garble the prompt, because the inbox console host repaints the
  screen after every resize. See "Bundled ConPTY" below.

Not implemented yet:

- **IME** (Japanese, Chinese, Korean input): implemented, including the
  candidate window at the cursor, but not yet verified with a real IME.
  Reports are welcome.
- **Color emoji** use the bundled Noto Color Emoji font. Segoe UI Emoji
  (COLR color font) is found but renders in grayscale if selected.
- **OSC 8 links** open only `http`, `https`, `mailto` and local `file`
  URLs (folders and non-executable files); other schemes are refused.
- `.fon` bitmap fonts are not listed.
- No winget package yet (see [Roadmap](#roadmap)). Only x86_64 builds are produced.

## Building a release

Requirements: Zig (see `build.zig.zon`), PowerShell 5.1+ and, for the
installer, Inno Setup 6
(`winget install --id JRSoftware.InnoSetup -e`). Setting up the Zig and
MSVC toolchain on Windows is described under "Windows" in `HACKING.md`.

```
zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -Dversion-string=1.2.3 -p build\release
pwsh -File dist\windows\make-zip.ps1 -Prefix build\release -OutDir build\dist
ISCC.exe /DAppVersion=1.2.3 /DSourceDir=build\dist\staging\ghostty /DOutputDir=build\dist dist\windows\installer\ghostty.iss
```

`-Doptimize=ReleaseFast` strips the executable by default. `make-zip.ps1`
reads the version from `ghostty.exe +version` unless `-Version` is given,
and writes entries in sorted order with a fixed timestamp so the same
inputs produce the same zip with the same PowerShell edition
(5.1 and 7 use different deflate implementations). The unpacked tree is
left in `<OutDir>\staging\ghostty` for the installer. `ISCC.exe` is not
long-path aware, so keep `OutDir` short enough that
`staging\ghostty\share\...` stays under 260 characters.

### Bundled ConPTY

Releases should ship `conpty.dll` and `OpenConsole.exe` from Microsoft's
MIT-licensed [`Microsoft.Windows.Console.ConPTY`](https://www.nuget.org/packages/Microsoft.Windows.Console.ConPTY)
NuGet package next to `ghostty.exe`. When they are present Ghostty uses
them instead of the ConPTY built into Windows; without them it falls back
to the inbox `conhost.exe`, which repaints the whole screen after every
resize and garbles reflowed output and multi-line prompts. They are not
checked into the repository. `make-zip.ps1` downloads the pinned package
version by default (checked against a pinned SHA-256). Use
`-ConptyVersion <v>` to pick another version, `-ConptyDir <dir>` to take
both files from a local folder, or `-NoConpty` to leave them out. Output
goes to `dist\windows\out\` (git-ignored) unless `-OutDir` is given:

```
pwsh -File dist\windows\make-zip.ps1 -Prefix build\release
```

The pinned default is `1.25.260710002-preview`: 1.25 is the first version
that resynchronises the cursor after a resize, and it is still a preview
on NuGet. Move the default to the first stable 1.25 release when one
ships.

The installer packages whatever `bin\` holds in the staged tree. Version
1.25 or newer is needed for correct resizing: older versions do not
resynchronise the cursor with the terminal after a resize. For a dev
build, copy the two files into `zig-out\bin`.

## Code signing & automatic in-app updates

### Automatic in-app updates (`check_for_updates`)

Open the Command Palette (`ctrl+shift+p`) and run **Check for Updates**. Ghostty queries the GitHub Releases API over `WinHTTP`:

1. Detects whether Ghostty is running from an **Inno Setup installation** (`unins000.exe` present in the parent directory) or a **Portable ZIP** layout (`share\ghostty` present without `unins000.exe`).
2. When a newer release is available and you click **Install & Restart**, Ghostty downloads `SHA256SUMS.txt` and the matching asset (`Ghostty-Windows-Setup-x64.exe` or `Ghostty-Windows-x64.zip`) into `%TEMP%\ghostty-update-<tick>`.
3. Verifies the downloaded file's SHA-256 digest against `SHA256SUMS.txt` before executing or extracting anything.
4. Applies the update:
   - **Installer mode:** Launches `Ghostty-Windows-Setup-x64.exe /SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /NOCANCEL /SP-` and exits so the installer upgrades and relaunches Ghostty automatically.
   - **Portable mode:** Extracts the verified ZIP, renames the running `ghostty.exe` to `ghostty.exe.old` (cleaned up on next launch), copies the updated tree into the portable folder after exit, and restarts `ghostty.exe`.

### Code signing (`dist/windows/sign-file.ps1`)

The release workflow (`.github/workflows/release-windows.yml`) signs `ghostty.exe` prior to `make-zip.ps1` and signs `ghostty-<version>-windows-x86_64-setup.exe` prior to generating `SHA256SUMS.txt` using `dist/windows/sign-file.ps1`.

Two signing modes are supported via GitHub Actions repository secrets (or local environment variables):

1. **Azure Trusted Signing (OIDC or Service Principal):**
   Set `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT`, `AZURE_CERT_PROFILE`, and Azure credentials (`AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and OIDC or `AZURE_CLIENT_SECRET`). `sign-file.ps1` automatically fetches `Microsoft.Trusted.Signing.Client` (`Azure.CodeSigning.Dlib.dll`), signs with `http://timestamp.acs.microsoft.com`, and runs `signtool verify /pa`.
2. **Base64 PFX Certificate:**
   Set `WINDOWS_PFX_BASE64` and `WINDOWS_PFX_PASSWORD`. `sign-file.ps1` decodes the PFX to a temporary file, signs via `signtool.exe sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256`, verifies with `signtool verify /pa`, and securely removes the temporary PFX.

If neither secret is configured (for example on unconfigured community forks), `sign-file.ps1` logs a notice and exits `0` so CI builds still succeed.

## Roadmap

- **Phase 1 (Shipped):**
  - Prebuilt Authenticode signing pipeline (`dist/windows/sign-file.ps1` supporting Azure Trusted Signing OIDC and PFX certificates).
  - SHA-256 verified automatic in-app updates (`check_for_updates`) for both Inno Setup installer and Portable ZIP installations.
- **Phase 2 (Next):**
  - **DirectX 11 / D3D12 + Microsoft WARP Software Fallback Renderer:** Support GPU-less virtual machines (Hyper-V, VMware, QEMU), Windows Sandbox, and Remote Desktop (RDP) sessions where the Microsoft Basic Render Driver does not provide OpenGL 4.3, plus native DirectComposition transparency and HDR.
  - **WinGet Package (`microsoft/winget-pkgs`):** Automated manifest submission with `InstallerType: inno` and `Scope: user`.
- **Phase 3 (Planned):**
  - **Taskbar Jump Lists & Shell Auto-Discovery (`ICustomDestinationList`):** Jump List actions (_New Window_, _New Tab_, _Open Configuration_) and auto-discovered profiles for PowerShell 7, Windows PowerShell 5.1, `cmd.exe`, WSL distributions, Git Bash, and MSYS2.
  - **Session Restore (`window-save-state`):** Persist and restore windows, tabs, splits, and working directories across restarts.
  - **Windows UI Automation (`UIAutomationCore.dll`):** Screen-reader accessibility (`IRawElementProviderSimple` / `ITextProvider`) for Windows Narrator and NVDA.
