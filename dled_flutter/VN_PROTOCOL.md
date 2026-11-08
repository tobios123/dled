# VN Protocol — LPU-1

Measured from four live pcapng captures of the reference app
communicating with an LPU-1 (firmware 1.29).  All multi-byte integers are
little-endian unless noted.

---

## High-level overview

The VN protocol runs over **UDP port 16945**.
It is a request/response + push protocol with four roles:

| Role | Direction | Description |
|---|---|---|
| Discovery | client -> broadcast | Announce presence, ask devices to identify |
| Identify reply | device -> broadcast | Device XML self-description |
| Keepalive | client -> device | Heartbeat at ~40 Hz; device disconnects if absent |
| Level set | client -> device | Set one fader/channel to a float level |
| Status query | client -> device | Read a device property |
| Status reply | device -> client | Answer to a query or unsolicited push |
| Program write | client -> device | Write program data (PUSH commands, bank >= 0x80) |

The client binds an **ephemeral UDP port** (not 16945) and sends to port 16945
on the device or to the broadcast address.  The device always replies from
port 16945.

---

## Command structure

Every non-keepalive, non-discovery packet begins with a 2-byte command word:

```
Byte[0]  =  op code   (what operation to perform)
Byte[1]  =  bank byte (which object to act on)
             bit7 = 0  -> read/query  (device replies with data)
             bit7 = 1  -> write/push  (no reply expected; bank = 0x80 + cuelist_index)
```

Bank values (low nibble when bit7=0):

| Bank | Meaning |
|---|---|
| 0x00 | GLOBAL (device-wide) |
| 0x01-0x10 | CUE[0]-CUE[15] (cuelist slot) |
| 0x1d | DEV_INFO (device configuration) |
| 0x09 | firmware version query |
| 0x0a | API version query |
| 0x11 | product code query |
| 0x34 | cuelist count query |
| 0xce/0xea/0xef/0xf0 | feature flag queries |

PUSH bank values (bit7 set):

| Bank | Meaning |
|---|---|
| 0x80 | PUSH GLOBAL |
| 0x81-0x8f | PUSH CUE[0]-CUE[15] |
| 0x88 | PUSH MEDIA (internal show player) |

Op codes:

| Op | Name | Meaning |
|---|---|---|
| 0x00 | ping/status | Device status / timestamp |
| 0x1f | name | Fixture/scene name; payload is CSV string |
| 0x29 | level | Fader/channel level (float) |
| 0x2b | string_list | Cue step list (CSV strings) |
| 0x2c | config_obj | Cuelist or device config object |
| 0x2d | float_param | Named float parameter by index |
| 0x34 | count | Object count |
| 0x3d | big_object | Large binary object |
| 0x46 | big_list | Large list (cuelist dump, 820 bytes) |
| 0x76 | discovery | ASCII "visual_identify" discovery payload |

> **Show upload:** there is no dedicated upload opcode.  Writing a program to the
> LPU uses op=0x1f PUSH (339 packets, fixture CSV definitions) followed by
> op=0x2b PUSH (343 packets, cuelist bulk write).  Sub-type byte 0x08 is a
> sub-type within op=0x1f frames, not a standalone command.

**Non-PUSH (query) packets** have `0xFF 0xFF` at bytes[10:11] (broadcast mask).
**PUSH (write) packets** have `0x00 0x00` at bytes[10:11].

---

## Packet header common layout

Most non-keepalive packets share this structure in the first 12-16 bytes:

```
Offset  Len  Description
  0      1   op code
  1      1   bank byte (bit7 = 1 means PUSH/write; low nibble = object index)
  2      1   sub-type (operation variant within the op)
  3      1   reserved: 0x00
  4      2   sub-index (uint16 LE; selects parameter or record within bank)
  6      4   reserved: 0x00 x4
 10      2   broadcast mask: 0xFF 0xFF = query/REQ, 0x00 0x00 = push/PUSH
 12      2   data length (uint16 LE; payload byte count after offset 20)
 14      2   packet counter (uint16 LE; monotonically increasing per session)
 16      4   reserved: 0x00 x4
 20      n   payload (data_length bytes)
```

> **Note:** the payload starts at byte 20, not byte 16.  Bytes 16-19 are always
> 0x00 in all observed frames.  Earlier documentation incorrectly placed payload
> at offset 16.

---

## Packet type reference

### 1. Discovery (client -> broadcast)

```
Payload:  "visual_identify"   (15 ASCII bytes, no null terminator)
```

Sent as a UDP broadcast to `255.255.255.255:16945` every 4 seconds, and also
as a unicast to the device IP immediately after the user connects.

---

### 2. Identify reply (device -> broadcast)

```
Payload:  XML, variable length, null-terminated
```

Example:
```xml
<?xml version="1.0" ?>
<visual_identify label="LPU-1">
  <version>1.29</version>
  <os>Embedded</os>
  <ip>192.168.1.12</ip>
  <port>16945</port>
</visual_identify>
```

Fields used by the client: `label`, `version`, `ip`, `port`.

---

### 3. Keepalive (client -> device)

```
Offset  Len  Value   Description
  0      1   0xFF    Single keepalive byte
```

Sent at **40 Hz (every 25 ms)**.  Absence triggers disconnect detection on the LPU.

> **Session heartbeat:** In addition to the raw 0xFF byte, the app sends op=0x2c
> sub=0x38 frames at regular intervals to maintain session state.  Earlier
> documentation labelled this "cmd=0x38" -- it is a sub-type within the
> config_obj opcode (0x2c), not a standalone command.

---

### 4. Level packet -- op 0x29 (client -> device / device -> client)

Sets a playback fader to a floating-point level.  **24 bytes total, no 0x1f
magic header** — this frame type uses its own layout distinct from the 0x1f
command family.

```
Offset  Len  Type       Description
  0      1   uint8      cmd = 0x29
  1      1   uint8      flags: 0x03 = REQ (App->LPU), 0x83 = RSP (LPU->App, bit7 set)
  2      1   uint8      sub-type / version byte (observed: 0x17, 0x18, 0x22, 0x24, 0x2f, 0x50)
  3      1   uint8      reserved: 0x00
  4      1   uint8      playback_index (0-based: 0=PB1 ... 7=PB8)
  5      5   bytes      reserved: 0x00 x5
 10      2   uint8x2    REQ: 0xFF 0xFF  |  RSP: 0x00 0x00
 12      2   uint16 LE  constant 0x0004 in all observed frames
 14      2   uint16 LE  sequence counter (monotonically increasing per connection)
 16      4   bytes      reserved: 0x00 x4
 20      4   float32 LE level: 0.0 = 0%, 1.0 = 100%
```

**Example** (PB1, level ~99.2%, counter = 0x0a26):
```
29 03 18 00  00 00 00 00  00 00 ff ff  04 00 26 0a  00 00 00 00  61 e2 7d 3f
```

**Level encoding table:**

| Level  | float32 hex   | float32 value |
|--------|---------------|---------------|
| 100%   | `00 00 80 3f` | 1.0           |
| ~99.2% | `61 e2 7d 3f` | 0.9918        |
| 0%     | `00 00 00 00` | 0.0           |

The LPU **echoes every REQ as RSP**: same bytes, flag byte[1] flipped to 0x83,
counter byte[2] decremented by 1.

#### Cue go / release push notifications (LPU->App only, cmd=0x29)

Cue go and release are driven by **physical button presses on the LPU hardware**.
The app does not send cmd=0x29 packets to trigger cues; instead the LPU pushes
five sub-type notifications to the app after each hardware event.

bytes[20:24] in push frames carry a **LE uint32** (not float32):

| Sub  | flags | fld10  | body uint32 | Meaning |
|------|-------|--------|-------------|---------|
| 0x22 | 0x02  | 0xffff | 0 or 1      | Level active state: 1=active, 0=inactive |
| 0x50 | 0x82  | 0x0000 | 0 or 1      | PUSH active state: 1=active, 0=inactive |
| 0x24 | 0x81  | 0x0000 | 1..N        | Active cue absolute counter (wraps at list length) |
| 0x2f | 0x81  | 0x0000 | 0,1,2,0xff  | Cue step index within the list |
| 0x42 | 0x1d  | 0xffff | (none)      | 20-byte level state query (no body) |

**Cue Go** (cue becomes active):
```
flags=0x02  sub=0x22  uint32=1   -- level active: 1
flags=0x82  sub=0x50  uint32=1   -- PUSH active: 1
flags=0x02  sub=0x22  uint32=1   -- (repeated)
```

**Cue Release** (cue becomes inactive):
```
flags=0x02  sub=0x22  uint32=0   -- level active: 0
flags=0x82  sub=0x50  uint32=0   -- PUSH active: 0
flags=0x81  sub=0x2f  uint32=N   -- cue step index (0=first, 1=second, 2=third)
flags=0x81  sub=0x24  uint32=N   -- absolute cue counter incremented
flags=0x02  sub=0x22  uint32=0   -- (repeated)
```

**sub=0x2f cue step index values:**

| value | meaning |
|-------|---------|
| 0x00  | first cue step |
| 0x01  | second cue step (NEXT CUE pressed once) |
| 0x02  | third cue step |
| 0xff  | special: list exhausted or wrapped |

**Flutter implementation:**

```dart
// Build a 24-byte fader level packet
Uint8List makeFaderLevel(int pbIndex, double level) {
  final buf = Uint8List(24);
  buf[0] = 0x29;
  buf[1] = 0x03;          // REQ flag
  // buf[2] sub-type: leave 0x00 or copy last seen value from LPU
  buf[4] = pbIndex;       // 0 = PB1, 7 = PB8
  buf[10] = 0xff;
  buf[11] = 0xff;
  buf[12] = 0x04;         // constant
  // buf[14:16] sequence counter -- increment each send
  ByteData.view(buf.buffer).setFloat32(20, level, Endian.little);
  return buf;
}
```

---

### 5. name packet -- op 0x1f (client -> device)

Sends a **fixture/scene name** as a null-terminated CSV string.

```
Offset  Len  Description
  0      1   op = 0x1f
  1      1   bank byte
  2      1   sub-type (0x08 for fixture definition, 0x0b for other)
  3      1   Reserved: 0x00
 10      2   Broadcast mask (0xFF 0xFF query, 0x00 0x00 push)
 12      2   String length (uint16 LE, includes null terminator)
 14      2   Packet counter
 16      4   Reserved: 0x00 x4
 20      n   Null-terminated CSV string
```

**CSV string format** (observed for GLOBAL name, bank=0x00):
```
"manufacturer","model","","profileID"
```
Example:
```
"FalconEyes","Desal-8 Series","","0180131204050608"
```

Fields:
1. Manufacturer name
2. Fixture model name
3. Mode / type (empty string if not used)
4. Profile ID (hex string encoding DMX channel profile -- see Fixture personality format below)

This is how the app writes fixture library entries to the LPU.

PUSH version uses bank 0x80 (GLOBAL PUSH) and sends the same string -- confirms
this is a write to LPU flash.

---

### 6. string_list packet -- op 0x2b (client -> device)

Sends a list of cue step names or other string data.

```
Offset  Len  Description
  0      1   op = 0x2b
  1      1   bank byte (cuelist index)
  2      1   sub-type
  4      2   sub-index (uint16 LE, which list within the bank)
 10      2   Broadcast mask
 12      2   Data length
 14      2   Packet counter
 16      4   Reserved
 20      n   Null-terminated CSV / list data
```

Large variant (op 0x46) seen at 820 bytes -- see bulk dump below.

---

### 7. config_obj packet -- op 0x2c (client -> device)

Sends configuration for a cuelist or device object.

```
Offset  Len  Description
  0      1   op = 0x2c
  1      1   bank byte (cuelist index)
  2      1   config type/version (0x32=standard, 0x34/0x35=alt, 0x3b/0x3c=extended)
  3      1   Reserved
  4      2   sub-index (uint16 LE -- selects which config record within bank)
  6      4   Reserved
 10      2   Broadcast mask
 12      2   Data length in bytes that follow (uint16 LE)
 14      2   Packet counter
 16      n   Config data (length varies: 4, 8, or 10 bytes)
```

Sub-index byte[4] distinguishes multiple config objects in one bank:
- `0x00` -- primary/default config
- `0x01` -- secondary (e.g. trigger config)
- `0x02` -- tertiary
- `0x04` -- quaternary (used by PUSH_MEDIA)

**Observed variants**:

| Cmd | Bank | Sub-idx | Data len | Notes |
|---|---|---|---|---|
| 0x012c | CUE[0] | 0 | 8 | Primary cuelist config |
| 0x022c | CUE[1] | 0 | 8 | Primary cuelist config |
| 0x052c | CUE[4] | 0 | 12 | Extended cuelist config |
| 0x812c | PUSH CUE[0] | 0 | 8 | Write cuelist config |
| 0x822c | PUSH CUE[1] | 0 | 8 | Write cuelist config |
| 0x832c | PUSH CUE[2] | 0 | 8 | Write cuelist config |
| 0x852c | PUSH CUE[4] | 0 | 12 | Write extended config |
| 0x862c | PUSH CUE[5] | 2 | 12 | Write sub-object 2 |
| 0x872c | PUSH CUE[6] | 1 | 8 | Write sub-object 1 |
| 0x882c | PUSH MEDIA | 4 | 14 | Write media config sub-object 4 |

---

### 8. float_param packet -- op 0x2d (client -> device)

Sets a named float parameter by index within an object.

```
Offset  Len  Description
  0      1   op = 0x2d
  1      1   bank byte (cuelist index)
  2      1   sub-type (0x33 observed)
  3      1   Reserved
  4      2   Parameter index (uint16 LE -- which float param within this bank)
  6      4   Reserved
 10      2   Broadcast mask
 12      2   Data length = 4 (uint16 LE)
 14      2   Packet counter
 16      4   Reserved
 20      4   float32 LE -- the parameter value
```

**Observed** (CUE[2], param index 7, value 0.7606):
```
2d 03 33 00  07 00 00 00  00 00 ff ff  04 00 89 05  00 00 00 00  48 b4 42 3f
```
float32 `48 b4 42 3f` = 0.7606 -- likely fade time in seconds (sub-second fade).

PUSH version (`0x832d`): same param index and value, broadcast mask = `00 00`.

MEDIA variant (`0x882d / 0x082d`), param index 4: value bytes = `55 d8 00 00` -- this
is an internal object reference ID (uint32 = 0x0000d855 = 55381), not a float.

---

### 9. Cuelist bulk dump -- op 0x46 (device -> client)

The 820-byte packet returned for query `0x0a2b` is a **cuelist slot status array**:
16 entries x 50 bytes each, preceded by a 20-byte header.

```
Offset  Len  Description
  0      2   cmd = 0x0a2b
  2      1   sub-type = 0x46
  ...
 10      2   Broadcast mask = 0xFF 0xFF
 12      2   Data length = 0x0320 = 800 (= 16 x 50)
 14      2   Packet counter
 16      4   Reserved
 20    800   16 x 50-byte cuelist slot records
```

**Each 50-byte slot record:**

```
Offset  Len  Description
  0     24   Unknown (zeros if slot is empty)
 24      4   Slot populated sentinel: 0x55 0xd8 0x00 0x00 if populated, else zeros
 28     22   Unknown (zeros observed)
```

The sentinel `0x55 0xd8` (`0xd855` LE = 55381) marks a **populated/active cuelist slot**.
In all captures, slots 0-3 are populated (4 active cuelists); slots 4-15 are all zeros.

This packet answers "which cuelist slots have programs loaded?". The app uses this
at connect time to know which slots to query for full data.

---

### 10. Fader level / Playback Go -- op 0x00 (App->LPU / LPU->App)

**Raw 9-byte frame — does NOT use the standard VN header.**

```
Offset  Len  Description
  0      1   cmd = 0x00
  1      1   level byte: 0x00 = off (0%), 0xf0 = full (100%)
  2      7   zeros (padding)
```

**App->LPU (REQ):** sets the playback fader level. Sending a sweep of frames
with rising level bytes (0x00 -> 0xf0) is the "playback go" action. Observed
sweep values: `00 03 09 0a 11 34 ce ea ef f0`.

**LPU->App (RSP):** LPU echoes the identical 9-byte frame as confirmation.

**Playback go — Flutter implementation:**

```dart
Uint8List makeFaderGo(double level) {
  // level: 0.0 = off, 1.0 = full (maps to byte range 0x00 - 0xf0)
  final buf = Uint8List(9);
  buf[0] = 0x00;
  buf[1] = (level * 0xf0).round().clamp(0, 0xf0);
  return buf;
}

// Trigger cue go: sweep level from 0 to full over ~200 ms
Future<void> plabackGo() async {
  for (final v in [0x00, 0x03, 0x09, 0x0a, 0x11, 0x34, 0xce, 0xea, 0xef, 0xf0]) {
    sendUdp(makeFaderGo(v / 0xf0));
    await Future.delayed(const Duration(milliseconds: 20));
  }
}
```

**Note:** The secondary channel (UDP port 58065) uses the same 9-byte frame
format for state queries; those slot-ID bytes are different objects from the
playback level byte here.

### 10b. Status query / reply -- op 0x00 (ping/status, secondary channel)

9-byte query on port 58065:
```
Offset  Len  Description
  0      2   Command ID (uint16 LE)
  2      7   Reserved: 0x00 x7
```

18-byte reply:
```
Offset  Len  Description
  0      2   Command ID (echoed)
  2      6   Reserved
  8      1   Data type: 2=UINT16, 4=UINT32, 6=FLOAT32
  9      4   Value
 13      5   Reserved
```

**Known queries and responses:**

| Cmd | Type | Value | Meaning |
|---|---|---|---|
| 0x0000 | FLOAT | -0.0 | Device status / timestamp |
| 0x0300 | FLOAT | 0.0 | DMX channel mask |
| 0x0900 | UINT16 | 7425 | Firmware version (major*256 + minor) |
| 0x0a00 | UINT16 | 2 | API protocol version = 2 |
| 0x1100 | UINT32 | 4478548 | Product code |
| 0x3400 | UINT32 | 16 | Cuelist count = 16 slots |
| 0xce00 | UINT32 | 0 | Feature flag |
| 0xea00 | UINT32 | 1 | Feature flag |
| 0xef00 | UINT32 | 0 | Feature flag |
| 0xf000 | UINT32 | 1 | Feature flag |

---

## Connection lifecycle and state sync

### Program model

The LPU stores programs in **16 cuelist slots** in flash memory.  Each slot holds:
- A fixture/scene name (op 0x1f CSV string)
- A cue step list (op 0x2b string_list)
- A configuration object (op 0x2c config_obj)
- Float parameters (op 0x2d float_param) e.g. fade time
- Level state per channel (op 0x29)

Programs persist across LPU power cycles.  The LPU continues DMX output when
the app disconnects; it only needs keepalives to maintain the control session.

### Full connect + sync sequence

```
Client                                LPU-1
  |                                     |
  |-- broadcast "visual_identify" ----->|  (every 4 s)
  |<-- XML identify reply --------------|
  |                                     |
  |  [user selects device]              |
  |-- unicast "visual_identify" ------->|
  |<-- XML identify reply --------------|
  |                                     |
  |-- 0xFF keepalive loop (40 Hz) ----->|  (start immediately)
  |                                     |
  |  PHASE 1: device-level queries      |
  |-- 0x0900 (fw version) ------------>|
  |-- 0x0a00 (api version) ----------->|
  |-- 0x1100 (product code) ---------->|
  |-- 0x3400 (cuelist count) --------->|  reply: count=16
  |-- 0x0000 / 0x0300 / flags -------->|
  |<-- 18-byte replies -----------------|
  |                                     |
  |  PHASE 2: cuelist slot scan         |
  |-- 0x0a2b (bulk cuelist dump) ------>|  820-byte reply
  |<-- 820-byte cuelist status array ---|  4 slots populated
  |                                     |
  |  PHASE 3: per-slot data fetch       |
  |  (for each populated slot n=0..15)  |
  |-- 0x0n1f (name / fixture CSV) ----->|
  |-- 0x0n2b (cue step list) ---------->|
  |-- 0x0n2c (config object) ---------->|
  |-- 0x0n29 (current level) ---------->|
  |<-- replies for each ---------------|
  |                                     |
  |  [UI rebuilt from downloaded state] |
  |                                     |
  |  LIVE CONTROL                       |
  |-- 0x0329 level packet (on change) ->|  fader moved in app
  |<-- 0x8329 level push --------------|  LPU-side fader change
  |-- PUSH 0x8n2c config write -------->|  parameter changed in app
  |-- PUSH 0x8n1f fixture name write -->|  fixture renamed
  |-- PUSH 0x8n2b cue list write ------>|  cue steps edited
```

### "Load program" logic

The LPU starts empty (all slot sentinels = 0x0000, not 0xd855).  When the app
"loads a program":
1. App sends PUSH commands to write all slot data (name, cue list, config, levels)
2. LPU stores in flash -- sentinel becomes `0xd855`
3. Next connect: Phase 2 bulk dump shows the slot as populated -> Phase 3 fetches it

When the app reconnects after a disconnect (not a fresh start), the slot data is
still in flash, so Phase 3 simply downloads it back -- no "load program" step needed.
The user only needs to "load program" when starting with a fresh/empty LPU or when
changing to a different saved program file.

---

## Fixture personality format (personalities.xml)

DLED's fixture library is `dled_flutter/assets/personalities.xml` (one example
fixture in the repository; your own fuller library as `personalities.local.xml`).
The same profile encoding is used in the VN name packet `profileID` field.

### XML structure

```xml
<personalities>
  <manufacturer label="FalconEyes">
    <model label="Desal-8 Series" class="Led">0180131204050608</model>
    <model label="Other fixture" class="Yoke spot">
      <mode label="8 bit">0203090A</mode>
      <mode label="16 bit">022203230412091480</mode>
    </model>
  </manufacturer>
</personalities>
```

Each `<model>` (or `<mode>` within a model) contains a **hex string** where every
two characters = one DMX channel function code, in channel order starting from
channel 1.  A model with modes uses the `<mode label="...">` children; a model
without modes has the hex string directly as its text content.

### Channel function codes

| Hex | Function |
|-----|----------|
| 01  | Dimmer / Intensity |
| 02  | Pan |
| 03  | Tilt |
| 04  | Red |
| 05  | Green |
| 06  | Blue |
| 07  | Amber |
| 08  | UV / White2 |
| 09  | Colour wheel |
| 0A  | Colour wheel 2 / fine |
| 0B  | Gobo wheel 1 |
| 0C  | Shutter / Strobe |
| 0D  | Gobo wheel 2 |
| 0E  | Prism rotation |
| 0F  | Focus |
| 10  | Zoom |
| 11  | Iris |
| 12  | Colour temperature (white balance) |
| 13  | Prism / effect wheel |
| 14  | Motor speed / tracking |
| 21  | Pan fine (16-bit LSB of 0x02) |
| 22  | Pan coarse (alt high-byte) |
| 23  | Tilt fine (16-bit LSB of 0x03) |
| 24  | Red fine |
| 25  | Green fine |
| 26  | Blue fine |
| 80  | Generic / custom (device-specific) |

### Decoding the observed profileID

Name packet example: `"FalconEyes","Desal-8 Series","","0180131204050608"`

ProfileID `0180131204050608` decodes to:
```
Ch 1: 01  Dimmer
Ch 2: 80  Generic (custom)
Ch 3: 13  Prism/effect wheel
Ch 4: 12  Colour temperature
Ch 5: 04  Red
Ch 6: 05  Green
Ch 7: 06  Blue
Ch 8: 08  UV / White2
```

This 8-channel LED fixture is the "FalconEyes Desal-8 Series" -- confirmed by
exact match to the personalities.xml entry for that model.

### How the profileID is used

When the app programs a fixture into the LPU it sends:
```
op 0x1f (name) PUSH -> "manufacturer","model","mode","profileID"
```

The LPU uses the profileID to label each DMX channel output correctly in the
device UI.  The app builds the profileID by looking up the fixture in
personalities.xml and concatenating the channel codes for the selected mode.

---

## LPU DMX standalone behaviour

The LPU continues outputting DMX when the app disconnects.  The VN session is
a **control channel only** -- DMX output is driven by the LPU's internal engine
from its flash state, not by the active connection.  A disconnection freezes
the last sent state until the app reconnects and sends changes.

---

## Implementation notes for vn_service.dart

### Already correct
- UDP ephemeral bind, send to port 16945
- `visual_identify` broadcast every 4 s + unicast at connect
- XML identify reply parsing (`label`, `version`, `ip`, `port`)
- Keepalive `0xFF` at 40 Hz
- Level packet layout: cmd bytes, channel, counter, float32 LE
- `_lastSent` delta encoding (only send changed channels)

### Gap 1: Startup query burst (implemented)

Send these 10 queries after connecting to populate device state:

```dart
for (final cmd in const [
  0x0000, 0x0300, 0x0900, 0x0a00, 0x1100,
  0x3400, 0xce00, 0xea00, 0xef00, 0xf000,
]) {
  _sendQuery(cmd);
}
```

### Gap 2: Byte[2] of level packet (implemented)

Byte[2] = cuelist index (not a rolling counter).

```dart
int cuelistIndex = 0;  // set by caller when user selects a cuelist

void _sendLevelPacket(int channelIndex, double level) {
  ...
  pkt.setUint8(2, cuelistIndex);
  ...
}
```

### Gap 3: Cuelist bulk dump query (needed for full reconnect)

After startup queries, send `0x0a2b` to get the 820-byte slot status:

```dart
_sendQuery(0x0a2b);
```

Parse the reply: for each of 16 slots, check bytes[20 + slot*50 + 24 : +2].
If those 2 bytes == `0x55 0xd8` the slot is populated.

### Gap 4: Per-slot data fetch (needed for full reconnect)

For each populated slot index `n` (0-15):

```dart
// Slot n queries: bank = (n+1), so slot 0 = bank 0x01
_sendQuery(((n + 1) << 8) | 0x1f);  // name / fixture CSV
_sendQuery(((n + 1) << 8) | 0x2b);  // cue step list
_sendQuery(((n + 1) << 8) | 0x2c);  // config object
_sendQuery(((n + 1) << 8) | 0x29);  // current level
```

### Gap 5: Inbound level push 0x8329 (needed for live sync)

`_onPacket` currently only inspects XML.  Extend to parse inbound level pushes
so the app mirrors device-side fader changes:

```dart
if (data.length >= 24) {
  final cmd = ByteData.sublistView(data).getUint16(0, Endian.little);
  if (cmd == 0x8329) {
    final bd = ByteData.sublistView(data);
    final ch = bd.getUint16(12, Endian.little);
    final level = bd.getFloat32(20, Endian.little);
    _onLevelPush?.call(ch, level);
    return;
  }
}
```

### Gap 6: Program write (PUSH commands, for "load program")

To write a program into a cuelist slot `n` on the LPU:

1. Write fixture name:
   ```dart
   // GLOBAL name (device-wide fixture definition):
   _sendPushString(0x801f, '"Manufacturer","Model","","profileID"\x00');
   ```

2. Write cue step list:
   ```dart
   _sendPushString(((0x80 + n + 1) << 8) | 0x2b, cueListCsv);
   ```

3. Write config object:
   ```dart
   _sendPushBytes(((0x80 + n + 1) << 8) | 0x2c, configBytes);
   ```

4. Write level for each channel:
   ```dart
   // Use PUSH level packet: bank byte = 0x80 | (n+1)
   _sendLevelPacketPush(n, channelIndex, level);
   ```

---

## 11. Show download -- op 0x46 (LPU -> client, 820-byte pages)

> Note: section 9 documents a different use of op=0x46 (cuelist bulk dump). This section
> documents the show-page download flow used by the reference app on startup/sync.

### Request packet (client -> LPU, 20 bytes)

The client sends sequential 20-byte UDP packets to trigger page delivery:

| Offset | Size | Value | Meaning |
|---|---|---|---|
| 0 | 1 | 0x2b | VN op |
| 1 | 1 | **0x1d** | request marker (NOT 0x0a -- that is the *response* byte[1]) |
| 2 | 1 | 0x46 | Command = show download |
| 3 | 1 | 0x00 | Reserved |
| 4-5 | 2 | 0x0000 | Reserved (zeros in a download request) |
| 6-7 | 2 | LE uint16 | `page_in_pb` -- page index within the current playback |
| 8-9 | 2 | LE uint16 | `block` -- block (bank) index 0..3 within the page |
| 10-11 | 2 | 0xffff | REQ marker |
| 12-15 | 4 | LE uint32 | Flash address (per-show region base, see below) |
| 16-19 | 4 | 0x00000000 | Reserved |

> **CORRECTION (2026-10):** earlier revisions of this table were wrong on three
> points, now confirmed from an app->LPU request-direction capture
> (`analysis/scripts/decode_download_request.py`, M400 run of 180 requests):
> request **byte[1] = 0x1d** (0x0a is the *response* byte[1]); bytes 6-7 carry
> `page_in_pb` and bytes 8-9 carry `block` (they are NOT zero); and the flash
> address starts at a **per-show region base**, never 0x00000000.

#### Flash address model (CONFIRMED)

The flash address at bytes 12-15 is **not** a blind `+0x10000` climb from zero.
The LPU flash is organised in **0x80000-byte per-page regions**, and the base
region is **per show** (it moves with whichever show is loaded):

```
region(linpage) = base_region + linpage * 0x80000
```

Within each 0x80000 region there are 8 sub-slots of 0x10000. The **first four**
(region+0x00000 / +0x10000 / +0x20000 / +0x30000) are fire-and-forget metadata
queries (sub bytes 0x05 / 0x27 / 0x29 / 0x2b, NO reply expected). The **last
four** are the cmd-0x46 download blocks (820-byte replies):

| Sub-slot | Flash offset in region | Role |
|---|---|---|
| 0 | region + 0x00000 | metadata query, sub 0x05 (no reply) |
| 1 | region + 0x10000 | metadata query, sub 0x27 (no reply) |
| 2 | region + 0x20000 | metadata query, sub 0x29 (no reply) |
| 3 | region + 0x30000 | metadata query, sub 0x2b (no reply) |
| 4 | region + 0x40000 | download block 0 (cmd 0x46) |
| 5 | region + 0x50000 | download block 1 (cmd 0x46) |
| 6 | region + 0x60000 | download block 2 (cmd 0x46) |
| 7 | region + 0x70000 | download block 3 (cmd 0x46) |

So **block n of a page is at `region + 0x40000 + n*0x10000`**, and the page
stride (block0 -> next page block0) is **0x80000, NOT 0x40000**. Confirmed
request addresses: within a page the download blocks step `+0x10000`
(block->block); from block3 to the next page's block0 the step is `+0x50000`
(0x80000 region stride minus the 0x30000 offset back into the download half).

**Per-show bases observed:**

| Show | region base | block0 (region+0x40000) |
|---|---|---|
| primary "download current show" capture | 0x04480000 | 0x044c0000 |
| `M400&12X12 - RGB_dim_shut` capture | 0x02160000 | 0x021a0000 |

**Do NOT climb open-ended past the valid regions.** There is no total-page-count
field, but the reference app issues a **bounded, address-correct** set of requests and
never reads past the show's valid flash. Walking the address up indefinitely
(waiting for "the LPU stops responding") reads unmapped flash and **wedges the
LPU firmware** (see section 13). The debug tool now walks a fixed linear page
plan with a hard cap instead.

### Response packet (LPU -> client, 820 bytes)

| Offset | Size | Value | Meaning |
|---|---|---|---|
| 0 | 1 | 0x2b | VN op |
| 1 | 1 | 0x0a | Bank |
| 2 | 1 | 0x46 | Command = show download |
| 3 | 1 | 0x00 | Reserved |
| 4-5 | 2 | LE uint16 | `pb_idx` -- playback index |
| 6-7 | 2 | LE uint16 | `page_idx` -- cue index within playback |
| 8-9 | 2 | 0x0000 | Reserved |
| 10-11 | 2 | 0xffff | Constant marker |
| 12-15 | 4 | LE uint32 | Flash address = **request flash + 0x320** (NOT a verbatim echo) |
| 16-19 | 4 | 0x00000000 | Reserved |
| 20-819 | 800 | raw bytes | Show page payload (one block / bank) |

> **Response byte[1] = 0x0a** (the request's byte[1] is 0x1d).
> **Response flash = request flash + 0x320.** The LPU does not echo the requested
> address verbatim -- it returns `req_addr + 0x320`. The debug tool matches a
> response to its request by computing `want_echo = (req_addr + 0x320) & 0xFFFFFFFF`.
> Within a page the LPU usually returns a non-zero payload only for block 0
> (blocks 1-3 commonly come back all-zero), so "stop at the first all-zero
> response" is **not** a valid terminator -- the bounded page plan is.


### .show XML mapping

Each page is the **four consecutive responses** at flash addresses `base + 0`,
`+0x10000`, `+0x20000`, `+0x30000`. Those four responses are the cue's **four
`<block>` elements** (the four banks of 16 fixtures each):

- `pb_idx` -> `<playbacks>` -> `<playback>` at that index
- `page_idx` -> `<cues>` -> `<cue>` at that index
- The four addr-ordered payloads (bytes 20-819 of each) -> base64-encoded onto
  `block[0]`, `block[1]`, `block[2]`, `block[3]` in flash-address order
  (block 0 = fixtures 0-15, block 1 = 16-31, block 2 = 32-47, block 3 = 48-63)
- A bank with no patched fixtures comes back genuinely all-zero and is written
  as an empty `<block />`

This allows full `.show` reconstruction from a live LPU download without the original file.
Verified against `show_open_and_download/download_show_M400&12X12 - RGB_dim_shut.pcapng`
(LPU -> app): 45 pages x 4 responses, stride +0x10000 within every page, **54/54
non-zero blocks match the `.show` byte-for-byte, 0 mismatches**. 9 pages carry
two or more populated blocks (e.g. pb=28 page=0 with block[0] AND block[2] both
non-zero) -- which only the bank model can produce.

### The 4 responses per page are the 4 blocks (banks)

Each unique (pb_idx, page_idx) page produces **four** 820-byte responses, one per
block (bank) of the cue, at flash addresses `base + 0`, `+0x10000`, `+0x20000`,
`+0x30000`. They are NOT "1 real page + 3 zero retransmits" -- that earlier theory
was disproven by `download_show_M400&12X12 - RGB_dim_shut.pcapng`, where 9 pages
carry two or more populated blocks (block[0] AND block[2] both non-zero). A bank
with no patched fixtures comes back genuinely all-zero (an empty higher bank),
which is what made the common "only block 0 has data" case look like retransmits.

The app keeps all four responses in flash-address order and maps them onto the
cue's four `<block>` elements (block 0 = fixtures 0-15, block 1 = 16-31,
block 2 = 32-47, block 3 = 48-63):

```python
# pages[(pb_idx, page_idx)] = list of 4 responses
pages.setdefault(key, []).append(data)
...
responses.sort(key=lambda r: r.flash_addr)   # block[0..3] order
```

### pb_idx = 8 is a real playback

Index 8 is a valid playback slot (not a sentinel). Earlier scripts incorrectly
skipped pb_idx == 8. All pb_idx values from the LPU response are valid and must
be included in the reconstructed XML.

---

## 12. Show upload -- op 0x2b bank 0x0a sub 0x47 (client -> LPU, 820-byte pages)

The download (section 11, `sub=0x46`) has a matching **write** counterpart used
when the app OPENS a `.show` file: it pushes every page of that file INTO the
LPU. The sub-type byte is the read/write discriminator:

| sub (byte[2]) | Direction | Meaning |
|---|---|---|
| 0x46 | LPU -> client | download page (read from flash) |
| 0x47 | client -> LPU | upload page (write to flash) |

### Upload packet (client -> LPU, 820 bytes)

| Offset | Size | Value | Meaning |
|---|---|---|---|
| 0 | 1 | 0x2b | VN op |
| 1 | 1 | 0x0a | bank |
| 2 | 1 | 0x47 | sub = show upload (write page) |
| 3 | 1 | 0x00 | reserved |
| 4-5 | 2 | LE uint16 | `pb_idx` -- playback index |
| 6-7 | 2 | LE uint16 | `page_idx` -- cue index within playback |
| 8-9 | 2 | 0x0000 | reserved |
| 10-11 | 2 | 0xffff | REQ marker |
| 12-13 | 2 | 0x0320 | data length = 800 (standard VN header field) |
| 14-15 | 2 | LE uint16 | packet counter (increments per frame) |
| 16-19 | 4 | 0x00000000 | reserved |
| 20-819 | 800 | raw bytes | show page payload (one block / bank) |

> Unlike the download page, the upload page does NOT carry a flash address.
> bytes[12:16] are the standard VN `data_length` (always 0x0320 = 800) and
> `packet counter`. The LPU allocates the flash slot itself; the app only
> identifies the target by `pb_idx` + `page_idx` and streams the four blocks
> in order.

### Four frames per page = the four blocks

Within one `(pb_idx, page_idx)` the app sends **four consecutive** 820-byte
upload frames (block 0..3, fixtures 0-15 / 16-31 / 32-47 / 48-63). The block is
positional -- identified by transmit order, not a header field -- and `page_idx`
increments only after all four blocks of the current page are sent. This is the
exact mirror of the download's four-block page.

### Proof (`show_open_and_download/`, roles app=192.168.1.171, LPU=192.168.1.12)

| Capture | App -> LPU 820-byte pages | LPU -> App 820-byte pages | Verdict |
|---|---|---|---|
| `open_show__M400&12X12 - RGB_dim_shut.pcapng` | **180** (`sub=0x47`, 45 pages x 4 blocks) | 180 (`sub=0x47` echo) + 191 (`sub=0x46`) | app UPLOADS the opened file |
| `download_show_M400&12X12 - RGB_dim_shut.pcapng` | **0** | 180 (`sub=0x46`, 45 pages x 4 blocks) | app only RECEIVES (download) |

Direction was established by source IP (the only reliable discriminator): in the
OPEN capture the app (192.168.1.171) is the SOURCE of all 180 upload frames; in
the DOWNLOAD capture the app sends zero bulk frames and the LPU (192.168.1.12) is
the source of all 180 pages. The LPU echoes each uploaded `sub=0x47` page back
with the same sub byte, which is why the OPEN capture also shows 180 `sub=0x47`
frames in the LPU -> app direction.

### Empty-cue skipping -- the uploader's page-selection rule

The upload is NOT a fixed/maximal page dump. The app transmits a page only for a
cue that has content; a **fully-empty cue (all 4 banks all-zero) is NOT sent**.
Within an emitted page, however, every one of the 4 blocks IS still transmitted
(empty higher banks are zero-filled).

The app enforces hard limits of **48 cues per playback**, **64 playbacks**, and
**64 fixtures**, so the theoretical maximum is `64 x 48 = 3072` pages. If the app
sent a fixed/maximal set it would always send the same page count, but different
shows produce different counts (28 / 45 / 54 -- far below 3072), so only pages
with content are emitted.

`analysis/scripts/confirm_no_empty_cue.py` groups the 180 OPEN-capture `sub=0x47`
frames by `(pb_idx, page_idx)` and counts the all-zero blocks per page:

| Blocks all-zero in page | Page count |
|---|---|
| 2 empty | 9 |
| 3 empty | 36 |
| 4 empty (skipped cue) | **0** |

- **No page is 4/4 empty.** All 45 transmitted pages carry >= 1 populated block
  (36 pages with 1 populated bank, 9 pages with 2).
- `54 populated + 126 zero-filled = 180` frames = 45 pages x 4 blocks: the app
  skips empty *cues* but never skips empty *banks within* a transmitted cue.

**Uploader rule** -- the complete, implementation-ready form (concrete app
bounds pb 0..63 / cue 0..47, the empty-cue skip, the 4-block zero-fill loop,
and the exact VN frame fields):

```
for each playback pb (0..63):
    for each cue page (0..47):
        if all 4 blocks of this cue are empty:
            skip the cue entirely        # part 2 - do not transmit
        else:
            for block b in 0..3:          # part 1 - send all 4, in order
                payload = block[b] or 800 zero bytes   # zero-fill empty banks
                send frame op=0x2b bank=0x0a sub=0x47,
                     pb_idx=pb, page_idx=cue, data_len=0x0320,
                     counter++, payload
```

- **Bounds** `pb 0..63` / `cue 0..47` are the app's hard UI limits
  (64 playbacks x 48 cues = 3072 theoretical pages).
- **Part 2 (skip)**: a cue whose 4 banks are all-zero is never transmitted.
- **Part 1 (emit)**: every other cue sends all 4 blocks in transmit order,
  zero-filling any empty bank with an 800-byte all-zero payload; `page_idx`
  advances only after the 4th block of the page is sent.
- **Frame fields**: `op=0x2b bank=0x0a sub=0x47`, `pb_idx`=bytes[4:6],
  `page_idx`=bytes[6:8], `data_len`=bytes[12:14]=0x0320 (800),
  `counter`=bytes[14:16] (increments per frame).

See `analysis/SHOW_DOWNLOAD_FLOW.md` section 8c and
`analysis/scripts/confirm_no_empty_cue.py`.

---

## 13. Session close / teardown -- there is NO disconnect command

### The symptom

A debug tool (`analysis/scripts/debug_lpu_discover_v2.py`) that opened a
session, downloaded the show, then **closed its UDP socket abruptly** left the
LPU-1 (192.168.1.12) **completely unreachable** -- it failed both ping and a
fresh connection from the reference app. Only a physical power cycle recovered
it. The working hypothesis was that the reference app sends some "disconnect" /
"session close" command before it tears down, and the tool was missing it.

### What the capture actually shows

The capture `samples/selecting_and_deselcting_lpu_in_device_list.pcapng`
contains several complete select -> download -> deselect cycles (selecting the
device downloads the show; deselecting removes it from the app UI). Two analyses
of the APP->LPU direction only (the app's own output) settle the question:

1. **Histogram of every distinct APP->LPU command**:
   the only things the app ever sends are
   - the `0xFF` keepalive (40 Hz),
   - the 10-command 9-byte startup query burst (twice per select),
   - a 4-command 20-byte status-poll loop (cmds `0x05 / 0x15 / 0x17 / 0x30`,
     magic `0x29`, ~100x each).

   There is **no rare, once-per-deselect command** -- nothing that looks like a
   disconnect. Deselect is a pure UI action.

2. **Gap finder on the APP->LPU stream**:
   over 1784 app packets spanning 11.657 s, there are **0 gaps > 200 ms**. The
   app's keepalive + poll loop runs **continuously, right up to the final
   packet**. The app NEVER goes silent -- not even across deselects.

Conclusions:
- There is **no disconnect / session-close packet**. The earlier full-stream gap
  finder was misled because the LPU keeps broadcasting its XML identify reply
  every ~1 s, which filled the apparent silence.
- Deselecting the device does **not** close the VN session; the app maintains the
  session continuously in the background.
- The app's steady-state is **always** keepalive + the `0x29` status-poll loop,
  and the app is **never left sitting in a paged-transfer (`0x46`/`0x47`)
  state**.

### The status-poll steady-state (magic 0x29)

The idle loop the app cycles forever (20-byte extended frames, `extra`=`0x0000`
at bytes[6:7], `seq` incrementing, session bytes rotating as new sub-sessions
open):

```
291d05003d...        cmd 0x05
291d15003c...e207    cmd 0x15
291d17003c...e107    cmd 0x17
291d30003d...e307    cmd 0x30
```

(hex abbreviated; session bytes seen rotating `3c00` -> `3d00`, seq `e107..e607`).

### Root cause and the fix (CONFIRMED)

The LPU wedge is **not** a missing disconnect command, and it is **not** the
abrupt socket close. The proven cause is the **out-of-range flash-address
climb** performed by the old show download.

The old `download_show` walked the flash address **open-ended** -- it kept
issuing `0x46` page requests with an ever-increasing flash address (seq-driven,
up to 512 pages) and waited for "the LPU stops responding" as its stop signal.
That walk climbs **past the show's valid flash regions** into unmapped flash.
Reading unmapped flash **wedges the LPU firmware**: the device then fails ping
and disappears from the reference app until it is physically power-cycled.

The reference app never does this. It issues a **bounded, address-correct** set of
page requests and never reads past the show's valid regions (there is no
total-page-count field in the protocol, but the app does not need one -- it
stops at the show's known extent, not at a timeout).

The cure is to mirror that: `download_show` now walks a **fixed linear page
plan** built from the per-show region base (`region = base + linpage*0x80000`,
see section 11), with a **hard cap of 128 pages** (`SHOW_MAX_PAGES_HARD_CAP`).
It never climbs open-ended and never reads unmapped flash, so the firmware does
not wedge.

> **Confirmed by isolation.** Disabling only the page-download part of the tool
> keeps the LPU alive across repeated script runs and lets it reconnect to the
> reference app; re-enabling the *old* open-ended download reproduces the wedge. The
> fault is the download's address walk, nothing else.

> **Two RED HERRINGS, eliminated.** (1) The *abrupt-socket-close / missing-
> disconnect-command* theory -- there is no disconnect packet (see above), and a
> graceful wind-down did not cure the wedge. (2) The *120 s keepalive hold*
> theory -- holding the session alive for ~2 minutes did **not** keep the device
> reachable either. Neither touched the real cause, which is the flash-address
> climb. Both are kept only as history here so they are not re-attempted.

This is implemented as `download_show()` (the bounded page plan) plus
`graceful_session_close()` in `analysis/scripts/debug_lpu_discover_v2.py`, the
latter called from `main()`'s `finally` block immediately before
`sock.close()`. `graceful_session_close()` still drains pending inbound packets
and runs a short status-poll wind-down, then dwells on the keepalive for its
`keepalive_hold` parameter -- now default **0.6 s**, a brief courtesy dwell
(tunable via `--keepalive-hold SECONDS`, `0` = close immediately). The long hold
was a red herring; the bounded download is the real fix.


**Flutter implication:** `vn_service.dart` must download the show with a
**bounded, address-correct page plan** (fixed linear walk over the show's valid
flash regions, hard-capped) and must **never** climb the flash address
open-ended waiting for the LPU to go silent. An open-ended walk reads unmapped
flash and wedges the device. Keep the keepalive running for the lifetime of the
connection; on intentional disconnect simply let the keepalive lapse. There is
no disconnect packet to send, and no long keepalive hold is required.
