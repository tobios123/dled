#!/usr/bin/env python3
# confirm_upload_pages.py
#
# A capture proved the decisive fact: in OPEN SHOW the APP sends
# 180 frames of 820 bytes with op=0x2b bank=0x0a (src == app IP). That is the
# APP writing full show PAGES into the LPU -- the UPLOAD. The 2b 0a 46 check
# found 0 app pages, so byte[2] of these upload frames is NOT 0x46. This script
# proves the exact upload-page signature and header, and counts the 820-byte
# pages in BOTH directions for BOTH captures so the upload-vs-download logic is
# tied to the proven roles (app=192.168.1.171, LPU=192.168.1.12).
#
# Evidence only. No guessing.

import struct
import os
from collections import Counter

BASE = r"samples/show_open_and_download"
OPEN_PCAP = os.path.join(BASE, "open_show__M400&12X12 - RGB_dim_shut.pcapng")
DOWN_PCAP = os.path.join(BASE, "download_show_M400&12X12 - RGB_dim_shut.pcapng")
VN_PORT = 16945
APP_IP = "192.168.1.171"
LPU_IP = "192.168.1.12"


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


def analyze(path, label):
    print("=" * 96)
    print(label)
    print(f"  file: {os.path.basename(path)}")
    print("=" * 96)

    # 820-byte frames split by direction and by byte[2] sub value
    pages_app2lpu = Counter()   # byte[2] -> count (upload candidates)
    pages_lpu2app = Counter()   # byte[2] -> count (download pages)
    app_upload_headers = []     # first few app->LPU 820-byte headers
    app_upload_addr = []        # flash_addr of each app->LPU 820 page
    app_upload_pbpage = Counter()  # (pb_idx, page_idx) of app uploads

    for linktype, raw in iter_pcapng_packets(path):
        u = extract_udp(linktype, raw)
        if u is None:
            continue
        src, sport, dst, dport, data = u
        if sport != VN_PORT and dport != VN_PORT:
            continue
        if len(data) < 820:
            continue
        if not (data[0] == 0x2b and data[1] == 0x0a):
            continue
        sub = data[2]
        if src == APP_IP:
            pages_app2lpu[sub] += 1
            pb = struct.unpack_from("<H", data, 4)[0]
            pg = struct.unpack_from("<H", data, 6)[0]
            addr = struct.unpack_from("<I", data, 12)[0]
            app_upload_pbpage[(pb, pg)] += 1
            app_upload_addr.append(addr)
            if len(app_upload_headers) < 6:
                app_upload_headers.append(data[:20].hex())
        elif src == LPU_IP:
            pages_lpu2app[sub] += 1

    print("820-byte 2b 0a frames by direction and byte[2] sub-value:")
    print(f"  APP  -> LPU (upload):   {dict(pages_app2lpu)}  total={sum(pages_app2lpu.values())}")
    print(f"  LPU  -> APP (download): {dict(pages_lpu2app)}  total={sum(pages_lpu2app.values())}")
    print()

    if app_upload_headers:
        print("APP -> LPU upload page headers (first 6, bytes 0-19):")
        for h in app_upload_headers:
            # decode fields
            b = bytes.fromhex(h)
            op, bank, sub = b[0], b[1], b[2]
            pb = struct.unpack_from("<H", b, 4)[0]
            pg = struct.unpack_from("<H", b, 6)[0]
            mk = b[10:12].hex()
            addr = struct.unpack_from("<I", b, 12)[0]
            print(f"    {h}")
            print(f"      op=0x{op:02x} bank=0x{bank:02x} sub=0x{sub:02x} pb={pb} page={pg} marker={mk} flash_addr=0x{addr:08x}")
        print()
        print(f"APP -> LPU distinct (pb,page) uploaded: {len(app_upload_pbpage)}")
        print(f"  flash_addr range: 0x{min(app_upload_addr):08x} .. 0x{max(app_upload_addr):08x}")
        # addr stride check
        uniq = sorted(set(app_upload_addr))
        if len(uniq) > 1:
            strides = Counter(uniq[i + 1] - uniq[i] for i in range(len(uniq) - 1))
            print(f"  distinct flash_addr count: {len(uniq)}  stride histogram: {dict(strides)}")
    else:
        print("APP -> LPU: no 820-byte upload pages (app sent only queries/keepalives)")
    print()


def main():
    analyze(OPEN_PCAP, "OPEN SHOW -- is the app UPLOADING 820-byte pages to the LPU?")
    analyze(DOWN_PCAP, "DOWNLOAD SHOW -- is the app UPLOADING, or only receiving?")


if __name__ == "__main__":
    main()
