# lpd: what the LPU puts on DMX

Measurements for the LPD-1 (findings: `DMX_ENGINE.md`).

| Folder / file | What |
|---|---|
| `tests/NAME.show`, `NAME.steps.json` | a test as data: the show uploaded and the steps run (written by `lpd_run.dart` from `dled_flutter/tool/lpd/tests.dart`) |
| `recordings/NAME_TIME.jsonl` | the LPU's DMX during the test: first frame, then only the channels that changed, with the steps as marks (format: `dled_flutter/tool/lpd/dmx_capture.dart`) |
| `recordings/NAME_TIME.txt` | the report: per fixture channel the expected value and the DMX value at every snap |

Tools (run in `dled_flutter`; the LPU at 192.168.1.12 unless `--ip`):

```bash
dart run tool/lpd_output.dart
```
shows (or with `artnet=on` ... sets) the LPU's Art-Net / sACN output.

```bash
dart run tool/lpd_capture.dart --ch 1-40
```
watches the DMX live (`--out FILE` records, `--sacn`, `--secs N`).

```bash
dart run tool/lpd_run.dart --list
```
lists the tests; `dart run tool/lpd_run.dart NAME` backs up the LPU's show
to `lpu_backups/`, uploads the test show, runs it and writes the recording
and report (`--no-upload` reruns on the show already there, `--port N` sends from that
UDP port). The LPU keeps
the test show; put a backup back with the lpu-show-upload skill.

```bash
python lpd/analyse.py NAME
```
per step what every attribute did: constant, a fade (start, end, time,
curve) or a wave (range, period, one period's shape, phase per fixture).
`python lpd/snaps.py NAME [CH,...]` prints the report's snaps as a table.
`dart run tool/lpd_reset.dart` closes EDIT, clears the programmer and
releases everything (the runner does that before and after each test).

Tests: `static`, `encode` (tests.dart); `fx_intensity`, `fx_speed`,
`fx_knob`, `fx_position`, `fx_colour`, `fades`, `fader_flags`, `cuelist`,
`gomodes`, `mixing`, `programmer`, `extra`, `follow_delay`, `open`, `load`,
`load_when`, `load_prog`, `memory_flash`, `clear_closed`, `live_edit`, `random_long`, `colour_mix`, `codes`, `memory_reset` (for after a power cycle),
`all64`, `go_hold`, `knob_follow`, `release_go`, `pb_props`, `flash_solo`
(tests_more.dart). A new test: add it to one of those lists. The probe
fixture (`probe()`) has one channel per function code; P10 / P8 are small
fixtures with intensity, pan / tilt and RGBAW.

`python lpd/make_replay.py` turns every test and its newest recording into
`lpd/replay/NAME.txt` for the C++ engine's tests (`firmware/lpd1/README.md`).

**The LPD-1 against the LPU**: run a test on
the box (the PC build: `firmware/lpd1`, `program.exe --port 26945 --bind
127.0.0.1 --artnet 127.0.0.1`)

```bash
dart run tool/lpd_run.dart NAME --ip 127.0.0.1 --lpu-port 26945 --no-backup --rec-dir lpd/box_recordings --recorded-show
```
then `python lpd/compare.py [NAME]` compares the box's recording with the
LPU's (score and worst steps per test).

Run tests over Ethernet when timing matters: over Wi-Fi a few frames drop
now and then (a fade then shows a flat stretch).
