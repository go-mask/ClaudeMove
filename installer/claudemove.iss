; ClaudeMove Windows 安裝程式 (Inno Setup 6)
#define AppVer "0.7.1"

[Setup]
AppId={{7C3E9B42-5A8D-4F1E-9C64-2B0D8E7A5310}
AppName=ClaudeMove
AppVersion={#AppVer}
AppPublisher=ClaudeMove Project
DefaultDirName={autopf}\ClaudeMove
DefaultGroupName=ClaudeMove
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=ClaudeMove-Setup-{#AppVer}
SetupIconFile=..\claudemove.ico
UninstallDisplayIcon={app}\claudemove.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
ShowLanguageDialog=no

[Tasks]
Name: "desktopicon"; Description: "建立桌面捷徑 (Create desktop shortcut)"; GroupDescription: "其他 (Additional):"

[Files]
Source: "..\claudemove.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\claudemove-gui.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ClaudeMove-GUI.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\ClaudeMove-GUI.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\claudemove.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\ClaudeMove.psm1"; DestDir: "{app}\src"; Flags: ignoreversion

[Icons]
Name: "{group}\ClaudeMove"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\ClaudeMove-GUI.vbs"""; IconFilename: "{app}\claudemove.ico"; WorkingDir: "{app}"
Name: "{autodesktop}\ClaudeMove"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\ClaudeMove-GUI.vbs"""; IconFilename: "{app}\claudemove.ico"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\ClaudeMove-GUI.vbs"""; Description: "啟動 ClaudeMove (Launch ClaudeMove)"; Flags: postinstall nowait skipifsilent

[Code]
function InitializeSetup(): Boolean;
var
  R: Integer;
begin
  Result := True;
  if Exec(ExpandConstant('{cmd}'), '/c where pwsh >nul 2>nul', '', SW_HIDE, ewWaitUntilTerminated, R) then
  begin
    if R <> 0 then
      MsgBox('未偵測到 PowerShell 7 (pwsh),ClaudeMove 需要它才能執行。' + #13#10 +
             '請先安裝: winget install Microsoft.PowerShell' + #13#10#13#10 +
             '(仍可繼續安裝,之後再補裝 pwsh)', mbInformation, MB_OK);
  end;
end;
