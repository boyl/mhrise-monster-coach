@echo off
setlocal
set "PWSH="
for /f "usebackq delims=" %%P in (`pwsh.exe -NoLogo -NoProfile -Command "$p=(Get-Command pwsh.exe -ErrorAction Stop); if($PSVersionTable.PSVersion.Major -lt 7){exit 2}; $p.Source"`) do set "PWSH=%%P"
if not defined PWSH (
  echo PowerShell 7 or later is required. Install it, then run UNINSTALL.cmd again.
  pause
  exit /b 2
)
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
