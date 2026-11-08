---
name: lpu-show-upload
description: Upload / send / load a .show file onto an LPU-1 lighting controller over the network, replacing the show on the device, with an automatic backup of the current show and a read-back verification. Use this whenever the user wants to put, push, restore, deploy or program a .show onto their LPU, restore a backup, or copy a show from one LPU to another - even if they phrase it as "open this show on the LPU" or "make the LPU play this".
---

# Upload a .show to an LPU-1

Uploading replaces **everything** on the LPU: all fixtures and all 64
playbacks. Playbacks that are running are affected immediately. That is why
the script has three safety steps and why you confirm with the user first.

## 1. Dry run (always first)

```bash
python .claude/skills/lpu-show-upload/scripts/lpu_upload.py "path/to/file.show" --ip <LPU-IP>
```

Without `--yes` nothing is sent and the LPU is not contacted. It validates the
file (slot ranges, DMX addresses within 1-512, block sizes, at most 48 cues
per playback) and lists the fixtures (with names/flags) and playbacks it would
write, plus how many slots get cleared. Exit code 2 = dry run done (expected,
not an error). If it reports errors, stop and explain them; don't try to "fix"
a show file silently.

## 2. Confirm

Tell the user which file goes to which LPU, that it replaces the current show,
and that a backup is made first. Point out what disappears: every fixture and
playback slot not in the file is cleared (the dry run says so loudly when the
file has no playbacks at all). Upload only after a clear yes - a request like
"check whether this show is OK" is not a yes.

## 3. Upload

```bash
python .claude/skills/lpu-show-upload/scripts/lpu_upload.py "path/to/file.show" --ip <LPU-IP> --yes
```

It then (the upload itself starts with RELEASE ALL: replacing a show under
running playbacks once left the LPU stuck until a power cycle, FINDINGS 20.13):
1. downloads the LPU's current show to `lpu_backups/lpu_<ip>_<time>.show`
   (`--backup FILE` to choose, `--no-backup` only if the user insists),
2. uploads, waiting for the LPU's echo of every frame (~20-30 s for a
   typical show),
3. reads the show back and compares it with the file
   (`--no-verify` skips this).

Exit code 0 = uploaded and verified. Exit code 1 = differences listed - report
them, and offer to restore the backup by uploading the backup file the same
way. If it stops with "no answer" mid-way, the LPU holds a partial show; tell
the user and offer to retry or restore the backup.

Leave out `--ip` to use broadcast discovery (fails with a list if several
LPUs answer). `--port` is only for the emulator.

## Notes

- Fixture names and patch flags (invert pan/tilt, swap, virtual dimmer) are
  part of the .show (`label`, `invert_pan="true"` ... on `<fixture>`; the app
  writes them only when set). The upload sets them exactly as in the file:
  flags in the file are switched on, and a flag that is on in the LPU but
  absent from the file is switched off.
  The LPU ignores pan/tilt flags on fixtures without pan/tilt.
- The LPU cuts model names to 29 characters; verification allows for that.
- The reference app only re-sends values that changed; this script always
  sends everything, which is slower but leaves nothing of the old show behind.

## Testing without hardware

Run the emulator (`python analysis/scripts/lpu_emulator.py --port 26945 --bind 127.0.0.1 --ip 127.0.0.1`)
and upload with `--ip 127.0.0.1 --port 26945 --yes`. Protocol details:
`analysis/FINDINGS.md` section 20, `dled_flutter/VN_PROTOCOL.md` section 12.
