Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDirectory = Split-Path -Parent $PSCommandPath
$sourceLauncher = Join-Path $scriptDirectory 'LaunchTokenUsageTray.vbs'
$sourceTrayScript = Join-Path $scriptDirectory 'TokenUsageTray.ps1'

if (-not (Test-Path -LiteralPath $sourceLauncher) -or -not (Test-Path -LiteralPath $sourceTrayScript)) {
    throw 'The launcher and tray script must be in the same folder as Install.ps1.'
}

$stateDirectory = Join-Path $env:LOCALAPPDATA 'CodexTokenUsageTray'
$installDirectory = Join-Path $stateDirectory 'app'
$launcherPath = Join-Path $installDirectory 'LaunchTokenUsageTray.vbs'
$trayScript = Join-Path $installDirectory 'TokenUsageTray.ps1'
New-Item -ItemType Directory -Path $installDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceLauncher -Destination $launcherPath -Force
Copy-Item -LiteralPath $sourceTrayScript -Destination $trayScript -Force

$startupDirectory = [Environment]::GetFolderPath('Startup')
$startupShortcut = Join-Path $startupDirectory 'Codex Token Usage Tray.lnk'
$shell = $null
$shell = New-Object -ComObject WScript.Shell
try {
    $shortcut = $shell.CreateShortcut($startupShortcut)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $trayScript
    $shortcut.WorkingDirectory = $installDirectory
    $shortcut.Description = 'Display Codex usage in the Windows notification area.'
    $shortcut.Save()
}
finally {
    if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
}

# Remove older startup methods after migration.
Unregister-ScheduledTask -TaskName 'Codex Token Usage Tray' -Confirm:$false -ErrorAction SilentlyContinue
$runKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($runKeyPath, $true)
try {
    if ($null -ne $runKey) { $runKey.DeleteValue('CodexTokenUsageTray', $false) }
}
finally {
    if ($null -ne $runKey) { $runKey.Dispose() }
}

$pidPath = Join-Path $stateDirectory 'app.pid'
if (Test-Path -LiteralPath $pidPath) {
    $trayPid = [int](Get-Content -Raw -LiteralPath $pidPath).Trim()
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $trayPid" -ErrorAction SilentlyContinue
    if ($null -ne $processInfo -and $processInfo.CommandLine -match 'TokenUsageTray\.ps1') {
        Stop-Process -Id $trayPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}

Start-Process -FilePath $startupShortcut

Write-Output 'Codex Token Usage is installed, running in the system tray, and added to the interactive Windows Startup folder.'
