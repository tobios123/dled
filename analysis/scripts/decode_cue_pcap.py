#!/usr/bin/env python3
"""
decode_cue_pcap.py
Dump ALL non-keepalive UDP payloads on port 16945 from the cue go/release capture.
"""
import struct, sys, os, collections

PCAP_FILE = os.path.join(os.path.dirname(__file__),
    "../../samples/"
    "go_release_go_next_cue_next_cue_release.pcapng")

VN_PORT = 16945

def read_pcapng_packets(path):
    with open(path, 'rb') as f:
        data = f.read()
    pos = 0
    link_type = 1
    packets = []
    while pos < len(data):
        if pos + 8 > len(data): break
        block_type = struct.unpack_from('<I', data, pos)[0]
        block_len  = struct.unpack_from('<I', data, pos + 4)[0]
        if block_len < 12 or pos + block_len > len(data): break
        block_body = data[pos + 8 : pos + block_len - 4]
        if block_type == 0x00000001:
            link_type = struct.unpack_from('<H', block_body, 0)[0]
        elif block_type == 0x00000006:
            if len(block_body) >= 20:
                cap_len = struct.unpack_from('<I', block_body, 12)[0]
                pkt = block_body[20 : 20 + cap_len]
                result = _parse_udp(pkt, link_type)
                if result: packets.append(result)
        elif block_type == 0x00000003:
            pkt = block_body[4:]
            result = _parse_udp(pkt, link_type)
            if result: packets.append(result)
        pos += block_len
    return packets

def _parse_udp(pkt, link_type):
    try:
        if link_type == 1:
            if len(pkt) < 14: return None
            eth_type = struct.unpack_from('>H', pkt, 12)[0]
            if eth_type == 0x8100:
                eth_type = struct.unpack_from('>H', pkt, 16)[0]
                pkt = pkt[18:]
            else:
                pkt = pkt[14:]
            if eth_type != 0x0800: return None
        if len(pkt) < 20: return None
        ihl = (pkt[0] & 0x0F) * 4
        if pkt[9] != 17: return None
        src_ip = '.'.join(str(b) for b in pkt[12:16])
        dst_ip = '.'.join(str(b) for b in pkt[16:20])
        pkt = pkt[ihl:]
        if len(pkt) < 8: return None
        src_port, dst_port = struct.unpack_from('>HH', pkt)
        payload = pkt[8:]
        return (src_ip, dst_ip, src_port, dst_port, payload)
    except Exception:
        return None

def hex_dump(data, indent="  ", width=16):
    lines = []
    for off in range(0, len(data), width):
        chunk = data[off:off+width]
        h = ' '.join(f'{b:02x}' for b in chunk)
        a = ''.join(chr(b) if 0x20 <= b < 0x7f else '.' for b in chunk)
        lines.append(f"{indent}{off:04x}: {h:<{width*3}}  {a}")
    return '\n'.join(lines)

def main():
    if not os.path.exists(PCAP_FILE):
        print(f"ERROR: not found: {PCAP_FILE}")
        sys.exit(1)

    packets = read_pcapng_packets(PCAP_FILE)
    vn = [(i, si, di, sp, dp, pay)
          for i, (si, di, sp, dp, pay) in enumerate(packets)
          if sp == VN_PORT or dp == VN_PORT]

    print(f"Total UDP: {len(packets)}  VN port 16945: {len(vn)}")

    # byte[0] distribution
    dist = collections.Counter()
    for _, si, di, sp, dp, pay in vn:
        if pay: dist[pay[0]] += 1
    print("\nFirst-byte distribution:")
    for b, cnt in sorted(dist.items()):
        print(f"  0x{b:02x}: {cnt}")

    # Dump ALL non-0xff packets with full hex
    print("\n=== ALL non-keepalive packets ===")
    for i, si, di, sp, dp, pay in vn:
        if not pay or pay[0] == 0xff: continue
        direction = "App->LPU" if sp != VN_PORT else "LPU->App"
        print(f"\n[{i:4d}] {direction}  len={len(pay)}")
        print(f"  hex: {pay.hex()}")
        print(hex_dump(pay, "       "))
        # decode as many fields as possible
        if len(pay) >= 3:
            print(f"  byte[0]=0x{pay[0]:02x} byte[1]=0x{pay[1]:02x} byte[2]=0x{pay[2]:02x}", end="")
            if len(pay) >= 4: print(f" byte[3]=0x{pay[3]:02x}", end="")
            print()
        if len(pay) >= 4 and pay[0] == 0x1f:
            print(f"  => 0x1f frame: cmd=0x{pay[2]:02x} idx={pay[3]}", end="")
            if len(pay) >= 12:
                fld10 = struct.unpack_from('<H', pay, 10)[0]
                fld12 = struct.unpack_from('<I', pay, 12)[0]
                print(f" fld10=0x{fld10:04x} fld12={fld12}", end="")
            print()
            if len(pay) > 20:
                body = pay[20:]
                print(f"  body ({len(body)}b): {body.hex()}")
                if len(body) >= 4:
                    u32 = struct.unpack_from('<I', body)[0]
                    f32 = struct.unpack_from('<f', body)[0]
                    print(f"  body as uint32={u32}  float32={f32:.6f}")

if __name__ == '__main__':
    main()
