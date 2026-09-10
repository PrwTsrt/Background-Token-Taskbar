Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Unregister-ScheduledTask -TaskName 'Codex Token Usage Tray' -Confirm:$false -ErrorAction SilentlyContinue
$startupShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Token Usage Tray.lnk'
Remove-Item -LiteralPath $startupShortcut -Force -ErrorAction SilentlyContinue

$runKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runKeyPath, $true)
try {
    if ($null -ne $runKey) {
        $runKey.DeleteValue('CodexTokenUsageTray', $false)
    }
}
finally {
    if ($null -ne $runKey) { $runKey.Dispose() }
}

$stateDirectory = Join-Path $env:LOCALAPPDATA 'CodexTokenUsageTray'
$pidPath = Join-Path $stateDirectory 'app.pid'
if (Test-Path -LiteralPath $pidPath) {
    $trayPid = [int](Get-Content -Raw -LiteralPath $pidPath).Trim()
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $trayPid" -ErrorAction SilentlyContinue
    if ($null -ne $processInfo -and $processInfo.CommandLine -match 'TokenUsageTray\.ps1') {
        Stop-Process -Id $trayPid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

$installDirectory = Join-Path $stateDirectory 'app'
if (Test-Path -LiteralPath $installDirectory) {
    $resolvedState = [System.IO.Path]::GetFullPath($stateDirectory).TrimEnd('\') + '\'
    $resolvedInstall = [System.IO.Path]::GetFullPath($installDirectory).TrimEnd('\') + '\'
    if ($resolvedInstall.StartsWith($resolvedState, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $installDirectory -Recurse -Force
    }
    else {
        throw 'Refusing to remove an install directory outside the app state folder.'
    }
}

Write-Output 'Codex Token Usage startup shortcut was removed, its background process was stopped, and its installed runtime was deleted.'
