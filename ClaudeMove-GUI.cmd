@echo off
rem ClaudeMove GUI launcher (double-click to run)
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh^) is required. Install with:
    echo   winget install Microsoft.PowerShell
    pause
    exit /b 1
)
start "" pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0claudemove-gui.ps1"
