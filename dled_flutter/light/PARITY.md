# Light page parity with the Flutter app

The light page (`light/`) is DLED for the ESP32 box: plain HTML / CSS / JS
like WLED's own page, ~130 KB gzipped (plus the 128 KB fixture library). It shares all **logic** with the
Flutter app: `light/api.dart` exposes `lib/core` and
`lib/services/vn_service.dart` as `window.dled` (compiled to `core.js` by
`dart run tool/build_light.dart`). Only the **screens** are written twice.

## How a Flutter change reaches the light page

- **Logic** (LPU protocol, show download / upload, live state, discovery,
  auto-connect, anything in `lib/core` or `vn_service.dart`): nothing to
  port. Rebuild the light page (`dart run tool/build_light.dart`).
- **New logic in a Flutter-only place** (`ShowModel`, `live_sync`,
  `show_loader`, `show_exporter`, screens): move the part the page also needs
  into `lib/core` (or another file without Flutter imports), then expose it
  in `light/api.dart`.
- **Screens**: add the feature to `light/src/app.js` / `style.css` and tick it
  off below. Keep the same names, colours and sizes as the Flutter widget.

Rule of thumb when adding a Flutter feature: write its logic so it has no
`package:flutter` import, and add a line to the table below.

## Status (2026-10-25)

| Feature (Flutter file) | Light page |
|---|---|
| Discovery, automatic connect (only one LPU / remembered) (`vn_service`) | yes (shared) |
| Show download, live updates (`lib/core`) | yes (shared) |
| Design width 768, scaled to the screen (`design_scale.dart`) | yes, by the window's shape (width / height): up to 0.75 768 wide; 0.75-1.55 1024 high, stretched to the window's width; from 1.55 PC mode |
| **PLAYBACK** (`playback_screen.dart`) | |
| - 64 tiles: name / number, cue x / n, 4 state colours, fader-row tint, darker edges | yes |
| - intensity / speed ticks on the tiles | yes |
| - "Intensity xx% / Speed xx%" for 1.5 s after a fader / knob change | yes |
| - GO by tapping a tile (only a playback with content) | yes |
| - RELEASE: tap to arm + tap a tile; hold 0.5 s = release all | yes |
| - long press (0.8 s) on a holding (yellow) tile releases it; a long press is never a GO | yes |
| - RENAME (RENAME PLAYBACK dialog), SWAP (blue first pick), PROPS (PLAYBACK PROPERTIES) | yes |
| - EDIT mode (tap a tile: its EDIT page) | yes |
| - 8 fader strips: LED, knob with LED ring, fader with scale, FLASH (only a stopped playback with cues) | yes |
| - change fader row: tap between tiles / 3-finger swipe / Ctrl+wheel | yes |
| - PC mode (window shape 1.55 and wider: 16:9 / 16:10 full screen, a tablet on its side): the grid in two halves side by side (1-32 | 33-64) over 16 strips, each group of 8 under its half: the fader row and the row four below it (1-8 with 33-40 ... 25-32 with 57-64) | page only (the app: not yet) |
| - collision lock (patch DMX overlap; rule shared in `core/patch.dart`) | yes |
| Top bar (`app_button.dart`), LED | yes (name as text instead of the logo) |
| Pull the top bar down to reload the page (mobile) | page only (the app has no reload) |
| Full screen: tap the name (the sign next to it); not on iPhones | page only |
| Add to home screen: own icon (`tool/make_light_icons.py`), opens without browser bars (iPad / iPhone; Android Chrome only over https) | page only |
| **OPTIONS** (`options_screen.dart`) | |
| - device list (LPU icon, IP, LABEL, FIRMWARE, HARDWARE, ART-NET, sACN); tap = connect, tap empty = disconnect | yes |
| - IP ADDRESS / RENAME (DEVICE NAME) / ART-NET / sACN dialogs, written to the LPU | yes (shared logic; IP check in `core/net.dart`) |
| - show files: list with date / size, NEW, REMOVE (ARE YOU SURE?), RENAME, SAVE, SAVE AS (overwrite check), OPEN with LOADING... % and Abort | yes - stored **on the box** (`/api/shows`; PC bridge: `Documents/DLED/shows`, ESP32: LittleFS) |
| - IMPORT / EXPORT (.show from / to this device) | yes |
| - FOLDER (Windows only) | no (not for a browser) |
| - remember the chosen LPU | yes (browser storage) |
| - opening a show while not connected (app: loads it into the app) | no: the page has no show of its own; OPEN needs the LPU |
| **EDIT** (`edit_screen.dart`, `edit_controls.dart`) | |
| - cues (scroll sideways, several selectable), ADD / REMOVE | yes |
| - fixtures grid: red = the loaded cue's fixtures (white for an empty slot), drag selection | yes (grid shared with PATCH in `ui.js`) |
| - RENAME CUE / CONDITION / ENTER DELAY / ENTER FADE | yes |
| - LOAD / RECORD / CLEAR / CLEAR ALL, the programmer follows live and is followed | yes (cue records and programmer in `core/cue_codec.dart`) |
| - LED faders, enabled by the selected fixtures' channels | yes |
| - colour mode button: faders / colour square / colour wheel | yes |
| - pan / tilt pad (-100..100), home, Fine | yes |
| - FX dialogs (waveforms, Size / Speed / Phase window faders, X / Ok / Cancel, live), red when the loaded cue has FX | yes |
| - LOAD of a cue: which fixtures | the page reads them from the cue's records (the app keeps its own list) |
| **POSITIONS** (`positions_screen.dart`; POS in EDIT's pad buttons) | |
| - 8 x 8 tiles, STORE (merge) / RENAME / SWAP / DELETE armed, SELECTED / WITH FIXTURES, recall back to EDIT | yes (`light/src/positions.js`; store logic shared: `models/position_store.dart`) |
| - pan / tilt per fixture on the LPU, one fixture at a time | yes (shared: `LpuSession.programmerPositions`) |
| - kept with the show file | the box: `NAME.positions` next to `NAME.show` (not listed); the PC bridge: `NAME.positions.json`, the Windows app's file; saved with SAVE / SAVE AS, read with OPEN |
| **PATCH** (`patch_screen.dart`, `fixture_grid.dart`) | |
| - 8 x 8 grid: name / number, manufacturer / model / mode, flags, address (red on a DMX collision), drag selection, DESELECT ALL | yes |
| - PERSONALITY LIBRARY (a-z, manufacturer / model / mode), RENAME FIXTURE, SET START ADDRESS (DIP switches, arrows), CLEAR, flags | yes (free addresses: `core/patch.dart`) |
| - where changes go | the page writes each change to the LPU at once and reads it back (`LpuSession.patchFixture`); the app changes its show and sends it with OPEN |
| Dialog style (`dialogs.dart`) | yes, shared in `light/src/ui.js` (panel, buttons, field, check box, segments, name dialog) |
