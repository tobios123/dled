# Protocol findings — LPU-1

Notes on the LPU-1's network protocol and `.show` format, measured from the
network traffic between an app and the device, for interoperability. Scripts
named here that are not in `analysis/scripts/` were one-off and are not
published; captures (`*.pcapng`) are not in the repository.

Summary of what live packet captures showed.

Capture file: `samples/reference_app_show_opening_and_sending_show_to_lpu.pcapng`
- App (desktop): 192.168.1.171
- LPU (hardware): 192.168.1.12
- Primary channel: UDP port 16945 (both directions)
- Secondary channel: UDP port 58065 (DMX/state stream)

---

## 1. VN Protocol — Primary Channel (UDP port 16945)

### 1.1 Frame Header Layout (20 bytes)

**Verified from pcap analysis: ALL non-keepalive, non-discovery frames share one
unified 20-byte header. Byte[0] is the opcode — NOT a magic byte.** Earlier
versions of this document incorrectly described 0x1f as a "magic" prefix and
treated byte[2] as the command. The actual layout, verified against the raw pcap,
is:

```
Offset  Size  Field
  0       1   op      (opcode: 0x1f=name, 0x29=level, 0x2b=string_list,
                        0x2c=config_obj, 0x2d=float_param, 0x00=ping/status)
  1       1   bank    (bit7 = PUSH/write; 0x00 = global, 0x01-0x10 = slot 0-15,
                        0x80 = push global, 0x81-0x90 = push slot 0-15,
                        0x1d = DEV_INFO)
  2       1   sub     (sub-type / sub-operation byte; varies per opcode)
  3       1   reserved (0x00)
  4       2   sub-index (LE uint16; parameter/slot index, 0x0000 if unused)
  6       4   reserved (0x00 x4)
 10       2   bcast   (0xFF 0xFF = query/REQ; 0x00 0x00 = push/PUSH)
 12       2   len     (LE uint16; payload byte count that follows)
 14       2   counter (LE uint16; monotonically increasing per connection)
 16       4   reserved (0x00 x4)
 20+      N   payload (opcode-specific, len bytes)
```

**Directly observed in this capture (App->LPU):**

| byte[0] op | packets | max len | description |
|-----------|---------|---------|-------------|
| 0x1f | 339 | 77 | name/fixture: fixture definition write (show upload) |
| 0x29 | 330 | 24 | level: fader/channel level (float32) |
| 0x2b | 343 | 820 | string_list/cuelist: bulk cuelist write |
| 0x2c | 2 | 20 | config_obj / session frame (header only, no payload) |
| 0x00 | 12 | 9 | ping/status query |
| 0x76 | 6 | 15 | `visual_identify` discovery (ASCII 'v') |

The commands listed in earlier revisions as "cmd=0x05 (poll)", "cmd=0x07 (ACK)",
"cmd=0x08 (upload)", "cmd=0x38 (heartbeat)" were sub-type bytes (byte[2]) inside
0x1f-opcode frames and were never the raw first byte on the wire. They do not
appear as standalone opcodes in this capture.

### 1.2 Discovery (pre-session, no 20-byte header)

| Direction | Size | Content |
|-----------|------|---------|
| App->broadcast | 15 | ASCII string `"visual_identify"` |
| LPU->App | 157 | XML device info (manufacturer, model, firmware, serial) |

### 1.3 Session Handshake

After discovery, app sends a 20-byte frame starting with `0x2c 0x1d ...`.
This establishes the session before any data commands.

### 1.4 Keepalive

Single byte `0xff` sent periodically on port 16945.
Observed: 1095 such bytes from App->LPU across the session.

### 1.5 Opcode Reference

| op   | Direction    | sub   | Payload   | Description |
|------|-------------|-------|-----------|-------------|
| 0x00 | REQ App->LPU | — | 7 bytes zeros | Ping / status query (9-byte frame total including 0x00+level byte) |
| 0x00 | RSP LPU->App | — | 13 bytes | Status reply |
| 0x1f | REQ App->LPU | 0x08 | null-terminated CSV | Fixture/name write (show upload, one frame per fixture) |
| 0x29 | REQ App->LPU | varies | float32 LE level | Fader/channel level set |
| 0x29 | RSP LPU->App | varies | float32 LE level | Level echo/ACK or push notification |
| 0x2b | REQ App->LPU | 0x46 | (none, 20-byte header) | Show-page download request (read one bank from flash) |
| 0x2b | RSP LPU->App | 0x46 | 800 bytes | Show-page download reply (one bank = 16 x 50-byte fixture records) |
| 0x2b | REQ App->LPU | 0x47 | 800 bytes | Show-page upload (one bank = 16 x 50-byte fixture records, write to flash) |
| 0x2b | RSP LPU->App | 0x47 | 800 bytes | Show-page upload echo |
| 0x2c | REQ both | 0x38 | (none, header only) | Session config / heartbeat (op=0x2c, bank=0x1d, sub=0x38) |
| 0x2d | REQ App->LPU | 0x33 | float32 LE | Float parameter set (fade time, etc.) |
| 0x76 | broadcast | — | ASCII "visual_identify" | Discovery (raw ASCII, no 20-byte header) |

---

## 2. Show Upload Sequence (op=0x1f / op=0x2b)

> **SUPERSEDED (2026-10-22)** — see section 20.7 for the complete, verified
> upload sequence.

**Verified from pcap: the show upload consists of two phases, both using the standard
20-byte header. There is no "0x1f magic byte" — 0x1f is the opcode for
name/fixture writes.**

### Phase 1: Fixture definitions — op=0x1f, sub=0x08 (App->LPU)

339 packets observed (one per fixture definition, possibly repeated or covering
multiple fixtures in the show).

```
Byte[0]  = 0x1f  (op: name/fixture)
Byte[1]  = 0x00  (bank: global)
Byte[2]  = 0x08  (sub: fixture definition write)
Byte[3]  = 0x00  (reserved)
Bytes[4:6]  = 0x0000  (sub-index unused)
Bytes[6:10] = 0x00000000
Bytes[10:12]= 0xffff  (REQ)
Bytes[12:14]= payload length LE uint16 (e.g. 0x0035 = 53 for 6-ch fixture)
Bytes[14:16]= counter LE uint16
Bytes[16:20]= 0x00000000
Bytes[20+]  = null-terminated CSV string:
              "manufacturer","model","mode_name","profile_hex_string"\x00
```

**Observed first fixture from pcap:** `"Showtec","Compact...` (truncated in output;
full CSV format matches personalities.xml entries for the uploaded show).

### Phase 2: Show-page bulk write — op=0x2b, bank=0x0a, sub=0x47 (App->LPU)

343 packets observed; max size 820 bytes = 20-byte header + 800-byte payload.

The 800-byte payload is one **block (bank)** of a show page = 16 fixture records
x 50 bytes. Banks map to fixtures by global index `block*16 + record` (bank 0 =
fixtures 0-15, bank 1 = 16-31, bank 2 = 32-47, bank 3 = 48-63). A full cue is four
such blocks, streamed in order; the app skips a cue only when all four banks are
empty, but within a transmitted cue it sends all four banks (empty higher banks
zero-filled). See `SHOW_DOWNLOAD_FLOW.md` sections 8b and 8c.

```
Byte[0]  = 0x2b  (op: string_list / cuelist)
Byte[1]  = 0x0a  (bank: 0x0a observed)
Byte[2]  = 0x47  (sub: upload / write to flash)
Bytes[4:6]  = pb_idx   (playback index, LE)
Bytes[6:8]  = page_idx (cue index within the playback, LE)
Bytes[10:12]= 0xffff (REQ)
Bytes[12:14]= 0x0320 = 800 (payload length)
Bytes[14:16]= counter (LE uint16, increments per frame)
Bytes[20:]  = 800-byte block = 16 x 50-byte fixture records
```

The sub byte (byte[2]) is the read/write discriminator: 0x46 = download
(LPU->app, read from flash, carries a flash address at bytes[12:16]); 0x47 =
upload (app->LPU, write to flash). Direction is established by source IP
(app = 192.168.1.171, LPU = 192.168.1.12). See `SHOW_DOWNLOAD_FLOW.md` section 8b.

> **Note on the 0x55 0xd8 sentinel.** A separate op=0x46 cuelist-slot query reply
> (NOT this 800-byte show-page upload) carries a 16-slot array in which each slot's
> bytes[24:26] = 0x55 0xd8 marks the slot populated. That sentinel belongs to the
> cuelist-slot query context (see `VN_PROTOCOL.md` section 9); it is not part of the
> sub=0x47 show-page payload, whose 50-byte records are fixture records keyed by the
> fixture profile (see `dled_flutter/SHOW_RECORD_MAP.md`).

### Observed fixture uploads (from show with 6 fixtures, payload decoded from CSV):

| Slot | Manufacturer | Model | Mode | Profile hex | Body len |
|------|-------------|-------|------|-------------|---------|
| 0 | Showtec | Compact Par 18 Tri | 6-Ch | `010405060C80` | 53 |
| 1 | Showtec | Compact Par 18 Tri | 6-Ch | `010405060C80` | 53 |
| 2 | Showtec | Compact Par 18 Tri | 6-Ch | `010405060C80` | 53 |
| 8 | Showtec | Kanjo spot 60 | 10 ch | `0222032314090A010C80` | 57 |
| 9 | Showtec | Kanjo spot 60 | 10 ch | `0222032314090A010C80` | 57 |
| 10 | Showtec | Kanjo spot 60 | 10 ch | `0222032314090A010C80` | 57 |

---

## 3. Fixture Profile Hex String Format

Each 2-character pair in the profile hex string is a DMX channel function code (one byte per channel, in DMX channel order).

### Decoded channel maps

**Compact Par 18 Tri (6-Ch): `01 04 05 06 0C 80`**

| Ch | Code | Function |
|----|------|----------|
| 1  | 0x01 | Dimmer/Intensity |
| 2  | 0x04 | Red |
| 3  | 0x05 | Green |
| 4  | 0x06 | Blue |
| 5  | 0x0C | (unknown — possibly strobe or macro) |
| 6  | 0x80 | (terminator / end marker) |

**Kanjo spot 60 (10 ch): `02 22 03 23 14 09 0A 01 0C 80`**

| Ch | Code | Function |
|----|------|----------|
| 1  | 0x02 | Pan |
| 2  | 0x22 | Pan fine (0x22 = Pan+0x20) |
| 3  | 0x03 | Tilt |
| 4  | 0x23 | Tilt fine |
| 5  | 0x14 | Colour wheel |
| 6  | 0x09 | Gobo wheel |
| 7  | 0x0A | Gobo rotation |
| 8  | 0x01 | Dimmer/Intensity |
| 9  | 0x0C | (unknown — possibly strobe) |
| 10 | 0x80 | (terminator / end marker) |

### Known function codes

| Code | Function |
|------|---------|
| 0x01 | Dimmer / Intensity |
| 0x02 | Pan |
| 0x03 | Tilt |
| 0x04 | Red |
| 0x05 | Green |
| 0x06 | Blue |
| 0x09 | Gobo wheel |
| 0x0A | Gobo rotation |
| 0x0C | Strobe / macro (tentative) |
| 0x14 | Colour wheel |
| 0x22 | Pan fine (Pan + 0x20 fine modifier) |
| 0x23 | Tilt fine |
| 0x80 | End-of-profile terminator |

---

## 4. DMX Address Assignment (cmd=0x0b / cmd=0x0c)

### cmd=0x0b — DMX address query

App sends one query per fixture slot (20-byte header only, no body).
LPU responds with a 4-byte little-endian uint32 = current DMX start address.

Query sequence matched to fixture slots (same order as upload):
- Slot 0 -> 1
- Slot 1 -> 7
- Slot 2 -> 13
- Slot 8 -> 19
- Slot 9 -> 29
- Slot 10 -> 39

These match the 6-ch and 10-ch sizes perfectly (1, 1+6=7, 7+6=13, 13+6=19, 19+10=29, 29+10=39).

### cmd=0x0c — DMX address write

App sends one frame per fixture slot assigning the start address.
LPU echoes the same frame back (same fld12 value, same 4-byte body).
Observed addresses (LE uint32): `01 00 00 00`, `07 00 00 00`, `0d 00 00 00`, `13 00 00 00`, `1d 00 00 00`, `27 00 00 00`
= decimal 1, 7, 13, 19, 29, 39.

---

## 5. Heartbeat / Session Frame (op=0x2c, sub=0x38)

> **WRONG (2026-10-22)** — `2c 1d 38` is not a heartbeat. **It is CLEAR
> programmer** (the edit window's CLEAR button, captured 2026-10-24, 20.17);
> the upload sends it first. It does not touch the show. Sub 0x38 with type
> 0x1d = delete / clear (section 20.1).

**Corrected from pcap: the heartbeat is op=0x2c (config_obj), bank=0x1d (DEV_INFO),
sub=0x38, header-only (no payload).**

Raw bytes: `2c 1d 38 00 00 00 00 00 00 00 ff ff 00 00 <counter_lo> <counter_hi> 00 00 00 00`

- 2 packets observed in this capture (App->LPU only)
- len field = 0x0000 (no payload)
- bcast mask = 0xffff (REQ)
- counter increments per frame

This is functionally equivalent to a session keepalive/sync frame; the sub-type
byte 0x38 is the heartbeat sub-code within the config_obj opcode family.

---

## 6. Secondary Channel (UDP port 58065) — DMX State Stream

### App->LPU (port 58065)

1095 of 1120 packets are a single byte `0xff` — keepalive for this channel.
Remaining packets are 9-byte frames: `00 XX 00 00 00 00 00 00 00`
where XX appears to be a fixture slot ID (0x00, 0x03, 0x09, 0x0a, 0x11, 0x34, 0xce, 0xea, 0xef, 0xf0).
These are likely slot state queries or DMX output requests.

### LPU->App (port 58065)

18-byte structured state records. Format per record:
```
Offset  Size  Field
  0       2   slot_id (LE uint16, matches the query XX byte)
  2       6   zeros (padding)
  8       1   record_type (0x04 = has value, 0x02 = has two bytes)
  9       1   value_byte_1
 10-17    8   (additional bytes, type-dependent)
```

Notable record: slot `0x0011` has `record_type=0x04` with body `4c 50 55 00 00 00 00 00 00` = ASCII `"LPU"`: the device name (alias), see 20.

The 234 LPU->App bytes on this channel contain 13 records covering the queried slot IDs.

---

## 7. Session Flow Summary

**Corrected from pcap evidence (pcap analysis 2026-10-18):**

1. App broadcasts `visual_identify` (15 bytes, raw ASCII, op=0x76/'v' byte)
2. LPU responds with XML device info (157 bytes, raw `<?xml...`)
3. App sends op=0x2c session/heartbeat frame (20 bytes, bank=0x1d, sub=0x38)
4. **Show upload phase 1:** App sends 339x op=0x1f frames (one per fixture definition,
   CSV string, sub=0x08)
5. **Show upload phase 2:** App sends 343x op=0x2b frames (cuelist bulk write,
   sub=0x47, 820 bytes including 16-slot cuelist array)
6. App sends 330x op=0x29 level frames (fader positions)
7. App sends 12x op=0x00 status queries; LPU replies with 13x op=0x00 status records
8. Throughout: 0xff keepalives on both channels

---

## 8. Fader / Playback Level Control (cmd=0x29)

Captured in: `fader_level_change_1_and_8_cue_go_and_released.pcapng`

### 0x29 — Playback fader level update (24-byte frame, no 0x1f header)

```
Offset  Size  Field
  0       1   cmd = 0x29
  1       1   flags: 0x03 = REQ (App->LPU), 0x83 = RSP (LPU->App, bit7 set)
  2       1   sub-type / version byte (varies: 0x17, 0x18, 0x22, 0x24, 0x2f, 0x50)
  3       1   reserved (0x00)
  4       1   playback_index (0-based: 0=PB1 ... 7=PB8)
  5       5   zeros (padding)
 10       2   0xffff on REQ, 0x0000 on RSP (same convention as 0x1f protocol)
 12       2   0x0004 (constant in all observed frames)
 14       2   LE uint16 sequence counter (increments per frame)
 16       4   zeros
 20       4   LE float32 level (0.0 = 0%, 1.0 = 100%)
```

### Encoding

| Level     | float32 hex    | float32 value |
|-----------|----------------|---------------|
| 100%      | `00 00 80 3f`  | 1.0           |
| ~99.2%    | `61 e2 7d 3f`  | 0.9918        |
| 0%        | `00 00 00 00`  | 0.0           |

The LPU echoes every REQ frame as RSP (same bytes, only flag byte[1] and counter
byte[2] differ — counter decrements by 1 in RSP, matching the 0x1f heartbeat pattern).

### Observed interaction

Fader 1 (PB1, index=0) drag: ~241 frames, level sweeps 1.0 → 0.0 → 1.0
Fader 8 (PB8, index=7): same pattern, same level encoding

### Flutter implementation note

```dart
// Build a 24-byte fader level packet
Uint8List makeFaderLevel(int pbIndex, double level) {
  final buf = Uint8List(24);
  buf[0] = 0x29;
  buf[1] = 0x03;  // REQ
  buf[4] = pbIndex;
  buf[10] = 0xff; buf[11] = 0xff;
  buf[12] = 0x04;
  ByteData.view(buf.buffer).setFloat32(20, level, Endian.little);
  return buf;
}
```

---

## 9. Playback State Query (cmd=0x00)

### 0x00 REQ (App->LPU, 9 bytes)

```
00 <slot_lo> <slot_hi> 00 00 00 00 00 00
```

Bytes [1:3] = LE uint16 slot/object ID being queried.

### 0x00 RSP (LPU->App, 18 bytes)

```
00 <slot_lo> <slot_hi> 00 00 00 00 00 <type> <v0> <v1> <v2> <v3> 00 00 00 00 00
```

- Bytes [1:3] = echoed slot ID
- Byte [8] = record type (0x02, 0x04, 0x06)
- Bytes [9:13] = value (type-dependent)

#### Observed slot responses

| Slot (hex) | Type | Value bytes    | Interpretation |
|-----------|------|----------------|----------------|
| 0x0000    | 0x06 | `02 00 00 00 00 01 00 00` | session/state blob |
| 0x0003    | 0x06 | `ff ff ff 00 00 00 00 00` | RGB color (white) |
| 0x0009    | 0x02 | `01 1d 00 ...` | cue state (1=active, cue=0x1d=29) |
| 0x000a    | 0x02 | `02 00 00 ...` | playback state (2) |
| 0x0011    | 0x04 | `4c 50 55 00 ...` | ASCII "LPU" identifier |
| 0x0034    | 0x04 | `10 00 00 00 ...` | numeric value 16 |
| 0x00ce    | 0x04 | `00 00 00 00 ...` | zero |
| 0x00ea    | 0x04 | `01 00 00 00 ...` | boolean/numeric 1 |
| 0x00ef    | 0x04 | `00 00 00 00 ...` | zero |
| 0x00f0    | 0x04 | `01 00 00 00 ...` | boolean/numeric 1 |

These queries repeat in a polling loop (seen 3 cycles of the same 10 slot IDs).

---

## 10. Known Unknowns / Open Questions

| Area | Unknown |
|------|---------|
| cmd=0x38 fld12 counter | Base value origin (session epoch?) |
| cmd=0x29 byte[2] | Sub-type/version purpose (values 0x17-0x50 observed) |
| cmd=0x00 slot IDs | Full mapping of slot IDs to playback/fixture/universe objects |
| cmd=0x00 record types | 0x02 vs 0x04 vs 0x06 distinction |
| "LPU" string | User-editable device name (set from the app UI); write command not yet identified |
| Show blocks 1-3 | Purpose not decoded (from .show file XML) |
| config_obj bytes | Internal layout for fade/trigger/speed storage |
| Exported .show format | Decoded: `dled_flutter/SHOW_FORMAT.md`, examples in `samples/` |

---

## 11. Fixture Personality Library

- Each fixture: manufacturer / model / mode and a channel hex string (one
  function code per DMX channel); DLED's library: `dled_flutter/assets/personalities.xml`
- Same encoding used in cmd=0x08 frames sent to LPU

---

## 12. What Still Needs Capturing

- Cue go / cue release commands (exact packet format) -> live data at: samples\go_release_go_next_cue_next_cue_release.pcapng"
- Full session: patch a fixture, create 2-3 cues, set fades, export show file
- This would decode: config_obj layout, fade/trigger parameters, .show export format
- See `dled_flutter/VN_PROTOCOL.md` for full protocol reference

---

## 13. Cue Go / Release Commands

Captured in: `samples/go_release_go_next_cue_next_cue_release.pcapng`

### Key finding

**Playback go is triggered by the app sending cmd=0x00 fader level packets (App->LPU).**
The user taps a playback button in the app; the app sends a sweep of cmd=0x00 frames
with rising level bytes (0x00 -> 0xf0 = fader moved to full). The LPU echoes each
frame back as confirmation. Separately, the LPU sends cmd=0x29 push notifications
reporting state changes after the cue becomes active.

**Packet counts in this capture:**
- App->LPU cmd=0x00: 60 frames (fader sweep)
- App->LPU cmd=0xff: 3218 frames (keepalive)
- LPU->App cmd=0x00: 60 frames (echo/confirmation)
- LPU->App cmd=0x29: 44 frames (state push notifications)
- LPU->App cmd=0x3c: 20 frames (unknown LPU push)
- LPU->App cmd=0x76: 20 frames (unknown LPU push)

### cmd=0x00 — Fader level / Playback Go (9 bytes, no 0x1f header)

This frame type does NOT use the standard 20-byte VN header. It is a raw 9-byte frame:

```
Offset  Size  Field
  0       1   cmd = 0x00
  1       1   level byte (0x00=off/0%, 0xf0=full/100%)
  2       7   zeros (padding)
```

**App->LPU** (REQ): sets the playback fader level. A rising sweep from 0x00 to 0xf0
represents "go" (fader pushed to full). Observed level values in order:
`00 03 09 0a 11 34 ce ea ef f0` — a smooth fader sweep.

**LPU->App** (RSP): LPU echoes the same 9-byte frame as confirmation.

**Flutter implementation:**

```dart
Uint8List makeFaderGo(double level) {
  // level: 0.0 = off, 1.0 = full (maps to 0x00 - 0xf0)
  final buf = Uint8List(9);
  buf[0] = 0x00;
  buf[1] = (level * 0xf0).round().clamp(0, 0xf0);
  return buf;
}
```

To trigger a cue go, send a sequence of frames sweeping level 0x00 -> 0xf0:
```dart
for (final level in [0x00, 0x03, 0x09, 0x0a, 0x11, 0x34, 0xce, 0xea, 0xef, 0xf0]) {
  sendUdp(makeFaderGo(level / 0xf0));
  await Future.delayed(Duration(milliseconds: 20));
}
```

### Push sub-types (cmd=0x29, LPU->App only)

All push frames are 24 bytes. bytes[20:24] are interpreted as LE uint32 (not float32):

| Sub | flags | fld10  | body uint32 | Meaning |
|-----|-------|--------|-------------|---------|
| 0x22 | 0x02 | 0xffff | 0 or 1 | Level active state: 1=active, 0=inactive |
| 0x50 | 0x82 | 0x0000 | 0 or 1 | PUSH active state: 1=active, 0=inactive |
| 0x24 | 0x81 | 0x0000 | 1..N | Active cue absolute counter (wraps at list length) |
| 0x2f | 0x81 | 0x0000 | 0,1,2,0xff | Cue step index (0=first step, 1=second, 0xff=special/looped) |
| 0x42 | 0x1d | 0xffff | (none) | Level state query, 20-byte header only, no body |

### Cue Go event sequence

Emitted when a cue becomes active (physical GO button pressed):

```
flags=0x02  sub=0x22  body=uint32(1)   -- level active state: 1 (active)
flags=0x82  sub=0x50  body=uint32(1)   -- PUSH active state: 1
flags=0x02  sub=0x22  body=uint32(1)   -- (repeated level notification)
```

### Cue Release event sequence

Emitted when a cue becomes inactive (physical RELEASE button pressed):

```
flags=0x02  sub=0x22  body=uint32(0)   -- level active state: 0 (inactive)
flags=0x82  sub=0x50  body=uint32(0)   -- PUSH active state: 0
flags=0x81  sub=0x2f  body=uint32(N)   -- cue step index (0=first, 1=second, 2=third)
flags=0x81  sub=0x24  body=uint32(N)   -- active cue absolute counter updated
flags=0x02  sub=0x22  body=uint32(0)   -- (repeated level notification)
```

### Next Cue advance (sub=0x2f)

sub=0x2f reports which cue step within the list is next/current:

| body uint32 | Meaning |
|-------------|---------|
| 0x00 | First cue step |
| 0x01 | Second cue step (NEXT CUE pressed once) |
| 0x02 | Third cue step (NEXT CUE pressed twice) |
| 0xff | Special: cue list exhausted or wrapped |

### Active cue counter (sub=0x24)

sub=0x24 body is an absolute monotonic counter of cue go events, wrapping at the
cue list length. Observed values for a 4-cue list: 4, 1, 2, 3, 4, 1, 2, 3, 4.

### 20-byte level state query (sub=0x42, flags=0x1d)

```
29 1d 42 00 00 00 00 00 00 00 ff ff 00 00 <seq_lo> <seq_hi> 00 00 00 00
```

Appears in pairs at cue transition boundaries (pkts 1529/1532 and 3283/3285).
Likely an internal LPU->App level state poll at cue step transitions.

---

## 14. Show Download — The 4 Responses Are the 4 Banks

### 14.1 Observed LPU response pattern

**CORRECTION (2026-10):** An earlier version of this section described the four
820-byte responses per page as "1 real page + 3 zero retransmits". That model is
DISPROVEN. The four responses are the **four blocks (banks)** of the cue, each a
16-fixture slot of the 50-byte record array:

| Response | Flash address | Content | Fixtures |
|---|---|---|---|
| 1st | base + 0x00000 | block[0] | 0-15 |
| 2nd | base + 0x10000 | block[1] | 16-31 |
| 3rd | base + 0x20000 | block[2] | 32-47 |
| 4th | base + 0x30000 | block[3] | 48-63 |

The flash address increments by `+0x10000` per block, so the four responses are
four distinct flash reads at four distinct addresses. A block that carries no
patched fixtures is genuinely all-zero (an empty higher bank) -- which is exactly
why the common "only block 0 has data" case USED to look like retransmits.

**Proof (`download_show_M400&12X12 - RGB_dim_shut.pcapng`):** 45 distinct pages,
exactly 4 responses each, stride `+0x10000` within every page; 54 populated blocks,
all 54 matching a `.show` `<block>` byte-for-byte. **9 pages carry two or more
populated blocks** (block[0] AND block[2] both non-zero) -- impossible under a
retransmit scheme, only the bank model explains it. See `SHOW_DOWNLOAD_FLOW.md`
section 4.

**App rule:** keep all four responses in flash-address order and map them onto
`cue.block[0..3]`. An empty bank stays an empty `<block/>`.

The protocol has **no checksum on the 800-byte payload** and **no ACK/NACK
mechanism**, so a page lost to Wi-Fi cannot be re-requested per index. The
majority-vote download below is retained only as insurance against that loss, NOT
as an explanation of the four responses.

### 14.2 Wi-Fi loss ambiguity (not a retransmit artifact)

Because there is no checksum or ACK, a page dropped by a Wi-Fi burst is
indistinguishable from a genuinely empty bank in a single download pass: both
arrive (or reconstruct) as all-zero. This is a transport-loss concern only -- the
four responses themselves are the four banks (section 14.1), not redundancy copies.

### 14.3 Insurance: N=3 majority-vote consensus download

**Industry standard when no checksum is available:** download N times and accept
only pages where at least M copies agree (majority vote, M > N/2). This guards
against Wi-Fi loss (section 14.2); it is NOT needed to interpret the four
per-page responses, which are always the four banks.

Implementation (a one-off script, not published; today: `analysis/lpu/lpu_io.py`):

1. Download the show up to 3 times, collecting `votes[(pb_idx, cue_idx, bank)] = [p1, p2, p3]`.
2. **Early stop:** after attempt 2, if all banks already agree between attempt 1
   and 2 -- skip attempt 3. (Fast path on good Wi-Fi: 2x download cost.)
3. For each bank, pick the payload that appears most often (majority).
4. If all 3 copies differ -- emit a warning and pick any non-zero copy, flag uncertain.
5. If all 3 copies are zeros -- accept as a genuinely empty bank (no warning).

---

## 15. Show download verification (op=0x46, 820-byte packets)

### Overview

Two independent pcap captures were compared against their corresponding `.show` XML files.
Every downloaded page matched the base64-decoded block data in the XML **byte-for-byte** (100%
match, no exceptions).

| Test set | Unique pages | Total packets | File size (approx) |
|---|---|---|---|
| show_all_fx_options | 28 | 84 | ~72 KB |
| M400&12X12 - RGB_dim_shut | 54 | 216 | ~134 KB |

### 20-byte packet header (LPU -> client, from-LPU direction)

Each 820-byte UDP packet carries one 800-byte show page. The header layout:

| Offset | Size | Value | Meaning |
|---|---|---|---|
| 0 | 1 | 0x2b | VN op byte |
| 1 | 1 | 0x0a | Bank |
| 2 | 1 | 0x46 | Command = show download |
| 3 | 1 | 0x00 | Reserved |
| 4-5 | 2 | LE uint16 | `pb_idx` -- playback index |
| 6-7 | 2 | LE uint16 | `page_idx` -- page within playback |
| 8-9 | 2 | 0x0000 | Reserved |
| 10-11 | 2 | 0xffff | Constant REQ marker |
| 12-15 | 4 | LE uint32 | Flash address (increments by 0x10000 per block/bank) |
| 16-19 | 4 | 0x00000000 | Reserved |

Payload: bytes 20-819 = 800-byte raw show page.

### Key insight: structure reconstruction from headers

The `pb_idx` and `page_idx` fields in each response header are sufficient to reconstruct the
full `.show` XML structure without access to the original file:

- `pb_idx` maps directly to the `<playback>` element index.
- `page_idx` maps to the `<cue>` element index within that playback.
- Each `<cue>` contains 4 `<block>` elements = the 4 banks of 16 fixtures. The four
  addr-ordered responses map onto `block[0..3]` (block[0] = fixtures 0-15,
  block[1] = 16-31, block[2] = 32-47, block[3] = 48-63). A bank with no patched
  fixtures is genuinely all-zero and stays an empty `<block/>`.

This means a complete `.show` XML can be built from a live LPU download
with no reference to the original file.

---

## 16. Show Upload — The 4 Frames Per Page Are the 4 Banks (App->LPU, op=0x2b sub=0x47)

> **CORRECTION (2026-10-22)** — the block is not positional: bytes 8-9 carry the
> block index 0-3 explicitly. See section 20.1 / 20.7.

### 16.1 Observed app upload behavior

**CORRECTION (2026-10):** An earlier version of this section described the four
app->LPU frames per `(pb_idx, cue_idx)` page as "4 identical retransmit copies".
That model is DISPROVEN. The four frames are the **four blocks (banks)** of the
cue -- the same bank model proven for the download direction (section 14):

| Frame | Block (bank) | Content | Fixtures |
|---|---|---|---|
| 1st | block[0] | 16 x 50-byte fixture records (or zero-filled) | 0-15 |
| 2nd | block[1] | 16 x 50-byte fixture records (or zero-filled) | 16-31 |
| 3rd | block[2] | 16 x 50-byte fixture records (or zero-filled) | 32-47 |
| 4th | block[3] | 16 x 50-byte fixture records (or zero-filled) | 48-63 |

The frames are NOT identical: within a page, populated banks carry real fixture
records while empty higher banks are zero-filled. The LPU echoes each frame back
with the same sub byte.

### 16.2 Evidence

Two `open_show__*.pcapng` captures were analyzed with `analysis/scripts/check_upload_retransmit.py`
and `analysis/scripts/confirm_no_empty_cue.py`:

| Capture file | App->LPU sub=0x47 frames | Unique (pb_idx, cue_idx) pages | Frames/page |
|---|---|---|---|
| open_show__show_all_fx_options.pcapng | 84 | 21 | 4 (= 4 banks) |
| open_show__M400&12X12 - RGB_dim_shut.pcapng | 180 | 45 | 4 (= 4 banks) |

Every page carries exactly 4 frames = its 4 banks. For the M400 capture the 180
frames decompose into **54 populated blocks + 126 zero-filled blocks**, and **9
pages carry two distinct non-zero blocks** (block[0] AND block[2]) -- which an
"identical retransmit" scheme could never produce. See `SHOW_DOWNLOAD_FLOW.md`
sections 8b and 8c. The `download_show__*.pcapng` files (pure LPU->app captures)
contained zero App->LPU upload packets, confirming upload and download are
separate sessions.

### 16.3 Comparison: download vs upload

| Direction | Frames/page | Frame content | Note |
|---|---|---|---|
| LPU->App (op=0x46 download) | 4 | 4 banks at +0x10000 stride; empty banks all-zero | read from flash |
| App->LPU (op=0x47 upload) | 4 | 4 banks in transmit order; empty banks zero-filled | write to flash |

Both directions stream the four banks of each cue. Neither is a retransmit scheme:
the four frames always carry four distinct bank slots, and an all-zero frame is a
genuinely empty bank, not a redundancy copy.

### 16.4 Implication for show upload implementation

When implementing show upload in the Flutter app or a custom client (see the
uploader rule in `SHOW_DOWNLOAD_FLOW.md` section 8c):

- For each cue that has content, send all **4 blocks** (banks) in order (block 0..3)
  as 820-byte frames (20-byte header + 800-byte block); zero-fill an empty higher bank.
- Skip a cue entirely only when all four of its banks are empty.
- No ACK/NACK is expected from the LPU; the LPU echoes each frame with the same sub byte.
- Inter-packet delay between the four bank frames is not specified; observed gap is
  negligible (back-to-back UDP sends within the same OS scheduler tick).

---

## 19. Directory Sweep — A RUNNING Playback Returns No Directory Reply

### 19.1 Summary

The per-playback DIRECTORY sweep (magic 0x29, type 0x1d, cmd 0x30, sub-index
0..63) used to enumerate a show before download does **not** report a playback
that is currently RUNNING (a cue is live on that playback). A running playback
is **silently dropped from the sweep** — it returns no parseable directory reply
at all. This OVERTURNS the earlier working theory that a running playback would
return a directory reply with a different run-state flag in `body[1]`.

### 19.2 The 4-run hardware experiment

Captured to a log (not published) with the
updated `--dir-debug` collector. Four hardware states were swept:

| Run | Hardware state              | pb0 present? | pb4 present? | Playbacks listed | Total pages |
|-----|-----------------------------|--------------|--------------|------------------|-------------|
| 1   | All released (baseline)     | yes (6 pg)   | yes (3 pg)   | 17               | 45          |
| 2   | pb0 running on cue 1        | **no**       | yes          | 16               | 39 (45 - 6) |
| 3   | pb0 running on cue 2        | **no**       | yes          | 16               | 39 (45 - 6) |
| 4   | pb0 cue 4 + pb4 cue 1       | **no**       | **no**       | 15               | 36 (45-6-3) |

**Baseline (Run 1, all released) — authoritative populated-playback table:**

```
pb0:6  pb1:3  pb2:3  pb3:3  pb4:3  pb5:1  pb6:1  pb8:1  pb10:2
pb11:2 pb12:2 pb24:3 pb25:3 pb26:3 pb27:3 pb28:3 pb40:3
= 17 playbacks, 45 pages total
```

### 19.3 Conclusions

1. **A running playback vanishes from the directory sweep.** When pb0 is live, the
   sweep output starts at pb1 and the page total drops by exactly pb0's page count
   (6 -> 39). The slot is not reported with a changed flag; it is simply absent.
2. **The cue number is irrelevant.** Run 2 (cue 1) and Run 3 (cue 2) produce
   identical output. What matters is only whether the playback is running, not
   which cue is active.
3. **The drop is per-slot and deterministic.** Run 4 has two live playbacks (pb0
   and pb4); both disappear independently and the page total subtracts exactly both
   their counts (45 - 6 - 3 = 36). The sweep list jumps pb3 -> pb5.
4. **The run-state-flag theory is DISPROVEN.** There is no alternate `body[1]`
   value for a running slot because there is no directory reply to carry it.

### 19.4 Implication for show export / enumeration

The directory sweep is **not a reliable full-show enumerator while any playback is
live**. It under-counts the show by exactly the running playbacks' page counts.
A complete export therefore requires one of:

- **Release all playbacks first**, then sweep (guarantees all 17/45 appear); or
- **An alternate enumeration path** that does not depend on the directory query
  answering for running slots (not yet identified).

### 19.5 Open question — silent timeout vs. unparsed datagram

The sweep collector was instrumented with a raw-capture diagnostic (`--dir-debug`)
to distinguish two possibilities for a running slot:

- `[DIR-DBG] pbN NO REPLY (silent timeout) ...` — the LPU sends nothing at all for
  that sub-index; or
- `[DIR-DBG] pbN NO parsed reply ...; dir-family datagram(s) seen: [hex]` — the LPU
  does send a directory-family datagram (magic `29 01`) but it fails the
  `body[3]==0xff` sentinel check and is silently drained.

Settling this requires re-running the single "pb0 running on cue 1" scenario with
the updated `--dir-debug` build. If the LPU emits an unparsed datagram, that datagram
may be the key to enumerating running playbacks without releasing them.

### 19.6 Fix in debug_lpu_discover_v2.py (2026-10-22) — download no longer depends on live state

- **Reply layout.** The "directory" query is a read of playback property 0x30.
  Its reply body `[00, populated, cue_count, active_cue]` ends in the **active cue**,
  and 0xff means released. This matches the LPU's `29 81 2f` active-cue push, where
  0xff also means "none". The old parser required that byte to be 0xff, so a
  running playback's reply would be thrown away. The parser now accepts any value
  and logs `RUNNING on cue N`.
- **Fallback.** If 0x30 gets no reply at all (the other possibility in 19.5), the
  script reads playback property **0x3d**, the plain cue count. This is stored show
  data that the reference app reads back after an upload.
- **Second bug (pb index).** The old page request left bytes 4-5 (playback index)
  at 0 and relied on a "flash address" that is really the data-length + packet-
  counter fields. Every page it fetched was therefore a cue of **pb0**. The Run 1 log
  above shows `header pb0 p0 vs plan pb1 p0` for every page after pb0, and its
  1908 non-zero bytes are reproduced exactly by replaying the old requests against
  the capture. Requests now carry pb/cue/block in bytes 4-9 like the reference app.
- **Simulation result.** Against a fake LPU replaying `download_show_M400...pcapng`,
  the fixed script saves 180/180 blocks identical to the `.show` file in three cases:
  all released, pb0 running (0x30 carries the cue), and pb0+pb4 with 0x30 silent.
- **CONFIRMED on hardware (2026-10-22, `analysis/scripts/run_pb0_running.txt`).**
  With pb0 and pb1 running, the LPU *does* answer 0x30. Their bodies were
  `00 03 06 00` and `00 03 03 00`; released slots return `00 01 nn ff`. So:
  - byte[1] is a state value: 0 = empty, 1 = loaded/released, 3 = running
    (probably bit 1 = live).
  - byte[3] is the active cue (0xff = none).

  The old code dropped these replies because byte[3] != 0xff, so section 19.5's
  "no reply" theory was wrong. The fixed script planned all 17 playbacks / 45
  pages, received 180/180 blocks, and `show_dump.bin` matches
  `m400_12x12_rgb_dim_shut.show` byte for byte. The 0x3d fallback was not
  needed.

---

## 20. Typed Property Frames — Unified Model (2026-10-22)

This section replaces the per-opcode guesses in sections 1, 2, 5, 8 and 16 with
one model that fits **every** frame in the write-back, download, toggle, GO and
live-monitor captures. Tools: `analysis/scripts/live_vn_monitor.py` (live/offline
decoder) and `analysis/scripts/confirm_writeback.py` (upload check).

### 20.1 Frame layout

Standard 20-byte header, payload from byte 20:

| Offset | Meaning |
|---|---|
| 0 | **object**: `0x1f` fixture, `0x28` action, `0x29` playback, `0x2b` cue, `0x2c` global, `0x3d` ? |
| 1 | **value type**: `0x00` string, `0x01` u32, `0x02` bool (u32 0/1), `0x03` float32, `0x05` 8-byte blob, `0x0a` 800-byte page, `0x1d` no body (read request, delete or action) |
| 2 | **property id** (tables below) |
| 4-5 | index 1: fixture or playback (0-based) |
| 6-7 | index 2: cue (0-based) |
| 8-9 | index 3: block 0-3 (pages only) |
| 10-11 | `ff ff` on every app frame and every reply; `00 00` on notifications |
| 12-13 | payload length (u16) |
| 14-15 | packet counter (u16), echoed in replies |

- **The bytes 12-15 "flash address" (section 15, VN_PROTOCOL §11) does not exist.**
  It is length + counter read as one u32. Pages are addressed only by bytes 4-9.
- **Read vs write ids:** write id = read id + 1 for most properties
  (05/06, 0b/0c, 15/16, 17/18, 1d/1e, 27/28, 29/2a, 2b/2c, 2d/2e, 39/3a, 46/47).
- **Echo:** the LPU echoes every app write byte for byte (same counter). The app
  sends the next write only after the echo arrives.
- **Notifications:** LPU -> app with byte[1] = value type | 0x80 (`0x80` string,
  `0x81` u32, `0x82` bool, `0x83` float), mask `00 00`. The LPU pushes them when a
  value changes, including live fader/knob feedback (`29 83 17`, `29 83 15`).
  `<obj> 81 00` is a generic "changed" event whose body is a change code
  (seen: 0x03, 0x14, 0x2e, 0x79, 0x121, 0x123, 0x128); the codes are not decoded.
- **Sub 0x38 with type 0x1d = delete/clear object** (fixture, playback), or
  reset (global). It is **not** a heartbeat; section 5 is superseded.

### 20.2 Playback properties (object 0x29) — all confirmed

| Property | Write | Read | Type | Notes |
|---|---|---|---|---|
| label | `06` | `05` | string | |
| speed (rotary knob) | `16` | `15` | float | signed, −1..1; LPU pushes `29 83 15` |
| intensity (fader) | `18` | `17` | float | LPU pushes `29 83 17` |
| background | `1e` | `1d` | bool | LPU pushes `29 82 1d`. Confirmed live (tick -> `29 02 1e = 1`) |
| go mode | `21` | — (in `30`) | u32 | 0 Go, 1 Toggle, 2 Flash, 3 Solo |
| GO button | `22` | — | bool | 1 = pressed, 0 = released |
| FLASH button | `23` | — | bool | 1 while held, 0 on release (see 20.2a) |
| RELEASE | `42` (type 1d, no body) | — | — | releases this playback (20.2a) |
| INSERT cue | `03` | — | u32 | 0-based position; `29 01 03 = 6` added cue 7 to pb1 (copies the previous cue's settings, empty blocks) |
| DELETE cue | `04` (type 1d, no body) | — | — | **index 2 = first cue (0-based), index 3 = number of cues** — confirmed 2026-10-22: pb1 cue 3 -> idx 2,1 (6 -> 5 cues); pb2 "remove all" -> idx 0,3 (3 -> 0); pb4 2 of 3 -> idx 0,2 (3 -> 1) |

After INSERT and DELETE the LPU re-sends the **whole playback** unasked: cue
count (`29 01 3d`) plus label/condition/fade/delay and all 4 blocks of every
cue (live run 2026-10-22, 19:16:36 and 19:17:32).
| repeat | `2e` | `2d` | u32 | 0 Loop, 1 Bounce, 2 Random, 3 Off |
| exclusive | `3a` | `39` | bool | Confirmed live (tick -> `29 02 3a = 1`) |
| cue count | `48` | `3d` | u32 | `48` also allocates the playback on upload |
| delete | `38` (type 1d) | — | — | |
| state summary | — | `30` | 4 bytes | see 20.3 |

Live pushes (LPU -> app): `29 82 50` active 0/1, `29 81 2f` active cue
(0xff = released), `29 81 24` cue phase (below).

#### 20.2a FLASH button and cue phase (live monitor run, 2026-10-22)

- **`29 02 23`** is sent on Flash press (1) and release (0). While it's held, the
  playback runs its current cue. Releasing it releases the playback.
- **Halt cues** (pb27, pb28): press -> `29 81 2f` = cue 1 and it stays there while
  held. Release -> active cue 0xff.
- **Follow cues** (pb13: 2 cues, condition Follow, delay 2 s): press -> cue 1.
  When cue 1's delay expires the next cue runs automatically, and because repeat
  is Loop it wraps back: cue 2 -> cue 1 -> cue 2 every 2.0 s until release.
- **Already running** (pb29, started with GO): Flash press/release produced
  **no** notifications, because the playback's state did not change.
- Unlike GO, Flash sends no `29 82 50` (active) push. Only `2f` and `24` change.
- **`29 81 24` is the cue phase, not a counter:**

  | Value | Meaning | Evidence |
  |---|---|---|
  | 1 | idle / released | after every release |
  | 2 | running with a timer active (fade or follow delay) | brief on every start; stays 2 through pb13's whole Follow loop, where a delay timer is always pending |
  | 3 | holding: cue on, nothing pending (Halt) | Halt cues after the fade |
  | 4 | releasing | on GO/Flash release |
  | 0 | playback has no cues | pushed after deleting all cues of pb2 (together with active cue = 0) |

  **Confirmed live (2026-10-22, second run):** phase 2 lasts exactly the cue's
  time, then 3. Measured: pb1 cue 1 = 20.0 s, cue 2 = 20.0 s, cue 3 = 6.0 s,
  pb2 cue 1 = 1.0 s. Phase 4 lasts the release fade (1.0 s here), then the
  active cue goes to 0xff and the phase to 1.

- **Release.** `29 1d 42` (playback index, no body) releases that playback.
  `28 1d 42` (action object, index 0) is the **RELEASE ALL** button: every
  running playback goes to phase 4, then released/idle after its release fade
  (pb1 and pb2: 1.0 s; pb29: about 15 ms). Earlier docs called sub 0x42 a "level
  state query"; that was wrong.

### 20.3 Playback property 0x30 — packed state

```
body[0] = go_mode << 4 | exclusive << 1 | background
body[1] = repeat  << 4 | state          state: 0 empty, 1 loaded/released, 3 running
body[2] = cue count
body[3] = active cue (0-based, 0xff = released; meaningless when state = 0)
```

Proven with the self-describing playbacks of `64fixtures_playback_menu.show`, which
the app downloaded inside `selecting_and_deselcting_lpu_in_device_list.pcapng`:

| Label | 0x30 body | go / bg+ex | repeat / state |
|---|---|---|---|
| "backg solo off" | `31 31 05 ff` | Solo / background | Off / 1 |
| "exclu flash ran" | `22 21 01 ff` | Flash / exclusive | Random / 1 |
| "backg excl togg" | `13 12 01 00` | Toggle / both | Bounce / 2 |

Also from the hardware run: `00 03 06 00` = pb running on cue 1. The value
state = 2 ("backg excl togg") has not been explained yet.

### 20.4 Cue properties (object 0x2b, index 1 = pb, index 2 = cue)

| Property | Write | Read | Type | Notes |
|---|---|---|---|---|
| label | `06` | `05` | string | |
| condition | `28` | `27` | u32 | 0 Halt, 1 Follow |
| fade | `2a` | `29` | u32 ms | `.show` `00-00-01-00` = 1000 |
| delay | `2c` | `2b` | u32 ms | |
| page block | `47` | `46` | 800 bytes | index 3 = block 0-3 |

All four editable cue properties were also seen **live from the edit window**
(2026-10-22, pb1 cue 6): condition `2b 01 28` Follow/Halt, delay `2b 01 2c`
6000 -> 5000 ms, fade `2b 01 2a` 3000 -> 1000 ms, label `2b 00 06` 'cue name'.
The LPU replies with the read id (`27`/`2b`/`29`/`05`) plus a `2b 81 00` change
event (codes: condition 0x5a, delay 0x36, fade 0x1a, label 0x121).

### 20.5 Fixture properties (object 0x1f, index 1 = fixture slot)

| Property | Write | Read | Type |
|---|---|---|---|
| definition `"Mfr","Model","Mode","PROFILE"` | `08` | `07` (notify `1f 80 07`) | string |
| DMX start address (1-based) | `0c` | `0b` | u32; 65535 = unpatched |
| name (patch screen label) | `06` | `05` | string |
| invert pan | `0e` | `0d` | bool |
| invert tilt | `10` | `0f` | bool |
| swap pan/tilt | `12` | `11` | bool |
| virtual dimmer | `14` | `13` | bool |
| delete | `38` (type 1d) | — | — |

**Patch screen, live run 2026-10-22 (20:53-20:57)** with fixtures 17-64:
- Add fixture = `1f 00 08` definition per slot. The LPU then **assigns the
  DMX addresses itself** and announces them: Shehds LED Wash RGBW (10 ch) got
  94, 104 ... 494. Fixtures 58-64 got **1**, because 504+ no longer fits in
  512 channels.
- Rename = `1f 00 06` per fixture (the app numbered them `set01` ... `set48`).
- Set address = `1f 01 0c` per fixture.
- The four patch-screen buttons sent `1f 02 0e`, `10`, `12`, `14` = 1 for all
  48 fixtures, one button at a time. **Confirmed by the user:** pressed in the
  order invert pan, invert tilt, swap pan/tilt, virtual dimmer.
- After delete, the LPU reports name `''` and address 65535.
- The earlier "definition (read) = 1f 1d 05" label was wrong: `05` is the
  name. The definition itself is announced via `1f 80 07`.

### 20.5a Edit window / programmer (live monitor run, 2026-10-22)

The user opened the edit window for pb1, loaded cue 1, moved one channel slider
down and up, and recorded the cue:

| Time | Frame | Meaning |
|---|---|---|
| 18:50:07.886 | `29 1d 42` pb2 | Release of pb2 when the edit window opened (to confirm) |
| 18:50:10.559 | `2c 02 35 = 0`, then read `2c 1d 34` -> `2c 01 34 = 0` | global flag on opening the edit window; meaning unknown |
| 18:50:22.995 | **`2c 1d 36`** (no body) | **LOAD cue into the programmer**. The LPU replies with 17 notifications `2c 8x 32`, idx 0-16 (programmer values, see below) |
| 18:50:27-36 | **`2d 03 33` idx 0, float** | **Channel slider** (object 0x2d), 0.98 -> 0.56 -> 1.0 -> 0.57; the LPU confirms each step with `2d 83 32` |
| 18:50:39.212 | **`2c 1d 37`** (no body) | **RECORD cue**. The LPU announces `2b 81 00` pb1 cue1 (codes 0x6b, 0x128) and pushes the new block 0 (`2b 0a 46`) |

- **Opening the edit window probably sends nothing** (user observation).
  **Loading a cue also selects the fixtures recorded in that cue**, so any
  fixture selection made before the load is overwritten.
- **Load and record DO carry the target** (second run, 18:59-19:01):
  index 1 = playback, index 2 = cue. `2c 1d 36` idx 0,1 = LOAD pb1 cue 2;
  `2c 1d 37` idx 0,1 = RECORD pb1 cue 2 (the LPU then announced "pb1 cue2
  changed" and sent the new block). Loads of idx 0,2 / 0,3 / 0,4 / 0,5 = cues
  3-6. The first run's `idx 0,0,0` was simply pb1 cue 1.
- **The selection mask is the 8x8 patch grid** (21:25:50, user dragged a
  rectangle): `03 03` -> `07 07 07` -> `0f 0f 0f 0f` -> ... -> all 64. Each byte
  is one grid row (fixtures 1-8, 9-16, ...), and each bit is a column.
- **INSERT cue `29 01 03 = 0xFFFFFFFF` (-1)** was sent on pb4 (21:25:44),
  probably "append at the end".
- **Patch flags are not acknowledged:** after `1f 02 0e = 1` for all 64
  fixtures the LPU sent no notification (names and definitions do get one).
- **Fixture selection CONFIRMED:** write `2c 05 3c`, LPU confirms with notify
  `2c 85 3b` (read id 0x3b). 8 bytes = 64-bit little-endian mask, bit n =
  fixture n+1. Selecting by hand went 00 -> 01 -> 03 -> 07 -> 0f -> 1f
  (fixtures 1 -> 1-5). After a LOAD, **the app** sends the selection of the
  loaded cue (cue 3 -> `1f 0f` = fixtures 1-5, 9-12). Each selection change is
  followed by a `2c 83 32` attr 17 notification (value 0).
- **Programmer values `2c 8x 32`, index 1 = attribute 0-17**, pushed after a
  LOAD (only the attributes that changed):

  | Attr | Type | Meaning |
  |---|---|---|
  | 0 | float | **intensity** (confirmed: slider after the colour sliders) |
  | 1 | 0x07, 4 bytes | **intensity FX** `[waveform, size, speed, phase]` |
  | 2 | 0x06, 8 bytes | **position** = 2 floats **pan, tilt, each -1.0..+1.0** (CONFIRMED 22:06: 159 joystick writes `2d 06 33`, pan -0.29 -> +0.96, tilt +0.44 -> -0.93) |
  | 3 | 0x07, 4 bytes | **position FX** `[waveform, size, speed, phase]` |
  | 4 | 0x08, 10 bytes = 5 x u16 | **colour = R, G, B, A, W** (one u16 per colour slider, UI order) |
  | 5 | 0x07, 4 bytes | **colour FX** `[waveform, size, speed, phase]` |
  | 6-16 | float | other attributes (fixture-dependent; 7, 15, 16 seen as sliders) |
  | 17 | integer, typed as float | appears after a selection change |

  **FX byte scaling (user-verified in the UI, 2026-10-22):**
  - size, phase: 0-255 = 0-100 % (÷ 2.55)
  - **speed: signed int8**, about 1.27-1.28 per %. 0 = 0 % (UI default),
    +1..+100 % = 1..127, −1 % = 255, −100 % = 129. The app sends +100 % as
    **128**, which wraps. Treat 128 as +100.
  - **The old "128 = 0" rule is wrong.** Proof from the cue blocks too:
    `fx_rainbow_size=18_speed=10_phase=85_record.pcapng` contains
    `0a 2f 0d d8/da` = Rainbow, size 47 (18 %), **speed 0x0d = +10 %**, phase
    ~85 %. No `0x8d` anywhere. `show_loader.dart` (`(sp - 128) / 127 * 100`)
    and PLAYBACK_CUE_OPTIONS §3b / SHOW_FORMAT / SHOW_RECORD_MAP
    still use the old rule.
  - **Attr 6-16** = 11 floats: colour wheel, shutter, gobo, gobo rotation,
    prism, focus, iris, frost, zoom, custom 1, custom 2. **Confirmed live
    2026-10-23**, fader by fader. (First assumed to follow the edit window's
    fader order r g b a w intens shutter col go rota prism iris focus zoom
    frost custom1 custom2; that order has shutter/colour wheel, iris/focus and
    zoom/frost swapped.) Faders are enabled per
    selected fixture when it has the channel. Channels outside this list (e.g.
    UV) cannot be controlled from the UI.

  So **each value is followed by its FX generator**. The FX layout is the same
  as inside the cue blocks (PLAYBACK_CUE_OPTIONS.md §3b, waveform ID table).
  Confirmed live on 2026-10-22 by editing the three generators:

  | Load | Attr | Bytes | Decoded |
  |---|---|---|---|
  | pb4 cue 1 "Twinkle" | 5 colour FX | `0c ff 2a 84` | Full Twinkle, size 255, speed 42, phase 132 |
  | pb41 cue 3 "Intens" | 1 intensity FX | `02 ff 15 4b` | Ramp, size 255, speed 21, phase 75 |
  | pb28 cue 1 | 3 position FX | `08 b3 0e 00` | Pan, size 179, speed 14, phase 0 |

  In each generator the user moved size -> speed -> phase -> waveform (-> None),
  and the bytes changed in exactly that order: byte 1, 2, 3, then 0. Clearing
  set all four to 0, and `2c 82 45` ("programmer has data") went to 0 when the
  last FX was cleared (19:38:47) and back to 1 when it was restored (19:38:48).
  This confirms 0x45 = programmer has data. The FX phase pushed by the LPU
  depends on the fixture selection (pb41: 0x4b before, 0x0c after the
  selection was set).

  Attr 4 across pb1 ("Basic col") cues 2-6: `0000 ffff ffff 0000 0000` cyan,
  `0000 ffff 0000 ..` green, `ffff ffff 0000 ..` yellow, `ffff 0000 0000 ..`
  red, `ffff 0000 ffff ..` magenta. The last two u16 are unknown (A / W?).
- **Choosing the playback to edit** (third run, 19:08-19:09, the user opened
  different playbacks in the edit window):

  | Frame | Meaning |
  |---|---|
  | `2c 02 35 = 1` | enter "choose a playback to edit" mode; the app re-reads `2c 1d 34` (= same value) |
  | **`2c 01 3f = N`** | **playback being edited, 0-based** (27 -> pb28, 26 -> pb27, 24 -> pb25, 5 -> pb6). LPU: `2c 81 00` change code 0x190; the app reads it back with `2c 1d 3e` |
  | `2c 02 35 = 0` | leave the mode (change code 0x126) |

  At 18:59:41/45 `35` went 1 -> 0 with no `3f` in between: the chooser was
  opened and cancelled. In the M400 open capture, `2c 01 3f = 26` = pb27.
  The mode meaning of `0x35` is inferred from this sequence.
- **Which DMX channel a slider / attribute index is** depends on the selected
  fixture's personality (`personalities.xml` profile string, VN_PROTOCOL
  "Fixture personality format"). The app UI must resolve that; the monitor
  only prints the raw index.
- **Object `0x2d` = programmer attribute** (write `33`, read/notify `32`).
  Index 1 is the attribute number, using the **same numbering as `2c ..32`**.
  Proven on 2026-10-22: moving a colour slider sent `2d 08 33` idx 4 with
  5 x u16 (only the first value moved: e88f -> 6a5d -> ffff), and the
  earlier dimmer-like slider was `2d 03 33` idx 0 (float). The old
  "float_param" note in VN_PROTOCOL §8 is this slider.
- **Colour (attr 4) = five u16 values, one per colour slider.** In the run of
  19:24:52-19:25:03 the user moved the edit window's **four single-colour
  sliders one after another**, and u16 #1, #2, #3 and #5 changed while #4
  stayed 0000. So the sliders map in order to #1, #2, #3, #5; #1-#3 follow
  R, G, B of the loaded cues. The slider names for #4/#5 (e.g. amber/white)
  were not recorded.
- **Intensity = attr 0** (float, `2d 03 33` idx 0): the slider after the colour
  sliders. Further float sliders seen: attr 7, 15, 16. Which channel those are
  depends on the fixture personality.
- **Notifications are sent twice**, once to each app socket (UDP ports 60442
  and 16945 on the PC). That's not a protocol repeat; the monitor drops the
  second copy.
- **After a fixture selection change** the LPU pushes the selection's current
  value of the changed attributes (e.g. `2c 88 32` attr 4 colour).
- **`2c 82 45`** (notify bool) = **programmer has data**: 0 after loading an
  empty cue or clearing the last attribute/FX, 1 otherwise (confirmed with the
  FX edits above).
- **Attr 17** decodes to tiny floats (1.783e-40, 2.088e-41), so it is really
  an integer, probably related to the selection. The monitor prints it raw.

### 20.5b Options page (live monitor run, 2026-10-22, 21:46-21:48)

| Object | Property | Write | Read | Type | Seen |
|---|---|---|---|---|---|
| `0x0a` Art-Net | universe | `33` | `32` | u32 | UI 1 -> 2 wrote **32** (`0x20`); maybe the Art-Net port-address form (subnet 2, universe 0), not confirmed |
| `0x0a` Art-Net | enabled | `26` | `25` | bool | 0 / 1 |
| `0x0b` sACN | universe | `33` | `32` | u32 | 1, then 2 (same as the UI) |
| `0x0b` sACN | enabled | `26` | `25` | bool | 1 / 0 |

Change codes: `0x13` = enabled changed, `0x17` = universe changed. The app
re-reads `25` (and `32` after a universe change) after every write.
- **The short 9-byte commands are device properties** (second run, 21:54):
  `[00, prop, 0 x6, length, value]`; a 9-byte frame with length 0 is a read,
  and write id = read id + 1 as everywhere else.

  | Prop | Value | Meaning | Evidence |
  |---|---|---|---|
  | `0x00` | `02 00 00 00 00 01` | MAC address | `.show` `<mac>02:00:00:00:00:01` |
  | `0x03` | `ff ff ff 00 ..` | subnet mask | `.show` `<subnet>255.255.255.0` |
  | `0x09` | `01 1d` | firmware 1.29 | `.show` `<firmware_version>1.29` |
  | `0x0a` | `02 00` | PCB version 2.0 | `.show` `<pcb_version>2.0` |
  | **`0x11` / `0x12`** | `'LPU1'` | **alias read / write** | write `00 12 .. 03 'LPU'` at 21:54:14, then `02 81 00` device changed, read back `'LPU'` |
  | `0x34` | 32 / 48 / 240 / 0 | **Art-Net universe** (CONFIRMED 21:58: always equals the last `0a 01 33` write; same value as `0a 1d 32`) | see below |
  | `0xf0` | 1 / 2 | **sACN universe** (CONFIRMED 22:15: follows every `0b 01 33` write) | |
  | `0xce` | 0 / 1 | **Art-Net enabled** (CONFIRMED 22:15: 1 after enabling, 0 after disabling) | |
  | `0xef` | 0 / 1 | **sACN enabled** (CONFIRMED 22:15) | |
  | `0xea` | always 1 | unknown | |

  **Writing a universe also enables that protocol** (22:15:37 / 22:15:41: the
  universe write produced change codes 0x13 + 0x17 and `enabled` read back 1).
  While connected, the app re-reads the short device properties about every
  5 s.

  **Art-Net universe encoding (21:58 test, CONFIRMED):** the UI range is
  **0-15** (user: "max was 15"). Stored value = **UI x 16**: UI 2 -> 32
  (`0x20`), 3 -> 48 (`0x30`), 15 (max) -> 240 (`0xF0`), 0 -> 0. The UI number
  is the Art-Net **Sub-Net** nibble (bits 4-7) with the Universe nibble 0.

  `debug_lpu_discover_v2.py` used wrong labels for these ("universes",
  "os_type", "device_type", "cue_count"); fixed.
- **Deselect + select the LPU** = the full download (playback reads, fixtures,
  cues, `28 1d 4f` = 0), the same as an app restart.

### 20.6 Actions and unknowns

- **`28 1d 42` = RELEASE ALL button** (see 20.2a).
- **`2c 1d 36` = LOAD cue, `2c 1d 37` = RECORD cue**, target in idx 1 = pb,
  idx 2 = cue (see 20.5a). **`2c 05 3c` = fixture selection mask.**

- **`28 1d 49` = playback Swap button.** Confirmed live on 2026-10-22: swapping
  pb7 <-> pb15 sent `28 1d 49` with index 1 = 6, then swapping back sent it with
  index 1 = 14. Afterwards the LPU re-announced both playbacks (`29 81 00` change
  codes, cue counts swapped 1 <-> 0). **CONFIRMED 22:06:** `28 1d 49` idx
  **2,18** = swap pb3 <-> pb19: index 1 and index 2 are the two playbacks
  (0-based).
- **`3d 1d 4a`** (index 0): the app sends it every ~10 s and the LPU only echoes
  it. Purpose unknown (possibly a status ping).
- **`2c 05 3c`** (8-byte global blob) and **`2c 02 35` / `2c 01 3f` / `2c 1d 34`
  / `2c 1d 36` / `2c 1d 3e`** (global settings) are not decoded.

### 20.7 Show upload (app opens a .show) — summary

The full sequence is in `dled_flutter/VN_PROTOCOL.md` §12 (the updated
copy; the project's own `dled_flutter/VN_PROTOCOL.md` does not have it yet):

1. `2c 1d 38` CLEAR programmer (was read as a show reset; 20.17).
2. Fixtures 0-63: `1f 00 08` definition + `1f 01 0c` address, or `1f 1d 38` delete.
3. Playbacks 0-63 ascending: `29 01 48` cue count, then per cue the 4 blocks
   `2b 0a 47` (pb, cue, block in bytes 4-9, empty banks zero-filled) plus cue
   label/fade/delay/condition. Then the playback label/intensity/speed/go mode,
   and always `29 02 1e` + `29 02 3a` (= background + exclusive). Empty slots
   get `29 1d 38`.
4. Read everything back.

312/312 uploaded blocks across three captures match their `.show` files.
Sections 2 and 16 (op 0x1f/0x2b "PUSH", positional blocks) are superseded.

**Live monitor run 2026-10-22 21:03 (M400 show loaded onto an LPU that already
held almost the same show):** same sequence, with two additions and one
important difference:
- After `2c 1d 38` RESET the app clears the fixture selection
  (`2c 05 3c` = 8 zero bytes).
- **Fixtures and named properties are only written when they differ from the
  LPU's current state.** The 9 patched fixtures got **no** `1f 00 08` /
  `1f 01 0c` (only the 55 empty slots got `1f 1d 38`). Playback labels: only
  pb29 got `29 00 06 = ''` (it had been renamed live before). Cue fades: only
  pb2 cues 1-3 and pb4 cues 2-3.
- **Always written:** cue count `29 01 48`, background `29 02 1e`, exclusive
  `29 02 3a` for every playback in the show, all 4 page blocks of every cue
  (180 frames = 45 cues), and DELETE for every empty playback slot.
- A re-implementation can simply send everything (as in the first M400
  capture, where the LPU held a different show). Diffing is an optimisation of
  the reference app, not a requirement.

**App restart = full download (21:15).** On startup the reference app reads the
whole LPU state again: `28 1d 4f` (action object, bool reply 0, meaning
unknown), then per fixture slot 1-64 name `05`, address `0b`, **`1f 1d 30`**
and definition `07`, all cues (label/condition/fade/delay + 4 pages; 84 pages
for 21 cues), plus programmer and edit state (`2d ..32` x17, `2c 3b/45/3e/34`).
So the app rebuilds its copy of the LPU from scratch on every start, and the
"only send differences" upload compares against that copy.
**`1f 1d 30` = packed fixture state** (u32): high 16 bits = DMX address
(fixture1 `0x00010000` = 1, fixture2 `0x00070000` = 7, fixture3 `0x000D0000` =
13; empty `0xFFFF0000`). The low 16 bits were 0.
**Low bits = pan/tilt flags (CONFIRMED 21:42 with Shehds LED BEAM 12x12W
moving heads):** after each button the app re-read `1f 1d 30` and got
`0x00010001` (invert pan) -> `0x00010003` (+ invert tilt) -> `0x00010007`
(+ swap pan/tilt). So bit 0 = invert pan, bit 1 = invert tilt, bit 2 = swap.
**Virtual dimmer** is not in this word: after `1f 02 14 = 1` the app read
`1f 1d 13` and got `1f 02 13 = 1`.
The earlier 21:30 test (all bits 0 with invert pan "on") used RGBWA+UV pars
without pan/tilt: the LPU ignores pan/tilt flags on such fixtures.
**So the flags can be downloaded:** pan/tilt flags come with the startup
fixture list (`1f 1d 30`), and virtual dimmer via `1f 1d 13` (the reference app
does not read it at startup, but the LPU answers it).
**Name length limit:** the LPU stored the definition's model as `"LED BEAM
12x12W RGBW Moving H"` (29 chars) although the app sent `"...Moving Head"`.
`28 1d 4f` answered 0 on both restarts (21:15 and 21:30); its meaning is still
unknown.

**Second example, 21:08 (`show_all_fx_options.show` loaded over the M400
show):** the diff works **per property**. Fixture 1 got its definition but no
address (1 = unchanged). Fixtures 2/3 got address 7/13 (were 6/11), and fixtures
9-11 got definition + address. pb1 got `intensity = 1.0` (M400 pb1 was 0.975).
Cue fades were reset to 0 only at positions that had 1 s before (pb1 cues 1-5,
pb2 and pb3 cues 1-3). All 21 cue labels and 4 playback labels were sent.
Always sent: cue count, background, exclusive, and 84 page frames (21 cues x
4); 58 fixture and 60 playback slots got DELETE. No undecoded frames.

### 20.8 Show download — summary

- Per playback 0-63, read `29 1d 30` (20.3). The cue count is in body[2]. A
  running playback answers too; the old parser dropped it (section 19).
- Per cue, read `2b 1d 05/27/29/2b`, then `2b 1d 46` for blocks 0-3.
- `debug_lpu_discover_v2.py --download --dynamic` does this. Verified on
  hardware with pb1/pb2 running: 180/180 blocks equal to the M400 `.show`.
  `--dir-debug` also prints each playback's properties (20.2/20.3).
  Output numbering is 1-based like the UI (playback 1-64, cue 1-N).
- The skill script `lpu-show-download` (analysis/lpu/lpu_io.py) does the full
  download (device, fixtures, playbacks, cues) and writes a .show + report.
  See `analysis/LPU_TOOLS.md`.

### 20.19 A repeated sequence number is only echoed; a new client gets a burst (2026-10-25)

Measured through the ESP32 box (`tool/real_box_connect_check.dart trace`,
`tool/real_lpu_seq_check.dart`, LPU firmware 1.29):

- **The LPU takes a request with the sequence number it has just answered
  (from the same address and port) for a repeat: it only echoes the request
  byte for byte, it does not answer a read again.** A lost answer followed
  by a resend with the same number therefore never brings the data; at the
  start of a session (only one request in flight) the read failed all 4
  attempts. A resend with a new number is answered normally. Writes keep
  their number on a resend, so the LPU never carries one out twice.
  (`lpu_client.dart` gives a re-sent read a new number.)
- **A new client (address + port) gets about 64 "changed" notifications at
  once** (`29 81 00 [playback] mask 0000`, one per playback) within ~10 ms
  of its first request. The ESP32 (10 Ethernet receive buffers, prebuilt
  Arduino framework) loses part of such a burst, and with it now and then an
  answer; direct from a PC nothing is lost.
- The first answer to a new port takes ~9 ms, later ones ~1 ms.
- Many sessions opened and dropped (dozens in a test session) slowed the
  LPU down: a direct show download took 1.2 s instead of 0.4 s until the
  LPU was power-cycled.

### 20.18 IP ADDRESS: the LPU's own address (2026-10-24, partial)

Capture `samples/ip_address_change.pcapng`: the real
app's OPTIONS > IP ADDRESS, Static, Ok, twice (192.168.1.12, then .13).

- **Write = short device property 0x02, 6 bytes**: the 4 IP bytes + `00 00`.
  `00 02 00 00 00 00 00 00 06 c0 a8 01 0d 00 00` set 192.168.1.13; the LPU
  echoes it and answers from the new address straight away (no restart).
- **0x03 = the subnet mask, 6 bytes** (`ff ff ff 00 00 00` = 255.255.255.0
  + `00 00`). The app reads it every 5 s while OPTIONS is open; it did not
  write it here (mask unchanged).
- **Mask write = 0x04**, 6 bytes: 4 mask bytes + `00 00`, sent right after
  0x02 and only when the mask changed. **DHCP = 0x02 and 0x04 both all
  zeros.** From the emulator log `samples/
  emu_ip_dhcp_log.txt` (reference app on another device, 2026-10-24): static
  192.168.1.173 (`c0 a8 01 ad`), .171, mask 255.255.255.12 (`ff ff ff 0c`),
  then DHCP. Invalid entries (999 / 888) are not sent at all.
- The app does not read 0x02; how it learns DHCP vs static is still open
  (0x03 is read every 5 s; 0xea read 1 on the LPU - unconfirmed).
- The reference app's dialog always opens on DHCP, even when a static IP is set
  (user-verified); ours does the same after a reconnect. Static IP from the
  Flutter app confirmed on the real LPU.
- The Flutter app writes the mask first, then the IP (the LPU moves at once,
  a later write would go to the old address); DHCP in the reference app's order.

### 20.17 Edit window of the reference app: CLEAR, leaving, LOAD (2026-10-24)

The reference app (phone) against the emulator with `--log`
(`lpu_downloads/emulator_log_edit.txt`), the user following a fixed list of
steps:

| Step | Frames |
|---|---|
| open EDIT, choose pb1 | **`2c 1d 36` LOAD pb1 cue1** by itself, then `2c 05 3c` = that cue's fixtures |
| select fixtures | `2c 05 3c` per change (mask, bit n = fixture n+1) |
| sliders / joystick | `2d 03 33` attr 0, `2d 08 33` attr 4 (all 5 colours each time), `2d 06 33` attr 2 - **every step sent**, no bundling (~20-50 ms apart) |
| FX dialog | `2d 07 33` attr 1 **live** while size / speed move |
| **CLEAR** | **`2c 1d 38`** (no body), once per press - nothing else |
| LOAD cue 2 | `2c 1d 36` pb1 cue2, then the cue's selection |
| **leave EDIT** | **`2c 02 35 = 1`** only - the programmer is **not** cleared |
| enter EDIT again | `2c 02 35 = 0` |

- So `2c 02 35` = "not in the edit window" (0 while editing), only sent on a
  change (the first entry after connecting sent none: it was already 0 in
  the emulator). Earlier "choose a playback" reading (20.5a) is the same flag.
- **Real LPU checks (our client):** with no fixture selected an attribute
  write leaves "has data" (`2c 45`) at 0; with fixture 1 selected intensity
  50 % sets it to 1 and the fixture lights; `2c 1d 38` sets it back to 0 and
  the playbacks take over again; selection, `35` and the whole show are
  unchanged (`tool/real_lpu_programmer_check.dart`).
- **Programmer reads are odd:** `2d 1d 32` with index 1 = N is answered as
  `2d 03 32` with **index 1 = 17** (float) for N = 0 and 4. The answer
  carries the request's **sequence number** (bytes 14-15) - a client that
  matches by index never takes it; matching by sequence would. Not needed by
  the app (it never reads the programmer).
- After `2c 1d 38` the LPU sent `29 81 00` "changed" (code 4) for all 64
  playbacks.
- The reference app polls `3d 1d 4a` (object 0x3d, unknown) every 10 s and the
  Art-Net universe short property every 5 s.

### 20.16 Reads can overlap - with a 0.5 ms gap (2026-10-24)

Real LPU over Wi-Fi: one request/answer takes median 19 ms (90 %: 26 ms),
no resends; a show download is 716 requests -> 16-17 s one by one.
Bursts of N reads sent back to back lose answers (4: 3/4 twice, 8: 1/8 once,
32: 6/32 once). With **0.5 ms between sends: no loss in 48 bursts** (4 / 8 /
16 / 32), 32 answers in 23-45 ms; 2 ms and 5 ms also lossless but slower.
The Dart client now keeps up to 16 reads in flight, paced 0.5 ms: **download
0.6 s**, the .show byte-identical to the one-by-one download (three runs).
Writes stay lock-step.

### 20.15 Deleted cues are announced, but not readable (2026-10-23, v1.0)

Seen on the real LPU (firmware 1.29) with a probe on the empty slot 63:
- Deleting cues (`29 1d 04`) makes the LPU send "changed" (`2b 81 00`) for the
  **deleted** cue indices too (codes 0x121 / 0x1a), besides `29 81 00` for
  the playback.
- Reads of a cue that no longer exists (e.g. `2b 00 05` label for cue 2 of a
  playback that now has 0) get **no answer at all** - the client times out
  (2.4 s with retries). The LPU keeps answering everything else.
- One edit announces the same playback several times (3-4 x `29 81 00`).
- Deleting a playback (`29 1d 38`) is followed by "changed" for all 64
  playbacks (code 0). Deleting the last cue of a playback is not.
- After deleting all cues the packed state is `00 00 00 00`: phase 0 (no
  cues) with active cue 0 instead of 0xff. With phase 0 the active cue byte
  means nothing (see the table above), so this is not a stuck playback.

Consequence for clients: read back only cues that still exist (check the
cue count first), read each announced object once, and do not treat one
unanswered read as a lost connection. The emulator now behaves the same.

### 20.14 Which client sockets get the live notifications (2026-10-23)

From all captures (`analysis` script: who sent what to the LPU, who got
notifications):

| Reference app socket | Sends | Notifications received |
|---|---|---|
| UDP **16945** | typed frames (reads, writes, actions) | **all** |
| a random port (e.g. 62143, 56891) | keepalive `ff`, short device reads `00 xx` | **none** |

In `lpu_and_reference_app_connection_from_packet_1515pcapng` two typed-frame
sockets (16945 and 16946) each got every notification (64 / 64), so the LPU
keeps more than one target. Conclusion: **the LPU sends notifications to
sockets that sent it typed frames**; keepalives and short reads do not
register a socket. Our CLI `monitor` only did a short read and got nothing
(20.13) - fixed by one typed read at start. **Confirmed on the real LPU
(22:41):** after one typed read the monitor got every push while the reference app
was used (GO down/up `29 82 50`, active cue `29 81 2f`, phase `29 81 24`
2 -> 3 after a 1 s fade, 4 -> released after a 1 s release), and the reference app
kept working. Still open: whether registrations expire and how many targets
the LPU keeps.

### 20.13 LPU stuck in "releasing" until a power cycle (2026-10-23, evening)

After a day of mixed use (reference app, our CLI pressing GO on the real
LPU in the morning, show uploads / opens), RELEASE ALL in the reference app no
longer brought playbacks back to released, restarting the app and loading a
new show did not help - only a power cycle did. Read-only state dump (29 30)
of the stuck LPU:

| pb | cues | state (29 30 byte1 & 0f) | active cue |
|---|---|---|---|
| 1 Basic col | 6 | 4 releasing | 5 |
| 2 Rainbow | 3 | 4 releasing | **5 (does not exist)** |
| 3 Random | 3 | 4 releasing | 1 |
| 4 Twinkle | 3 | 4 releasing | 1 |
| 5 Duel Col | 3 | 4 releasing | **8 (does not exist)** |
| 6 Strobe | 1 | 4 releasing | 1 |
| others | | 1 released | - |

Active cues past the end of the playback suggest the show was replaced while
these playbacks were running (the LPU kept the old cue numbers) and the
release fade can then never finish. Cause not proven. Rules from this:
- Release everything (RELEASE ALL) before uploading / opening a show; our
  upload should do that itself (v0.7) - and refuse or warn when playbacks run.
- `dled_cli status` (read-only) shows this state and flags impossible cues.
- In the same session `dled_cli monitor` (keepalive + one read, no writes)
  received **no** notifications for 60 s while buttons were pressed in the
  reference app. Not yet known whether the LPU only notifies the reference app's
  sockets or whether nothing changed because it was stuck. Re-test after the
  power cycle, reference app closed first.

### 20.12 The reference app does not follow changes made by another client (2026-10-23)

With the Dart CLI pressing GO / changing playbacks on the real LPU while a
second app watched: the app showed playbacks in an in-between state,
and its own RELEASE ALL (normally: release everything and go back to the
first cue) left them hanging. So the reference app keeps its own idea of the
playback state from its own presses and only partly applies the LPU's
notifications. Consequence for our app: in connected mode the playback state
must come only from the LPU (notifications + `29 30` packed state / active
cue), never from local button presses. Also the CLI/emulator are a good way to
test exactly this ("someone else changed it").

### 20.11 Record offsets of the extra faders (app-saved show, 2026-10-23)

`show_all_fx_options.show` (copy: `analysis/tests/data/app_saved_channels.show`)
has two new playbacks made for this:

- pb4 "color and gobo" (Kanjo spot 60): colour wheel, gobo, shutter set.
- pb5 "new channels de" (CLF Aorun, 16 ch): cue 1 with every fader up, then
  cues "frost off", "focus off", "prism off", "gobo off", "color wheel off",
  "shutter off", "intensity off", each with exactly that fader at 0.
- pb9 "color channel c" (Compact Par 18 Tri): cues "1=r, 2=g, 3=b" etc.

Result (u16 BE): 16 intensity, **18 colour wheel**, 20/22/24 R/G/B
(confirmed per fixture), **30 gobo**, 34 shutter, **38 frost**, **40 focus**,
**42 prism**.

Update (same file, saved 18:00): pb6 "missing channel" on three SilverStar
PLUTO 200 "Basic" (profile `02031409800A0A0B100E0D11120F010C13`), each cue
with exactly one fader at full: **32 gobo rotation, 36 iris, 44 zoom,
46 custom 1, 48 custom 2**. Every record byte 12-49 is now mapped
(`analysis/lpu/showfile.py` `ATTR_OFFSETS`).

Function code -> fader: a cue only stores the faders a fixture has a code for
(Kanjo 09/0A/0C -> only 18/30/34; Aorun 0E/0F/10/12 -> only 38/40/42/46). Both
fit the rule "codes 0x0A..0x12 in order = offsets 30..46":
0x0B gobo rotation, 0x0D iris, 0x0E frost, 0x0F focus, 0x10 prism, 0x11 zoom,
0x12 custom 1 (only the Aorun backs this one). 0x13 stays UV (fixture names,
e.g. "RGBWA+UV"); which fader drives UV and 0x80 (generic) is still open.
Final proof would be the LPU's Art-Net output: one fader up, see which DMX
channel moves.

A live capture while sliding faders only shows the programmer attribute index
(`2d 07 33 attr N`, see 20.x); the record offsets only appear in recorded cues
(show file, or the 800-byte pages of an upload).

### 20.10 Hidden .show attributes (app-saved file, 2026-10-23)

The app writes attributes only when not default, so the sample shows never
showed these. Found by saving a show with those options set
(`pan_tiltt_dimmer.show`, copy: `analysis/tests/data/app_saved_flags.show`):

- `<fixture ... invert_pan="true" />`, `invert_tilt`, `swap_pan_tilt`,
  `virtual_dimmer`: **confirmed**, one attribute per flag, only when on.
- `<fixture label="...">`: fixture name, **confirmed**; the app writes it
  right after `index`: `index, label, address, manufacturer, model, [mode],
  profile, [flags]`.
- `mode` is omitted for models without modes (confirmed).
- Not yet seen in a file: fixture `personality="%u:%u"`, playback `level`,
  `<show readonly=..>`, a `<buttons>` section. The user confirmed (2026-10-23)
  that managing shows in the app sends no commands to the LPU, so these are
  app-side (UI) only; the tools just keep them unchanged.
- Cue data on **unpatched** slots is real: while recording, the app lets you
  select grid items that have no fixture patched, and the cue stores values
  for them (user, 2026-10-23). The report lists them as "data on unpatched
  slots"; upload sends them like any other block data.

So a .show **does** carry names and flags. The Python upload writes them
according to the file (absent = off), and download writes them into the file.

### 20.9 Fixture record layout and function codes (sample-show survey, 2026-10-22)

Surveyed every non-zero byte of the 50-byte records in all five sample shows,
per fixture profile:

| Bytes | Content | Evidence |
|---|---|---|
| 0-3 / 4-7 / 8-11 | intensity / position / colour FX `[wave, size, speed, phase]` | as in SHOW_FORMAT.md |
| 12-13 / 14-15 | pan / tilt, **int16 little-endian, signed around the centre** (DMX = 32767 + value; corrected 2026-10-27, lpd/DMX_ENGINE.md) | varies only on the M400 moving heads |
| 16-17 | intensity, u16 **LE** (corrected 2026-10-27) | `ff ff` = full |
| 20 / 22 / 24 / 26 / 28 | **R, G, B, A, W**, u16 LE | RGBWA+UV pars (profile `04 05 06 08 07 13`) fill all five; same order as programmer attr 4 |
| 30-48 | further attributes | profiles with shutter (`0C`) always use **34**; 30 seen with profile `01 04 05 06 0C 80`; the rest is unmapped |

- **The Dart table `kFunctionOffset` (show_loader.dart) is partly wrong:** it
  puts shutter (0x0C) at 36 and maps pan/tilt/motor/custom into bytes 4-11,
  which are the FX slots. Not changed in the app yet.
- **Function codes** confirmed against fixture names / manuals:
  0x01 dimmer, 0x02 pan, 0x03 tilt, **0x22 pan fine**, 0x23 tilt fine,
  0x04 red, 0x05 green, 0x06 blue, **0x07 amber, 0x08 white, 0x13 UV**
  ("RGBWA+UV" = `04 05 06 08 07 13`), 0x09 colour wheel, **0x0A gobo**,
  0x0C shutter/strobe, 0x14 pan/tilt speed, 0x80 generic/function (Kanjo spot
  60 = `02 22 03 23 14 09 0A 01 0C 80`). VN_PROTOCOL's older table (0x08
  "UV/White2", 0x0A "colour wheel 2", 0x13 "prism", 0x22 "pan coarse alt") is
  wrong for these codes. Other codes remain unconfirmed.


