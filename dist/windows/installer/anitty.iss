#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<staged anitty folder containing bin\ and share\>
#endif
#ifndef OutputDir
  #define OutputDir "..\out"
#endif
#ifndef Arch
  #define Arch "x86_64"
#endif

#define AppName "Anitty"
#define AppExe "anitty.exe"
#define AppUserModelID "dev.recursivefunctions.anitty"

[Setup]
AppId={{6B3C1E0A-5F7D-4C43-9E0B-2B1D8A7F4C21}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Anitty contributors
AppPublisherURL=https://github.com/RecursiveFunctions/anitty
AppSupportURL=https://github.com/RecursiveFunctions/anitty/issues
AppUpdatesURL=https://github.com/RecursiveFunctions/anitty/releases
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
LicenseFile={#SourceDir}\LICENSE
SetupIconFile={#SourcePath}\..\anitty.ico
UninstallDisplayIcon={app}\bin\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename=anitty-{#AppVersion}-windows-{#Arch}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ChangesAssociations=yes
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "contextmenu"; Description: "Add ""Open Anitty here"" to the folder context menu"; GroupDescription: "Explorer integration:"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\share\*"; DestDir: "{app}\share"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README-windows.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\THIRD-PARTY-NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\licenses\*"; DestDir: "{app}\licenses"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{app}\bin\anitty.exe.old"
Type: files; Name: "{app}\bin\ghostty.exe.old"
Type: files; Name: "{app}\bin\ghostty.exe"
Type: files; Name: "{app}\bin\ghostty.pdb"
Type: files; Name: "{app}\bin\conpty.dll"
Type: files; Name: "{app}\bin\OpenConsole.exe"
Type: files; Name: "{autoprograms}\Ghostty.lnk"
Type: files; Name: "{autodesktop}\Ghostty.lnk"
Type: filesandordirs; Name: "{app}\share\ghostty"
Type: filesandordirs; Name: "{app}\share\locale"
Type: filesandordirs; Name: "{app}\share\terminfo"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\bin\{#AppExe}"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AppUserModelID}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\bin\{#AppExe}"; WorkingDir: "{%USERPROFILE}"; AppUserModelID: "{#AppUserModelID}"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Ghostty"; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Ghostty"; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Drive\shell\Ghostty"; Flags: deletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Anitty"; ValueType: string; ValueName: ""; ValueData: "Open Anitty here"; Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Anitty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\{#AppExe}"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\Background\shell\Anitty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"" ""--working-directory=%V\."""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Anitty"; ValueType: string; ValueName: ""; ValueData: "Open Anitty here"; Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Directory\shell\Anitty"; ValueType: string; ValueName: "Icon"; ValueData: """{app}\bin\{#AppExe}"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Directory\shell\Anitty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"" ""--working-directory=%V\."""; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Drive\shell\Anitty"; ValueType: string; ValueName: ""; ValueData: "Open Anitty here"; Tasks: contextmenu; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Drive\shell\Anitty"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"",0"; Tasks: contextmenu
Root: HKA; Subkey: "Software\Classes\Drive\shell\Anitty\command"; ValueType: string; ValueName: ""; ValueData: """{app}\bin\{#AppExe}"" ""--working-directory=%V\."""; Tasks: contextmenu

[Run]
Filename: "{app}\bin\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; WorkingDir: "{%USERPROFILE}"; Flags: nowait postinstall skipifsilent
Filename: "{app}\bin\{#AppExe}"; WorkingDir: "{%USERPROFILE}"; Flags: nowait; Check: ShouldRelaunchAfterSilentInstall

[Code]
function ShouldRelaunchAfterSilentInstall: Boolean;
var
  I: Integer;
begin
  Result := False;
  if not WizardSilent then Exit;
  for I := 1 to ParamCount do
  begin
    if CompareText(ParamStr(I), '/RESTARTAPPLICATIONS') = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;
