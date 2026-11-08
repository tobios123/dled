# Playback & Cue Options Reference

Complete catalogue of every option a `<playback>` and a `<cue>` can carry in a
`.show` file (format version 1.19.0).

Every attribute below is proven from real show files and cross-checked against
the parser in `lib/services/show_loader.dart`. The source evidence files are:

- `samples/cue_fx_show.show`
- `samples/show_all_fx_options.show`
- `samples/m400_12x12_rgb_dim_shut.show`
- `samples/64fixtures_playback_menu.show`
- `samples/64fixtures.show`

---

## XML hierarchy

```
<show application="..." version="1.19.0">
  <playbacks>
    <playback index label intensity gomode repeat speed background exclusive>   <!-- a cuelist / fader -->
      <cues>
        <cue label delay fade condition>                   <!-- a step -->
          <blocks>
            <block>base64...</block>   <!-- block 0 = bank 0: fixtures 0-15   (800 bytes = 16 records x 50) -->
            <block>base64...</block>   <!-- block 1 = bank 1: fixtures 16-31  (empty if that bank is unpatched) -->
            <block>base64...</block>   <!-- block 2 = bank 2: fixtures 32-47 -->
            <block>base64...</block>   <!-- block 3 = bank 3: fixtures 48-63  (global index = block*16 + record) -->
          </blocks>
        </cue>

      </cues>
    </playback>
  </playbacks>
</show>
```

---

## 1. `<playback>` options (the cuelist / fader)

| Attribute   | Type / values                          | Default | Notes |
|-------------|----------------------------------------|---------|-------|
| `index`     | int, cuelist slot `0`–`63` (**required**) | —     | Physical fader/button slot. |
| `label`     | string                                 | `''`    | Display name. Optional. |
| `intensity` | float `0.0`–`1.0`                      | `1.0`   | Master level set by the **playback fader**. |
| `gomode`    | `Go` / `Toggle` / `Flash` / `Solo`     | `Go`    | How the GO button behaves. Stored capitalised in the file. |
| `repeat`    | `Loop` / `Bounce` / `Random` / `Off`   | `Loop`  | Cue-list loop behaviour. Stored capitalised in the file (see **"loop"** below). |
| `speed`     | float, **negative = reverse**          | `1.0`   | Playback/FX speed multiplier. Set by the **rotary knob** on the playback window (negative = reverse). The fader sets `intensity`, not speed. |
| `background` | bool `true` / `false`                 | `false` | "Background" checkbox in the **Playback Properties** window. Real file attribute `background="true"` (see note below). |
| `exclusive`  | bool `true` / `false`                 | `false` | "Exclusive" checkbox in the **Playback Properties** window. Real file attribute `exclusive="true"` (see note below). |

### Enum meanings

- **gomode**
  - `Go` – each press advances to the next cue.
  - `Toggle` – press to start, press again to release.
  - `Flash` – active only while held (momentary).
  - `Solo` – activates this playback and kills others.
- **repeat** (this is the **"loop"** option at the playback level)
  - `Loop` – restart from cue 1 after the last cue.
  - `Bounce` – play forward then backward.
  - `Random` – jump to random cues.
  - `Off` – stop after the last cue.
- **speed** — set by the **rotary knob** on the playback window. A **negative**
  value runs the playback/FX in **reverse**; `1.0` is normal forward speed. The
  **fader** sets `intensity`, **not** speed (there is no separate "speed
  slider"). Confirmed real `<playback>` attribute (see the evidence lines
  above).
- **background** / **exclusive** — boolean **checkboxes** in the
  **Playback Properties** window (`true` / `false`).
  - `background` – the playback keeps running / outputs regardless of the
    normal playback focus.
  - `exclusive` – activating this playback suppresses the others.
  - ✅ **Proven real `.show` attributes:** both are genuine lowercase
    `<playback>` attributes with lowercase `true` values, confirmed from
    `64fixtures_playback_menu.show` (`background="true"`, `exclusive="true"` —
    see the evidence lines below). They are rarely used, but
    `show_loader.dart._parsePlayback` **now reads both** (lowercase `true` /
    `false`, default `false`) and plumbs them through `ShowPlayback` →
    `applyToModel` into the `Cuelist.background` / `Cuelist.exclusive` fields,
    which already round-trip through the model's JSON.

### Real examples

```xml
<playback index="0"  label="fx color">
<playback index="5"  label="Strobe" gomode="Flash">
<playback index="26" label="Tilt"   speed="-0.4">
<playback index="15" speed="0.5">
<playback index="28"/>                 <!-- bare: everything defaults -->
```

Evidence (actual `<playback>` lines from real files):

- `m400_12x12_rgb_dim_shut.show`:
  `<playback index="15" speed="0.5" />`,
  `<playback index="26" label="Tilt" speed="-0.4">`,
  `<playback index="27" label="Pan" speed="-0.3">`,
  `<playback index="40" label="Intens" speed="-0.4">`, plus `gomode="Flash"`
  and `intensity="0.975104"`.
- `64fixtures_playback_menu.show` — four playbacks configured with every
  Playback-Properties option, labelled with abbreviations of their settings:
  `<playback index="0" label="backg solo off" repeat="Off" gomode="Solo" background="true">`,
  `<playback index="7" label="exclu flash ran" repeat="Random" gomode="Flash" exclusive="true">`,
  `<playback index="56" label="backg excl togg" repeat="Bounce" gomode="Toggle" background="true" exclusive="true">`,
  `<playback index="63" label="default">`, plus the simple
  `<playback index="24" intensity="0.443983" speed="0.9" />` and
  `<playback index="31" intensity="0.651452" speed="1" />`.

So `speed`, `intensity`, `gomode`, `repeat`, `background` and `exclusive` are
all confirmed real `<playback>` attributes, and **all six are now decoded** by
`show_loader.dart._parsePlayback` (each with its default fallback), plumbed
through `ShowPlayback` and written into the `Cuelist` model by `applyToModel`.

---

## 2. `<cue>` options (one step inside a playback)

| Attribute   | Type / values                       | Default  | Notes |
|-------------|-------------------------------------|----------|-------|
| `label`     | string                              | `''`     | Cue name. Optional. |
| `delay`     | `HH-MM-SS-FF` → seconds             | `0`      | Wait time before the cue fades in. |
| `fade`      | `HH-MM-SS-FF` → seconds             | `0`      | Crossfade duration (used for both fade-in and fade-out). |
| `condition` | `Halt` / `Follow` | `Halt` | Trigger behaviour. The reference app offers exactly two values: `Halt` and `Follow`. `Halt` is the omitted default; only `condition="Follow"` is written on disk. |

### `condition` — this covers "halt" and "follow"

The reference app UI offers exactly two cue conditions: `Halt` and `Follow`.
`Halt` is the omitted default; only `condition="Follow"` is written to the file.

| Value    | Meaning                                                        |
|----------|----------------------------------------------------------------|
| `Halt`   | Default. Cue waits for a **manual GO** — i.e. it **halts**.    |
| `Follow` | Auto-advances from the previous cue after its `delay` elapses. |


### Time format `HH-MM-SS-FF`

`FF` is hundredths of a second (frames at 1/100 s). Parsed in
`show_loader.dart._parseFade` as `h*3600 + m*60 + s + FF/100`.

| String        | Seconds |
|---------------|---------|
| `00-00-01-00` | 1.0 s   |
| `00-00-02-00` | 2.0 s   |
| `00-00-03-00` | 3.0 s   |

### Real examples

```xml
<cue label="Scene A" delay="00-00-02-00" fade="00-00-03-00">
<cue label="Chase B" delay="00-00-01-00" fade="00-00-01-00">
<cue condition="Follow" delay="00-00-02-00">   <!-- auto-follow after 2 s -->
<cue label="None">                              <!-- label only -->
<cue/>                                           <!-- bare snapshot, instant, manual GO -->
```

Evidence: `cue_fx_show.show` proves `delay`/`fade`; `m400_12x12_rgb_dim_shut.show`
has six cues `{condition:"Follow", delay:"00-00-02-00"}` plus many bare `<cue/>`
snapshot cues.

---

## 3. Per-cue DMX & FX data (inside `<block>`)

Each cue has **4** `<block>` elements. **The four blocks are four banks of 16
fixtures each** — a non-empty block is always base64 of **800 bytes = 16
records × 50 bytes**. The global fixture index is:

```
global_index = block * 16 + record
    block 0 -> fixtures  0–15
    block 1 -> fixtures 16–31
    block 2 -> fixtures 32–47
    block 3 -> fixtures 48–63   (max 64 fixtures)
```

This is where the **channels** and **fx** live. Only the number of banks
holding real patched data differs per file; the model is universal and applies
to every `.show` dynamically. `show_loader.dart` **now decodes all 4 blocks as
banks** (keying every record by its global index and emitting only patched
indices), so fixtures 16–63 are no longer dropped.

> **Bank model — proven on `64fixtures.show` (all 64 fixtures patched).**
> The earlier "4-frame chase" theory is **disproven**. Cue #7 (Rainbow colour
> FX) carries a continuous **colour-phase fan** across all 64 fixtures:
> `phase = 3 + global_index * 4`
> — block 0 rec0=3 … rec15=63, block 1 = 67…127, block 2 = 131…191,
> block 3 = 195…255. One unbroken ramp across the banks means a **spatial
> fan-out across fixtures, NOT a time-based chase between blocks**. Blocks that
> look like "duplicates" are simply banks each holding their own 16 fixtures at
> the same FX settings.
>
> **Block-2 stray record (sparse shows).** When every patched fixture fits in
> bank 0 (index < 16), block 2 can still carry exactly **one** extra non-zero
> record at a fixed per-file index that mirrors block 0's FX but sits at an
> **unpatched** global index (`show_all_fx_options.show` = rec13 → global 45;
> `m400_12x12_rgb_dim_shut.show` = rec6 → global 38). Leading theory: an app
> grid cell that was **selected but left unpatched**, captured when Record was
> pressed. Because the bank parser emits only patched indices, this stray is
> **dropped naturally** and never reaches the model.


### 3a. Channels (static DMX levels per fixture)

Channel values are stored at fixed record-relative slots as 16-bit big-endian
pairs. Which channels a fixture exposes comes from its `profile` hex (each
2-hex-digit pair is a DMX function code).

| Confidence | Channels |
|------------|----------|
| 100% verified | Dimmer, Red, Green, Blue |
| ~80% confident | Pan, Tilt, Shutter (`0x0C`) |
| Function-code set a fixture may carry | Dimmer, Pan, Tilt, Pan-fine, Tilt-fine, Red, Green, Blue, Amber, UV/White, Colour wheel, Colour wheel 2, Gobo 1, Gobo 2, Shutter/Strobe, Prism, Focus, Zoom, Iris, Colour-temperature, Motor speed |

### 3b. FX — three independent layers

Each layer is a 4-byte slot `[type, size, speed, phase]` (byte order as read
by `show_loader.dart._decodeFxSlot`):

- `type`  – waveform ID (category-specific; see below)
- `size`  – `0`–`255` (app slider `0…100%`)
- `speed` – signed int8 (app slider `-100…+100%`, about 1.27 per %: `0` = 0,
  `255` = −1 %, `129` = −100 %; the app writes +100 % as `128`, read it as +100)
- `phase` – `0`–`255` (app slider `0…100%`)

| Layer         | Waveform types                                        |
|---------------|-------------------------------------------------------|
| **Colour**    | None, Random, Rainbow, Full Sines, Full Twinkle       |
| **Position**  | None, Square, Random, Circle, Eight, Pan, Tilt        |
| **Intensity** | None, Sine, Ramp, Inversed Ramp, Square, Random       |

Confirmed waveform ID table (from `show_all_fx_options.show`):

| ID | Colour FX    | Position FX | Intensity FX   |
|----|--------------|-------------|----------------|
| 0  | None         | None        | None           |
| 1  | —            | —           | Sine           |
| 2  | —            | —           | Ramp           |
| 3  | —            | —           | Inversed Ramp  |
| 4  | —            | Square      | Square         |
| 5  | Random       | Random      | Random         |
| 6  | —            | Circle      | —              |
| 7  | —            | Eight       | —              |
| 8  | —            | Pan         | —              |
| 9  | —            | Tilt        | —              |
| 10 | Rainbow      | —           | —              |
| 11 | Full Sines   | —           | —              |
| 12 | Full Twinkle | —           | —              |

> The same numeric ID means a different waveform in each category.

---

## 4. Quick map of the common terms

| Term you asked about | Where it lives | Attribute / field |
|----------------------|----------------|-------------------|
| **fx**        | `<cue>` block 0 | 3 FX slots (colour / position / intensity), each type+size+speed+phase |
| **channels**  | `<cue>` block 0 | per-fixture DMX values (Dimmer / RGB / Pan / Tilt / …) |
| **fade**      | `<cue>`         | `fade` (HH-MM-SS-FF) |
| **delay**     | `<cue>`         | `delay` (HH-MM-SS-FF) |
| **halt**      | `<cue>`         | `condition="Halt"` (default; waits for manual GO) |
| **follow**    | `<cue>`         | `condition="Follow"` (auto-advance after delay) |
| **loop**      | `<playback>` | `repeat="Loop"` (whole cue list). |
| playback name    | `<playback>` | `label` |
| master level     | `<playback>` | `intensity` |
| button behaviour | `<playback>` | `gomode` (Go/Toggle/Flash/Solo) |
| speed / reverse  | `<playback>` | `speed` (negative = reverse) |

---

## 5. Single-playback options — complete list (static + runtime)

Every option that applies to **one playback**, split into the two places a
playback is configured/controlled: the **static settings persisted in the
`.show` file** and the **live settings exchanged over the app <-> LPU VN
protocol** (UDP port 16945) while the program is running. Cue-level options
(`fade` / `delay` / `condition` / `label` on `<cue>`, and the per-cue
block/channel/FX data) are **excluded** — they belong to cues, not playbacks.

### 5A. Static options saved in the `.show` file (`<playback>` XML attributes)

The persisted, per-playback settings. All eight are confirmed real attributes
and are decoded by `show_loader.dart._parsePlayback`.

| # | Attribute    | Type / values                        | Default | UI control |
|---|--------------|--------------------------------------|---------|------------|
| 1 | `index`      | int `0`–`63` (**required**)          | —       | physical fader/button slot |
| 2 | `label`      | string                               | `''`    | name field |
| 3 | `intensity`  | float `0.0`–`1.0`                    | `1.0`   | **playback fader** (master level) |
| 4 | `gomode`     | `Go` / `Toggle` / `Flash` / `Solo`   | `Go`    | GO button behaviour |
| 5 | `repeat`     | `Loop` / `Bounce` / `Random` / `Off` | `Loop`  | cue-list loop behaviour (the **"loop"** setting) |
| 6 | `speed`      | float, **negative = reverse**        | `1.0`   | **rotary knob** |
| 7 | `background` | bool `true` / `false`                | `false` | Playback Properties checkbox (keeps running regardless of focus) |
| 8 | `exclusive`  | bool `true` / `false`                | `false` | Playback Properties checkbox (suppresses other playbacks) |

(See section 1 above for enum meanings and real `.show` evidence lines.)

### 5B. Live/runtime options over app <-> LPU (VN protocol, UDP 16945)

What the app and LPU exchange while running, addressed per playback (the VN
`bank` byte = the cuelist/playback index; PUSH/write uses `bank | 0x80`).

| # | Option | Opcode / frame | Direction | Payload | Notes |
|---|--------|----------------|-----------|---------|-------|
| 1 | **Master level / fader** | `0x29`, 24-byte frame, `byte4 = playback_index` | App->LPU REQ (flags `0x03`); LPU echoes RSP (flags `0x83`) | float32 `0.0`–`1.0` at bytes 20-23 | Live equivalent of `intensity`; built by `makeFaderLevel(pbIndex, level)` |
| 2 | **Playback GO (fader sweep)** | `0x00`, raw 9-byte frame | App->LPU; LPU echoes | level byte `0x00` -> `0xf0` sweep | Triggers the playback / cue go |
| 3 | **Playback config object** | `0x2c` config_obj, bank = cuelist index, sub-index `0`/`1`/`2`/`4` | App<->LPU (PUSH `bank\|0x80` to write) | 8 / 12 / 14-byte config blob | Read/write of persisted playback settings (gomode / repeat / speed / trigger). This is what `cuelist_config_all_btn_toggled.pcapng` toggles |
| 4 | **Named float parameter** | `0x2d` float_param, bank = cuelist index, param index | App<->LPU (PUSH to write) | float32 | Per-playback float param (e.g. fade/speed stored value) |
| 5 | **Level-active state push** | `0x29` sub `0x22` (flags `0x02`) | LPU->App push | uint32 `0`/`1` | Playback active (running) = 1, inactive = 0 |
| 6 | **PUSH-active state push** | `0x29` sub `0x50` (flags `0x82`) | LPU->App push | uint32 `0`/`1` | Secondary active flag |
| 7 | **Level-state query** | `0x29` sub `0x42` (flags `0x1d`) | LPU->App | 20-byte, no body | Polls current level state |
| 8 | **Run-state / current cue position** | `0x29` sub `0x24` and sub `0x2f` (flags `0x81`) | LPU->App push | uint32 | Sub `0x24` = active-cue absolute counter (wraps at list length); sub `0x2f` = cue step index (`0`,`1`,`2`,`0xff`). This is the playback's live **position pointer** — kept here as playback run-state even though it references the current cue |

### 5C. Startup retrieval — what the app reads back from the LPU at connect

Part 5B above lists the **live control + LPU->App push** traffic. Equally
important for a single playback is the **read/query side**: when the app
connects it downloads each playback's persisted state back from the LPU flash.
Every static option in 5A is reconstructed from these reads (there is no local
copy — the LPU is the source of truth after a reconnect).

Connect sequence (see `VN_PROTOCOL.md` "Full connect + sync sequence"):

| Phase | Query (App->LPU) | Reply | Retrieves (per playback) |
|-------|------------------|-------|--------------------------|
| Phase 2 | **Cuelist bulk dump** `0x0a2b` (op `0x46`) | 820 bytes = 16 x 50-byte slot records | Which playback slots are **populated** — sentinel `0x55 0xd8` = this playback exists |
| Phase 3 | **Config object read** `0x0n2c` (bank = `n+1`) | config blob | `gomode` / `repeat` / `speed` / `background` / `exclusive` / trigger |
| Phase 3 | **Current level read** `0x0n29` | 24-byte level frame | `intensity` (master level) |
| Phase 3 | **Cue step list read** `0x0n2b` (string_list) | CSV list | the playback's **list of cues** (names / step order) |
| Phase 3 | **Float param read** `0x0n2d` | float32 | per-playback float params (fade/speed value) |
| Sweep | **Directory sweep** magic `0x29`, type `0x1d`, cmd `0x30`, sub-index 0..63 | directory reply per slot | per-playback **page / cue count** (enumeration) |
| Download | **Show-page download** `0x2b` sub `0x46` (820-byte pages) | 4 banks x page | the playback's actual cue **block content** (mostly cue-level) |

> **Read vs. write.** The `0x2c` config_obj and `0x2d` float_param in 5B are
> shown there as *writes* (PUSH `bank|0x80`); at connect they are also **read**
> (query with bit7 clear, bank = `n+1`). The `0x29` level is likewise both read
> (Phase 3) and controlled live (5B item 1).

> **Running-playback caveat (see `analysis/FINDINGS.md` section 19):** the
> directory sweep silently drops any playback that is currently RUNNING — it
> returns no parseable directory reply for that slot until the playback is
> released, so the sweep under-counts a live show.

### 5D. Static vs. runtime cross-reference

| Playback concept | Static (`.show`) | Runtime (VN) |
|------------------|------------------|--------------|
| master level     | `intensity`      | `0x29` level frame (byte4 = pb index) |
| go / trigger     | `gomode`         | `0x00` 9-byte GO sweep |
| loop behaviour   | `repeat`         | `0x2c` config_obj |
| speed / reverse  | `speed`          | `0x2c` config_obj / `0x2d` float_param |
| background       | `background`     | `0x2c` config_obj |
| exclusive        | `exclusive`      | `0x2c` config_obj |
| active / running | — (not stored)   | `0x29` sub `0x22` / `0x50` push |
| current cue      | — (cue-level)    | `0x29` sub `0x24` / `0x2f` push |

> **Directory-sweep caveat (see `analysis/FINDINGS.md` section 19):** while a
> playback is actively running it is silently dropped from the LPU directory
> sweep (magic `0x29`, type `0x1d`, cmd `0x30`, sub-index 0..63) — it returns no
> parseable directory reply for that slot until released.

---

*Generated from measurements of `.show` files; see
`SHOW_FORMAT.md` for the full binary block layout and
`analysis/lpu/showfile.py` for the decoder. Runtime options
cross-referenced against `VN_PROTOCOL.md` and `analysis/FINDINGS.md`.*
