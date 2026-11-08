---
name: vn-capture-decode
description: Decode LPU-1 network traffic (the VN protocol on UDP 16945) from a pcap / pcapng capture or live from the network into readable lines - which object, property, index, value, and what the app or device did (GO, fader, programmer write, cue block, show upload / download). Use this whenever the user gives a .pcap / .pcapng of LPU traffic, wants to see what an app sends to the LPU or the LPD-1, asks what a VN frame or opcode means, wants to watch the traffic live while pressing buttons, or wants to check an emulator / the LPD-1 against a capture - even if they only say "what is the app sending" or "decode this capture".
---

# Decode VN traffic (LPU-1, UDP 16945)

The frame format is known and decoded by tools in this repository: use them
instead of guessing offsets.

## The frame (for reading raw bytes)

Typed property frame: a 20-byte header + body, all numbers little-endian
(`dled_flutter/lib/core/frame.dart`, `analysis/lpu/protocol.py`):

| Bytes | Field |
|---|---|
| 0 | object (0x02 device, 0x1f fixture, 0x28 action, 0x29 playback, 0x2b cue, 0x2c global, 0x2d programmer ...) |
| 1 | value type (0x00 string, 0x01 u32, 0x02 bool, 0x03 float, 0x05 blob, 0x0a page, 0x1d no body); `| 0x80` = a notification |
| 2 | property |
| 4-5, 6-7, 8-9 | index 1 (fixture / playback), index 2 (cue), index 3 (block) |
| 10-11 | mask (ff ff; 00 00 in notifications) |
| 12-13 | body length |
| 14-15 | sequence |

A write's property is the read's + 1, and the device echoes every write
byte for byte. Short device properties are 9-byte requests
`[00, prop, 0 x 6, length]`. Discovery is a broadcast of the text
`visual_identify` (the protocol's own word), answered with a small XML.
Meanings of objects and properties: `dled_flutter/VN_PROTOCOL.md` and
`analysis/FINDINGS.md` section 20.

## 1. A saved capture

```bash
python analysis/scripts/live_vn_monitor.py --pcap CAPTURE.pcapng --lpu LPU-IP
```

prints one line per frame with the direction, the decoded object /
property / indices and the value (`--all` keeps the heartbeats, `--log FILE`
also writes the lines). It needs `tshark` (Wireshark). Without it,
`analysis/scripts/parse_pcapng.py` reads pcapng in plain Python, and the
narrower decoders `decode_cue_pcap.py`, `decode_fader_pcap.py`,
`decode_fx_pcap.py`, `decode_sync_pcap.py` and `parse_lpu_pcap.py` pick out
one kind of traffic.

## 2. Live

```bash
python analysis/scripts/live_vn_monitor.py --list
python analysis/scripts/live_vn_monitor.py --iface NAME --lpu LPU-IP
```

Ask the user what they will press, then read the lines that appear for each
action. A capture only sees traffic that passes this PC: run the app on the
same PC, or use a switch with port mirroring.

## 3. Check an emulator or the LPD-1 against a capture

```bash
python analysis/scripts/emulator_conformance.py CAPTURE.pcapng --app-ip APP-IP
python analysis/scripts/emulator_conformance.py CAPTURE.pcapng --app-ip APP-IP --target HOST:PORT
```

replays the app's requests and compares every answer with the real
device's (`--target` tests another server, e.g. the LPD-1's PC build).

## Reporting

Summarise: the time span and the devices involved; per user action the
frames it caused (object, property, indices, value); anything not in
`VN_PROTOCOL.md` (new property, odd length) as an open point. Captures
belong to the user's own network: do not commit them (`*.pcapng` is
ignored).
