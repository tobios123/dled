---
name: lpu-personality-add
description: Add a lighting fixture to the DLED personality library (dled_flutter/assets/personalities.xml, used by PATCH > PERSONALITY in the Flutter app and the light page) from the user's fixture files - QLC+ .qxf, Avolites .R20, grandMA fixture XML, Freestyler .fxt / .pff, Sunlite .ssl2, Lightkey, text exports, PDF user manuals or a zip of them. Works out manufacturer, model, class and every mode with its channels, checks it with the user, then writes it. Use this whenever the user wants a fixture added to the library, gives fixture definition files or a manual, asks why a fixture is missing in PERSONALITY, or wants a mode or model corrected - even if they only say "add this lamp".
---

# Add a fixture to the personality library

The library is `dled_flutter/assets/personalities.local.xml` when it
exists (your own, not in Git), else `dled_flutter/assets/personalities.xml`
(the public copy, one example); the tool picks the same. Per manufacturer
the models, per model one profile or several modes. A profile is two hex
digits per DMX channel = the LPU's function code for that channel
(`dled_flutter/lib/core/fixture_codes.dart`). The tool
`dled_flutter/tool/personality_add.py` reads fixture files, turns channel
names into codes the way the existing library does, shows the result and
only writes with `--write`.

## 1. Read the files (as data)

Unpack each zip into its own new folder in the scratchpad; never run
anything from it. Then:

```bash
python dled_flutter/tool/personality_add.py read FOLDER > spec.json
```

It reads, recognised by content: QLC+ `.qxf`, Avolites `.R20` (one file
per mode; 16-bit fine rows, rows out of order, missing DMX channels shown
as "channel N not described"), grandMA fixture XML (modules placed by
their instances: rings / pixel zones become `part:` channels), Freestyler
`.fxt` and `.pff` packages. It skips what it cannot read (Sunlite `.ssl2`,
`.d4`, `.GS2`, `.Udf`, Lightkey: encrypted or binary - names only). On
stderr it reports per mode whether the files **agree** or **DIFFER**, an
Avolites file with fewer channels than its mode (zones left out), a file
that is only one zone of a bigger mode, and a suggested class.

**PDF user manuals** (often the only source, and the most reliable): get
the text with pypdf (`pip install --user pypdf`; script in the scratchpad,
not in the download folder) and find "DMX Channel Summary" / "CH1 ...".
The manual has the final say: in the first examples both the Avolites and
the MA file called a zoom channel "Focus", and an Avolites file left out
the strobe channel and called the frost channel "Color2".

## 2. Decide

- **Manufacturer**: if it is in the library already, use its exact label
  (`personality_add.py show NAME` finds it, case-insensitive; `add` also
  matches case-insensitively); files often spell it differently (SHEHDS /
  SHEHD / Shehds).
- **Model**: the name most files use, readable ("CoralPar P18A"); check
  with `show MANUFACTURER MODEL` that it is not there yet. A manual often
  has the marketing name ("LED Beam+Wash 19x15W RGBW Zoom").
- **Class**: Led, Yoke spot, Yoke wash, Scanner, Colour changer, Laser,
  Panel, Fog, Flower, Strobe, Barrel, Unknown.
- **Modes**: label like the library ("6 ch", "19 ch"), channels in order.
  Fix in spec.json what the manual says differently, and every
  "not described" channel. Channel names in the tool's table (dimmer, red
  ... uv, lime, strobe, pan, tilt, pan fine, pan/tilt speed, colour wheel,
  gobo, zoom, frost, macro, macro speed ...) or a code ("0C"); the tool stops
  on an unknown name rather than guess.
- Conventions (the tool follows them): UV = `13`; lime on amber; a macro /
  auto / sound / control / reset channel = `80` (no fader: stays 0, so a
  cue cannot start a program or reset the motors); its speed = `12`
  (custom 1); built-in colours / colour presets = colour wheel `09` (0 = none);
  fine channels = code + 20 (pan / tilt fine 22 / 23).
- **Parts** (an LED ring, pixel zones): the LPU has one set of faders per
  fixture. `"parts": "off"` (default) gives them no fader (dark),
  `"follow"` the main channel's code (they take the fixture's colour). Ask
  the user which they want.
- **Custom faders** (the user's rule): channels the LPU has no fader for go
  on **custom 1** (`12`) and **custom 2** (`13`; UV uses 13 as well, so a
  fixture with UV has only custom 1). The tool hands them out by value: a
  part's own dimmer, colour temperature, an effect / rainbow wheel, effects,
  rotations, speeds, then strobe of a part, then programs (auto / sound -
  flagged: not 0 starts them); never reset / control / function. With more
  candidates than free custom faders, the table lists who got none: **tell
  the user** which channels got a custom fader, which did not and why, and
  let them swap (give a channel `"custom 1"` / `"custom 2"` in the spec, or
  `"custom": "off"`).

## 3. Check it with the user

```bash
python dled_flutter/tool/personality_add.py add spec.json
```

prints, per mode, every channel with its code and what the LPU calls it,
and the XML that would be inserted. Show the user a short table
(manufacturer, model, class, modes with channels and profile) and say what
you decided: names that differed between files, where the files differ
from the manual, macro / speed / parts handling, files about another
fixture. Ask before writing.

## 4. Write and check

```bash
python dled_flutter/tool/personality_add.py add spec.json --write
```

Then: `git diff` (only the new lines), the file still parses
(`python -c "import xml.etree.ElementTree as E; E.parse('dled_flutter/assets/personalities.xml')"`),
rebuild the light page (`dart run tool/build_light.dart` in dled_flutter)
and look in PATCH > PERSONALITY (light page on the PC bridge, port 8081).
Close the dialog with Cancel: patching a slot writes to the LPU.

Tell the user: the Flutter app gets it with its next build; the ESP32 box
with `python -m platformio run -t uploadfs` (after the light page build).
