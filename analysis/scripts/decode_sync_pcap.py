import struct, sys

PCAP = r'samples\live_lpu_connection_sync_of_show_lpu_memory_to_app.pcapng'

def read_pcapng(path):
    with open(path,'rb') as f:
        data = f.read()
    i = 0
    pkts = []
    while i < len(data)-8:
        btype = struct.unpack_from('<I',data,i)[0]
        blen  = struct.unpack_from('<I',data,i+4)[0]
        if blen < 12 or i+blen > len(data): break
        if btype == 6:  # EPB
            caplen = struct.unpack_from('<I',data,i+16)[0]
            pkt = data[i+28:i+28+caplen]
            pkts.append(pkt)
        i += blen
    return pkts

pkts = read_pcapng(PCAP)
print(f'Total packets: {len(pkts)}')

vn_pkts = []
for p in pkts:
    if len(p) < 42: continue
    eth_type = struct.unpack_from('>H',p,12)[0]
    if eth_type != 0x0800: continue
    if p[23] != 17: continue  # UDP only
    src_ip = '.'.join(str(p[26+x]) for x in range(4))
    dst_ip = '.'.join(str(p[30+x]) for x in range(4))
    sport = struct.unpack_from('>H',p,34)[0]
    dport = struct.unpack_from('>H',p,36)[0]
    udp_len = struct.unpack_from('>H',p,38)[0]
    payload = p[42:42+max(0,udp_len-8)]
    if sport==16945 or dport==16945:
        vn_pkts.append((src_ip,sport,dst_ip,dport,payload))

print(f'VN port 16945 packets: {len(vn_pkts)}')

lpu_pkts = [(s,sp,d,dp,pay) for s,sp,d,dp,pay in vn_pkts if sp==16945]
app_pkts = [(s,sp,d,dp,pay) for s,sp,d,dp,pay in vn_pkts if dport==16945]
print(f'LPU->app: {len(lpu_pkts)},  app->LPU: {len(app_pkts)}')

print('\n--- LPU->app unique message types (first 30 each) ---')
seen = {}
for s,sp,d,dp,pay in lpu_pkts:
    if not pay: continue
    key = pay[:4].hex()
    if key not in seen:
        seen[key] = {'count':0,'example':pay}
    seen[key]['count'] += 1

for k,(v) in list(seen.items())[:30]:
    pay = v['example']
    c = v['count']
    printable = all(32<=b<127 or b in (9,10,13) for b in pay[:60])
    print(f'  [{k}] count={c} len={len(pay)}')
    print(f'    hex: {pay[:64].hex()}')
    if printable:
        print(f'    txt: {pay[:120]}')

print('\n--- app->LPU unique message types ---')
seen2 = {}
for s,sp,d,dp,pay in app_pkts:
    if not pay: continue
    key = pay[:4].hex()
    if key not in seen2:
        seen2[key] = {'count':0,'example':pay}
    seen2[key]['count'] += 1

for k,v in list(seen2.items())[:20]:
    pay = v['example']
    c = v['count']
    printable = all(32<=b<127 or b in (9,10,13) for b in pay[:60])
    print(f'  [{k}] count={c} len={len(pay)}')
    print(f'    hex: {pay[:64].hex()}')
    if printable:
        print(f'    txt: {pay[:120]}')

# Look for XML-like content
print('\n--- Large LPU->app payloads (possible show sync) ---')
for s,sp,d,dp,pay in lpu_pkts:
    if len(pay) > 200:
        printable = all(32<=b<127 or b in (9,10,13) for b in pay[:80])
        print(f'  {s}->{d} len={len(pay)} hex={pay[:32].hex()}')
        if printable:
            print(f'    {pay[:200]}')
        break
