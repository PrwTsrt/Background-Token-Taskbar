param(
    [switch]$Once
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AppName = 'Codex Token Usage'
$script:AppVersion = '1.2.0'
$script:RefreshIntervalMs = 120000
$script:RpcProcess = $null
$script:RpcRequestId = 0
$script:CurrentIcon = $null
$script:LastSummary = $null
$script:IsRefreshing = $false
$script:CodexPath = $null
$script:Context = $null
$script:NotifyIcon = $null
$script:Timer = $null
$script:Mutex = $null
$script:RunValueName = 'CodexTokenUsageTray'
$script:RunKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:ScheduledTaskName = 'Codex Token Usage Tray'
$script:ScriptDirectory = Split-Path -Parent $PSCommandPath
$script:LauncherPath = Join-Path $script:ScriptDirectory 'LaunchTokenUsageTray.vbs'
$script:StartupShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Token Usage Tray.lnk'
$script:StateDirectory = Join-Path $env:LOCALAPPDATA 'CodexTokenUsageTray'
$script:LogPath = Join-Path $script:StateDirectory 'app.log'
$script:PidPath = Join-Path $script:StateDirectory 'app.pid'

function Write-AppLog {
    param([string]$Message)

    try {
        if (-not (Test-Path -LiteralPath $script:StateDirectory)) {
            New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $script:LogPath) -and
            (Get-Item -LiteralPath $script:LogPath).Length -gt 1MB) {
            Move-Item -LiteralPath $script:LogPath -Destination ($script:LogPath + '.old') -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    }
    catch {
        # Logging must never interrupt the tray app.
    }
}

function Find-CodexExecutable {
    $command = Get-Command 'codex.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot) {
        $candidate = Get-ChildItem -LiteralPath $binRoot -Filter 'codex.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate.FullName
        }
    }

    throw 'Codex CLI was not found. Open or reinstall the Codex desktop app, then try again.'
}

function Stop-CodexServer {
    if ($null -eq $script:RpcProcess) {
        return
    }

    try {
        if (-not $script:RpcProcess.HasExited) {
            $script:RpcProcess.StandardInput.Close()
            if (-not $script:RpcProcess.WaitForExit(1000)) {
                $script:RpcProcess.Kill()
            }
        }
        $script:RpcProcess.Dispose()
    }
    catch {
        Write-AppLog ('Unable to stop Codex app server cleanly: ' + $_.Exception.Message)
    }
    finally {
        $script:RpcProcess = $null
    }
}

function Read-RpcResponse {
    param(
        [Parameter(Mandatory)] [int]$RequestId,
        [int]$TimeoutMs = 15000
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($script:RpcProcess.HasExited) {
            throw "Codex app server exited with code $($script:RpcProcess.ExitCode)."
        }

        $remaining = [Math]::Max(1, $TimeoutMs - [int]$watch.ElapsedMilliseconds)
        $readTask = $script:RpcProcess.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            throw "Timed out waiting for Codex usage data."
        }

        $line = $readTask.Result
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $message = $line | ConvertFrom-Json
        }
        catch {
            Write-AppLog ('Ignored non-JSON app-server output: ' + $line)
            continue
        }

        $idProperty = $message.PSObject.Properties['id']
        if ($null -ne $idProperty -and [int]$message.id -eq $RequestId) {
            if ($null -ne $message.PSObject.Properties['error']) {
                throw ('Codex app server error: ' + ($message.error | ConvertTo-Json -Compress -Depth 8))
            }
            return $message.result
        }
    }

    throw 'Timed out waiting for Codex usage data.'
}

function Send-RpcRequest {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [AllowNull()] $Params = $null,
        [int]$TimeoutMs = 15000
    )

    $script:RpcRequestId++
    $request = [ordered]@{
        id = $script:RpcRequestId
        method = $Method
    }
    if ($null -ne $Params) {
        $request.params = $Params
    }

    $json = $request | ConvertTo-Json -Compress -Depth 10
    $script:RpcProcess.StandardInput.WriteLine($json)
    $script:RpcProcess.StandardInput.Flush()
    return Read-RpcResponse -RequestId $script:RpcRequestId -TimeoutMs $TimeoutMs
}

function Start-CodexServer {
    if ($null -ne $script:RpcProcess -and -not $script:RpcProcess.HasExited) {
        return
    }

    Stop-CodexServer
    $script:CodexPath = Find-CodexExecutable

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:CodexPath
    $startInfo.Arguments = 'app-server --listen stdio://'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true

    $script:RpcProcess = [System.Diagnostics.Process]::new()
    $script:RpcProcess.StartInfo = $startInfo
    if (-not $script:RpcProcess.Start()) {
        throw 'Unable to start the Codex app server.'
    }

    $clientInfo = [ordered]@{
        clientInfo = [ordered]@{
            name = 'token-usage-tray'
            title = $script:AppName
            version = $script:AppVersion
        }
    }
    $null = Send-RpcRequest -Method 'initialize' -Params $clientInfo
    Write-AppLog ('Connected to Codex app server at ' + $script:CodexPath)
}

function Get-CodexUsage {
    try {
        Start-CodexServer
        $response = Send-RpcRequest -Method 'account/rateLimits/read'

        $limits = $null
        $byId = $response.PSObject.Properties['rateLimitsByLimitId']
        if ($null -ne $byId -and $null -ne $response.rateLimitsByLimitId) {
            $codexProperty = $response.rateLimitsByLimitId.PSObject.Properties['codex']
            if ($null -ne $codexProperty) {
                $limits = $codexProperty.Value
            }
        }
        if ($null -eq $limits) {
            $limits = $response.rateLimits
        }
        if ($null -eq $limits -or $null -eq $limits.primary) {
            throw 'Codex returned no primary usage window.'
        }

        $primaryRemaining = [Math]::Max(0, [Math]::Min(100, 100 - [int][Math]::Round([double]$limits.primary.usedPercent)))
        $secondaryRemaining = $null
        if ($null -ne $limits.secondary) {
            $secondaryRemaining = [Math]::Max(0, [Math]::Min(100, 100 - [int][Math]::Round([double]$limits.secondary.usedPercent)))
        }

        return [pscustomobject]@{
            PrimaryRemaining = $primaryRemaining
            PrimaryUsed = [int][Math]::Round([double]$limits.primary.usedPercent)
            PrimaryWindowMinutes = [int]$limits.primary.windowDurationMins
            PrimaryResetsAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$limits.primary.resetsAt).ToLocalTime()
            SecondaryRemaining = $secondaryRemaining
            SecondaryUsed = if ($null -ne $limits.secondary) { [int][Math]::Round([double]$limits.secondary.usedPercent) } else { $null }
            SecondaryWindowMinutes = if ($null -ne $limits.secondary) { [int]$limits.secondary.windowDurationMins } else { $null }
            SecondaryResetsAt = if ($null -ne $limits.secondary) { [DateTimeOffset]::FromUnixTimeSeconds([long]$limits.secondary.resetsAt).ToLocalTime() } else { $null }
            PlanType = [string]$limits.planType
            UpdatedAt = Get-Date
        }
    }
    catch {
        Stop-CodexServer
        throw
    }
}

function Format-WindowLabel {
    param([int]$Minutes)

    if ($Minutes -lt 60) {
        return "$Minutes-minute"
    }
    if ($Minutes % 1440 -eq 0) {
        return ('{0}-day' -f ($Minutes / 1440))
    }
    return ('{0}-hour' -f ($Minutes / 60))
}

function Format-ResetTime {
    param([DateTimeOffset]$ResetAt)

    $local = $ResetAt.LocalDateTime
    if ($local.Date -eq (Get-Date).Date) {
        return $local.ToString("'today' HH:mm")
    }
    if ($local.Date -eq (Get-Date).Date.AddDays(1)) {
        return $local.ToString("'tomorrow' HH:mm")
    }
    return $local.ToString('ddd d MMM HH:mm')
}

if ($Once) {
    try {
        $usage = Get-CodexUsage
        [ordered]@{
            primaryWindow = Format-WindowLabel $usage.PrimaryWindowMinutes
            primaryRemainingPercent = $usage.PrimaryRemaining
            primaryResetsAt = $usage.PrimaryResetsAt.ToString('o')
            secondaryWindow = if ($null -ne $usage.SecondaryWindowMinutes) { Format-WindowLabel $usage.SecondaryWindowMinutes } else { $null }
            secondaryRemainingPercent = $usage.SecondaryRemaining
            secondaryResetsAt = if ($null -ne $usage.SecondaryResetsAt) { $usage.SecondaryResetsAt.ToString('o') } else { $null }
            plan = $usage.PlanType
        } | ConvertTo-Json
        exit 0
    }
    catch {
        Write-Error $_
        exit 1
    }
    finally {
        Stop-CodexServer
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TokenUsageNativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@

function New-UsageBarsIcon {
    param(
        [AllowNull()] $PrimaryRemaining = $null,
        [AllowNull()] $SecondaryRemaining = $null,
        [ValidateSet('Normal', 'Loading', 'Error')] [string]$State = 'Normal'
    )

    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $trackBrush = $null
    $borderPen = $null
    $primaryBrush = $null
    $secondaryBrush = $null
    $statusPen = $null
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $trackBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(48, 52, 58))
        $borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(210, 215, 222), 1)
        $graphics.FillRectangle($trackBrush, 2, 2, 28, 12)
        $graphics.FillRectangle($trackBrush, 2, 18, 28, 12)
        $graphics.DrawRectangle($borderPen, 2, 2, 27, 11)
        $graphics.DrawRectangle($borderPen, 2, 18, 27, 11)

        if ($State -eq 'Normal') {
            $primaryValue = [Math]::Max(0, [Math]::Min(100, [int]$PrimaryRemaining))
            $primaryWidth = [int][Math]::Round(26 * $primaryValue / 100)
            if ($primaryWidth -gt 0) {
                $primaryBrush = [System.Drawing.SolidBrush]::new((Get-UsageColor $primaryValue))
                $graphics.FillRectangle($primaryBrush, 3, 3, $primaryWidth, 10)
            }

            if ($null -ne $SecondaryRemaining) {
                $secondaryValue = [Math]::Max(0, [Math]::Min(100, [int]$SecondaryRemaining))
                $secondaryWidth = [int][Math]::Round(26 * $secondaryValue / 100)
                if ($secondaryWidth -gt 0) {
                    $secondaryBrush = [System.Drawing.SolidBrush]::new((Get-UsageColor $secondaryValue))
                    $graphics.FillRectangle($secondaryBrush, 3, 19, $secondaryWidth, 10)
                }
            }
        }
        elseif ($State -eq 'Loading') {
            $statusPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(86, 156, 214), 3)
            $graphics.DrawLine($statusPen, 4, 8, 14, 8)
            $graphics.DrawLine($statusPen, 4, 24, 14, 24)
        }
        else {
            $statusPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(220, 62, 62), 3)
            $graphics.DrawLine($statusPen, 5, 5, 27, 27)
            $graphics.DrawLine($statusPen, 27, 5, 5, 27)
        }

        $handle = $bitmap.GetHicon()
        try {
            return ([System.Drawing.Icon]::FromHandle($handle).Clone())
        }
        finally {
            [void][TokenUsageNativeMethods]::DestroyIcon($handle)
        }
    }
    finally {
        if ($null -ne $statusPen) { $statusPen.Dispose() }
        if ($null -ne $secondaryBrush) { $secondaryBrush.Dispose() }
        if ($null -ne $primaryBrush) { $primaryBrush.Dispose() }
        if ($null -ne $borderPen) { $borderPen.Dispose() }
        if ($null -ne $trackBrush) { $trackBrush.Dispose() }
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Set-TrayIcon {
    param(
        [AllowNull()] $PrimaryRemaining = $null,
        [AllowNull()] $SecondaryRemaining = $null,
        [ValidateSet('Normal', 'Loading', 'Error')] [string]$State = 'Normal'
    )

    $newIcon = New-UsageBarsIcon -PrimaryRemaining $PrimaryRemaining -SecondaryRemaining $SecondaryRemaining -State $State
    $oldIcon = $script:CurrentIcon
    $script:CurrentIcon = $newIcon
    $script:NotifyIcon.Icon = $newIcon
    if ($null -ne $oldIcon) {
        $oldIcon.Dispose()
    }
}

function Get-UsageColor {
    param([int]$Remaining)

    if ($Remaining -ge 50) { return [System.Drawing.Color]::FromArgb(23, 145, 80) }
    if ($Remaining -ge 20) { return [System.Drawing.Color]::FromArgb(219, 121, 28) }
    return [System.Drawing.Color]::FromArgb(201, 48, 48)
}

function Get-AutoStartEnabled {
    if (Test-Path -LiteralPath $script:StartupShortcutPath) {
        return $true
    }

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunKeyPath, $false)
    try {
        return $null -ne $key -and $null -ne $key.GetValue($script:RunValueName, $null)
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Set-AutoStartEnabled {
    param([bool]$Enabled)

    if ($Enabled) {
        $startupDirectory = Split-Path -Parent $script:StartupShortcutPath
        if (-not (Test-Path -LiteralPath $startupDirectory)) {
            New-Item -ItemType Directory -Path $startupDirectory -Force | Out-Null
        }
        $shell = $null
        $shell = New-Object -ComObject WScript.Shell
        try {
            $shortcut = $shell.CreateShortcut($script:StartupShortcutPath)
            $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $shortcut.Arguments = '"{0}"' -f $script:LauncherPath
            $shortcut.WorkingDirectory = $script:ScriptDirectory
            $shortcut.Description = 'Display Codex usage in the Windows notification area.'
            $shortcut.Save()
        }
        finally {
            if ($null -ne $shell) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
        }
    }
    else {
        Remove-Item -LiteralPath $script:StartupShortcutPath -Force -ErrorAction SilentlyContinue
    }

    # Remove older startup methods after migration.
    Unregister-ScheduledTask -TaskName $script:ScheduledTaskName -Confirm:$false -ErrorAction SilentlyContinue
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunKeyPath, $true)
    try {
        if ($null -ne $key) { $key.DeleteValue($script:RunValueName, $false) }
    }
    finally {
        if ($null -ne $key) { $key.Dispose() }
    }
}

function Update-Tray {
    if ($script:IsRefreshing) {
        return
    }

    $script:IsRefreshing = $true
    $script:RefreshItem.Enabled = $false
    $script:RefreshItem.Text = 'Refreshing...'
    try {
        $usage = Get-CodexUsage
        $script:LastSummary = $usage

        $primaryName = Format-WindowLabel $usage.PrimaryWindowMinutes
        $primaryReset = Format-ResetTime $usage.PrimaryResetsAt
        $script:PrimaryItem.Text = "$primaryName`: $($usage.PrimaryRemaining)% remaining - resets $primaryReset"

        if ($null -ne $usage.SecondaryRemaining) {
            $secondaryName = Format-WindowLabel $usage.SecondaryWindowMinutes
            $secondaryReset = Format-ResetTime $usage.SecondaryResetsAt
            $script:SecondaryItem.Text = "$secondaryName`: $($usage.SecondaryRemaining)% remaining - resets $secondaryReset"
            $script:SecondaryItem.Visible = $true
        }
        else {
            $script:SecondaryItem.Visible = $false
        }

        $planText = if ([string]::IsNullOrWhiteSpace($usage.PlanType)) { 'unknown plan' } else { $usage.PlanType }
        $script:PlanItem.Text = "Plan: $planText | updated $($usage.UpdatedAt.ToString('HH:mm'))"
        $tooltip = "5h: $($usage.PrimaryRemaining)% left"
        if ($null -ne $usage.SecondaryRemaining) {
            $tooltip += " | Week: $($usage.SecondaryRemaining)% left"
        }
        $script:NotifyIcon.Text = $tooltip.Substring(0, [Math]::Min(63, $tooltip.Length))
        Set-TrayIcon -PrimaryRemaining $usage.PrimaryRemaining -SecondaryRemaining $usage.SecondaryRemaining
        Write-AppLog ("Usage refreshed: primary=$($usage.PrimaryRemaining)% remaining; secondary=$($usage.SecondaryRemaining)% remaining")
    }
    catch {
        $message = $_.Exception.Message
        $script:PrimaryItem.Text = 'Usage unavailable'
        $script:SecondaryItem.Visible = $false
        $script:PlanItem.Text = $message
        $script:NotifyIcon.Text = ('Codex usage unavailable: ' + $message).Substring(0, [Math]::Min(63, ('Codex usage unavailable: ' + $message).Length))
        Set-TrayIcon -State 'Error'
        Write-AppLog ('Refresh failed: ' + $message)
    }
    finally {
        $script:RefreshItem.Enabled = $true
        $script:RefreshItem.Text = 'Refresh now'
        $script:IsRefreshing = $false
    }
}

function Show-UsageBalloon {
    if ($null -eq $script:LastSummary) {
        $script:NotifyIcon.BalloonTipTitle = $script:AppName
        $script:NotifyIcon.BalloonTipText = 'Usage is not available yet. Choose Refresh now to retry.'
    }
    else {
        $usage = $script:LastSummary
        $lines = @(
            "$(Format-WindowLabel $usage.PrimaryWindowMinutes): $($usage.PrimaryRemaining)% remaining; resets $(Format-ResetTime $usage.PrimaryResetsAt)"
        )
        if ($null -ne $usage.SecondaryRemaining) {
            $lines += "$(Format-WindowLabel $usage.SecondaryWindowMinutes): $($usage.SecondaryRemaining)% remaining; resets $(Format-ResetTime $usage.SecondaryResetsAt)"
        }
        $script:NotifyIcon.BalloonTipTitle = $script:AppName
        $script:NotifyIcon.BalloonTipText = $lines -join [Environment]::NewLine
    }
    $script:NotifyIcon.ShowBalloonTip(5000)
}

$createdNew = $false
$script:Mutex = [System.Threading.Mutex]::new($true, 'Local\CodexTokenUsageTray', [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    if (-not (Test-Path -LiteralPath $script:StateDirectory)) {
        New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    }
    Set-Content -LiteralPath $script:PidPath -Value $PID -Encoding ascii
    Write-AppLog "Starting $($script:AppName) $($script:AppVersion) (PID $PID)"

    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:Context = [System.Windows.Forms.ApplicationContext]::new()
    $script:NotifyIcon = [System.Windows.Forms.NotifyIcon]::new()
    $script:NotifyIcon.Visible = $true
    $script:NotifyIcon.Text = 'Codex usage: loading...'
    Set-TrayIcon -State 'Loading'

    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    $script:PrimaryItem = [System.Windows.Forms.ToolStripMenuItem]::new('Loading Codex usage...')
    $script:PrimaryItem.Enabled = $false
    $script:SecondaryItem = [System.Windows.Forms.ToolStripMenuItem]::new('')
    $script:SecondaryItem.Enabled = $false
    $script:PlanItem = [System.Windows.Forms.ToolStripMenuItem]::new('')
    $script:PlanItem.Enabled = $false
    $script:RefreshItem = [System.Windows.Forms.ToolStripMenuItem]::new('Refresh now')
    $openItem = [System.Windows.Forms.ToolStripMenuItem]::new('Open Codex')
    $script:AutoStartItem = [System.Windows.Forms.ToolStripMenuItem]::new('Start with Windows')
    $script:AutoStartItem.CheckOnClick = $true
    $script:AutoStartItem.Checked = Get-AutoStartEnabled
    $exitItem = [System.Windows.Forms.ToolStripMenuItem]::new('Exit')

    [void]$menu.Items.Add($script:PrimaryItem)
    [void]$menu.Items.Add($script:SecondaryItem)
    [void]$menu.Items.Add($script:PlanItem)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$menu.Items.Add($script:RefreshItem)
    [void]$menu.Items.Add($openItem)
    [void]$menu.Items.Add($script:AutoStartItem)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$menu.Items.Add($exitItem)
    $script:NotifyIcon.ContextMenuStrip = $menu

    $script:RefreshItem.add_Click({ Update-Tray })
    $openItem.add_Click({
        try {
            $path = Find-CodexExecutable
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $path
            $startInfo.Arguments = 'app'
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            [void][System.Diagnostics.Process]::Start($startInfo)
        }
        catch {
            Write-AppLog ('Unable to open Codex: ' + $_.Exception.Message)
        }
    })
    $script:AutoStartItem.add_Click({
        try {
            Set-AutoStartEnabled -Enabled $script:AutoStartItem.Checked
        }
        catch {
            $script:AutoStartItem.Checked = -not $script:AutoStartItem.Checked
            Write-AppLog ('Unable to update auto-start: ' + $_.Exception.Message)
        }
    })
    $exitItem.add_Click({
        $script:NotifyIcon.Visible = $false
        $script:Context.ExitThread()
    })
    $script:NotifyIcon.add_MouseClick({
        param($sender, $eventArgs)
        if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            Show-UsageBalloon
        }
    })

    $script:Timer = [System.Windows.Forms.Timer]::new()
    $script:Timer.Interval = $script:RefreshIntervalMs
    $script:Timer.add_Tick({ Update-Tray })
    $script:Timer.Start()

    Update-Tray
    [System.Windows.Forms.Application]::Run($script:Context)
}
catch {
    Write-AppLog ('Fatal error: ' + $_.Exception.ToString())
    throw
}
finally {
    if ($null -ne $script:Timer) { $script:Timer.Stop(); $script:Timer.Dispose() }
    if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() }
    if ($null -ne $script:CurrentIcon) { $script:CurrentIcon.Dispose() }
    Stop-CodexServer
    Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() }
    Write-AppLog 'Stopped.'
}
