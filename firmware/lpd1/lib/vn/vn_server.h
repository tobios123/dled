// vn_server.h -- the LPD-1's side of the LPU's VN protocol (UDP
// 16945): what lets the apps (ours and the original one) work with the box as
// with an LPU-1. It introduces itself as LPD-1. A port of analysis/lpu/simulator.py (the emulator the reference app
// accepts; frames in analysis/FINDINGS.md 20), but on the engine's show and
// with live control going to the engine.
//
// Portable C++17 like the engine: no sockets and no clock. The caller feeds
// every datagram that arrives at UDP 16945 to handle(), calls tick() every
// frame, and sends what the server hands to its Send function. handle(),
// tick() and Engine::render() must not run at the same time (one task, or a
// lock around them).

#pragma once

#include <stddef.h>
#include <stdint.h>

#include <functional>
#include <string>
#include <vector>

#include "engine.h"

namespace lpd {

constexpr uint16_t kVnPort = 16945;
// Fixture records (one fixture in one cue, ~60 bytes in RAM) the box keeps in
// all: what fits next to the rest on the ESP32. The LPU keeps far more.
constexpr size_t kMaxRecords = 3000;

// An IPv4 address (a.b.c.d = a << 24 | ... | d) and a UDP port.
struct Peer {
  uint32_t ip = 0;
  uint16_t port = 0;
  Peer() = default;
  Peer(uint32_t i, uint16_t p) : ip(i), port(p) {}
  bool operator==(const Peer &o) const { return ip == o.ip && port == o.port; }
};
constexpr uint32_t kBroadcast = 0xffffffff;

// What the box tells about itself, and the settings the app changes.
struct VnDevice {
  uint32_t ip = 0;
  uint16_t port = kVnPort;  // ours (another one only on a PC that runs the reference app)
  uint32_t subnet = 0xffffff00;
  uint8_t mac[6] = {0x02, 0x4c, 0x50, 0x44, 0x00, 0x01};  // locally administered
  std::string alias = "LPD-1";
  uint32_t artnetUniverse = 16;  // raw: the app's universe x 16
  bool artnetEnabled = true;
  uint32_t sacnUniverse = 1;
  bool sacnEnabled = false;
  // The address the app set (OPTIONS > IP ADDRESS; FINDINGS 20.18): 0 = DHCP.
  // The box applies them (networkVersion() changes); ip / subnet above are
  // what it has now.
  uint32_t staticIp = 0, staticMask = 0;
};

class VnServer {
 public:
  using Send = std::function<void(const uint8_t *data, size_t len, Peer to)>;

  VnServer(Engine &engine, Send send);

  VnDevice &device() { return dev_; }
  // Per-fixture text the engine does not need (the app shows it).
  struct FixtureInfo {
    std::string name, manufacturer, model, mode, profile;
  };
  FixtureInfo &fixtureInfo(int slot) { return info_[slot]; }

  // A datagram that arrived at UDP 16945 from [from], at [now] ms.
  void handle(const uint8_t *data, size_t len, Peer from, uint32_t now);
  // Every frame: notifications of cue changes (GO, follow, release) and the
  // identify broadcast every second.
  void tick(uint32_t now);

  // Goes up with every change to the show or the device settings (to save
  // them).
  uint32_t showVersion() const { return showVersion_; }
  // Goes up when the app sets the IP address / mask / DHCP.
  uint32_t networkVersion() const { return networkVersion_; }

  // The show, the fixture texts and the device settings (alias, Art-Net,
  // sACN) as one file, and back. loadShow() takes nothing from a file it
  // cannot read completely (returns false; the show is then unchanged).
  std::vector<uint8_t> saveShow() const;
  // The same file in pieces of at most [piece] bytes, for the board: one
  // big buffer (it doubled to 64 kB for a 34 kB show) was more than its
  // heap had in one block - the save crashed it (2026-10-29).
  std::vector<std::vector<uint8_t>> saveShowPieces(size_t piece = 4096) const;
  bool loadShow(const uint8_t *data, size_t len);

 private:
  struct Frame {
    uint8_t op, type, prop;
    uint16_t i1, i2, i3, seq;
    const uint8_t *body;
    size_t len;
  };
  struct ProgAttr {
    uint8_t type = 0x03;
    uint8_t len = 4;
    uint8_t body[10] = {};
  };
  struct Seen {
    Peer peer;
    uint32_t at;
  };

  void send(const std::vector<uint8_t> &d, Peer to) { send_(d.data(), d.size(), to); }
  std::vector<uint8_t> frame(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1, uint16_t i2, uint16_t i3,
                             const uint8_t *body, size_t len, uint16_t seq, bool notification) const;
  void reply(const Frame &f, Peer to, uint8_t type, const uint8_t *body, size_t len);
  void replyU32(const Frame &f, Peer to, uint8_t type, uint32_t v);
  void replyStr(const Frame &f, Peer to, const std::string &s);
  void notify(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1, uint16_t i2, uint16_t i3, const uint8_t *body,
              size_t len);
  void notifyU32(uint8_t op, uint8_t type, uint8_t prop, uint16_t i1, uint32_t v);
  void changed(uint8_t op, uint16_t i1, uint16_t i2, uint32_t code);

  void shortProperty(const uint8_t *data, size_t len, Peer from);
  void request(const Frame &f, const uint8_t *raw, size_t rawLen, Peer from, uint32_t now);
  void write(const Frame &f, uint32_t now);

  std::string identifyXml() const;
  uint32_t fixtureState(int slot) const;
  void playbackState(int pb, uint8_t out[4], uint32_t now);
  std::string definition(int slot) const;
  uint16_t nextAddress(int channels) const;
  void playbackChanged(int pb);
  void announce();
  void readBlock(int pb, int cue, int block, uint8_t out[800]) const;
  bool blockFits(const Frame &f) const;
  void writeBlock(int pb, int cue, int block, const uint8_t *data, size_t len);
  void loadCue(int pb, int cue, uint32_t now);
  void recordCue(int pb, int cue);
  void clearProgrammer();
  void programmerToEngine(int attr, uint32_t now);
  static ProgAttr attrDefault(int attr);

  Engine &engine_;
  Send send_;
  VnDevice dev_;
  FixtureInfo info_[kSlots];
  bool used_[kPlaybacks] = {};  // playbacks the app has written (others read as absent)
  int lastCue_[kPlaybacks];
  uint32_t chooseMode_ = 1, editPb_ = 0;
  uint64_t selection_ = 0;
  ProgAttr attrs_[17];
  bool attrsSet_ = false;
  uint32_t attrMask_ = 0;  // attributes with a value (bit per attribute)
  std::vector<Seen> clients_;
  std::vector<uint32_t> otherLpus_;
  uint32_t nextAnnounce_ = 0;
  uint32_t showVersion_ = 0;
  uint32_t networkVersion_ = 0;
};

}  // namespace lpd
