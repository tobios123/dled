# LPU tools

Python tools for the LPU-1 and `.show` files, built
on the protocol decoded in `FINDINGS.md` section 20. Standard library only
(Python 3.9+). Commands below run from the project folder.

## The three skills

Claude Code picks these up from `.claude/skills/` when you ask in plain words
("what's in this show", "back up my LPU", "put this show on the LPU").
The scripts also work on their own:

| Task | Command |
|---|---|
| Report on a .show file | `python .claude/skills/lpu-show-read/scripts/show_report.py FILE.show [--out report.txt] [--summary]` |
| Download the LPU's show | `python .claude/skills/lpu-show-download/scripts/lpu_download.py [--ip IP] --show out.show --txt out.txt` |
| Upload a .show (dry run) | `python .claude/skills/lpu-show-upload/scripts/lpu_upload.py FILE.show [--ip IP]` |
| Upload a .show (for real) | `... lpu_upload.py FILE.show [--ip IP] --yes` (backs up to `lpu_backups/`, uploads, verifies) |

Without `--ip` the LPU is found by broadcast discovery.

## Emulator

`analysis/scripts/lpu_emulator.py` is a fake LPU-1 that the reference app and
the tools can use:

```
python analysis/scripts/lpu_emulator.py [--show start.show] [--save end.show] [--alias EMU] [--log]
```

- Answers discovery and announces itself every second.
- Keeps a show in memory, echoes and stores every write, answers every read
  with the real LPU's value types, sends the change notifications, and
  handles GO / FLASH / RELEASE / RELEASE ALL, swap, insert/delete cue,
  programmer load/record and the options page.
- No DMX output; fade/follow timing is not simulated.
- Port 16945: the reference app also listens there, so it can't run on the same
  PC address as the emulator. Close the PC app and use the app on a
  phone/tablet, or give the PC a second IP and pass `--bind`/`--ip` with it.
  (Binding the PC's own LAN address next to the app was tried on 2026-10-23:
  the emulator then caught the app's traffic, including the real LPU's, and
  echoed it back in an endless loop.) Frames from real LPUs and notifications
  are now ignored.
- Self-test on one PC: `--port 26945 --bind 127.0.0.1 --ip 127.0.0.1`, and
  pass `--ip 127.0.0.1 --port 26945` to the download/upload scripts.

## Monitoring

`analysis/scripts/live_vn_monitor.py` decodes <-> LPU traffic live
(needs Wireshark/tshark). `--pcap FILE` decodes a saved capture.

## Library (`analysis/lpu/`)

| Module | Contents |
|---|---|
| `protocol.py` | frame build/parse, `LpuClient` (lock-step writes, `read_many` with overlapping reads, keepalive), `discover()` |
| `showfile.py` | `.show` load/save, cue time format, 50-byte record decoding, FX tables |
| `personalities.py` | `personalities.xml` lookup, DMX function names |
| `report.py` | the text report |
| `lpu_io.py` | `download()`, `upload()`, `compare()` |
| `simulator.py` | the emulator (`LpuState`, `LpuEmulator`, `run()`) |

## Tests

```
python -m unittest discover -s analysis/tests -v
python analysis/scripts/emulator_conformance.py "samples/*.pcapng" --show SOME.show
```

The unit tests cover the decoders, `.show` round trips and an emulator
upload/download round trip. The conformance script replays the reference app's
frames from every capture into the emulator and checks that each write is
echoed and each read answered with the same value type as the real LPU
(21 captures pass).

## Known limits

- Fixture names/flags live in `.show` `<fixture>` attributes (FINDINGS 20.10);
  download writes them, upload applies them (absent = off). Device settings
  (alias, Art-Net, sACN) are in the report only. Unknown attributes and
  sections (e.g. `<buttons>`) are kept unchanged on load/save.
- The LPU cuts model names to 29 characters.
- Every record byte is mapped (FINDINGS 20.11). Open: which fader drives the
  DMX function codes 0x13 (UV) and 0x80 (generic).
- Upload sends every value (slower than the reference app, which only sends
  differences, but nothing of the previous show survives).
