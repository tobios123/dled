// LPD-1 on the PC: the VN server and the
// engine as a Windows program, so the reference app and our tools can use the
// LPD-1 without the board.
//
//   python -m platformio run -e pc
//   .pio/build/pc/program.exe [--port 16945] [--bind IP] [--ip IP] [--artnet IP] [--sacn IP]
//                             [--alias NAME] [--show-file FILE]
//
// UDP 16945 is also what the reference app (and the LPU's own
// Programmer) listen on: on a PC that runs one of them use another port, e.g.
// --port 26945 --bind 127.0.0.1, and give the tools the same port.
// --artnet IP / --sacn IP send the DMX as Art-Net / sACN (universe and on /
// off as the device settings) to that address, e.g. 127.0.0.1 for
// tool/lpd_capture.dart on this PC.
// --show-file FILE keeps the show there like the board keeps it in LittleFS
// (loaded at the start, saved 2 s after the last change).

#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmsystem.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <chrono>
#include <string>
#include <vector>

#include "engine.h"
#include "net_out.h"
#include "vn_server.h"

namespace {

uint32_t nowMs() {
  using namespace std::chrono;
  static const steady_clock::time_point t0 = steady_clock::now();
  return (uint32_t)duration_cast<milliseconds>(steady_clock::now() - t0).count();
}

uint32_t parseIp(const char *s) {
  in_addr a{};
  inet_pton(AF_INET, s, &a);
  return ntohl(a.s_addr);
}

// This PC's address on the LAN (the one a route to the LAN would use).
uint32_t localIp() {
  SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
  sockaddr_in to{};
  to.sin_family = AF_INET;
  to.sin_port = htons(1);
  to.sin_addr.s_addr = htonl(parseIp("192.168.255.255"));
  uint32_t ip = parseIp("127.0.0.1");
  if (connect(s, (sockaddr *)&to, sizeof to) == 0) {
    sockaddr_in me{};
    int n = sizeof me;
    if (getsockname(s, (sockaddr *)&me, &n) == 0) ip = ntohl(me.sin_addr.s_addr);
  }
  closesocket(s);
  return ip;
}

}  // namespace

int main(int argc, char **argv) {
  int port = lpd::kVnPort;
  std::string bind = "0.0.0.0", announce, artnetTo, alias = "LPD-1", showFile, sacnTo_;
  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    auto next = [&]() -> std::string { return i + 1 < argc ? argv[++i] : ""; };
    if (a == "--port") port = atoi(next().c_str());
    else if (a == "--bind") bind = next();
    else if (a == "--ip") announce = next();
    else if (a == "--artnet") artnetTo = next();
    else if (a == "--sacn") sacnTo_ = next();
    else if (a == "--alias") alias = next();
    else if (a == "--show-file") showFile = next();
    else {
      fprintf(stderr, "usage: program [--port N] [--bind IP] [--ip IP] [--artnet IP] [--sacn IP] [--alias NAME] [--show-file FILE]\n");
      return 2;
    }
  }
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  timeBeginPeriod(1);  // 1 ms timer: without it the 25 ms frames jitter by ~15 ms
  SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  BOOL yes = TRUE;
  setsockopt(sock, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof yes);
  sockaddr_in me{};
  me.sin_family = AF_INET;
  me.sin_port = htons(port);
  me.sin_addr.s_addr = htonl(parseIp(bind.c_str()));
  if (::bind(sock, (sockaddr *)&me, sizeof me) != 0) {
    fprintf(stderr, "UDP %s:%d is taken (the reference app or the reference app?): use --port\n", bind.c_str(), port);
    return 1;
  }
  // Windows reports an ICMP "port unreachable" as an error on the next
  // receive (WSAECONNRESET); a gone client must not stop the server
  BOOL no = FALSE;
  DWORD ret = 0;
  WSAIoctl(sock, _WSAIOW(IOC_VENDOR, 12), &no, sizeof no, nullptr, 0, &ret, nullptr, nullptr);

  static lpd::Engine engine;
  auto sendTo = [&](const uint8_t *d, size_t n, lpd::Peer to) {
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(to.port);
    a.sin_addr.s_addr = htonl(to.ip);
    sendto(sock, (const char *)d, (int)n, 0, (sockaddr *)&a, sizeof a);
  };
  lpd::VnServer vn(engine, sendTo);
  vn.device().ip = announce.empty() ? (bind == "0.0.0.0" ? localIp() : parseIp(bind.c_str())) : parseIp(announce.c_str());
  vn.device().alias = alias;
  vn.device().port = port;
  if (!showFile.empty()) {
    if (FILE *f = fopen(showFile.c_str(), "rb")) {
      std::vector<uint8_t> d;
      uint8_t chunk[4096];
      size_t n;
      while ((n = fread(chunk, 1, sizeof chunk, f)) > 0) d.insert(d.end(), chunk, chunk + n);
      fclose(f);
      bool ok = vn.loadShow(d.data(), d.size());
      printf("saved show %s: %s (%u bytes)\n", showFile.c_str(), ok ? "loaded" : "NOT readable", (unsigned)d.size());
    }
  }
  uint32_t saved = vn.showVersion(), seen = saved, changedAt = 0;
  auto saveWhenQuiet = [&](uint32_t now) {
    uint32_t v = vn.showVersion();
    if (showFile.empty() || v == saved) return;
    if (v != seen) {
      seen = v, changedAt = now;
      return;
    }
    if (now - changedAt < 2000) return;
    std::vector<uint8_t> d = vn.saveShow();
    std::string tmp = showFile + ".tmp";
    FILE *f = fopen(tmp.c_str(), "wb");
    bool ok = f && fwrite(d.data(), 1, d.size(), f) == d.size();
    if (f) fclose(f);
    ok = ok && MoveFileExA(tmp.c_str(), showFile.c_str(), MOVEFILE_REPLACE_EXISTING);
    printf("show %s (%u bytes)\n", ok ? "saved" : "NOT saved", (unsigned)d.size());
    fflush(stdout);
    saved = v;
  };
  bool loopbackOnly = bind == "127.0.0.1";

  // Art-Net / sACN out: one socket, to the addresses given (unicast; the
  // board broadcasts Art-Net and sends sACN to its multicast group)
  SOCKET out = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  setsockopt(out, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof yes);
  auto dest = [](const std::string &ip, uint16_t p) {
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_port = htons(p);
    a.sin_addr.s_addr = htonl(parseIp(ip.c_str()));
    return a;
  };
  sockaddr_in artTo = dest(artnetTo, lpd::kArtnetPort), sacnTo = dest(sacnTo_, lpd::kSacnPort);

  char ipText[16];
  uint32_t ip = vn.device().ip;
  snprintf(ipText, sizeof ipText, "%u.%u.%u.%u", ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255);
  printf("LPD-1 (PC) on UDP %s:%d, announced as %s%s%s\n", bind.c_str(), port, ipText,
         artnetTo.empty() ? "" : ", Art-Net to ", artnetTo.c_str());
  fflush(stdout);

  uint8_t dmx[lpd::kUniverse];
  uint8_t buf[2048];
  uint8_t pkt[lpd::kSacnSize];
  uint8_t artSeq = 0, sacnSeq = 0;
  const uint8_t cid[16] = {'L', 'P', 'D', '1', 'P', 'C'};
  uint32_t next = nowMs();
  while (true) {
    uint32_t now = nowMs();
    int32_t wait = (int32_t)(next - now);
    if (wait > 0) {
      fd_set rd;
      FD_ZERO(&rd);
      FD_SET(sock, &rd);
      timeval tv{0, wait * 1000};
      if (select(0, &rd, nullptr, nullptr, &tv) > 0) {
        sockaddr_in from{};
        int fl = sizeof from;
        int n = recvfrom(sock, (char *)buf, sizeof buf, 0, (sockaddr *)&from, &fl);
        if (n > 0) {
          lpd::Peer p{ntohl(from.sin_addr.s_addr), ntohs(from.sin_port)};
          vn.handle(buf, n, p, nowMs());
        }
      }
      continue;
    }
    next += 25;  // 40 frames / s
    if ((int32_t)(now - next) > 250) next = now + 25;  // after a stall
    if (!loopbackOnly) vn.tick(now);
    else {
      // no identify broadcasts when only this PC may talk to it
      uint32_t ipSave = vn.device().ip;
      vn.device().ip = 0;
      vn.tick(now);
      vn.device().ip = ipSave;
    }
    engine.render(now, dmx);
    saveWhenQuiet(now);
    const lpd::VnDevice &d = vn.device();
    if (!artnetTo.empty() && d.artnetEnabled) {
      artSeq = artSeq == 255 ? 1 : artSeq + 1;
      size_t n = lpd::artnetPacket(pkt, dmx, d.artnetUniverse, artSeq);
      sendto(out, (const char *)pkt, (int)n, 0, (sockaddr *)&artTo, sizeof artTo);
    }
    if (!sacnTo_.empty() && d.sacnEnabled) {
      size_t n = lpd::sacnPacket(pkt, dmx, d.sacnUniverse, sacnSeq++, cid, d.alias.c_str());
      sendto(out, (const char *)pkt, (int)n, 0, (sockaddr *)&sacnTo, sizeof sacnTo);
    }
  }
}
