# LPD-1 firmware

The LPD-1 is a box that does what the LPU-1 does: the original
app and DLED talk to it as to an LPU, and it computes the DMX itself.

| Part | State |
|---|---|
| `lib/engine` | **the DMX engine**: cue lists, go modes, fades with the intensity memory, HTP mixing, background / exclusive, FX generators with the speed knob, programmer / EDIT, fixture flags, DMX output. Portable C++17, no Arduino calls. Rules: `lpd/DMX_ENGINE.md` |
| `test/test_replay` | replays every recording of the real LPU (`lpd/replay`) into the engine and compares the DMX |
| `test/test_speed` | the worst case (64 playbacks x 64 fixtures x 3 FX) per frame |
| `lib/vn` | **the VN server**: what lets the apps work with the box as with an LPU-1 (it introduces itself as LPD-1) (port of `analysis/lpu/simulator.py`, on the engine's show, live control into the engine). Portable, no sockets |
| `test/test_vn` | the VN server without a network |
| `lib/dmxout` | DMX out on a MAX485 as WLED wires it: UART2, TX on GPIO2 |
| `lib/vn/vn_store.cpp` | the box's show file (show, fixture texts, device settings; ~15 kB for a 47-cue show) |
| `src/main.cpp` | the board: Ethernet, VN server on UDP 16945, the engine to DMX and Art-Net, render time on the serial log; the show saved in LittleFS, a test show while nothing is saved |
| `src/pc/main_pc.cpp` | the same on Windows (`env:pc`), for testing without the board; `--show-file` keeps the show |
| to do | sACN out, the LPD tests against the box (milestone 4) |

Run the tests on the PC (needs gcc: WinLibs MinGW-w64 on this PC):

```bash
python lpd/make_replay.py
```
(in the repository root: turns `lpd/tests` + `lpd/recordings` into `lpd/replay`), then in this folder

```bash
python -m platformio test -e native
```

Each replay prints its score (share of DMX values within 1 of the LPU's,
+-37.5 ms) and its worst steps. `LPD_REPLAY=NAME` runs one replay,
`LPD_TRACE=ch,fromMs,toMs` prints the LPU and the engine side by side for
one channel.

The VN server on the PC (another port when the reference app holds 16945 on
this PC):

```bash
python -m platformio run -e pc
```
then `.pio/build/pc/program.exe --port 26945 --bind 127.0.0.1 --artnet 127.0.0.1`
and e.g. `python analysis/scripts/emulator_conformance.py "samples/"*.pcapng --target 127.0.0.1:26945`,
the lpu-show-upload skill or `dart run bin/dled_cli.dart ... --ip 127.0.0.1 --port 26945`.

Build for the box:

```bash
python -m platformio run -e wt32-eth01
```

Flashing, pins and checks: [FIRST_FLASH.md](FIRST_FLASH.md) (replaces
what is on that board, e.g. WLED; not on the DLED bridge).
