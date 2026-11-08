"""
Check whether app->LPU show upload (op=0x2b sub=0x47) also retransmits each page
multiple times, mirroring the LPU->app 3x download retransmit pattern.

Parses pcapng EPB blocks, extracts UDP src/dst port 16945, counts per-(pb_idx,cue_idx)
occurrences of op=0x2b sub=0x47 packets in the App->LPU direction.
"""
import os, struct, sys, collections

PCAP_DIR = r"samples\show_open_and_download"

APP_IP_LAST = 171   # 192.168.1.171
LPU_IP_LAST = 12    # 192.168.1.12
VN_PORT = 16945

def parse_pcapng(path):
    """Yield (src_ip_last_octet, dst_ip_last_octet, src_port, dst_port, payload_bytes)."""
    with open(path, 'rb') as f:
        data = f.read()
    pos = 0
    link_type = 1  # default ethernet
    while pos < len(data) - 8:
        block_type, block_len = struct.unpack_from('<II', data, pos)
        if block_len < 12 or pos + block_len > len(data):
            break
        block_data = data[pos:pos+block_len]
        if block_type == 0x0A0D0D0A:  # SHB
            pass
        elif block_type == 0x00000001:  # IDB
            lt = struct.unpack_from('<H', block_data, 8)[0]
            link_type = lt
        elif block_type == 0x00000006:  # EPB
            cap_len = struct.unpack_from('<I', block_data, 20)[0]
            pkt = block_data[28:28+cap_len]
            if link_type == 1 and len(pkt) >= 34:
                eth_type = struct.unpack_from('>H', pkt, 12)[0]
                if eth_type == 0x0800:  # IPv4
                    ihl = (pkt[14] & 0x0f) * 4
                    proto = pkt[14+9]
                    if proto == 17:  # UDP
                        src_ip = pkt[14+12+3]
                        dst_ip = pkt[14+16+3]
                        udp = pkt[14+ihl:]
                        if len(udp) >= 8:
                            sp, dp, udp_len = struct.unpack_from('>HHH', udp)
                            payload = udp[8:8+udp_len-8]
                            yield src_ip, dst_ip, sp, dp, payload
        pos += block_len

def analyze(path):
    print(f"\n=== {os.path.basename(path)} ===")
    # Count (pb_idx, cue_idx) occurrences for op=0x2b sub=0x47 App->LPU
    upload_counts = collections.Counter()
    upload_payloads = collections.defaultdict(list)
    total_upload = 0
    for src, dst, sp, dp, pay in parse_pcapng(path):
        if dp != VN_PORT and sp != VN_PORT:
            continue
        # App->LPU direction
        if src == APP_IP_LAST and dst == LPU_IP_LAST:
            if len(pay) >= 3 and pay[0] == 0x2b and pay[2] == 0x47:
                total_upload += 1
                if len(pay) >= 8:
                    pb_idx = struct.unpack_from('<H', pay, 4)[0]
                    cue_idx = struct.unpack_from('<H', pay, 6)[0]
                    key = (pb_idx, cue_idx)
                    upload_counts[key] += 1
                    upload_payloads[key].append(bytes(pay[20:20+8]) if len(pay) >= 28 else b'')

    print(f"Total op=0x2b sub=0x47 App->LPU packets: {total_upload}")
    print(f"Unique (pb_idx, cue_idx) pairs: {len(upload_counts)}")
    if upload_counts:
        count_dist = collections.Counter(upload_counts.values())
        print("Distribution of per-(pb_idx,cue_idx) occurrence counts:")
        for cnt in sorted(count_dist):
            print(f"  {cnt}x : {count_dist[cnt]} pages")
        # Show first few entries
        print("First 10 (pb_idx, cue_idx) -> count:")
        for i, (k, v) in enumerate(sorted(upload_counts.items())):
            if i >= 10:
                break
            print(f"  pb={k[0]} cue={k[1]} -> {v} packets, first payload prefix: {upload_payloads[k][0].hex()}")

print("Listing dir:", PCAP_DIR)
try:
    entries = os.listdir(PCAP_DIR)
    print("Files:", entries)
except Exception as e:
    print("ERROR listing dir:", e)
    sys.exit(1)

for fname in entries:
    if fname.endswith('.pcapng'):
        analyze(os.path.join(PCAP_DIR, fname))

print("\nDone.")
