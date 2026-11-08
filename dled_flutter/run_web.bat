@echo off
title DLED Flutter Web Server

set FLUTTER=flutter
set APPDIR=%~dp0

echo ============================================
echo  DLED Flutter Web App
echo ============================================
echo.

:: Kill anything on port 8080
echo Freeing port 8080...
for /f "tokens=5" %%a in ('netstat -ano 2^>nul ^| findstr ":8080 "') do (
    taskkill /F /PID %%a >nul 2>&1
)
timeout /t 1 /nobreak >nul

:: Build web release
echo Building web release...
cd /d "%APPDIR%"
call "%FLUTTER%" build web --release
if errorlevel 1 (
    echo.
    echo BUILD FAILED. Press any key to exit.
    pause >nul
    exit /b 1
)

echo.
echo Build complete. Starting server on http://localhost:8080
echo Open http://localhost:8080 in your browser.
echo Press Ctrl+C to stop.
echo.

:: Serve from build\web using Python
cd /d "%APPDIR%build\web"
python -m http.server 8080
