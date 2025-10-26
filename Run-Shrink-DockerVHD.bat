@echo off
setlocal EnableExtensions

REM === Locate the PS1 in the same folder ===
set "SCRIPT=%~dp0Shrink-DockerVHD.ps1"
if not exist "%SCRIPT%" (
  echo [X] Not found: "%SCRIPT%"
  echo Put Run-Shrink-DockerVHD.bat in the SAME folder as Shrink-DockerVHD.ps1
  echo.
  pause
  exit /b 1
)

REM === Check if running as Administrator ===
>nul 2>&1 net session
if %errorlevel% neq 0 (
  echo [*] Elevating to Administrator...
  REM Prefer PowerShell 7 (pwsh) if available; otherwise Windows PowerShell
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "if (Get-Command pwsh -ErrorAction SilentlyContinue) {" ^
    "  Start-Process pwsh -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command'," ^
    "    'try { & ''%SCRIPT%'' -OpenLog } catch { Write-Error $_ } finally { Read-Host ''(admin) Press Enter to close...'' }')" ^
    "} else {" ^
    "  Start-Process PowerShell -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command'," ^
    "    'try { & ''%SCRIPT%'' -OpenLog } catch { Write-Error $_ } finally { Read-Host ''(admin) Press Enter to close...'' }')" ^
    "}"
  echo.
  echo [*] An elevated window was launched. If it closes instantly, check policy/log popups.
  echo.
  pause
  exit /b 0
)

REM === Already Administrator: run inline and ALWAYS pause on exit ===
echo [*] Running as Administrator...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { & '%SCRIPT%' -OpenLog } catch { Write-Error $_ } finally { Read-Host 'Press Enter to close...' }"

endlocal
