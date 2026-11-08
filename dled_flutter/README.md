# DLED (Flutter app)

Programs and plays an LPU-1 over the network. See the
repository's `README.md` for the whole project.

- `lib/core/`: the LPU protocol, `.show` files, cue records (no Flutter
  imports; shared with the light page and the CLI)
- `lib/screens/`, `lib/widgets/`: PLAYBACK, EDIT (with POSITIONS), PATCH,
  OPTIONS
- `light/`: the light page (`light/PARITY.md`: what it has of the app)
- `bin/`: the CLI (`dled_cli.dart`) and the PC bridge (`dled_bridge.dart`)
- `VN_PROTOCOL.md`: the protocol

```bash
flutter test
flutter run -d windows
```
