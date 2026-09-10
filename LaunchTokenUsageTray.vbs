Option Explicit

Dim shell, fso, scriptDirectory, trayScript, powerShellPath, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fso.GetParentFolderName(WScript.ScriptFullName)
trayScript = fso.BuildPath(scriptDirectory, "TokenUsageTray.ps1")
powerShellPath = "C:\Program Files\PowerShell\7\pwsh.exe"

If Not fso.FileExists(powerShellPath) Then
    powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
End If

command = Chr(34) & powerShellPath & Chr(34) & _
    " -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & _
    Chr(34) & trayScript & Chr(34)

shell.Run command, 0, False
