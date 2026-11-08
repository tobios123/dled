@echo off
rem Run the DLED CLI (dled_flutter\bin\dled_cli.dart) from any folder:
rem   dled status --ip 192.168.1.12
rem File paths in the arguments are relative to the folder you are in.
rem Uses Flutter's own Dart when FLUTTER_ROOT is set (the plain "dart"
rem command needs git on the PATH), else "dart" from the PATH.
setlocal
set "DART=dart"
if defined FLUTTER_ROOT if exist "%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe" set "DART=%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart.exe"
"%DART%" run "%~dp0dled_flutter\bin\dled_cli.dart" %*
exit /b %ERRORLEVEL%
