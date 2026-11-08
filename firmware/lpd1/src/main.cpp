// LPD-1 box, milestones 1-2: the engine on the WT32-ETH01
// with real outputs, and the VN server (lib/vn) so the apps find it (as
// LPD-1, speaking the LPU-1's protocol) and can upload / run a show. Starts with a test show
// (LPD_TEST_SHOW=0 in platformio.ini starts empty, like an LPU).
//  - DMX out on the MAX485 (lib/dmxout; pins from platformio.ini, WLED's
//    default TX GPIO2)
//  - the same frame as Art-Net (broadcast, universe 16 on the wire like the
//    LPU) and sACN (239.255.0.1), each when switched on in the app's
//    OPTIONS (Art-Net is on at first); tool/lpd_capture.dart records them:
//      dart run tool/lpd_capture.dart <box IP> --ch 1-24 [--sacn]
//  - every 10 s on the serial log (115200): the engine's time per frame
// The show and the device settings are saved in LittleFS (/show.bin) 2 s
// after the last change, and loaded at the start; without a saved show the
// test show runs.
//  - firmware updates over the network (ArduinoOTA, UDP 3232; env
//    wt32-eth01-ota in platformio.ini); password LPD_OTA_PASSWORD at build
//    time, none when it is empty

#include <Arduino.h>
#include <ArduinoOTA.h>
#include <AsyncUDP.h>
#include <ESPmDNS.h>
#include <ETH.h>
#include <LittleFS.h>

#include "dmx_out.h"
#include "engine.h"
#include "net_out.h"
#include "vn_server.h"

// WT32-ETH01: LAN8720 at PHY address 1, its oscillator enabled by GPIO16,
// clock in on GPIO0, MDC 23, MDIO 18 (as the DLED bridge)
#define ETH_ADDR 1
#define ETH_POWER_PIN 16
#define ETH_MDC_PIN 23
#define ETH_MDIO_PIN 18

#ifndef LPD_DMX_TX_PIN
#define LPD_DMX_TX_PIN 2
#endif
#ifndef LPD_DMX_EN_PIN
#define LPD_DMX_EN_PIN -1
#endif
#ifndef LPD_TEST_SHOW
#define LPD_TEST_SHOW 1
#endif
#ifndef LPD_OTA_PASSWORD
#define LPD_OTA_PASSWORD ""
#endif

static lpd::Engine engine;
static lpd::DmxOut dmxOut;
static uint8_t dmx[lpd::kUniverse];
static AsyncUDP artnet, vnUdp;
static bool ethUp = false;
// loop() handles the VN frames and the frames; the lock stays for anything
// else that touches the engine (applyNetwork).
static SemaphoreHandle_t engineLock;

// VN packets from the network task to loop()
struct VnPacket {
  uint32_t ip;
  uint16_t port, len;
  uint8_t data[1472];
};
constexpr int kVnQueue = 16;
static QueueHandle_t vnQueue;

// the show to save, from loop() to the saver task
static std::vector<std::vector<uint8_t>> saveBuf;
static SemaphoreHandle_t saveLock;
static TaskHandle_t saver;
static void saverTask(void *);
static volatile bool otaRunning = false;

static void vnSend(const uint8_t *d, size_t n, lpd::Peer to) {
  vnUdp.writeTo(d, n, IPAddress(to.ip >> 24, to.ip >> 16 & 255, to.ip >> 8 & 255, to.ip & 255), to.port);
}
static lpd::VnServer vn(engine, vnSend);

static void handleVn() {
  static VnPacket v;
  while (xQueueReceive(vnQueue, &v, 0) == pdTRUE) {
    xSemaphoreTake(engineLock, portMAX_DELAY);
    vn.handle(v.data, v.len, lpd::Peer{v.ip, v.port}, millis());
    xSemaphoreGive(engineLock);
  }
}

static void onEth(arduino_event_id_t event) {
  switch (event) {
    case ARDUINO_EVENT_ETH_START:
      ETH.setHostname("lpd1");
      break;
    case ARDUINO_EVENT_ETH_GOT_IP: {
      IPAddress ip = ETH.localIP(), mask = ETH.subnetMask();
      vn.device().ip = (uint32_t)ip[0] << 24 | ip[1] << 16 | ip[2] << 8 | ip[3];
      vn.device().subnet = (uint32_t)mask[0] << 24 | mask[1] << 16 | mask[2] << 8 | mask[3];
      uint8_t mac[6];
      ETH.macAddress(mac);
      memcpy(vn.device().mac, mac, 6);
      ethUp = true;
      Serial.printf("Ethernet: %s\n", ETH.localIP().toString().c_str());
      break;
    }
    case ARDUINO_EVENT_ETH_DISCONNECTED:
    case ARDUINO_EVENT_ETH_STOP:
      ethUp = false;
      break;
    default:
      break;
  }
}

// ArtDmx: "Art-Net", OpDmx 0x5000, protocol 14, sequence, physical,
// universe (16 bits LE: the LPU sends 16 for the app's universe 1), length.
// Art-Net (broadcast) and sACN (multicast 239.255.hi.lo), as the device
// settings say (the app's OPTIONS page; lib/netout).
static void sendNetwork() {
  static uint8_t pkt[lpd::kSacnSize];
  static uint8_t artSeq = 0, sacnSeq = 0;
  if (!ethUp) return;
  const lpd::VnDevice &d = vn.device();
  if (d.artnetEnabled) {
    artSeq = artSeq == 255 ? 1 : artSeq + 1;
    size_t n = lpd::artnetPacket(pkt, dmx, d.artnetUniverse, artSeq);
    artnet.broadcastTo(pkt, n, lpd::kArtnetPort);
  }
  if (d.sacnEnabled) {
    uint8_t cid[16] = {'L', 'P', 'D', '1'};
    memcpy(cid + 10, d.mac, 6);
    size_t n = lpd::sacnPacket(pkt, dmx, d.sacnUniverse, sacnSeq++, cid, d.alias.c_str());
    uint32_t g = lpd::sacnGroup(d.sacnUniverse);
    artnet.writeTo(pkt, n, IPAddress(g >> 24, g >> 16 & 255, g >> 8 & 255, g & 255), lpd::kSacnPort);
  }
}

// The test show: 64 fixtures (In pan tilt R G B A W) at 1, 9, 17 ...; pb1
// a Sinus on the intensity (phase spread), pb2 a Circle, pb3 a Rainbow, all
// running. The worst case for the timing is test/test_speed.
static void testShow() {
  lpd::Show &show = engine.show();
  for (int i = 0; i < lpd::kSlots; i++) {
    lpd::Fixture &f = show.fixtures[i];
    f.patched = true;
    f.address = 1 + 8 * i;
    f.count = 8;
    for (int c = 0; c < 8; c++) f.codes[c] = c + 1;
    lpd::VnServer::FixtureInfo &info = vn.fixtureInfo(i);  // what the app shows
    info.manufacturer = "LPD-1";
    info.model = "Test";
    info.mode = "8 ch";
    info.profile = "0102030405060708";
  }
  for (int g = 0; g < 3; g++) {
    lpd::Cue cue;
    for (int i = 0; i < lpd::kSlots; i++) {
      lpd::Record r{(uint8_t)i, {}};
      static const uint8_t waves[3] = {1, 6, 10};  // Sinus, Circle, Rainbow
      r.bytes[4 * g] = waves[g];
      r.bytes[4 * g + 1] = 255;               // size 100 %
      r.bytes[4 * g + 2] = 32;                // speed 25 %
      r.bytes[4 * g + 3] = (uint8_t)(i * 4);  // phase spread
      if (g == 0) r.bytes[16] = 0xff, r.bytes[17] = 0xff;  // intensity 100 %
      cue.records.push_back(r);
    }
    show.playbacks[g].cues.push_back(cue);
    engine.go(g, millis());
  }
}

static void applyNetwork();

void setup() {
  Serial.begin(115200);
  dmxOut.begin(LPD_DMX_TX_PIN, LPD_DMX_EN_PIN);
  WiFi.onEvent(onEth);
  ETH.begin(ETH_ADDR, ETH_POWER_PIN, ETH_MDC_PIN, ETH_MDIO_PIN, ETH_PHY_LAN8720, ETH_CLOCK_GPIO0_IN);
  MDNS.begin("lpd1");
  ArduinoOTA.setHostname("lpd1");
  ArduinoOTA.setMdnsEnabled(false);  // MDNS runs already
  if (strlen(LPD_OTA_PASSWORD)) ArduinoOTA.setPassword(LPD_OTA_PASSWORD);
  ArduinoOTA.onStart([] {
    otaRunning = true;  // no show saves while the new firmware is written
    Serial.println("OTA: update started");
  });
  ArduinoOTA.onEnd([] { Serial.println("OTA: done, restarting"); });
  ArduinoOTA.onError([](ota_error_t e) {
    otaRunning = false;
    Serial.printf("OTA: error %u\n", (unsigned)e);
  });
  ArduinoOTA.begin();
  engineLock = xSemaphoreCreateMutex();
  saveLock = xSemaphoreCreateMutex();
  xTaskCreatePinnedToCore(saverTask, "save", 8192, nullptr, 0, &saver, 0);  // priority 0: below loop(); LittleFS needs the stack
  vnUdp.listen(lpd::kVnPort);
  // The network task only queues the packet: its stack (4 kB) is too small
  // for the engine (a GO / RELEASE over the network crashed the board,
  // 2026-10-28); loop() handles it within a millisecond.
  vnQueue = xQueueCreate(kVnQueue, sizeof(VnPacket));
  vnUdp.onPacket([](AsyncUDPPacket &p) {
    if (p.length() > sizeof(VnPacket::data)) return;
    static VnPacket v;  // one network task: no other caller
    IPAddress ip = p.remoteIP();
    v.ip = (uint32_t)ip[0] << 24 | ip[1] << 16 | ip[2] << 8 | ip[3];
    v.port = p.remotePort();
    v.len = p.length();
    memcpy(v.data, p.data(), v.len);
    xQueueSend(vnQueue, &v, 0);  // full: dropped, like a lost datagram
  });
  bool loaded = false;
  if (LittleFS.begin(true)) {  // formats the partition the first time
    File f = LittleFS.open("/show.bin", "r");
    if (f) {
      std::vector<uint8_t> d(f.size());
      f.read(d.data(), d.size());
      f.close();
      loaded = vn.loadShow(d.data(), d.size());
      Serial.printf("saved show: %s (%u bytes)\n", loaded ? "loaded" : "NOT readable", (unsigned)d.size());
    }
  } else {
    Serial.println("LittleFS: no file system, the show is not saved");
  }
  if (!loaded && LPD_TEST_SHOW) testShow();
  // Background playbacks start by themselves at power-up (the manual)
  for (int pb = 0; loaded && pb < lpd::kPlaybacks; pb++) {
    const lpd::Playback &p = engine.show().playbacks[pb];
    if (p.background && !p.cues.empty()) engine.go(pb, millis());
  }
  if (vn.device().staticIp) applyNetwork();
  Serial.printf("LPD-1: VN server on UDP 16945, test show %s, DMX TX GPIO%d (enable %d), Art-Net universe %u\n",
                !loaded && LPD_TEST_SHOW ? "running" : "off", LPD_DMX_TX_PIN, LPD_DMX_EN_PIN,
                (unsigned)vn.device().artnetUniverse);
}

// The address the app set: static (gateway x.x.x.1) or DHCP (staticIp 0).
// The LPU moves at once, without a restart; so does the box.
static void applyNetwork() {
  const lpd::VnDevice &d = vn.device();
  auto ipOf = [](uint32_t v) { return IPAddress(v >> 24, v >> 16 & 255, v >> 8 & 255, v & 255); };
  if (d.staticIp) {
    uint32_t mask = d.staticMask ? d.staticMask : 0xffffff00;
    ETH.config(ipOf(d.staticIp), ipOf((d.staticIp & mask) | 1), ipOf(mask));
    xSemaphoreTake(engineLock, portMAX_DELAY);
    vn.device().ip = d.staticIp;
    vn.device().subnet = mask;
    xSemaphoreGive(engineLock);
    Serial.printf("static address %s\n", ipOf(d.staticIp).toString().c_str());
  } else {
    ETH.config(INADDR_NONE, INADDR_NONE, INADDR_NONE);  // DHCP again
    Serial.println("DHCP");
  }
}

// Save the show 2 s after the last change (an upload is hundreds of writes).
static void saveWhenQuiet(uint32_t now) {
  static uint32_t saved = 0, seen = 0, changedAt = 0;
  uint32_t v = vn.showVersion();
  if (v == saved) return;
  if (v != seen) {
    seen = v;
    changedAt = now;
    return;
  }
  if (now - changedAt < 2000 || otaRunning) return;
  xSemaphoreTake(engineLock, portMAX_DELAY);
  std::vector<std::vector<uint8_t>> d = vn.saveShowPieces();  // no big block (vn_server.h)
  xSemaphoreGive(engineLock);
  xSemaphoreTake(saveLock, portMAX_DELAY);
  saveBuf.swap(d);  // the newest show; the saver takes it when it gets to it
  xSemaphoreGive(saveLock);
  xTaskNotifyGive(saver);
  saved = v;
}

// Writing the flash takes some 100 ms (the first GO after an upload came
// 0.6 s late while loop() saved, 2026-10-28): a task of its own, below loop().
static void saverTask(void *) {
  for (;;) {
    ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
    std::vector<std::vector<uint8_t>> d;
    xSemaphoreTake(saveLock, portMAX_DELAY);
    d.swap(saveBuf);
    xSemaphoreGive(saveLock);
    if (d.empty()) continue;
    File f = LittleFS.open("/show.tmp", "w");
    bool ok = (bool)f;
    size_t total = 0;
    for (const auto &p : d) {
      ok = ok && f.write(p.data(), p.size()) == p.size();
      total += p.size();
    }
    if (f) f.close();
    ok = ok && LittleFS.rename("/show.tmp", "/show.bin");
    Serial.printf("show %s (%u bytes)\n", ok ? "saved" : "NOT saved", (unsigned)total);
  }
}

void loop() {
  static uint32_t next = 0, frames = 0, renderUs = 0, maxUs = 0;
  ArduinoOTA.handle();
  handleVn();
  uint32_t now = millis();
  if ((int32_t)(now - next) < 0) {
    delay(1);
    return;
  }
  next = now + 25;  // 40 frames / s
  xSemaphoreTake(engineLock, portMAX_DELAY);
  vn.tick(now);
  uint32_t t0 = micros();
  engine.render(now, dmx);
  uint32_t us = micros() - t0;
  xSemaphoreGive(engineLock);
  renderUs += us;
  if (us > maxUs) maxUs = us;
  dmxOut.send(dmx);
  sendNetwork();
  saveWhenQuiet(now);
  // the app's IP ADDRESS dialog: IP and mask come as two writes, in either
  // order (FINDINGS 20.18); act 200 ms after the last one
  static uint32_t netSeen = 0, netAt = 0;
  if (vn.networkVersion() != netSeen) {
    if (!netAt) netAt = now;
    if (now - netAt >= 200) {
      netSeen = vn.networkVersion();
      netAt = 0;
      applyNetwork();
    }
  }
  if (++frames % 400 == 0) {
    Serial.printf("render: %lu us per frame (max %lu), ch1 %u, heap %u kB\n",
                  (unsigned long)(renderUs / 400), (unsigned long)maxUs, dmx[0],
                  (unsigned)(ESP.getFreeHeap() / 1024));
    renderUs = maxUs = 0;
  }
}
