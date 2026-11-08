import struct, sys, os

FILTER_IP = "192.168.1.12"

def parse_file(path):
    print(f"\n=== {os.path.basename(path)} ===")
    with open(path, "rb") as f:
        data = f.read()
    pos = 0
    linktype = 1  # default Ethernet
    pkt_num = 0
    while pos < len(data) - 8:
        bt = struct.unpack_from("<I", data, pos)[0]
        if bt == 0x0A0D0D0A:
            # SHB
            blen = struct.unpack_from("<I", data, pos+4)[0]
            print(f"  SHB at {pos}, len={blen}")
            pos += blen
            continue
        if bt not in (1, 2, 3, 6):
            # unknown block, try to skip
            blen = struct.unpack_from("<I", data, pos+4)[0]
            if blen < 12 or blen > len(data):
                break
            pos += blen
            continue
        blen = struct.unpack_from("<I", data, pos+4)[0]
        if blen < 12 or pos + blen > len(data):
            break
        block = data[pos:pos+blen]
        if bt == 1:
            # IDB
            lt = struct.unpack_from("<H", block, 8)[0]
            linktype = lt
            print(f"  IDB linktype={linktype}")
        elif bt == 6:
            # EPB
            pkt_num += 1
            raw = block[20:20 + struct.unpack_from("<I", block, 20)[0]] if False else None
            cap_len = struct.unpack_from("<I", block, 20)[0]
            pkt_data = block[28:28+cap_len]
            decode_pkt(pkt_num, linktype, pkt_data)
        elif bt == 3:
            # SPB
            pkt_num += 1
            cap_len = struct.unpack_from("<I", block, 12)[0]
            pkt_data = block[16:16+cap_len]
            decode_pkt(pkt_num, linktype, pkt_data)
        elif bt == 2:
            # OPB
            pkt_num += 1
            cap_len = struct.unpack_from("<I", block, 16)[0]
            pkt_data = block[20:20+cap_len]
            decode_pkt(pkt_num, linktype, pkt_data)
        pos += blen

def decode_pkt(num, linktype, raw):
    if linktype == 1:
        if len(raw) < 14:
            return
        ethertype = struct.unpack_from(">H", raw, 12)[0]
        if ethertype != 0x0800:
            return
        ip = raw[14:]
    elif linktype == 101:
        ip = raw
    else:
        return
    if len(ip) < 20:
        return
    proto = ip[9]
    src_ip = ".".join(str(b) for b in ip[12:16])
    dst_ip = ".".join(str(b) for b in ip[16:20])
    if FILTER_IP not in (src_ip, dst_ip):
        return
    ihl = (ip[0] & 0xf) * 4
    payload = ip[ihl:]
    if proto == 17 and len(payload) >= 8:
        sport = struct.unpack_from(">H", payload, 0)[0]
        dport = struct.unpack_from(">H", payload, 2)[0]
        udp_data = payload[8:]
        print(f"  PKT#{num} UDP {src_ip}:{sport} -> {dst_ip}:{dport} len={len(udp_data)}")
        print_hex(udp_data)
    elif proto == 6 and len(payload) >= 20:
        sport = struct.unpack_from(">H", payload, 0)[0]
        dport = struct.unpack_from(">H", payload, 2)[0]
        tcp_off = ((payload[12] >> 4) & 0xf) * 4
        tcp_data = payload[tcp_off:]
        if tcp_data:
            print(f"  PKT#{num} TCP {src_ip}:{sport} -> {dst_ip}:{dport} len={len(tcp_data)}")
            print_hex(tcp_data)
        else:
            print(f"  PKT#{num} TCP {src_ip}:{sport} -> {dst_ip}:{dport} (no payload)")

def print_hex(data, max_bytes=256):
    data = data[:max_bytes]
    for i in range(0, len(data), 16):
        chunk = data[i:i+16]
        hex_part = " ".join(f"{b:02x}" for b in chunk)
        asc_part = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
        print(f"    {i:04x}  {hex_part:<48}  {asc_part}")

# the captures to read: given on the command line (your own; not in the repo)
files = sys.argv[1:] or [
    r"samples/app_running_lpu_connectedto_network_thenselecting_the_lpu_what_downloads_curent_show.pcapng",
    r"samples/startup_second_attempt.pcapng",
]
for f in files:
    if os.path.exists(f):
        parse_file(f)
    else:
        print(f"NOT FOUND: {f}")
