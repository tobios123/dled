---
name: lpu-show-download
description: Download / extract / back up the complete show from an LPU-1 lighting controller over the network into a .show file and/or a readable text report (fixtures, playbacks, cues, channel values, FX, device settings like alias, Art-Net and sACN). Use this whenever the user wants to get, save, back up, export, inspect or document what is currently on their LPU, compare the LPU with a .show file, or asks what the LPU is playing - even if they only say "pull the show off the device" or "what's on my LPU".
---

# Download the show from an LPU-1

The script reads everything the reference app reads when it connects: device
settings, all 64 fixture slots, all 64 playbacks, and every cue's settings and
4 data blocks. It only reads - nothing on the LPU changes - and it only asks
for slots, cues and blocks the LPU itself reports. That matters: open-ended
reads past the end of the show have wedged the LPU firmware before (it needed
a power cycle), so don't replace this with ad-hoc probing.

## Run it

```bash
python .claude/skills/lpu-show-download/scripts/lpu_download.py --ip <LPU-IP> --show lpu_downloads/lpu_2026-10-22.show --txt lpu_downloads/lpu_2026-10-22.txt
```

- `--ip` the LPU's address (the one the user gives, or found earlier in the
  conversation). Leave it out to find the LPU by broadcast discovery (fails
  with a list if several answer).
- `--show FILE` write a .show the reference app can open.
- `--txt FILE` write the readable report (same format as `lpu-show-read`).
  `--summary` leaves out per-fixture values.
- `--port` only for tests against the emulator (see below).

At least one of `--show` / `--txt` is required. A typical show downloads in
1-2 seconds on the real device (reads overlap, FINDINGS 20.16). Unless the user says otherwise, save into
`lpu_downloads/` in the project with names that say what and when, e.g.
`lpu_2026-10-22.show` (folders are created as needed). The report format is
explained in the `lpu-show-read` skill.

## Things to tell the user

- Fixture **names** and patch **flags** (invert pan/tilt, swap pan/tilt,
  virtual dimmer) are saved in the .show like the app does (`label`,
  `invert_pan="true"`, ...). Device settings (alias, Art-Net, sACN) have no
  place in the .show; they are only in the text report.
- The LPU stores model names cut to 29 characters; the report shows them as
  stored.
- If the download fails with "no answer", the LPU is unreachable or another
  tool is talking to it. The reference app can stay connected while downloading.

## Testing without hardware

`analysis/scripts/lpu_emulator.py` runs a fake LPU (if the user says one is
already running at an address/port, just use it). For a self-test on one PC:
`python analysis/scripts/lpu_emulator.py --port 26945 --bind 127.0.0.1 --ip 127.0.0.1 --show some.show`
and download with `--ip 127.0.0.1 --port 26945`.

Protocol details: `analysis/FINDINGS.md` section 20, code in `analysis/lpu/`.
