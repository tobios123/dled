@echo off
setlocal EnableDelayedExpansion
title DLED Release Builder

set FLUTTER=flutter
set APPDIR=%~dp0
set VERSION=

:: Read version from pubspec.yaml
for /f "tokens=2 delims=: " %%V in ('findstr /B "version:" "%APPDIR%pubspec.yaml"') do (
    set VERSION=%%V
)
:: Strip the build number (e.g. 1.19.0+119 -> 1.19.0)
for /f "tokens=1 delims=+" %%V in ("!VERSION!") do set VERSION=%%V

echo ============================================
echo  DLED Release Builder  v!VERSION!
echo ============================================
echo.

:: Kill any running instance that may lock the build folder
echo Stopping any running dled.exe...
taskkill /F /IM dled.exe >nul 2>&1
timeout /t 1 /nobreak >nul

cd /d "%APPDIR%"

:: Clean previous build
echo [1/4] Cleaning...
call %FLUTTER% clean
if errorlevel 1 goto :fail

:: Get dependencies
echo [2/4] Getting dependencies...
call %FLUTTER% pub get
if errorlevel 1 goto :fail

:: Build Windows release
echo [3/4] Building Windows release...
call %FLUTTER% build windows --release
if errorlevel 1 goto :fail

:: Package into a zip
echo [4/4] Packaging...
set RELEASEDIR=%APPDIR%build\windows\x64\runner\Release
set ZIPNAME=%APPDIR%dled-windows-v!VERSION!.zip

:: Use PowerShell to zip
powershell -Command "Compress-Archive -Path '%RELEASEDIR%\*' -DestinationPath '%ZIPNAME%' -Force"
if errorlevel 1 (
    echo WARNING: Could not create zip. Release folder is still at:
    echo   %RELEASEDIR%
) else (
    echo.
    echo Release zip: %ZIPNAME%
)

echo.
echo ============================================
echo  BUILD COMPLETE  v!VERSION!
echo ============================================
echo.
echo Executable: %RELEASEDIR%\dled.exe
echo.
echo To run: start "" "%RELEASEDIR%\dled.exe"
echo.
pause
exit /b 0

:fail
echo.
echo BUILD FAILED. See errors above.
pause
exit /b 1
