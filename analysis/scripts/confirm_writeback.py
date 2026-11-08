"""Verify a show write-back capture against the .show file the app opened.

Decodes every app -> LPU write frame (VN_PROTOCOL.md section 12) and compares
fixtures, DMX addresses, cue counts, cue labels and all 800-byte block
payloads with the .show XML.

Usage:
    python confirm_writeback.py capture.pcapng file.show [app_ip]

Example:
    python confirm_writeback.py \
        "../../samples/reference_app_show_opening_and_sending_show_to_lpu.pcapng" \
        "../../samples/show_all_fx_options.show"
"""
import base64
import struct
import sys
import xml.etree.ElementTree as ET

VN_PORT = 16945


# --- minimal pcapng reader -------------------------------------------------

def _pcapng_packets(data):
    off, endian, ifaces = 0, '<', []
    while off + 12 <= len(data):
        btype = struct.unpack_from(endian + 'I', data, off)[0]
        if btype == 0x0A0D0D0A:
            endian = '<' if data[off + 8:off + 12] == b'\x4d\x3c\x2b\x1a' else '>'
            ifaces = []
        blen = struct.unpack_from(endian + 'I', data, off + 4)[0]
        if blen < 12:
            break
        body = data[off + 8:off + blen - 4]
        if btype == 1:  # interface description: link type + ts resolution
            link, res, o = struct.unpack_from(endian + 'H', body, 0)[0], 1e6, 8
            while o + 4 <= len(body):
                code, olen = struct.unpack_from(endian + 'HH', body, o)
                if code == 0:
                    break
                if code == 9:
                    r = body[o + 4]
                    res = 2 ** (r & 0x7f) if r & 0x80 else 10 ** r
                o += 4 + ((olen + 3) & ~3)
            ifaces.append((link, res))
        elif btype == 6:  # enhanced packet
            ifid, th, tl, cap, _ = struct.unpack_from(endian + 'IIIII', body, 0)
            link, res = ifaces[ifid] if ifid < len(ifaces) else (1, 1e6)
            yield ((th << 32) | tl) / res, link, body[20:20 + cap]
        off += blen


def _ip_payload(link, pkt):
    if link == 1:  # ethernet (+ VLAN tags)
        et, o = struct.unpack_from('>H', pkt, 12)[0], 14
        while et in (0x8100, 0x88a8):
            et, o = struct.unpack_from('>H', pkt, o + 2)[0], o + 4
        return pkt[o:] if et == 0x0800 else None
    if link == 113:
        return pkt[16:] if struct.unpack_from('>H', pkt, 14)[0] == 0x0800 else None
    if link == 276:
        return pkt[20:] if struct.unpack_from('>H', pkt, 0)[0] == 0x0800 else None
    if link in (101, 228):
        return pkt
    if link == 0:
        return pkt[4:]
    return None


def udp_packets(path):
    """Yield (ts, src_ip, sport, dst_ip, dport, payload) for IPv4 UDP."""
    for ts, link, pkt in _pcapng_packets(open(path, 'rb').read()):
        ip = _ip_payload(link, pkt)
        if not ip or len(ip) < 20 or ip[0] >> 4 != 4 or ip[9] != 17:
            continue
        if struct.unpack_from('>H', ip, 6)[0] & 0x1FFF:
            continue
        ihl, tot = (ip[0] & 15) * 4, struct.unpack_from('>H', ip, 2)[0]
        udp = ip[ihl:tot]
        sport, dport, ulen = struct.unpack_from('>HHH', udp, 0)
        yield (ts, '.'.join(map(str, ip[12:16])), sport,
               '.'.join(map(str, ip[16:20])), dport, bytes(udp[8:ulen]))


# --- comparison --------------------------------------------------------------

def main():
    cap, showf = sys.argv[1], sys.argv[2]
    app = sys.argv[3] if len(sys.argv) > 3 else '192.168.1.171'

    root = ET.parse(showf).getroot()
    fixtures = {int(f.get('index')): f.attrib for f in root.iter('fixture')}
    show_blocks, show_names, show_counts = {}, {}, {}
    for pb in root.iter('playback'):
        p = int(pb.get('index'))
        cues = pb.findall('cues/cue')
        show_counts[p] = len(cues)
        for c, cue in enumerate(cues):
            show_names[(p, c)] = cue.get('label')
            for b, blk in enumerate(cue.findall('blocks/block')):
                text = (blk.text or '').strip()
                show_blocks[(p, c, b)] = base64.b64decode(text) if text else b''

    up_blocks, up_names, up_counts, up_fix, up_addr, deleted = {}, {}, {}, {}, {}, {}
    order = []
    for _, src, _, _, dport, pl in udp_packets(cap):
        if src != app or dport != VN_PORT or len(pl) < 20:
            continue
        key = (pl[0], pl[1], pl[2])
        i1, i2, i3 = struct.unpack_from('<HHH', pl, 4)
        body = pl[20:]
        if key == (0x2b, 0x0a, 0x47):
            up_blocks[(i1, i2, i3)] = body
            order.append((i1, i2, i3))
        elif key == (0x2b, 0x00, 0x06):
            up_names[(i1, i2)] = body.rstrip(b'\0').decode('latin1')
        elif key == (0x29, 0x01, 0x48):
            up_counts[i1] = struct.unpack('<I', body)[0]
        elif key == (0x1f, 0x00, 0x08):
            up_fix[i1] = body.rstrip(b'\0').decode('latin1')
        elif key == (0x1f, 0x01, 0x0c):
            up_addr[i1] = struct.unpack('<I', body)[0]
        elif pl[1] == 0x1d and pl[2] == 0x38:
            deleted.setdefault(pl[0], set()).add(i1)

    print('fixtures written:', sorted(up_fix))
    for i, csv in sorted(up_fix.items()):
        f = fixtures.get(i)
        exp = '"%s","%s","%s","%s"' % (f['manufacturer'], f['model'], f['mode'], f['profile']) if f else None
        print('  fixture %2d  csv %s  address %s (show %s)' % (
            i, 'OK' if csv == exp else 'DIFF %r vs %r' % (csv, exp),
            up_addr.get(i, 'not captured'), f and f['address']))
    print('fixture slots deleted:', len(deleted.get(0x1f, ())),
          '| overlap with written:', sorted(deleted.get(0x1f, set()) & set(up_fix)))
    print('playback slots deleted:', sorted(deleted.get(0x29, ())))
    print('cue counts written:', up_counts)
    print('cue counts in show:', {p: show_counts.get(p) for p in up_counts})

    match = 0
    for k, body in sorted(up_blocks.items()):
        exp = show_blocks.get(k) or bytes(800)
        if body == exp:
            match += 1
        else:
            print('  MISMATCH block', k)
    print('pages written: %d, block frames: %d' % (len({k[:2] for k in up_blocks}), len(up_blocks)))
    print('block payloads equal to .show: %d/%d' % (match, len(up_blocks)))
    print('block frames in ascending (playback, cue, block) order:', order == sorted(order))
    bad = [(k, v, show_names.get(k)) for k, v in up_names.items() if v != (show_names.get(k) or '')]
    print('cue labels written: %d, mismatches: %s' % (len(up_names), bad or 'none'))
    missing = sorted({(p, c) for (p, c, _) in show_blocks} - {k[:2] for k in up_blocks})
    print('show pages not written:', missing or 'none')


if __name__ == '__main__':
    main()
