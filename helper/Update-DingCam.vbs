' Opens the "Update DingCam" window with no console window. Installed by DingCam-Setup.exe (Start menu shortcut).
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\Update-DingCam.ps1""", 0, False
