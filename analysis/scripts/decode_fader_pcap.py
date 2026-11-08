#!/usr/bin/env python3
"""
decode_fader_pcap.py
Analyze the fader/level change capture:
  fader_level_change_1_and_8_cue_go_and_released.pcapng
Expected: playback 1 goes 100->0->100, then playback 8 does same.
Goal: find the level-control command and decode its fields.
"""
import struct, sys, os, collections

PCAP_FILE = os.path.join(os.path.dirname(__file__),
    "../../samples/"
    "fader_level_change_1_and_8_cue_go_and_released.pcapng")

VN_PORT = 16945
APP_IP  = "192.168.1.171"
LPU_IP  = "192.168.1.12"

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

def parse_header(pay):
    if len(pay) < 20: return None
    flags = pay[1]
    cmd   = pay[2]
    idx   = pay[3]
    fld10 = struct.unpack_from('<H', pay, 10)[0]
    fld12 = struct.unpack_from('<I', pay, 12)[0]
    fld16 = struct.unpack_from('<I', pay, 16)[0]
    return dict(flags=flags, cmd=cmd, idx=idx, fld10=fld10,
                fld12=fld12, fld16=fld16,
                direction='RSP' if (flags & 0x80) else 'REQ')

def main():
    if not os.path.exists(PCAP_FILE):
        print(f"ERROR: file not found: {PCAP_FILE}")
        sys.exit(1)

    packets = read_pcapng_packets(PCAP_FILE)
    print(f"Total UDP packets decoded: {len(packets)}")

    vn_pkts = [(i, si, di, sp, dp, pay)
               for i, (si, di, sp, dp, pay) in enumerate(packets)
               if sp == VN_PORT or dp == VN_PORT]
    other   = [(i, si, di, sp, dp, pay)
               for i, (si, di, sp, dp, pay) in enumerate(packets)
               if sp != VN_PORT and dp != VN_PORT]

    print(f"VN port 16945 packets: {len(vn_pkts)}")
    print(f"Other ports:           {len(other)}")

    # -- Command distribution on port 16945 --
    print("\n=== CMD distribution on port 16945 ===")
    cmd_count = collections.Counter()
    for i, si, di, sp, dp, pay in vn_pkts:
        if not pay: continue
        if pay[0] == 0x1f and len(pay) >= 3:
            direction = 'RSP' if (pay[1] & 0x80) else 'REQ'
            cmd_count[(pay[2], direction)] += 1
        elif pay[0] == 0xff:
            cmd_count[('0xff keepalive', '')] += 1
        else:
            cmd_count[(f'other_0x{pay[0]:02x}', '')] += 1
    for k, v in sorted(cmd_count.items(), key=lambda x: -x[1]):
        print(f"  cmd=0x{k[0]:02x} {k[1]}: {v}" if isinstance(k[0], int)
              else f"  {k[0]}: {v}")

    # -- Show every UNIQUE command seen (not 0x38/0x05/keepalive) --
    print("\n=== All NON-heartbeat/poll frames (showing first 5 of each cmd) ===")
    skip_cmds = {0x38, 0x05}
    shown = collections.defaultdict(int)
    for i, si, di, sp, dp, pay in vn_pkts:
        if not pay or pay[0] != 0x1f or len(pay) < 3: continue
        cmd = pay[2]
        if cmd in skip_cmds: continue
        direction = 'RSP' if (pay[1] & 0x80) else 'REQ'
        key = (cmd, direction)
        if shown[key] >= 5: continue
        shown[key] += 1
        h = parse_header(pay)
        body = pay[20:] if len(pay) > 20 else b''
        print(f"\n[pkt {i}] cmd=0x{cmd:02x} {direction}  {si}:{sp}->{di}:{dp}  total={len(pay)}")
        print(f"  header: flags=0x{h['flags']:02x} idx={h['idx']} "
              f"fld10=0x{h['fld10']:04x} fld12=0x{h['fld12']:08x}({h['fld12']}) "
              f"fld16=0x{h['fld16']:08x}")
        print(f"  raw hdr: {pay[:20].hex()}")
        if body:
            print(f"  body ({len(body)} bytes):")
            print(hex_dump(body, "    "))
            # Try to interpret body as various types
            if len(body) >= 4:
                u32 = struct.unpack_from('<I', body)[0]
                f32 = struct.unpack_from('<f', body)[0]
                print(f"  body[0:4] as LE uint32={u32}  float32={f32:.6f}")
            if len(body) >= 2:
                u16 = struct.unpack_from('<H', body)[0]
                print(f"  body[0:2] as LE uint16={u16}  (0-65535)  as pct={u16/655.35:.1f}%")
            if len(body) >= 1:
                print(f"  body[0] as uint8={body[0]}  as pct={body[0]/2.55:.1f}%")

    # -- Full chronological dump of interesting commands --
    print("\n\n=== FULL CHRONOLOGICAL DUMP (skip heartbeat/keepalive) ===")
    for i, si, di, sp, dp, pay in vn_pkts:
        if not pay: continue
        if pay[0] == 0xff: continue
        if pay[0] != 0x1f or len(pay) < 3: continue
        cmd = pay[2]
        if cmd in skip_cmds: continue
        h = parse_header(pay)
        body = pay[20:] if len(pay) > 20 else b''
        direction = h['direction']
        print(f"[{i:4d}] cmd=0x{cmd:02x} {direction:3s}  "
              f"idx={h['idx']:3d}  fld10=0x{h['fld10']:04x}  "
              f"fld12={h['fld12']:10d}  fld16={h['fld16']:10d}  "
              f"body={body.hex() if body else '(none)'}")
        if body and len(body) >= 4:
            u32 = struct.unpack_from('<I', body)[0]
            f32 = struct.unpack_from('<f', body)[0]
            print(f"        => uint32={u32}  float32={f32:.4f}  uint16[0]={struct.unpack_from('<H',body)[0]}")

    # -- Other port distribution --
    if other:
        print("\n\n=== OTHER PORTS ===")
        port_dist = collections.Counter()
        for i, si, di, sp, dp, pay in other:
            port_dist[(min(sp,dp), max(sp,dp))] += 1
        for k, v in sorted(port_dist.items(), key=lambda x: -x[1]):
            print(f"  ports {k[0]}<->{k[1]}: {v} packets")
        # Show first few of each
        seen_ports = set()
        for i, si, di, sp, dp, pay in other:
            pk = (min(sp,dp), max(sp,dp))
            if pk in seen_ports: continue
            seen_ports.add(pk)
            print(f"\n  First packet on ports {sp}<->{dp}:")
            print(hex_dump(pay[:64], "    "))

if __name__ == '__main__':
    main()
