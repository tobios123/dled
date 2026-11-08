#!/usr/bin/env python3
"""Parse pcapng files and extract UDP port 16945 (VN protocol) packets."""
import struct, sys, os, glob

def parse_pcapng(path):
    print(f"\n=== {os.path.basename(path)} ===")
    data = open(path, 'rb').read()
    off = 0
    iface_link_type = 1  # default ethernet
    packets = []

    while off + 8 <= len(data):
        block_type = struct.unpack_from('<I', data, off)[0]
        block_len  = struct.unpack_from('<I', data, off+4)[0]
        if block_len < 12 or off + block_len > len(data):
            break

        # SHB = 0x0A0D0D0A
        if block_type == 0x0A0D0D0A:
            pass

        # IDB = 0x00000001
        elif block_type == 0x00000001:
            iface_link_type = struct.unpack_from('<H', data, off+8)[0]

        # EPB = 0x00000006
        elif block_type == 0x00000006:
            # iface_id(4) cap_len(4) orig_len(4) pkt_data
            cap_len  = struct.unpack_from('<I', data, off+20)[0]
            pkt_data = data[off+28 : off+28+cap_len]
            pkt = parse_pkt(pkt_data, iface_link_type)
            if pkt:
                packets.append(pkt)

        # SPB = 0x00000003
        elif block_type == 0x00000003:
            orig_len = struct.unpack_from('<I', data, off+8)[0]
            cap_len = min(orig_len, block_len - 16)
            pkt_data = data[off+12 : off+12+cap_len]
            pkt = parse_pkt(pkt_data, iface_link_type)
            if pkt:
                packets.append(pkt)

        off += block_len

    print(f"  Found {len(packets)} VN packets (UDP 16945)")
    for p in packets[:100]:
        print(f"  {p['src']}:{p['sport']} -> {p['dst']}:{p['dport']}  {p['payload'].hex()}")
        interpret(p['payload'])
    if len(packets) > 100:
        print(f"  ... ({len(packets)-100} more)")
    return packets


def parse_pkt(data, link_type):
    """Extract UDP src/dst/payload from a raw packet, return dict or None."""
    try:
        # Link layer
        if link_type == 1:   # Ethernet
            if len(data) < 14: return None
            ethertype = struct.unpack_from('>H', data, 12)[0]
            if ethertype == 0x0800:
                ip_off = 14
            elif ethertype == 0x8100:  # VLAN
                ip_off = 18
            else:
                return None
        elif link_type == 101:  # Raw IP
            ip_off = 0
        else:
            return None

        # IPv4
        if len(data) < ip_off + 20: return None
        ihl = (data[ip_off] & 0x0F) * 4
        proto = data[ip_off + 9]
        src = '.'.join(str(data[ip_off+12+i]) for i in range(4))
        dst = '.'.join(str(data[ip_off+16+i]) for i in range(4))
        if proto != 17: return None  # UDP only

        udp_off = ip_off + ihl
        if len(data) < udp_off + 8: return None
        sport, dport = struct.unpack_from('>HH', data, udp_off)
        payload = data[udp_off+8 :]

        if sport != 16945 and dport != 16945:
            return None

        return {'src': src, 'dst': dst, 'sport': sport, 'dport': dport, 'payload': payload}
    except Exception as e:
        return None


def interpret(payload):
    if len(payload) == 0:
        return
    if len(payload) == 1 and payload[0] == 0xFF:
        print("    -> Keepalive (0xFF)")
        return
    if payload[0:1] == b'<':
        print(f"    -> XML identify: {payload[:120].decode('utf-8','replace')}")
        return
    if payload[:15] == b'visual_identify':
        print("    -> Discovery broadcast")
        return
    if len(payload) == 24 and payload[0] == 0x29 and payload[1] == 0x03:
        seq = payload[2]
        ff1, ff2 = payload[10], payload[11]
        ch = struct.unpack_from('<H', payload, 12)[0]
        ctr = struct.unpack_from('<H', payload, 14)[0]
        level = struct.unpack_from('<f', payload, 20)[0]
        print(f"    -> Level pkt: seq={seq} ch={ch} ctr={ctr} level={level:.3f} ff={ff1:02x}{ff2:02x}")
        return
    if len(payload) == 9:
        cmd = struct.unpack_from('<H', payload, 0)[0]
        print(f"    -> Query: cmd=0x{cmd:04x} ({payload.hex()})")
        return
    print(f"    -> Unknown {len(payload)} bytes: {payload[:32].hex()}")


folder = r'samples'
files = sorted(glob.glob(os.path.join(folder, '*.pcapng')))
for f in files:
    parse_pcapng(f)
