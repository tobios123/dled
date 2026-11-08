# `.show` - Annotated 50-byte Cue Record

A cue's binary data is one base64 `<block>` = **800 bytes = 16 records x 50
bytes**. This file annotates ONE 50-byte record. Four blocks per cue = four
banks of 16 records; global fixture index = `block*16 + record`.

Legend: `OK` = proven from real data, `~` = inferred from profile order,
`??` = not yet understood.

```
 byte:  0  1  2  3 | 4  5  6  7 | 8  9 10 11 |12 13 14 15|16 17|18 19|20 21|22 23|24 25| ...
        +----------+-----------+------------+-----------+-----+-----+-----+-----+-----+
region: | Intens FX | Position FX| Colour  FX | ??  gap   |Dimmr| ??  | Red |Green|Blue | ...
        | (bytes0-3)| (bytes4-7) | (bytes8-11)|(bytes12-15)| 16  |     | 20  | 22  | 24  |
```

## FX region - bytes 0-11  (three 4-byte slots)

Each slot = `[type, size, speed, phase]`.

| Bytes | Slot        | Status | Notes |
|-------|-------------|--------|-------|
| 0-3   | Intensity FX | OK | type: 0 None,1 Sinus,2 Ramp,3 Inversed Ramp,4 Square,5 Random |
| 4-7   | Position FX  | OK | type: 0 None,4 Square,5 Random,6 Circle,7 Eight,8 Pan,9 Tilt |
| 8-11  | Colour FX    | OK | type: 0 None,5 Random,10 Rainbow,11 Full Sinus,12 Full Twinkle |

Slot scaling: `size = b/255*100` (%), `speed` = signed int8 `/127*100` (%; 0 = 0,
255 = -1, 129 = -100, 128 = +100 as written by the app),
`phase = b/255*100` (%). Colour phase fans by global index = `3 + idx*4`.

> **CONFLICT (unresolved):** `kFunctionOffset` in `show_loader.dart` also maps
> Pan=4, PanFine=5, Tilt=6, TiltFine=7, Motor=8, Custom=10 into this same
> 4-11 region. For RGB/dimmer fixtures these offsets never carry static channel
> data, so there is no observed collision; but whether a mover stores a STATIC
> Pan/Tilt here (vs only FX) is NOT yet resolved.

## Unknown gap - bytes 12-15

| Bytes | Status | Notes |
|-------|--------|-------|
| 12-15 | ?? | Never observed non-zero in any sample. Purpose unknown. |

## Channel region - bytes 16-49  (16-bit big-endian pairs)

Keyed by DMX function code via `kFunctionOffset`. Each entry is a coarse+fine
pair `(offset, offset+1)`; simple 8-bit fixtures use the coarse byte.

| Offset | fn code | Channel          | Status | Notes |
|--------|---------|------------------|--------|-------|
| 16     | 0x01    | Dimmer / Intensity | OK  | proven |
| 18-19  | -       | (gap)            | ??     | not understood |
| 20     | 0x04    | Red              | OK     | holds 0xFFFF in the RGB sample block |
| 22     | 0x05    | Green            | OK     | proven |
| 24     | 0x06    | Blue             | OK     | proven |
| 26     | 0x07    | Amber            | ~      | offset from profile order |
| 28     | 0x08    | UV / White2      | ~      | |
| 30     | 0x09    | Colour wheel     | ~      | |
| 32     | 0x0A    | Colour wheel 2   | ~      | |
| 34     | 0x0B    | Gobo wheel 1     | ~      | |
| 36     | 0x0C    | Shutter / Strobe | ~      | ~80% confident |
| 38     | 0x0D    | Gobo wheel 2     | ~      | |
| 40     | 0x0E    | Prism rotation   | ~      | |
| 42     | 0x0F    | Focus            | ~      | |
| 44     | 0x10    | Zoom             | ~      | |
| 46     | 0x11    | Iris             | ~      | |
| 48     | 0x12    | Colour temp      | ~      | |

Movers additionally reuse the low offsets (collide with the FX region above):
Pan=4 (0x02), PanFine=5 (0x21), Tilt=6 (0x03), TiltFine=7 (0x23),
Motor=8 (0x14), Custom=10 (0x80). Unresolved - see the CONFLICT note.

## Worked example

`show_all_fx_options.show`, playback index=8 "color channel c", cue
"1=r, 2=g, 3=b": in block 0 the record for fixture index 0 carries `0xFFFF`
at the Red offset (byte 20), fixture index 1 at Green (22), fixture index 2 at
Blue (24) - matching the cue label. All three are Showtec Compact Par 18 Tri
(profile `010405060C80`: Dimmer, Red, Green, Blue, Shutter, Custom).
