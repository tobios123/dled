// net_out.h -- the DMX frame as Art-Net and sACN (E1.31) packets, as the LPU
// sends them (Art-Net universe 16 on the wire = the app's universe 1;
// sACN universe 1 to 239.255.0.1, port 5568). Portable: only builds the
// packets, the caller sends them (Art-Net to 6454, sACN to 5568).

#pragma once

#include <stddef.h>
#include <stdint.h>

namespace lpd {

constexpr uint16_t kArtnetPort = 6454, kSacnPort = 5568;
constexpr size_t kArtnetSize = 18 + 512, kSacnSize = 126 + 512;

// ArtDmx; [universe] as on the wire (15 bits).
size_t artnetPacket(uint8_t out[kArtnetSize], const uint8_t dmx[512], uint16_t universe, uint8_t sequence);

// E1.31 data packet, priority 100; [cid] the sender's 16-byte id, [name] its
// source name (up to 63 characters).
size_t sacnPacket(uint8_t out[kSacnSize], const uint8_t dmx[512], uint16_t universe, uint8_t sequence,
                  const uint8_t cid[16], const char *name);

// The multicast group of an sACN universe: 239.255.hi.lo.
inline uint32_t sacnGroup(uint16_t universe) { return 0xefff0000u | universe; }

}  // namespace lpd
