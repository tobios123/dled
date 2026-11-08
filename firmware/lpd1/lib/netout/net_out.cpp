// net_out.cpp -- see net_out.h. E1.31 layout: root layer 0-37, framing layer
// 38-114 (universe at 113), DMP layer 115- (start code at 125, the 512
// channels from 126).

#include "net_out.h"

#include <string.h>

namespace lpd {

namespace {

void be16(uint8_t *p, uint16_t v) { p[0] = v >> 8, p[1] = v & 0xff; }
void be32(uint8_t *p, uint32_t v) { be16(p, v >> 16), be16(p + 2, v & 0xffff); }
// a PDU's "flags and length": 0x7 in the top 4 bits, the length to the end
void flagsLength(uint8_t *p, size_t len) { be16(p, 0x7000 | (uint16_t)len); }

}  // namespace

size_t artnetPacket(uint8_t out[kArtnetSize], const uint8_t dmx[512], uint16_t universe, uint8_t sequence) {
  static const uint8_t head[12] = {'A', 'r', 't', '-', 'N', 'e', 't', 0, 0x00, 0x50, 0, 14};
  memcpy(out, head, sizeof head);
  out[12] = sequence;
  out[13] = 0;  // physical
  out[14] = universe & 0xff, out[15] = universe >> 8 & 0x7f;
  out[16] = 512 >> 8, out[17] = 512 & 0xff;
  memcpy(out + 18, dmx, 512);
  return kArtnetSize;
}

size_t sacnPacket(uint8_t out[kSacnSize], const uint8_t dmx[512], uint16_t universe, uint8_t sequence,
                  const uint8_t cid[16], const char *name) {
  memset(out, 0, kSacnSize);
  // root layer
  be16(out, 0x0010);  // preamble size
  be16(out + 2, 0);   // postamble size
  memcpy(out + 4, "ASC-E1.17\0\0\0", 12);
  flagsLength(out + 16, kSacnSize - 16);
  be32(out + 18, 0x00000004);  // VECTOR_ROOT_E131_DATA
  memcpy(out + 22, cid, 16);
  // framing layer
  flagsLength(out + 38, kSacnSize - 38);
  be32(out + 40, 0x00000002);  // VECTOR_E131_DATA_PACKET
  strncpy((char *)out + 44, name, 63);
  out[108] = 100;  // priority
  be16(out + 109, 0);  // synchronisation address
  out[111] = sequence;
  out[112] = 0;  // options
  be16(out + 113, universe);
  // DMP layer
  flagsLength(out + 115, kSacnSize - 115);
  out[117] = 0x02;  // VECTOR_DMP_SET_PROPERTY
  out[118] = 0xa1;  // address and data type
  be16(out + 119, 0);  // first property address
  be16(out + 121, 1);  // increment
  be16(out + 123, 513);  // start code + 512 channels
  out[125] = 0;  // start code
  memcpy(out + 126, dmx, 512);
  return kSacnSize;
}

}  // namespace lpd
