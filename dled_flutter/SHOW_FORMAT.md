# .show File Format — Decoded Status

Source file analysed: `m400_12x12_rgb_dim_shut.show`

---

## XML Structure

```
<show application="..." version="1.19.0">
  <system>
    <host>
      <os/>
      <ips><ip/></ips>
    </host>
    <device>
      <mac/>  <ip/>  <subnet/>  <dhcp/>
      <pcb_version/>  <firmware_version/>  <type/>
    </device>
  </system>
  <fixtures>
    <fixture index address manufacturer model mode profile/>
  </fixtures>
  <playbacks>
    <playback index label intensity gomode repeat speed>
      <cues>
        <cue fade delay condition label>
          <blocks>
            <block>base64...</block>   <!-- block 0 = bank 0: fixtures 0-15   (800-byte DMX snapshot) -->
            <block>base64...</block>   <!-- block 1 = bank 1: fixtures 16-31  (empty if unpatched) -->
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

## Fields Fully Decoded and Wired

### `<show>` root
| Attribute    | Type   | Used as               |
|--------------|--------|-----------------------|
| `version`    | string | `ParsedShow.appVersion` |

### `<system/device>` (child element text)
| Element            | Used as                         |
|--------------------|---------------------------------|
| `<type>`           | `ParsedShow.deviceType`         |
| `<firmware_version>` | `ParsedShow.firmwareVersion`  |
| `<ip>`             | `ParsedShow.deviceIp`           |

### `<fixture>` attributes
| Attribute      | Type   | Used as                              |
|----------------|--------|--------------------------------------|
| `index`        | int    | `ShowFixture.index` (block record 0-15) |
| `address`      | int    | `ShowFixture.address` (DMX start, 1-based) |
| `manufacturer` | string | `ShowFixture.manufacturer`           |
| `model`        | string | `ShowFixture.model`                  |
| `mode`         | string | `ShowFixture.mode` (omitted by the app when the model has no modes) |
| `profile`      | hex string | `ShowFixture.functionCodes` (2-hex-digit pairs = DMX channel function codes) |
| `invert_pan`, `invert_tilt`, `swap_pan_tilt`, `virtual_dimmer` | `"true"` | Patch-screen flags. Written only when on (CONFIRMED with an app-saved file, 2026-10-23); absent = off. Not read by `show_loader.dart` yet. |
| `label`        | string | Fixture name from the patch screen, written right after `index` and only when set (CONFIRMED, 2026-10-23). Not read by `show_loader.dart` yet. |
> Files may also hold attributes or sections not listed here (for example
> fixture `personality`, playback `level`, a `<buttons>` section, `readonly`
> on `<show>`). The Python tools in `analysis/lpu/` and the Dart reader keep
> such unknown attributes / sections unchanged.

Profile decoding: each 2-character hex pair is a function code mapped to a byte offset within the 50-byte fixture record via `kFunctionOffset` (see `show_loader.dart`).

### `<playback>` attributes
| Attribute   | Type   | Default | Used as                          |
|-------------|--------|---------|----------------------------------|
| `index`     | int    | —       | `ShowPlayback.index` (cuelist slot 0-63) |
| `label`     | string | `''`    | `Cuelist.label`                  |
| `intensity` | float  | `1.0`   | `Cuelist.level`                  |
| `gomode`    | enum   | `Go`    | `Cuelist.goMode` (`Go`/`Toggle`/`Flash`/`Solo`; `Go` is the omitted default) |
| `repeat`    | enum   | `Loop`  | `Cuelist.repeatMode` (`Loop`/`Bounce`/`Random`/`Off`; `Loop` is the omitted default) |
| `speed`     | float  | `1.0`   | `Cuelist.speed` (negative = reverse) |

### `<cue>` attributes
| Attribute   | Type   | Default  | Used as                              |
|-------------|--------|----------|--------------------------------------|
| `fade`      | `HH-MM-SS-FF` | `0.0s` | `Cue.fadeIn` and `Cue.fadeOut` (seconds) |
| `delay`     | `HH-MM-SS-FF` | `0.0s` | `Cue.delay` (seconds)          |
| `condition` | enum   | `Halt` | `Cue.condition` — exactly two values `Halt`/`Follow`. `Halt` is the omitted default; only `condition="Follow"` is written on disk. |
| `label`     | string | `''`     | `Cue.label`                         |

### `<block>` (first non-empty block per cue)
800 bytes (base64-encoded), decoded as 16 records x 50 bytes.  
Record index = fixture `index` attribute.  
Within each 50-byte record, channel values are at fixed byte offsets keyed by function code (`kFunctionOffset` map).  
Values are uint8 (0-255); 16-bit movers use a coarse+fine uint16 BE pair.

#### FX encoding within block 0

Each fixture's 50-byte record contains **three fixed 4-byte FX slots** at byte offsets 0, 4, and 8.
These are at the start of the record, before any DMX channel data.

```
Bytes  0-3   Intensity FX slot
Bytes  4-7   Position  FX slot
Bytes  8-11  Colour    FX slot

Each 4-byte slot layout:
  byte +0  waveform_id   uint8
  byte +1  size          uint8  0-255  (app slider 0-100%)
  byte +2  speed         int8          (app slider -100..100%, ~1.27 per %:
                                        0 = 0%, 255 = -1%, 129 = -100%; the app
                                        writes +100% as 128, read 128 as +100%)
  byte +3  phase         uint8  0-255  (app slider 0-100%)
```

If `waveform_id == 0 && size == 0 && speed == 0` the slot is inactive (no FX).

**Confirmed waveform IDs** (from `show_all_fx_options.show`):

| ID | Intensity FX   | Position FX | Colour FX    |
|----|----------------|-------------|--------------|
|  0 | None           | None        | None         |
|  1 | Sine           | —           | —            |
|  2 | Ramp           | —           | —            |
|  3 | Inversed ramp  | —           | —            |
|  4 | Square         | Square      | —            |
|  5 | Random         | Random      | Random       |
|  6 | —              | Circle      | —            |
|  7 | —              | Eight       | —            |
|  8 | —              | Pan         | —            |
|  9 | —              | Tilt        | —            |
| 10 | —              | —           | Rainbow      |
| 11 | —              | —           | Full Sines   |
| 12 | —              | —           | Full Twinkle |

Note: IDs 1-3 and 6-12 are category-specific; the same numeric value means different waveforms in different FX categories.

---

## Fields Read but NOT Yet Used / Applied

| Element / Attribute             | Notes                                              |
|---------------------------------|----------------------------------------------------|
| `<system/host/os>`              | Parsed as XML but discarded — not stored           |
| `<system/host/ips/ip>`          | Parsed as XML but discarded — not stored           |
| `<system/device/mac>`           | Not stored                                         |
| `<system/device/subnet>`        | Not stored                                         |
| `<system/device/dhcp>`          | Not stored                                         |
| `<system/device/pcb_version>`   | Not stored                                         |

---

## Fields NOT Decoded (Unknown)

| Location                    | What we know                          | Unknown                                  |
|-----------------------------|---------------------------------------|------------------------------------------|
| 50-byte record bytes 12-15  | Three FX slots (0-11) and the channel region (16-49) decoded; see below. | The 4-byte gap at 12-15 has never been observed non-zero. Purpose unknown. |

---

## Block Binary Layout (decoded)

```
800 bytes = 16 records x 50 bytes
Record i = bytes [i*50 .. i*50+49]  (i = fixture index 0-15)

Within each 50-byte record:
  bytes 0-11 are the three 4-byte FX slots (Intensity 0-3, Position 4-7,
  Colour 8-11; see the FX section above). The DMX channel region runs from
  byte 16. Which function codes a fixture exposes comes from its own profile
  hex, so only those offsets carry channel data.

  Every value is u16 little-endian (16-bit: high byte = coarse channel, low
  byte = fine channel); pan / tilt are int16, signed around the centre (DMX =
  32767 + value, all zero = centre). Measured from the LPU's DMX output on
  2026-10-27 (lpd/DMX_ENGINE.md section 2); before that this said big-endian.

  offset  programmer fader   status
  ------  ----------------   ------
  12      pan                confirmed
  14      tilt               confirmed
  16      intensity          confirmed
  18      colour wheel       confirmed
  20-28   R, G, B, A, W      confirmed (2026-10-23: per-fixture R/G/B cues)
  30      gobo               confirmed
  32      gobo rotation      confirmed
  34      shutter            confirmed
  36      iris               confirmed
  38      frost              confirmed
  40      focus              confirmed
  42      prism              confirmed
  44      zoom               confirmed
  46      custom 1           confirmed
  48      custom 2           confirmed
```

"Confirmed" = an app-saved cue switched exactly that fader on or off
(`show_all_fx_options.show`, playbacks "color and gobo", "new channels de",
"missing channel", 2026-10-23). Bytes 12-15 are NOT the FX slots: those are 0-11.

> **`kFunctionOffset` in `show_loader.dart` is wrong** (it puts pan/tilt at
> 4-7, colour wheel at 30, shutter at 36, ...). Use the table above.
> Which function *code* in a fixture's `profile` drives each fader is only
> partly known: 0x01 intensity, 0x02/0x03 pan/tilt, 0x04-0x08 R G B A W,
> 0x09 colour wheel, 0x0A gobo, 0x0C shutter; by the code order (FINDINGS 20.11)
> 0x0B gobo rotation, 0x0D iris, 0x0E frost, 0x0F focus, 0x10 prism, 0x11 zoom,
> probably 0x12 custom 1. Which fader drives 0x13 (UV) and 0x80 is open.

---

## Summary

| Category          | Status                    |
|-------------------|---------------------------|
| Show metadata     | ✓ decoded                 |
| Device info       | ✓ partially decoded (type, firmware, ip) |
| Fixture patch     | ✓ decoded                 |
| Playback settings | ✓ decoded (all 6 attrs)   |
| Cue settings      | ✓ decoded (fade, delay, condition, label) |
| DMX block 0       | ✓ decoded (800-byte snapshot) |
| DMX blocks 1-3    | ✓ decoded (banks 1-3 = fixtures 16-63, global index = block*16 + record) |
| Host system info  | ✗ not stored              |
| Device MAC/subnet | ✗ not stored              |
