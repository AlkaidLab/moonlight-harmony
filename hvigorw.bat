@echo off
REM Hvigor wrapper script for HarmonyOS projects (Windows)
REM Auto-generated for compatibility

setlocal enabledelayedexpansion

set "PROJECT_DIR=%~dp0"
cd /d "%PROJECT_DIR%"

REM Check for hvigor in different locations
where hvigor >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    hvigor %*
    exit /b %ERRORLEVEL%
)

if exist "%PROJECT_DIR%node_modules\.bin\hvigor.cmd" (
    call "%PROJECT_DIR%node_modules\.bin\hvigor.cmd" %*
    exit /b %ERRORLEVEL%
)

echo Error: Cannot find hvigor. Run "ohpm install --all" or open the project in DevEco Studio.
exit /b 1
