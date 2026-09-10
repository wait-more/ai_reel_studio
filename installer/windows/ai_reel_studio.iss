; AIReelStudio Windows installer (Inno Setup 6/7+)
; Build with: ISCC.exe installer\windows\ai_reel_studio.iss
; Or via:     powershell -File scripts\pack_windows.ps1
; MyReleaseDir 由打包脚本传入（默认 Release；也可用 -Configuration Debug）

#define MyAppName "AIReelStudio"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#define MyAppPublisher "AIReelStudio"
#define MyAppExeName "ai_reel_studio.exe"
#ifndef MyReleaseDir
  #define MyReleaseDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef MyOutputDir
  #define MyOutputDir "..\..\dist"
#endif

[Setup]
; {{…} → 字面量 {…}（与已发布安装包 AppId 保持一致，勿改）
AppId={{A1B2C3D4-E5F6-4789-ABCD-AIREELSTUDIO01}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; 已安装时默认沿用上次目录，并隐藏目录页（未装过仍显示）
UsePreviousAppDir=yes
UsePreviousPrivileges=yes
DisableDirPage=auto
OutputDir={#MyOutputDir}
OutputBaseFilename=AIReelStudio-{#MyAppVersion}-Setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 与现网安装一致：写入 HKLM，升级才能识别 Program Files 下的旧版
PrivilegesRequired=admin
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 排除调试符号与本地痕迹（不限定必须是 Release）
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,.aireel*,*.log,*.tmp"

[Icons]
; 使用 exe 内嵌图标，避免单独 IconFilename 在部分环境触发 ShellExecuteEx(87)
; PrivilegesRequired=lowest 时用 {autoprograms}/{autodesktop} 更稳妥
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
