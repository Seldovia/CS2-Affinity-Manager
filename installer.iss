#define MyAppName "CS2 Affinity Manager"
#define MyAppVersion "1.9.4"
#define MyAppExeName "CS2-AffinityManager.exe"
#define MyAppPublisher "Sel"

[Setup]
AppId={{B7D9F2A1-4C3E-4F8A-9D2B-1A6E5C8F3D71}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=CS2-AffinityManager-Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=icon.ico
UninstallDisplayIcon={app}\CS2-AffinityManager.exe
AppendDefaultDirName=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "CS2-AffinityManager.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "icon.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Start Menu only. No desktop shortcut and no [Tasks] entry offering one --
; this runs from a Task Scheduler trigger when cs2.exe launches, so a desktop
; icon would just be clutter.
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
; Task Scheduler registration is delegated entirely to the exe's own
; -installtask logic so the trigger-building code lives in one place only.
Filename: "{app}\{#MyAppExeName}"; Parameters: "-installtask"; Flags: runhidden waituntilterminated; StatusMsg: "Registering auto-start trigger..."
Filename: "{app}\{#MyAppExeName}"; Parameters: "-configureNow"; Description: "Configure CS2 Affinity Manager now"; Flags: postinstall skipifsilent nowait; Check: WantsCustomizeNow

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""CS2 Affinity Manager Trigger"" /F"; Flags: runhidden; RunOnceId: "DelCS2Task"

[Code]
var
  FinalPage: TWizardPage;
  RecommendedRadio: TRadioButton;
  CustomizeRadio: TRadioButton;
  RecommendedInfoLabel: TLabel;
  CustomizeInfoLabel: TLabel;
  CpuName: String;
  CpuCores, CpuThreads: Integer;
  RecommendedTier: String;
  CpuSupported: Boolean;

procedure DetectCpu;
var
  ResultCode: Integer;
  TempFile, Script, Line: String;
  Lines: TArrayOfString;
  PipePos1, PipePos2: Integer;
  RegName: String;
  EnvThreads: Integer;
begin
  CpuCores := 0;
  CpuThreads := 0;
  CpuName := '';
  TempFile := ExpandConstant('{tmp}\cpuinfo.txt');

  Script :=
    '$c = Get-CimInstance Win32_Processor; ' +
    'if (-not $c) { $c = Get-WmiObject Win32_Processor }; ' +
    '$c = $c | Select-Object -First 1; ' +
    '$co = $c.NumberOfCores; ' +
    'if (-not $co -or $co -lt 1) { $co = $c.NumberOfLogicalProcessors }; ' +
    '$th = $c.NumberOfLogicalProcessors; ' +
    '$nm = $c.Name.Trim(); ' +
    '$out = $nm + ''|'' + [string]$co + ''|'' + [string]$th; ' +
    '[IO.File]::WriteAllText(''' + TempFile + ''', $out)';

  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
          '-NoProfile -ExecutionPolicy Bypass -Command "' + Script + '"',
          '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    if LoadStringsFromFile(TempFile, Lines) and (GetArrayLength(Lines) > 0) then
    begin
      Line := Trim(Lines[0]);
      PipePos1 := Pos('|', Line);
      if PipePos1 > 0 then
      begin
        CpuName := Copy(Line, 1, PipePos1 - 1);
        Delete(Line, 1, PipePos1);
        PipePos2 := Pos('|', Line);
        if PipePos2 > 0 then
        begin
          CpuCores  := StrToIntDef(Copy(Line, 1, PipePos2 - 1), 0);
          CpuThreads := StrToIntDef(Copy(Line, PipePos2 + 1, Length(Line)), 0);
        end;
      end;
    end;
  end;

  // Registry + env-var fallback if PowerShell probe fails
  if (CpuCores = 0) or (CpuThreads = 0) or (Length(CpuName) = 0) then
  begin
    if RegQueryStringValue(HKEY_LOCAL_MACHINE,
        'HARDWARE\DESCRIPTION\System\CentralProcessor\0',
        'ProcessorNameString', RegName) then
      CpuName := Trim(RegName)
    else
      CpuName := 'Generic x64 Processor';
    EnvThreads := StrToIntDef(GetEnv('NUMBER_OF_PROCESSORS'), 8);
    if EnvThreads > 0 then
    begin
      CpuThreads := EnvThreads;
      CpuCores   := EnvThreads div 2;
      if CpuCores < 1 then CpuCores := 1;
    end;
  end;

  if (CpuCores = 0) or (CpuThreads = 0) then
  begin
    CpuName    := 'Unknown CPU';
    CpuSupported := False;
  end;

  // Mirrors Get-RecommendedTierName in CS2-AffinityManager.ps1 v1.8.
  // Profile order of preference:
  //   Intel hybrid   -> Intel Hybrid   (P-cores game, E-cores background)
  //   multi-CCD AMD  -> Single Die     (keep the game inside one chiplet)
  //   4+ cores       -> Standard
  //   anything less  -> Balanced       (no isolation; holding threads back hurts)
  //
  // v1.8 dropped the hard 4-32 core support window. The script now handles any
  // CPU with 2+ threads, so the installer no longer refuses to recommend.
  // Intel hybrid detection: E-cores lack HT, so P-cores = threads - cores.
  if CpuThreads >= 2 then
  begin
    CpuSupported := True;
    if (Pos('Intel', CpuName) > 0) and (CpuThreads < CpuCores * 2)
       and (CpuThreads > CpuCores) and (CpuCores > 6) then
      RecommendedTier := 'Intel Hybrid'
    else if (Pos('AMD', CpuName) > 0) and (CpuCores > 8) then
      RecommendedTier := 'Single Die (CCD0)'
    else if CpuCores >= 4 then
      RecommendedTier := 'Standard'
    else
      RecommendedTier := 'Balanced';
  end
  else
    CpuSupported := False;
end;

procedure InitializeWizard;
var
  W, Col1X, Col2X, ColW: Integer;
begin
  DetectCpu;

  FinalPage := CreateCustomPage(wpSelectTasks, 'Configuration',
    'Choose how CS2 Affinity Manager should be set up.');

  W    := FinalPage.SurfaceWidth;
  // Two-column layout: left = option title + radio, right = description
  Col1X := 0;
  Col2X := 160;
  ColW  := W - Col2X - 4;

  // ---- OPTION 1: Recommended ----
  RecommendedRadio := TRadioButton.Create(FinalPage);
  RecommendedRadio.Parent  := FinalPage.Surface;
  RecommendedRadio.Top     := 8;
  RecommendedRadio.Left    := Col1X;
  RecommendedRadio.Width   := Col2X - 8;
  RecommendedRadio.Caption := 'Use Recommended';
  RecommendedRadio.Checked := CpuSupported;
  RecommendedRadio.Enabled := CpuSupported;

  RecommendedInfoLabel := TLabel.Create(FinalPage);
  RecommendedInfoLabel.Parent    := FinalPage.Surface;
  RecommendedInfoLabel.Top       := 6;
  RecommendedInfoLabel.Left      := Col2X;
  RecommendedInfoLabel.Width     := ColW;
  RecommendedInfoLabel.AutoSize  := False;
  RecommendedInfoLabel.Height    := 80;
  RecommendedInfoLabel.WordWrap  := True;
  if CpuSupported then
    RecommendedInfoLabel.Caption :=
      CpuName + #13#10 +
      Format('%d cores / %d threads  -  Plan: %s', [CpuCores, CpuThreads, RecommendedTier]) + #13#10 +
      'App auto-launches with CS2. No further setup needed.'
  else
    RecommendedInfoLabel.Caption :=
      CpuName + #13#10 +
      Format('%d cores / %d threads', [CpuCores, CpuThreads]) + #13#10 +
      'CPU topology could not be read. Manual setup required.';

  // ---- DIVIDER ----

  // ---- OPTION 2: Customize ----
  CustomizeRadio := TRadioButton.Create(FinalPage);
  CustomizeRadio.Parent  := FinalPage.Surface;
  CustomizeRadio.Top     := 110;
  CustomizeRadio.Left    := Col1X;
  CustomizeRadio.Width   := Col2X - 8;
  CustomizeRadio.Caption := 'Customize';
  CustomizeRadio.Checked := not CpuSupported;

  CustomizeInfoLabel := TLabel.Create(FinalPage);
  CustomizeInfoLabel.Parent   := FinalPage.Surface;
  CustomizeInfoLabel.Top      := 108;
  CustomizeInfoLabel.Left     := Col2X;
  CustomizeInfoLabel.Width    := ColW;
  CustomizeInfoLabel.AutoSize := False;
  CustomizeInfoLabel.Height   := 60;
  CustomizeInfoLabel.WordWrap := True;
  CustomizeInfoLabel.Caption  :=
    'Opens the configuration window on first launch.' + #13#10 +
    'Choose isolation plan, thread assignments, and exceptions.';
end;

function WantsCustomizeNow: Boolean;
begin
  Result := CustomizeRadio.Checked or (not CpuSupported);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = FinalPage.ID) and (not CpuSupported) and RecommendedRadio.Checked then
  begin
    MsgBox('This CPU requires manual setup. Please select "Customize".', mbInformation, MB_OK);
    Result := False;
  end;
end;

// NOTE: {localappdata} under PrivilegesRequired=admin resolves to the account
// that cleared the UAC prompt. On a normal single-user machine that is the
// right profile. On a shared or domain machine where an admin installs for
// someone else, this seeds the admin's config instead -- harmless, because the
// app writes its own defaults on first run for whoever actually launches it.
procedure WriteInitialConfig;
var
  ConfigDir, ConfigPath, Json: String;
begin
  ConfigDir  := ExpandConstant('{localappdata}\CS2-AffinityManager');
  ConfigPath := ConfigDir + '\config.json';

  // Never clobber an existing config on an upgrade or reinstall -- that would
  // silently wipe custom thread assignments. The only case where overwriting
  // is correct is when the user explicitly picked "Recommended" on the wizard
  // page, which is a deliberate request to reset to defaults.
  if FileExists(ConfigPath) and (not RecommendedRadio.Checked) then
    exit;

  ForceDirectories(ConfigDir);

  if RecommendedRadio.Checked and CpuSupported then
    Json :=
      '{' + #13#10 +
      '  "planTier": "Auto",' + #13#10 +
      '  "pinningMode": "Both",' + #13#10 +
      '  "theme": "Toothpaste",' + #13#10 +
      '  "userExceptions": [],' + #13#10 +
      '  "customCs2Threads": [],' + #13#10 +
      '  "customBgThreads": [],' + #13#10 +
      '  "needsConfiguration": false,' + #13#10 +
      '  "configPending": false,' + #13#10 +
      '  "savedCpuCores": ' + IntToStr(CpuCores) + ',' + #13#10 +
      '  "savedCpuThreads": ' + IntToStr(CpuThreads) + #13#10 +
      '}'
  else
    Json :=
      '{' + #13#10 +
      '  "planTier": "Auto",' + #13#10 +
      '  "pinningMode": "Both",' + #13#10 +
      '  "theme": "Toothpaste",' + #13#10 +
      '  "userExceptions": [],' + #13#10 +
      '  "customCs2Threads": [],' + #13#10 +
      '  "customBgThreads": [],' + #13#10 +
      '  "needsConfiguration": true,' + #13#10 +
      '  "configPending": false,' + #13#10 +
      '  "savedCpuCores": ' + IntToStr(CpuCores) + ',' + #13#10 +
      '  "savedCpuThreads": ' + IntToStr(CpuThreads) + #13#10 +
      '}';

  SaveStringToFile(ConfigPath, Json, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WriteInitialConfig;
end;
