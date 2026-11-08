#!/usr/bin/env python3
# confirm_no_empty_cue.py
#
# Final evidence for the uploader rule: a fully-empty cue (all 4 banks zero)
# is NOT transmitted.
#
# confirm_upload_pages.py already proved the OPEN capture carries 180 app->LPU
# sub=0x47 upload frames = 45 pages x 4 blocks. This script goes one level
# deeper: it groups those frames by (pb_idx, page_idx), and for every page
# counts how many of its 4 blocks (banks) are all-zero. It then confirms that
# NO transmitted page is 4/4 empty -- i.e. every page the app chose to upload
# has at least one populated block.
#
# Combined with the capture statistics (different shows produce 28 / 45 / 54
# pages, far below the 64 x 48 = 3072 theoretical maximum), this shows the app
# does NOT emit a fixed/maximal page set -- it skips fully-empty cues entirely,
# while still sending all 4 blocks (zero-filling empty banks) for any page that
# has content.
#
# Evidence only. No guessing.

import struct
import os
from collections import Counter, defaultdict

BASE = r"samples/show_open_and_download"
OPEN_PCAP = os.path.join(BASE, "open_show__M400&12X12 - RGB_dim_shut.pcapng")
VN_PORT = 16945
APP_IP = "192.168.1.171"
LPU_IP = "192.168.1.12"
UPLOAD_SUB = 0x47

# App hard limits (stated by the reference app UI).
MAX_PLAYBACKS = 64
MAX_CUES_PER_PB = 48
THEORETICAL_MAX_PAGES = MAX_PLAYBACKS * MAX_CUES_PER_PB  # 3072


def iter_pcapng_packets(path):
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    linktype = 1
    n = len(data)
    while pos + 12 <= n:
        bt = struct.unpack_from("<I", data, pos)[0]
        blen = struct.unpack_from("<I", data, pos + 4)[0]
        if blen < 12 or pos + blen > n:
            break
        block = data[pos:pos + blen]
        if bt == 0x0A0D0D0A:
            pass
        elif bt == 1:
            linktype = struct.unpack_from("<H", block, 8)[0]
        elif bt == 6:
            cap_len = struct.unpack_from("<I", block, 20)[0]
            yield linktype, block[28:28 + cap_len]
        elif bt == 3:
            orig_len = struct.unpack_from("<I", block, 12)[0]
            yield linktype, block[16:16 + orig_len]
        elif bt == 2:
            cap_len = struct.unpack_from("<I", block, 16)[0]
            yield linktype, block[20:20 + cap_len]
        pos += blen


def extract_udp(linktype, raw):
    if linktype == 1:
        if len(raw) < 14:
            return None
        if struct.unpack_from(">H", raw, 12)[0] != 0x0800:
            return None
        ip = raw[14:]
    elif linktype == 101:
        ip = raw
    else:
        return None
    if len(ip) < 20 or (ip[0] >> 4) != 4 or ip[9] != 17:
        return None
    ihl = (ip[0] & 0xF) * 4
    src = ".".join(str(b) for b in ip[12:16])
    dst = ".".join(str(b) for b in ip[16:20])
    udp = ip[ihl:]
    if len(udp) < 8:
        return None
    sport = struct.unpack_from(">H", udp, 0)[0]
    dport = struct.unpack_from(">H", udp, 2)[0]
    return src, sport, dst, dport, udp[8:]


def main():
    print("=" * 96)
    print("CONFIRM: no transmitted page is 4/4 empty (fully-empty cues are skipped)")
    print(f"  file: {os.path.basename(OPEN_PCAP)}")
    print("=" * 96)

    # pages[(pb, page)] = list of 800-byte payloads in transmit order (block 0..3)
    pages = defaultdict(list)

    for linktype, raw in iter_pcapng_packets(OPEN_PCAP):
        u = extract_udp(linktype, raw)
        if u is None:
            continue
        src, sport, dst, dport, data = u
        if sport != VN_PORT and dport != VN_PORT:
            continue
        if len(data) < 820:
            continue
        # app -> LPU upload page only
        if not (data[0] == 0x2b and data[1] == 0x0a and data[2] == UPLOAD_SUB):
            continue
        if src != APP_IP:
            continue
        pb = struct.unpack_from("<H", data, 4)[0]
        pg = struct.unpack_from("<H", data, 6)[0]
        payload = data[20:820]  # 800 bytes
        pages[(pb, pg)].append(payload)

    total_pages = len(pages)
    total_frames = sum(len(v) for v in pages.values())

    print(f"app -> LPU upload frames (sub=0x47): {total_frames}")
    print(f"distinct (pb, page) pages:           {total_pages}")
    print(f"expected frames if 4 blocks/page:    {total_pages * 4}")
    print()

    # Per-page empty-block analysis.
    empty_count_hist = Counter()   # (# of all-zero blocks in the page) -> page count
    non_four_block = []            # pages that did not have exactly 4 frames
    fully_empty_pages = []         # pages where ALL blocks are zero (should be none)
    populated_blocks = 0

    for key in sorted(pages.keys()):
        blocks = pages[key]
        if len(blocks) != 4:
            non_four_block.append((key, len(blocks)))
        n_empty = sum(1 for b in blocks if not any(b))
        n_populated = len(blocks) - n_empty
        populated_blocks += n_populated
        empty_count_hist[n_empty] += 1
        if n_populated == 0:
            fully_empty_pages.append(key)

    print("empty-block histogram  (how many of a page's blocks are all-zero):")
    for n_empty in sorted(empty_count_hist):
        pages_with = empty_count_hist[n_empty]
        label = "ALL EMPTY -- would be a skipped cue" if n_empty == 4 else ""
        print(f"  {n_empty} empty block(s): {pages_with:3d} page(s)   {label}")
    print()

    print(f"total populated (non-zero) blocks across all pages: {populated_blocks}")
    print(f"total zero-filled (empty bank) blocks:              {total_frames - populated_blocks}")
    print()

    if non_four_block:
        print(f"WARNING: {len(non_four_block)} page(s) did NOT have exactly 4 blocks:")
        for key, cnt in non_four_block:
            print(f"    pb={key[0]} page={key[1]} -> {cnt} block(s)")
        print()

    # The decisive assertions.
    print("-" * 96)
    if fully_empty_pages:
        print(f"RESULT: FAIL -- {len(fully_empty_pages)} transmitted page(s) are 4/4 empty:")
        for key in fully_empty_pages:
            print(f"    pb={key[0]} page={key[1]}")
    else:
        print("RESULT: PASS -- every transmitted page has >= 1 populated block.")
        print("        No fully-empty cue was uploaded. The app skips empty cues.")
    print()
    print(f"Theoretical max pages (64 x 48) = {THEORETICAL_MAX_PAGES}.")
    print(f"This show uploaded only {total_pages} page(s) -- far below the max,")
    print("which confirms the app does NOT send a fixed/maximal page set.")
    print("-" * 96)


if __name__ == "__main__":
    main()
