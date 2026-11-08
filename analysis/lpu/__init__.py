"""Shared library for the LPU-1 tools.

protocol     -- VN UDP client (typed property frames, lock-step writes)
personalities -- personalities.xml lookup and DMX function names
showfile     -- .show XML read/write and 50-byte fixture record decoding
report       -- human-readable text report of a show
lpu_io       -- download a show from an LPU / upload a show to an LPU
simulator    -- stateful fake LPU for testing without hardware

Protocol reference: analysis/FINDINGS.md section 20, dled_flutter/VN_PROTOCOL.md.
"""
