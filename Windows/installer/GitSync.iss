; GitSync for Windows — per-user installer (no administrator rights needed).
#define AppVersion GetEnv("GITSYNC_VERSION")
#if AppVersion == ""
  #define AppVersion "1.0.0"
#endif
#define Arch GetEnv("GITSYNC_ARCH")
#if Arch == ""
  #define Arch "x64"
#endif

[Setup]
AppId={{6E2B7F1C-6A3D-4C0B-9C51-2B1E6B5D9F01}
AppName=GitSync
AppVersion={#AppVersion}
AppPublisher=Atonettt
AppPublisherURL=https://github.com/Atonettt/GitCloudSync
DefaultDirName={localappdata}\Programs\GitSync
DefaultGroupName=GitSync
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\artifacts
OutputBaseFilename=GitSync-Setup-{#Arch}
SetupIconFile=..\src\GitSync.App\Assets\GitSync.ico
UninstallDisplayIcon={app}\GitSync.exe
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed={#Arch}compatible
ArchitecturesInstallIn64BitMode={#Arch}compatible
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.DesktopIcon=在桌面创建快捷方式
english.DesktopIcon=Create a desktop shortcut
chinesesimplified.Launch=启动 GitSync
english.Launch=Start GitSync

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; Flags: unchecked

[Files]
Source: "..\publish\{#Arch}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{userprograms}\GitSync"; Filename: "{app}\GitSync.exe"
Name: "{userdesktop}\GitSync"; Filename: "{app}\GitSync.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\GitSync.exe"; Description: "{cm:Launch}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM GitSync.exe /F"; Flags: runhidden; RunOnceId: "StopGitSync"

[Registry]
; Start at login is managed by the app; remove its entry on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "GitSync"; Flags: uninsdeletevalue dontcreatekey
