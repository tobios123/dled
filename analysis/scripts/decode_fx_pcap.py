"""
Extract FX waveform ID from fx_rainbow_size=18_speed=10_phase=85_record.pcapng.
Look for 800-byte UDP payloads containing the block data and print bytes 8-11
of the first fixture record to confirm waveform ID for Rainbow.
"""
import struct, sys

PCAP = 'samples/fx_rainbow_size=18_speed=10_phase=85_record.pcapng'

def read_pcapng(path):
    with open(path, 'rb') as f:
        data = f.read()
    i = 0
    packets = []
    while i < len(data) - 8:
        block_type = struct.unpack_from('<I', data, i)[0]
        block_len  = struct.unpack_from('<I', data, i+4)[0]
        if block_len < 12 or block_len > len(data):
            break
        body = data[i+8 : i+block_len-4]
        # Enhanced Packet Block = 6, Simple Packet Block = 3
        if block_type == 6 and len(body) >= 20:
            # iface_id(4) + ts_hi(4) + ts_lo(4) + cap_len(4) + orig_len(4) = 20
            cap_len = struct.unpack_from('<I', body, 12)[0]
            pkt = body[20:20+cap_len]
            packets.append(pkt)
        elif block_type == 3 and len(body) >= 4:
            orig_len = struct.unpack_from('<I', body, 0)[0]
            pkt = body[4:]
            packets.append(pkt)
        i += block_len
    return packets

pkts = read_pcapng(PCAP)
print(f'Total packets: {len(pkts)}')

for pi, pkt in enumerate(pkts):
    # Try to find 800-byte payloads anywhere in packet (skip ethernet/IP/UDP headers)
    for offset in range(0, len(pkt)-800):
        chunk = pkt[offset:offset+800]
        # Check if this looks like a block: bytes 30-31 = 0x60 0x73 and 34-35 = 0x81 0xC4
        if chunk[30] == 0x60 and chunk[31] == 0x73 and chunk[34] == 0x81 and chunk[35] == 0xC4:
            print(f'\nPacket {pi} offset {offset}: found 800-byte block marker')
            print(f'  fixture[0] bytes 0-15: {list(chunk[0:16])}')
            print(f'  FX bytes 8-11: waveform={chunk[8]} size={chunk[9]} speed={chunk[10]} phase={chunk[11]}')
            # Check multiple fixture records
            for fi in range(8):
                rec = chunk[fi*50:(fi+1)*50]
                if any(rec):
                    nz = [(o,rec[o]) for o in range(50) if rec[o]]
                    print(f'  fixture[{fi}] bytes 8-11: {list(rec[8:12])}  nonzero={nz[:8]}')
            break
