; DingCam-Setup.exe: a normal Windows installer for the DingCam PC helper (no terminal, no zip, no admin rights).
; Built by build\Build-Setup.ps1 (which passes /DVer=<version> and stages the stamped helper files).
; It copies the helper scripts to {app}, then runs the same Install-DingCam.ps1 as the zip does (hidden) and shows
; its report on a page. Uninstall is in Windows Settings > Apps; it runs Uninstall-DingCam.ps1 (hidden).

#ifndef AppVer
  #define AppVer "0.0.0"
#endif

[Setup]
AppId={{6B3D2F1E-7C4A-4E2B-9A61-D1C9A0E5B7F3}
AppName=DingCam
AppVersion={#AppVer}
AppVerName=DingCam {#AppVer}
AppPublisher=Holmstein
AppPublisherURL=https://github.com/Holmstien/DingCam
AppSupportURL=https://github.com/Holmstien/DingCam/issues
AppUpdatesURL=https://github.com/Holmstien/DingCam/releases/latest
DefaultDirName={localappdata}\DingCam\setup
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
DisableWelcomePage=no
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=DingCam-Setup-{#AppVer}
SetupIconFile=stage\DingCam.ico
UninstallDisplayIcon={app}\DingCam.ico
UninstallDisplayName=DingCam
WizardStyle=modern
WizardImageFile=stage\wizard.bmp
WizardSmallImageFile=stage\wizard-small.bmp
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no

[Messages]
WelcomeLabel2=This sets up the free DingCam helper, which saves a video clip of your level-ups, boss and rare kills in WoW Forever and files every picture in your Journey folder.%n%nIt runs quietly in the background, starts with Windows, and never touches the game.%n%nYou'll also need the DingCam addon from CurseForge.
FinishedHeadingLabel=DingCam is ready
FinishedLabelNoIcons=All set! In game, type /dingcam test to save a test clip.%n%nTo update later, open Update DingCam from the Start menu. To remove it: Windows Settings > Apps > DingCam > Uninstall. Your clips and pictures are always kept.
FinishedLabel=All set! In game, type /dingcam test to save a test clip.%n%nTo update later, open Update DingCam from the Start menu. To remove it: Windows Settings > Apps > DingCam > Uninstall. Your clips and pictures are always kept.

[Files]
Source: "stage\helper\*"; DestDir: "{app}"; Flags: ignoreversion
Source: "stage\DingCam.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\Update DingCam"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Update-DingCam.vbs"""; IconFilename: "{app}\DingCam.ico"; Comment: "Check for a newer DingCam and install it"

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Uninstall-DingCam.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "DingCamHelperUninstall"

[Code]
var
  ReportPage: TOutputMsgMemoWizardPage;
  OldVersion: String;

// The DingCam helper already on this PC, if any: from an earlier DingCam-Setup (its Apps entry) or from the old zip
// installer (the version line inside the installed helper script). '' when there is none.
function InstalledVersion(): String;
var
  Lines: TArrayOfString;
  I, P: Integer;
  S: String;
begin
  Result := '';
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{6B3D2F1E-7C4A-4E2B-9A61-D1C9A0E5B7F3}_is1', 'DisplayVersion', S) then
  begin
    Result := S;
    exit;
  end;
  if LoadStringsFromFile(ExpandConstant('{localappdata}\DingCam\app\DingCam-Helper.ps1'), Lines) then
    for I := 0 to GetArrayLength(Lines) - 1 do
    begin
      S := Trim(Lines[I]);
      if Pos('$Version = ''', S) = 1 then
      begin
        S := Copy(S, 13, Length(S));
        P := Pos('''', S);
        if P > 0 then Result := Copy(S, 1, P - 1) else Result := S;
        exit;
      end;
    end;
end;

// On the Welcome page the button says Update (or Repair) when DingCam is already installed, Install otherwise.
procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpWelcome then
  begin
    if OldVersion = '' then WizardForm.NextButton.Caption := 'Install'
    else if OldVersion = '{#AppVer}' then WizardForm.NextButton.Caption := 'Repair'
    else WizardForm.NextButton.Caption := 'Update';
  end;
end;

procedure InitializeWizard;
var
  Old: String;
begin
  Old := InstalledVersion();
  OldVersion := Old;
  if Old <> '' then
  begin
    WizardForm.WelcomeLabel1.Caption := 'Update DingCam';
    if Old = '{#AppVer}' then
      WizardForm.WelcomeLabel2.Caption := 'DingCam {#AppVer} is already on this PC. Click Next to repair it (reinstall the same version).' + #13#10#13#10 + 'Your settings and your Journey folder (clips and pictures) are kept.'
    else
      WizardForm.WelcomeLabel2.Caption := 'This updates the DingCam helper on this PC from ' + Old + ' to {#AppVer}.' + #13#10#13#10 + 'Your settings and your Journey folder (clips and pictures) are kept. The helper restarts by itself.';
  end;
  ReportPage := CreateOutputMsgMemoPage(wpInstalling, 'Your setup',
    'Here''s what DingCam found on your PC.',
    'Anything marked with ! needs a quick fix (it says how). Everything else is ready.', '');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Rc: Integer;
  Report: AnsiString;
  Text: String;
  Cmd: String;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Starting the DingCam helper and checking your setup...';
    Cmd := '/C powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
           ExpandConstant('{app}\Install-DingCam.ps1') + '" -FromSetup > "' + ExpandConstant('{tmp}\report.txt') + '" 2>&1';
    if not Exec(ExpandConstant('{cmd}'), Cmd, '', SW_HIDE, ewWaitUntilTerminated, Rc) then
      Text := 'Could not run the DingCam setup step. Please run this installer again.'
    else if LoadStringFromFile(ExpandConstant('{tmp}\report.txt'), Report) then
    begin
      Text := String(Report);
      StringChangeEx(Text, 'DingCam installer', '', True);
      StringChangeEx(Text, '  [OK] ', '  OK   ', True);
      StringChangeEx(Text, '  [!!] ', '  !    ', True);
      Text := Trim(Text);
    end
    else
      Text := 'DingCam was installed, but its setup report could not be read.';
    ReportPage.RichEditViewer.Lines.Text := Text;
  end;
end;
