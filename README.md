# Codex Token Usage for the Windows taskbar

This small background utility displays the remaining Codex allowance as two stacked bars in the Windows notification area (system tray).

- The top bar shows the percentage remaining in the 5-hour window.
- The bottom bar shows the percentage remaining in the weekly window.
- Right-click it to see the primary and secondary windows, their reset times, the current plan, refresh controls, and auto-start status.
- Left-click it for a compact status notification.
- It refreshes every two minutes and uses Codex's own local app server, so it does not store or copy account credentials.

## Install

Run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer copies the two runtime files into `%LOCALAPPDATA%\CodexTokenUsageTray\app`, launches the utility, and creates a shortcut in the current user's interactive Windows Startup folder. No administrator rights are needed. Windows may initially place the icon in the taskbar overflow menu; drag it onto the visible notification area if you want it shown permanently.

## Test the data source

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\TokenUsageTray.ps1 -Once
```

This prints a credential-free JSON summary and exits.

## Uninstall

Run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

This removes auto-start and stops the running tray process. The project files remain in place.
