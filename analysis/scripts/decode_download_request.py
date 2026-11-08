#!/usr/bin/env python3
"""
decode_download_request.py -- extract the app->LPU show-download REQUEST frames.

Goal: confirm the exact 20-byte download request byte layout (bytes 4-7,
byte1, and the flash address @12-15) directly from a request-direction
capture, resolving the SHOW_DOWNLOAD_FLOW.md section 2 vs VN_PROTOCOL.md
section 11 discrepancy.

Uses dpkt (fallback to scapy). tshark/editcap are NOT required.
"""

import sys
import struct

VN_PORT = 16945
LPU_IP  = "192.168.1.12"   # LPU always replies from port 16945


def iter_udp_payloads(path):
    """Yield (ts, src_ip, dst_ip, sport, dport, payload) for every UDP packet."""
    try:
        import dpkt
    except ImportError:
        dpkt = None

    if dpkt is not None:
        import socket as _socket
        opener = open(path, "rb")
        with opener as f:
            # pcapng vs pcap autodetect
            magic = f.read(4)
            f.seek(0)
            if magic == b"\x0a\x0d\x0d\x0a":
                reader = dpkt.pcapng.Reader(f)
            else:
                reader = dpkt.pcap.Reader(f)
            for ts, buf in reader:
                try:
                    eth = dpkt.ethernet.Ethernet(buf)
                except Exception:
                    continue
                ip = eth.data
                if not isinstance(ip, dpkt.ip.IP):
                    continue
                udp = ip.data
                if not isinstance(udp, dpkt.udp.UDP):
                    continue
                src = _socket.inet_ntoa(ip.src)
                dst = _socket.inet_ntoa(ip.dst)
                yield (ts, src, dst, udp.sport, udp.dport, bytes(udp.data))
        return

    # scapy fallback
    from scapy.all import rdpcap, IP, UDP
    pkts = rdpcap(path)
    for p in pkts:
        if IP in p and UDP in p:
            ip = p[IP]
            udp = p[UDP]
            payload = bytes(udp.payload)
            yield (float(p.time), ip.src, ip.dst, udp.sport, udp.dport, payload)


def main():
    if len(sys.argv) < 2:
        print("usage: decode_download_request.py <capture.pcapng> [lpu_ip]")
        return
    path = sys.argv[1]
    lpu_ip = sys.argv[2] if len(sys.argv) > 2 else LPU_IP

    print(f"[INFO] Decoding {path}")
    print(f"[INFO] LPU IP = {lpu_ip} (port {VN_PORT})\n")

    total = 0
    req_046 = []   # app->LPU download requests (sub byte 0x46)
    resp_046 = []  # LPU->app download responses
    other_app = {} # histogram of app->LPU frames by (len, b0, b1, b2)

    for rec in iter_udp_payloads(path):
        ts, src, dst, sport, dport, payload = rec
        if VN_PORT not in (sport, dport):
            continue
        total += 1
        app_to_lpu = (dst == lpu_ip and dport == VN_PORT) or (src != lpu_ip and dport == VN_PORT)
        lpu_to_app = (src == lpu_ip and sport == VN_PORT)

        if len(payload) >= 3 and payload[2] == 0x46:
            if lpu_to_app:
                resp_046.append((ts, len(payload), payload[:20]))
            else:
                req_046.append((ts, src, dst, sport, dport, len(payload), payload))


        if app_to_lpu and 16 <= len(payload) <= 40:
            key = (len(payload), payload[0] if payload else -1,
                   payload[1] if len(payload) > 1 else -1,
                   payload[2] if len(payload) > 2 else -1)
            other_app[key] = other_app.get(key, 0) + 1

    print(f"[INFO] {total} UDP frames on port {VN_PORT}")
    print(f"[INFO] download REQUESTS (app->LPU, byte2=0x46): {len(req_046)}")
    print(f"[INFO] download RESPONSES (LPU->app, byte2=0x46): {len(resp_046)}\n")

    if req_046:
        print("=== app->LPU download REQUEST frames (first 12) ===")
        for i, (ts, src, dst, sport, dport, ln, payload) in enumerate(req_046[:12]):
            flash = struct.unpack_from("<I", payload, 12)[0] if ln >= 16 else -1
            print(f"  #{i:02d} {src}:{sport} -> {dst}:{dport}  len={ln}")
            print(f"      hex: {payload[:20].hex()}")
            print(f"      b0={payload[0]:02x} b1={payload[1]:02x} b2={payload[2]:02x} b3={payload[3]:02x}")
            print(f"      b4-5={payload[4:6].hex()} b6-7={payload[6:8].hex()} "
                  f"b8-9={payload[8:10].hex()} b10-11={payload[10:12].hex()}")
            print(f"      flash_addr(@12-15 LE)=0x{flash:08x}  b16-19={payload[16:20].hex()}")
        if len(req_046) > 12:
            print(f"  ... ({len(req_046) - 12} more)")
        # show flash address progression
        print("\n=== flash address progression (first 20 requests) ===")
        addrs = []
        for (ts, src, dst, sport, dport, ln, payload) in req_046:
            if ln >= 16:
                addrs.append(struct.unpack_from("<I", payload, 12)[0])
        for i, a in enumerate(addrs[:20]):
            delta = (a - addrs[i-1]) if i > 0 else 0
            print(f"  req {i:3d}: 0x{a:08x}  (delta +0x{delta:x})")
        if addrs:
            print(f"\n  first addr = 0x{addrs[0]:08x}")
            print(f"  last  addr = 0x{addrs[-1]:08x}")
            print(f"  total requests = {len(addrs)}")
    else:
        print("[WARN] No app->LPU download request frames (byte2=0x46) found.")
        print("       This capture may be response-direction only.\n")

    # ----- decode the LPU->app RESPONSE frames -----
    if resp_046:
        print("\n=== LPU->app download RESPONSE frames (first 12) ===")
        # resp_046 currently only kept payload[:20]; re-collect full payloads.
        full_resps = []
        for rec in iter_udp_payloads(path):
            ts, src, dst, sport, dport, payload = rec
            if VN_PORT not in (sport, dport):
                continue
            if len(payload) >= 3 and payload[2] == 0x46 and src == lpu_ip and sport == VN_PORT:
                full_resps.append((ts, len(payload), payload))

        for i, (ts, ln, payload) in enumerate(full_resps[:12]):
            if ln < 20:
                print(f"  #{i:02d} short resp len={ln}: {payload.hex()}")
                continue
            pb_idx   = struct.unpack_from("<H", payload, 4)[0]
            page_idx = struct.unpack_from("<H", payload, 6)[0]
            b8_9     = payload[8:10].hex()
            b10_11   = payload[10:12].hex()
            flash    = struct.unpack_from("<I", payload, 12)[0]
            body     = payload[20:ln]
            non_zero = sum(1 for b in body if b != 0)
            print(f"  #{i:02d} len={ln}  b0={payload[0]:02x} b1={payload[1]:02x} "
                  f"b2={payload[2]:02x} b3={payload[3]:02x}")
            print(f"      pb_idx(@4-5)={pb_idx}  page_idx(@6-7)={page_idx}  "
                  f"b8-9={b8_9}  b10-11={b10_11}")
            print(f"      flash_addr(@12-15 LE)=0x{flash:08x}  payload={len(body)}B  "
                  f"{non_zero} non-zero  [{body[:8].hex()}...]")
        if len(full_resps) > 12:
            print(f"  ... ({len(full_resps) - 12} more)")

        # response flash-address progression and (pb,page)->addr table
        print("\n=== RESPONSE flash address progression (first 20) ===")
        rows = []
        for (ts, ln, payload) in full_resps:
            if ln >= 20:
                pb   = struct.unpack_from("<H", payload, 4)[0]
                page = struct.unpack_from("<H", payload, 6)[0]
                addr = struct.unpack_from("<I", payload, 12)[0]
                nz   = sum(1 for b in payload[20:ln] if b != 0)
                rows.append((pb, page, addr, nz))
        for i, (pb, page, addr, nz) in enumerate(rows[:20]):
            delta = (addr - rows[i-1][2]) if i > 0 else 0
            print(f"  resp {i:3d}: pb={pb:2d} page={page:2d} "
                  f"addr=0x{addr:08x} (delta +0x{delta:x}) nz={nz}")
        if rows:
            all_addrs = [r[2] for r in rows]
            print(f"\n  first addr = 0x{min(all_addrs):08x}")
            print(f"  last  addr = 0x{max(all_addrs):08x}")
            print(f"  total responses = {len(rows)}")
            uniq_pages = sorted(set((r[0], r[1]) for r in rows))
            print(f"  unique (pb_idx,page_idx) pages = {len(uniq_pages)}")
            # infer per-page stride and per-block stride
            print("\n  first 8 unique pages -> block0 addr:")
            seen = {}
            for (pb, page, addr, nz) in rows:
                seen.setdefault((pb, page), addr)
            for k in uniq_pages[:8]:
                print(f"    pb={k[0]:2d} page={k[1]:2d}  base_addr=0x{seen[k]:08x}")

    print("\n=== app->LPU small-frame histogram (len, b0, b1, b2) : count ===")
    for key in sorted(other_app):
        ln, b0, b1, b2 = key
        print(f"  len={ln:3d} b0=0x{b0:02x} b1=0x{b1:02x} b2=0x{b2:02x} : {other_app[key]}")



if __name__ == "__main__":
    main()
