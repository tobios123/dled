---
name: lpu-show-read
description: Read and explain a LPU-1 .show file - fixture patch with every DMX channel named from personalities.xml, playbacks with their options (go mode, repeat, background, exclusive, intensity, speed), cues with fade/delay/condition, and per-fixture channel values and FX for every cue. Use this whenever the user asks what is in a .show file, wants a show summarised, compared, checked or turned into a text report, asks which fixtures/channels/cues a show has, or mentions a .show file from the reference app or LPU - even if they don't say "report".
---

# Read a .show file

A `.show` file is XML written by the reference app: device info, a fixture patch,
and up to 64 playbacks whose cues store fixture data as base64 "blocks"
(4 blocks x 16 fixture records x 50 bytes). Reading it by hand is error-prone,
so use the bundled script; it decodes the blocks and names every DMX channel
from `dled_flutter/assets/personalities.xml`.

## Run it

From anywhere in the project:

```bash
python .claude/skills/lpu-show-read/scripts/show_report.py "path/to/file.show"
```

Options:
- `--out report.txt` write the report to a file instead of printing it
- `--summary` leave out the per-fixture channel values (good for big shows)
- `--personalities FILE` use another personalities.xml

For a long show, write to a file and read the parts the user asked about rather
than pasting the whole report back.

## Reading the report

- Numbers are 1-based like the reference app: fixture 1-64, playback 1-64, cue 1-N.
- `FIXTURES`: DMX range, manufacturer / model / mode, the fixture class from
  personalities.xml in brackets (e.g. `[Yoke wash]` - a category, not a name),
  then `name:` and `flags:` when set, and the DMX channel list. A note says
  when a fixture is not in personalities.xml or its profile differs.
- `PLAYBACKS`: options, then each cue with `[Halt|Follow, fade, delay]`.
  Only playbacks that exist are listed; the rest are empty.
- Per cue, one line per fixture with data (`fixture N:`): `int` (intensity),
  `RGBAW`, `pan`/`tilt`, the other faders by name (colour wheel, gobo, gobo
  rotation, shutter, iris, frost, focus, prism, zoom, custom 1, custom 2), and
  the three FX generators as `waveform size% speed% phase%` (`colour FX ...`).
  All values are % of full scale.
- `(no channel)` after a fader: the cue stores a value for a fader this
  fixture has no DMX channel for, so it has no effect (left over from
  programming with several fixture types selected).
- "data on unpatched slots": the app lets you select grid items without a
  fixture while recording and keeps their values; harmless.
- `@NN=x%` should no longer appear (every record byte is mapped); if it does,
  call it unmapped rather than guessing.

Channel names in the fixture's channel list marked `?` (e.g. `custom 1?`,
`red fine?`) are inferred, not confirmed; say so if the answer depends on them.
`.show` indexes are 0-based in the XML (`index="5"` = playback 6).

## Background

Record layout, FX encoding (speed is a signed byte, 0 = stopped) and the
function-code table are documented in `analysis/FINDINGS.md` section 20 and
`analysis/lpu/showfile.py`. The same report is produced for shows downloaded
from a live LPU (skill `lpu-show-download`).
