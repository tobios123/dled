# DLED Flutter — Release Guide

## Current version
`1.20.0+120` (pubspec.yaml: `version: <semver>+<build-number>`)

---

## Quick release (Windows)

```
Double-click build_release.bat
```

That script:
1. Kills any running `dled.exe` so the `build/` folder is not locked
2. `flutter clean` — wipes stale build artifacts
3. `flutter pub get` — resolves dependencies
4. `flutter build windows --release` (~45-60 s)
5. Zips the entire `Release/` folder to `dled-windows-v<version>.zip`

---

## Manual commands

From inside `dled_flutter/`:

```bat
:: Kill running app (if open)
taskkill /F /IM dled.exe

:: Clean
flutter clean

:: Install deps
flutter pub get

:: Windows release
flutter build windows --release

:: Web release (served by Python)
flutter build web --release
```

---

## Output locations

| Target | Output path |
|---|---|
| **Windows EXE** | `build\windows\x64\runner\Release\dled.exe` |
| **Windows – all runtime files** | `build\windows\x64\runner\Release\` |
| **Web** | `build\web\` |
| **Android APK** | `build\app\outputs\flutter-apk\app-release.apk` |

---

## What must be distributed together (Windows)

The `Release\` folder contains everything needed — **copy the whole folder**, not just the exe:

```
dled.exe
flutter_windows.dll
data/
  flutter_assets/          <- fonts, icons, personalities.xml
  app.so                   <- compiled Dart code
```

To share a release, zip the whole `Release\` folder (what `build_release.bat` does).

---

## Bumping the version

Edit `pubspec.yaml`:

```yaml
version: 1.20.0+120   # semver+build-number
```

Convention: build number = semver with dots removed (`1.20.0` → `120`).

Then rebuild with `build_release.bat`.

---

## Web release + serve locally

```bat
run_web.bat
```

That script builds the web release and serves it on `http://localhost:8080` via Python.

A browser cannot send UDP itself: the web build reaches the LPU through the bridge (`bin/dled_bridge.dart`, see `lib/core/udp_web.dart`).

---

## Android

```bat
flutter build apk --release
```

Output: `build\app\outputs\flutter-apk\app-release.apk`

Install on device:
```bat
adb install build\app\outputs\flutter-apk\app-release.apk
```

For a Play Store bundle:
```bat
flutter build appbundle --release
```

---

## Troubleshooting

| Error | Fix |
|---|---|
| `Cannot open source file: ...ephemeral\cpp_client_wrapper\...` | Stale build cache. Run `flutter clean` then rebuild |
| `Flutter failed to delete a directory at "build"` | `dled.exe` is still running. Run `taskkill /F /IM dled.exe` first |
| `No pubspec.yaml file found` | Must run `flutter` commands from inside the `dled_flutter\` directory |
| `46 packages have newer versions` | Safe to ignore — these are informational. Run `flutter pub outdated` to review |
| Build takes >2 min | First build after `flutter clean` is always slow (compiles C++ wrapper). Subsequent builds without `clean` are faster |

---

## Flutter version in use

```
Flutter 3.24.3 (stable)
Dart 3.5.3
```

If you upgrade Flutter, run `flutter pub upgrade` to pick up compatible package versions, then `build_release.bat`.
