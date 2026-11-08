# DMX Programmer Logic

## What is a DMX Programmer application?

A DMX programmer (also called a "lighting console") is software/hardware that controls
stage lighting fixtures over the DMX512 protocol. DMX sends a universe of 512 channels,
each with a value 0-255, at ~44 Hz. Each fixture occupies one or more consecutive channels
starting at its patched address.

---

## App architecture — three screens

### 1. PATCH screen
The patch screen maps real physical fixtures to DMX channel addresses.

- **Fixture library** (`personalities.xml`): Contains manufacturer/model/mode definitions.
  Each mode stores a hex string where every 2 hex characters = 1 DMX channel.
  Example: `"090A0B"` = 3 channels (channel functions: intensity, strobe, colour).
- **Patch grid**: 64 slots. Each slot holds one `FixturePatch` with:
  - `slot` (0-63): visual position on grid
  - `address` (1-512): first DMX channel in the universe
  - `universe` (0-255): Art-Net/sACN universe number
  - `channelCount`: number of DMX channels this fixture uses (from personality hex)
  - `manufacturer`, `model`, `mode`: identity
  - `label`: user-readable name
- **Auto-addressing**: when patching multiple fixtures of the same type, the address
  increments by `channelCount` per fixture, so they don't overlap.
  Example: 3x PAR fixture, 4ch each, starting at address 1 → 1, 5, 9.
- **Universe**: 512 channels max per universe. Fixture address + channelCount - 1 must be <= 512.

### 2. EDIT screen (Programmer)
The edit/programmer screen is where lighting looks are designed and recorded.

**Programmer concept:**
The "programmer" is a temporary workspace. It holds channel values for selected fixtures.
Values in the programmer override the playback output (programmer always wins = "HTP override").

**Workflow:**
1. **Select fixtures** from the grid (fixtures patched in PATCH screen appear here).
   - Selected fixture highlighted white/blue.
   - Fixtures with programmer values highlighted green.
2. **Set attribute values** using the channel faders at the bottom:
   - R, G, B, A, W = colour channels (red, green, blue, amber, white)
   - In = intensity/dimmer
   - Sh = shutter/strobe
   - Col = colour wheel
   - Go = gobo wheel
   - Rota = gobo rotation
   - Prism, Iris, Focus, Zoom, Frost = optical effects
   - Custom = user-defined
3. **LOAD**: copies current cue values for a fixture back into programmer (for editing existing cues).
4. **RECORD**: saves the current programmer state as a new cue in the selected cuelist.
   - A **cue** is a snapshot of channel values for all fixtures in the programmer.
   - After recording, the programmer is cleared.
5. **CLEAR**: discards all programmer values without recording.

**Cuelists:**
- A cuelist is a sequence of cues (scenes).
- Each cue can have a fade-in time, delay, and condition.
- The cuelist is assigned to a playback slot (1-64).

### 3. PLAYBACK screen
The playback screen runs the show.

**Playback grid (8x8 = 64 slots):**
- Each slot holds a cuelist.
- Tap to GO (start playing) / tap again to release.
- Playing cuelists drive DMX output.

**Fader strips (8 physical faders):**
- Each fader controls the intensity/level of one cuelist (0-100%).
- **FLASH button** (momentary): hold = force full level (100%), release = back to fader value.
  Used for flash/bump effects (e.g. hitting a beat in music).
- **Rotary knob**: controls a secondary parameter (speed, effect rate, etc.).

**Playback properties per cuelist:**
- **Background**: cuelist continues playing when another is started.
- **Exclusive**: releasing this cuelist also releases all others.
- **Go Mode**: Go (advance cue), Toggle (go/release), Flash (momentary), Solo (mutes others).
- **Repeat**: Loop, Bounce, Random, Off.

**RELEASE button** (top bar):
- If a cuelist is selected: releases only that cuelist (fade to black, state = released).
- If no cuelist selected: releases ALL active cuelists.

**SWAP button**: tap SWAP then tap another slot to swap the cuelist labels between two slots.

---

## DMX output flow

```
Fixtures (PATCH) -> Programmer values (EDIT) -> HTP merge with Cuelists (PLAYBACK)
                                                      |
                                               Fader level scaling
                                                      |
                                          Art-Net / sACN output -> fixtures
```

- **HTP (Highest Takes Precedence)**: for intensity channels, the highest value from any
  source (programmer or any active cuelist) is output.
- **LTP (Latest Takes Precedence)**: for position/colour channels, the most recently
  changed value wins.
- **Fader level**: scales the output of a cuelist. Fader at 50% = all values halved.
- **Blackout**: overrides ALL output to 0 on all channels.

---

## Network output (OPTIONS tab)

Since v0.8 the app sends **no DMX itself**: the LPU does all DMX output (its
own DMX port, and Art-Net / sACN if switched on). The flow above describes
what the LPU computes.

- The device list shows the LPUs found by VN discovery (UDP 16945).
- The Art-Net / sACN switches and the rename change the **connected LPU's**
  settings (alias, Art-Net on/off, sACN on/off); the LPU reads them back.
  For an LPU that is not connected they only change the list.

---

## Show file format

> **Two different things, do not confuse them.** The JSON below is this Flutter
> app's **own internal cache / working state** (how it persists the live model
> in `SharedPreferences` between launches). It is **NOT** the .show interchange
> `.show` file. The real `.show` file that the reference app imports/exports and that the LPU
> speaks is **UTF-8 XML** (`<show application="..." version="1.19.0">` with
> `<fixtures>` / `<playbacks>` / `<cues>` / base64 `<block>` elements) -- see
> `SHOW_FORMAT.md` and `PLAYBACK_CUE_OPTIONS.md` for the authoritative format.

Internal app cache (this app's model, saved in SharedPreferences):
```json
{
  "showFileName": "My Show",
  "cuelists": [ { "id": 1, "label": "Front wash", "state": 0, "level": 0.0, ... } ],
  "fixtures": [ { "id": 1, "slot": 0, "manufacturer": "...", "address": 1, "channelCount": 4, ... } ]
}
```
- Max 50 show files.
- Show is marked "modified" (asterisk in footer) whenever fixtures or cuelists change.
- SAVE persists the internal cache to SharedPreferences; OPEN loads and replaces
  the current show. (Importing/exporting the real XML `.show` interchange file is
  a separate path -- see `SHOW_FORMAT.md`.)

---

## Key data model relationships

```
ShowModel
  |- cuelists: List<Cuelist>        (64 slots, playback)
  |- fixtures: List<FixturePatch>   (patched fixtures, shared by PATCH + EDIT)
  |- networkDevices: List<NetworkDevice>
  |- showFiles: List<ShowFile>      (saved show index)
```

`FixturePatch.channelCount` drives:
- Auto-address increment in PATCH screen when adding multiple fixtures
- Channel address overlap prevention (address + channelCount - 1 <= 512)
- Future: determines which attribute faders map to which DMX channels
