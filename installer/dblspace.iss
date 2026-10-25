; dblspace.iss - Inno Setup 6 script for DblSpace
; Build: run build.bat from the repo root. Paths below are relative to this
; installer\ folder: the app is built into ..\dist, which is also where the
; finished setup .exe goes.
;
; - Installs for the current user only (AppData\Local\Programs\DblSpace),
;   so no admin / UAC prompt.
; - Closes a running DblSpace before installing or uninstalling.
; - Optional "start when I sign in" (same registry value the tray menu's
;   "Start with Windows" uses, so the two stay in sync).
; - Uninstall removes the app, its Start menu entry, auto-start and settings.

#define AppName    "DblSpace"
#define AppExe     "dblspace.exe"
#define DistDir    AddBackslash(SourcePath) + "..\dist"
; Version comes from the exe's version resource (src\dblspace.rc)
#define AppVersion GetStringFileInfo(DistDir + "\" + AppExe, "ProductVersion")

[Setup]
; AppId identifies the app for upgrades/uninstall - never change it
AppId={{0169A258-4F45-44F3-BB2B-205DE69A5BD9}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppComments=Double-tap Space to type a period, like on a Mac
AppPublisher=Christopher Martinez
AppCopyright=Copyright (c) 2026 Christopher Martinez
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#DistDir}
OutputBaseFilename={#AppName}-Setup-{#AppVersion}
SetupIconFile=..\src\dblspace.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
; We close the app ourselves (see [Code]), so no "files in use" dialog
CloseApplications=no

[Tasks]
Name: autostart; Description: "Start {#AppName} when I sign in to Windows"

[Files]
Source: "{#DistDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; Comment: "Double-tap Space to type a period"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; \
    ValueName: "DblSpace"; ValueData: """{app}\{#AppExe}"""; Tasks: autostart

[Run]
Filename: "{app}\{#AppExe}"; Description: "Start {#AppName} now"; Flags: nowait postinstall skipifsilent

[Code]
const
  WM_CLOSE    = $0010;
  RUN_KEY     = 'Software\Microsoft\Windows\CurrentVersion\Run';
  APP_MUTEX   = 'DblSpace_SingleInstance';

{ Ask a running DblSpace to exit (removes its tray icon cleanly) and wait
  up to 5 seconds for it to go away. }
procedure CloseRunningApp();
var
  h: HWND;
  i: Integer;
begin
  h := FindWindowByClassName('DblSpaceWnd');
  if h = 0 then Exit;
  PostMessage(h, WM_CLOSE, 0, 0);
  for i := 1 to 50 do
  begin
    if not CheckForMutexes(APP_MUTEX) then Exit;
    Sleep(100);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseRunningApp();
  if CheckForMutexes(APP_MUTEX) then
    Result := 'DblSpace is still running. Exit it from its tray icon and try again.'
  else
    Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  { Upgrading with auto-start unticked: remove an existing auto-start entry }
  if (CurStep = ssPostInstall) and not WizardIsTaskSelected('autostart') then
    RegDeleteValue(HKCU, RUN_KEY, 'DblSpace');
end;

function InitializeUninstall(): Boolean;
begin
  CloseRunningApp();
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    { The tray menu can turn auto-start on by itself, so always clean up }
    RegDeleteValue(HKCU, RUN_KEY, 'DblSpace');
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\DblSpace');
  end;
end;
