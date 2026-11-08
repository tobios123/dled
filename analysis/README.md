# analysis/: the LPU-1 protocol

Notes and tools about the LPU-1's network protocol (VN, UDP 16945) and its
`.show` file format, measured from the traffic between an app and the
device, for interoperability.

| File | What |
|---|---|
| `FINDINGS.md` | the protocol, frame by frame (section 20: the typed property frames) |
| `SHOW_DOWNLOAD_FLOW.md` | how a show is downloaded and uploaded |
| `LPU_TOOLS.md` | how to use the tools below |
| `lpu/` | Python library: protocol, `.show` files, fixture library, reports, emulator |
| `tests/` | its tests: `python -m unittest discover -s analysis/tests` |

## Tools (`scripts/`)

| Script | Purpose |
|---|---|
| `lpu_emulator.py` | a fake LPU-1 that apps and the tools can use |
| `emulator_conformance.py` | replays a capture into the emulator (or another server, e.g. the LPD-1) and checks every answer |
| `live_vn_monitor.py` | decodes VN traffic live or from a capture (needs tshark) |
| `debug_lpu_discover_v2.py` | session debug tool; `--download --dynamic` reads the show |
| `parse_pcapng.py`, `parse_lpu_pcap.py` | read pcapng captures in plain Python |
| `decode_cue_pcap.py`, `decode_fader_pcap.py`, `decode_fx_pcap.py`, `decode_sync_pcap.py` | pick one kind of traffic out of a capture |
| `decode_download_request.py`, `check_upload_retransmit.py` | show download / upload details from a capture |
| `confirm_writeback.py`, `confirm_no_empty_cue.py`, `confirm_upload_pages.py` | checks against a real device |
| `make_dart_goldens.py` | writes the reference data the Dart tests compare against |

Captures (`*.pcapng`) are not in the repository: record your own (Wireshark,
or `live_vn_monitor.py --log`). The Claude Code skill
`.claude/skills/vn-capture-decode` walks through decoding one.

Python 3.9+, standard library; the capture tools optionally use `tshark`.
