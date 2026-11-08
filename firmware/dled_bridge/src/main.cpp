// DLED bridge firmware -- WT32-ETH01 (classic ESP32 + LAN8720, 4 MB).
//
// Does what dled_flutter/bin/dled_bridge.dart does on a PC:
//  - serves the light DLED page from LittleFS (gzipped files, as built by
//    tool/build_light.dart; the browser unpacks them)
//  - WebSocket /vn: a binary message is one datagram
//      [channel u8 1-255] [IPv4 4 bytes] [port u16 big-endian] [datagram]
//    browser -> box: send it as UDP from that channel's socket; box ->
//    browser: what arrived at the channel's socket, with the sender's address.
//    0.0.0.0:0 without a datagram closes the channel.
//    box -> browser may also be several datagrams in one message (it writes
//    the frames itself, see flushPages()):
//      [0] then per datagram [length u16 big-endian] [channel] [IPv4] [port] [datagram]
//    (the length counts from the channel byte). The relay runs in loop()
//    (see relay()).
//  - sends at least 0.5 ms apart, of all pages together (the LPU drops answers to
//    requests that arrive back to back, FINDINGS 20.16); a broadcast to
//    255.255.255.255 also goes to this network's broadcast address.
// Show files (the light page's OPTIONS), as /shows/NAME.show in LittleFS -
// the same API as the PC bridge:
//   GET /api/shows (list), GET / PUT / DELETE /api/shows/NAME,
//   POST /api/shows/NAME?to=NEW (rename).
// Updates over the network (after one serial flash with this code):
//  - firmware: ArduinoOTA (UDP 3232, no password, like the LPD-1), env
//    wt32-eth01-ota in platformio.ini
//  - the page: PUT /api/page/NAME (upload_page.py) writes one page file
//    (index.html.gz, core.js.gz, icon-192.png ...) and leaves /shows alone.
//    Not `uploadfs`: that replaces the whole file system, saved shows too.
// Open http://dled.local (or the IP shown on the serial log) in a browser.

#include <Arduino.h>
#include <ArduinoOTA.h>
#include <AsyncUDP.h>
#include <ESPAsyncWebServer.h>
#include <ESPmDNS.h>
#include <ETH.h>
#include <LittleFS.h>

#include <map>
#include <vector>

// WT32-ETH01: LAN8720 at PHY address 1, its oscillator enabled by GPIO16,
// clock in on GPIO0, MDC 23, MDIO 18.
#define ETH_ADDR 1
#define ETH_POWER_PIN 16
#define ETH_MDC_PIN 23
#define ETH_MDIO_PIN 18

static AsyncWebServer server(80);
static AsyncWebSocket ws("/vn");
static bool ethUp = false;

// The relay runs in loop(), never in the web server's task (async_tcp) or the
// UDP task: those only hand messages over through two queues. Sending a
// datagram (with its 0.5 ms pacing) inside async_tcp, while the UDP task
// pushed replies into the web socket, blocked both until the watchdog reset
// the board. Replies are collected per page (see flushPages()).
struct Msg {
  uint32_t client;
  uint8_t *data; // page: [ch][ip][port][datagram]; nullptr = the page left
  size_t len;
  int64_t at; // when it arrived (esp_timer, us); answers only
};
static QueueHandle_t fromPages, toPages;
// loop() sleeps until a message is queued (a task notification from the
// sender): a fixed delay(1) per round made a show download 6x slower than
// the Windows app (every request waited up to 1 ms twice, 761 requests)
static TaskHandle_t loopTask;
static inline void wakeLoop() { xTaskNotifyGive(loopTask); }

// Serial log (statsTick): every 5 s while a page is connected, one line per
// page and one for the box. The UDP / async_tcp tasks only increment their
// counters; loop() reads them (32-bit, no lock needed).
struct PageStats {
  uint32_t up = 0, down = 0, pageFull = 0; // datagrams to / from the LPU; dropped: page too slow
  uint32_t messages = 0;                   // WebSocket messages sent (several datagrams each)
  // the LPU leg: request sent by the box -> its answer at the box
  uint32_t answers = 0, unanswered = 0;    // unanswered: no answer within 1 s
  int64_t lpuSum = 0, lpuMax = 0;          // us
  // the box: answer arrived -> written into the page's connection
  uint32_t held = 0;
  int64_t holdSum = 0, holdMax = 0; // us
};
static std::map<uint32_t, PageStats> stats; // loop() only
// replies collected per page (batches) and the WebSocket frame being
// written to the page's TCP connection (out, from out_at); loop() only
static std::map<uint32_t, std::vector<uint8_t>> batches;
struct Out {
  std::vector<uint8_t> frame;
  size_t at = 0;
  std::vector<int64_t> arrived; // when the answers in the frame arrived
  bool busy() const { return at < frame.size(); }
};
static std::map<uint32_t, std::vector<int64_t>> batchArrived; // per batch, like Out::arrived
static std::map<uint32_t, Out> outs;
static const size_t maxBatch = 24 * 1024;
static void flushPages();
static volatile uint32_t dropToPages = 0, dropFromPages = 0, dropNoMemory = 0;

// One UDP socket per (page, channel); only loop() touches them.
struct Channel {
  AsyncUDP *udp = nullptr;
  // requests waiting for their answer: key (see frameKey) -> sent at (us)
  std::map<uint64_t, int64_t> waiting;
};

// A VN frame's object, property and indexes as one number: an answer (reply
// or echo) has the same key as its request (lpu_client.dart matches them so).
// 0 = not a request / answer (short, a notification, a keepalive).
static uint64_t frameKey(const uint8_t *d, size_t n) {
  if (n < 20 || (d[1] & 0x80) || d[10] != 0xff || d[11] != 0xff) return 0;
  uint64_t i1 = d[4] | d[5] << 8, i2 = d[6] | d[7] << 8, i3 = d[8] | d[9] << 8;
  return (uint64_t)d[0] | (uint64_t)d[2] << 8 | i1 << 16 | i2 << 32 | i3 << 48;
}
static std::map<uint32_t, std::map<uint8_t, Channel>> channels; // client id -> channel -> socket

static void closeChannel(uint32_t client, uint8_t ch) {
  auto c = channels.find(client);
  if (c == channels.end()) return;
  auto it = c->second.find(ch);
  if (it == c->second.end()) return;
  it->second.udp->close();
  delete it->second.udp;
  c->second.erase(it);
}

static void closeClient(uint32_t client) {
  auto c = channels.find(client);
  if (c == channels.end()) return;
  for (auto &e : c->second) {
    e.second.udp->close();
    delete e.second.udp;
  }
  channels.erase(c);
}

static Channel *openChannel(uint32_t client, uint8_t ch) {
  Channel &c = channels[client][ch];
  if (c.udp) return &c;
  c.udp = new AsyncUDP();
  if (!c.udp->listen(0)) { // a free local port; broadcast is allowed
    delete c.udp;
    channels[client].erase(ch);
    Serial.printf("page %u: channel %u: no UDP socket\n", client, ch);
    return nullptr;
  }
  Serial.printf("page %u: channel %u open\n", client, ch);
  c.udp->onPacket([client, ch](AsyncUDPPacket &p) {
    // UDP task: copy it as [ch][ip][port][data] for loop(); dropped when
    // the queue is full (the LPU protocol asks again)
    size_t n = p.length();
    uint8_t *m = (uint8_t *)malloc(7 + n);
    if (!m) {
      dropNoMemory++;
      return;
    }
    IPAddress ip = p.remoteIP();
    m[0] = ch;
    for (int i = 0; i < 4; i++) m[1 + i] = ip[i];
    m[5] = p.remotePort() >> 8;
    m[6] = p.remotePort() & 0xff;
    memcpy(m + 7, p.data(), n);
    Msg msg{client, m, 7 + n, esp_timer_get_time()};
    if (xQueueSend(toPages, &msg, 0) != pdTRUE) {
      free(m);
      dropToPages++;
    } else {
      wakeLoop();
    }
  });
  return &c;
}

// One spacing for everything the box sends, not per page: with two pages
// (or a page's keepalive next to another's requests) their datagrams could
// reach the LPU back to back, and it dropped the answers (resends).
static int64_t lastSendUs = -1000000;

static void sendPaced(Channel *c, const uint8_t *data, size_t n, IPAddress ip, uint16_t port) {
  int64_t wait = lastSendUs + 500 - esp_timer_get_time();
  if (wait > 0) delayMicroseconds((uint32_t)wait);
  c->udp->writeTo(data, n, ip, port);
  lastSendUs = esp_timer_get_time();
}

// page -> UDP (loop)
static void fromPage(uint32_t client, const uint8_t *m, size_t len) {
  if (len < 7) return;
  uint8_t ch = m[0];
  IPAddress ip(m[1], m[2], m[3], m[4]);
  uint16_t port = (m[5] << 8) | m[6];
  const uint8_t *data = m + 7;
  size_t n = len - 7;
  if (ip == IPAddress(0, 0, 0, 0) && port == 0 && n == 0) {
    closeChannel(client, ch);
    Serial.printf("page %u: channel %u closed\n", client, ch);
  } else if (Channel *c = openChannel(client, ch)) {
    stats[client].up++;
    sendPaced(c, data, n, ip, port);
    if (uint64_t k = frameKey(data, n)) c->waiting[k] = esp_timer_get_time();
    if (ip == IPAddress(255, 255, 255, 255) && ethUp) {
      IPAddress own = ETH.localIP(), mask = ETH.subnetMask();
      IPAddress bc(own[0] | ~mask[0], own[1] | ~mask[1], own[2] | ~mask[2], own[3] | ~mask[3]);
      sendPaced(c, data, n, bc, port);
    }
  }
}

// async_tcp task: only copy the message for loop()
static void onWs(AsyncWebSocket *, AsyncWebSocketClient *client, AwsEventType type, void *arg, uint8_t *data,
                 size_t len) {
  if (type == WS_EVT_CONNECT) {
    // the replies are small and many: send each at once, no Nagle delay
    if (client->client()) client->client()->setNoDelay(true);
    Serial.printf("page %u connected from %s\n", client->id(), client->remoteIP().toString().c_str());
  } else if (type == WS_EVT_DISCONNECT) {
    Msg msg{client->id(), nullptr, 0, 0};
    xQueueSend(fromPages, &msg, portMAX_DELAY); // must not get lost: closes its sockets
    wakeLoop();
    Serial.printf("page %u left\n", client->id());
  } else if (type == WS_EVT_DATA) {
    auto *info = (AwsFrameInfo *)arg;
    // one datagram per message, always small enough for one frame
    if (!(info->final && info->index == 0 && info->len == len && info->opcode == WS_BINARY)) return;
    uint8_t *m = (uint8_t *)malloc(len);
    if (!m) {
      dropNoMemory++;
      return;
    }
    memcpy(m, data, len);
    Msg msg{client->id(), m, len, 0};
    if (xQueueSend(fromPages, &msg, 0) != pdTRUE) {
      free(m);
      dropFromPages++;
    } else {
      wakeLoop();
    }
  }
}

static void relay() {
  Msg msg;
  while (xQueueReceive(fromPages, &msg, 0) == pdTRUE) {
    if (msg.data) {
      fromPage(msg.client, msg.data, msg.len);
      free(msg.data);
    } else {
      closeClient(msg.client);
      stats.erase(msg.client);
      batches.erase(msg.client);
      batchArrived.erase(msg.client);
      outs.erase(msg.client);
    }
  }
  // replies: collected per page, then sent (see flushPages)
  while (xQueueReceive(toPages, &msg, 0) == pdTRUE) {
    if (channels.count(msg.client)) {
      // the LPU leg: the answer's request, sent on this channel
      auto &chs = channels[msg.client];
      auto ch = chs.find(msg.data[0]);
      uint64_t k = msg.len > 7 ? frameKey(msg.data + 7, msg.len - 7) : 0;
      if (k && ch != chs.end()) {
        auto w = ch->second.waiting.find(k);
        if (w != ch->second.waiting.end()) {
          PageStats &st = stats[msg.client];
          int64_t t = msg.at - w->second;
          st.answers++;
          st.lpuSum += t;
          if (t > st.lpuMax) st.lpuMax = t;
          ch->second.waiting.erase(w);
        }
      }
      std::vector<uint8_t> &b = batches[msg.client];
      if (b.size() + 2 + msg.len > maxBatch) {
        stats[msg.client].pageFull++; // a page that does not keep up misses it (the LPU code asks again)
      } else {
        if (b.empty()) b.push_back(0); // several datagrams in one message
        b.push_back(msg.len >> 8);
        b.push_back(msg.len & 0xff);
        b.insert(b.end(), msg.data, msg.data + msg.len);
        batchArrived[msg.client].push_back(msg.at);
        stats[msg.client].down++;
      }
    }
    free(msg.data);
  }
  flushPages();
}

// Replies are written as WebSocket frames straight into the page's TCP
// connection, as much as its send buffer takes; the rest follows when TCP
// has room again. The WebSocket library's own queue sends one message per
// round trip and only lets go of a message at its next event: a burst of
// replies (a show download reads 16 at once) went out one per 20 ms or
// slower (6x slower than the Windows app). While a frame is still being
// written, new replies collect in one batch, which becomes the next frame.
// A page that does not keep up only holds up itself.
static void frameFrom(std::vector<uint8_t> &batch, Out &out) {
  size_t n = batch.size();
  out.frame.clear();
  out.at = 0;
  out.frame.push_back(0x82); // final frame, binary
  if (n < 126) {
    out.frame.push_back(n);
  } else if (n < 65536) {
    out.frame.push_back(126);
    out.frame.push_back(n >> 8);
    out.frame.push_back(n & 0xff);
  } else {
    out.frame.push_back(127);
    for (int i = 7; i >= 0; i--) out.frame.push_back(i >= 4 ? 0 : (n >> (8 * i)) & 0xff);
  }
  out.frame.insert(out.frame.end(), batch.begin(), batch.end());
  batch.clear();
}

void flushPages() {
  for (auto it = batches.begin(); it != batches.end();) {
    uint32_t id = it->first;
    AsyncWebSocketClient *c = ws.client(id);
    AsyncClient *tcp = c ? c->client() : nullptr;
    if (!tcp || !channels.count(id) || c->status() != WS_CONNECTED) {
      outs.erase(id); // the page left
      it = batches.erase(it);
      continue;
    }
    Out &out = outs[id];
    if (!out.busy() && !it->second.empty()) {
      frameFrom(it->second, out);
      out.arrived.swap(batchArrived[id]);
      batchArrived[id].clear();
      stats[id].messages++;
    }
    if (out.busy()) {
      size_t n = tcp->add((const char *)out.frame.data() + out.at, out.frame.size() - out.at);
      if (n) {
        out.at += n;
        tcp->send();
      }
      if (!out.busy()) { // all written: how long its answers were held here
        PageStats &st = stats[id];
        int64_t now = esp_timer_get_time();
        for (int64_t a : out.arrived) {
          st.held++;
          st.holdSum += now - a;
          if (now - a > st.holdMax) st.holdMax = now - a;
        }
        out.arrived.clear();
      }
    }
    ++it;
  }
}

static bool pagesWaiting() {
  for (auto &b : batches)
    if (!b.second.empty() || outs[b.first].busy()) return true;
  return false;
}

// Every 5 s while a page is connected, for example:
//   page 3 (192.168.1.171): up 41/s down 40/s in 12 messages/s, page full 0
//     lpu: 812 answers, avg 1.2 ms, max 6.3 ms, unanswered 0; hold: avg 0.4 ms, max 3.1 ms
// lpu = request sent by the box -> answer at the box; unanswered = none in
// 1 s; hold = answer at the box -> written into the page's connection.
//   box: 2 pages, 4 channels; queue drops to pages 0 from pages 0, no memory 0;
//        queued 0/256 0/128; free heap 143 kB (lowest 98 kB)
// "page full" climbing = that page cannot keep up (it misses messages).
static void statsTick() {
  static uint32_t last = 0;
  static std::map<uint32_t, PageStats> before;
  if (millis() - last < 5000) return;
  float secs = (millis() - last) / 1000.0f;
  last = millis();
  if (ws.count() == 0) return;
  size_t open = 0;
  for (auto &c : channels) open += c.second.size();
  // requests without an answer for 1 s count as unanswered
  int64_t now = esp_timer_get_time();
  for (auto &c : channels) {
    for (auto &ch : c.second) {
      for (auto w = ch.second.waiting.begin(); w != ch.second.waiting.end();) {
        if (now - w->second > 1000000) {
          stats[c.first].unanswered++;
          w = ch.second.waiting.erase(w);
        } else {
          ++w;
        }
      }
    }
  }
  for (auto &e : stats) {
    PageStats &b = before[e.first], &s = e.second;
    AsyncWebSocketClient *c = ws.client(e.first);
    uint32_t answers = s.answers - b.answers, held = s.held - b.held;
    Serial.printf("page %u (%s): up %.0f/s down %.0f/s in %.0f messages/s, page full %u\n", e.first,
                  c ? c->remoteIP().toString().c_str() : "gone", (s.up - b.up) / secs, (s.down - b.down) / secs,
                  (s.messages - b.messages) / secs, (unsigned)(s.pageFull - b.pageFull));
    Serial.printf("  lpu: %u answers, avg %.1f ms, max %.1f ms, unanswered %u; hold: avg %.1f ms, max %.1f ms\n",
                  (unsigned)answers, answers ? (s.lpuSum - b.lpuSum) / 1000.0 / answers : 0.0, s.lpuMax / 1000.0,
                  (unsigned)(s.unanswered - b.unanswered), held ? (s.holdSum - b.holdSum) / 1000.0 / held : 0.0,
                  s.holdMax / 1000.0);
    s.lpuMax = s.holdMax = 0; // the maximum of these 5 s
    b = s;
  }
  for (auto it = before.begin(); it != before.end();) it = stats.count(it->first) ? std::next(it) : before.erase(it);
  Serial.printf("box: %u pages, %u channels; queue drops to pages %u from pages %u, no memory %u; "
                "queued %u/256 %u/128; free heap %u kB (lowest %u kB)\n",
                (unsigned)ws.count(), (unsigned)open, (unsigned)dropToPages, (unsigned)dropFromPages,
                (unsigned)dropNoMemory, (unsigned)uxQueueMessagesWaiting(toPages),
                (unsigned)uxQueueMessagesWaiting(fromPages), (unsigned)(ESP.getFreeHeap() / 1024),
                (unsigned)(ESP.getMinFreeHeap() / 1024));
}

// --- show files ---------------------------------------------------------------

static String showPath(const String &name) {
  if (name.isEmpty() || name.length() > 64 || name.startsWith(".")) return "";
  for (char c : name) {
    if (c == 0 || strchr("\\/:*?\"<>|", c)) return "";
  }
  return "/shows/" + name + ".show";
}

// "/api/shows/My%20show" -> "My show"
static String showName(AsyncWebServerRequest *r) {
  String url = r->url();
  return r->urlDecode(url.substring(url.lastIndexOf('/') + 1));
}

static void listShows(AsyncWebServerRequest *r) {
  String out = "[";
  File dir = LittleFS.open("/shows");
  for (File f = dir.openNextFile(); f; f = dir.openNextFile()) {
    String n = f.name();
    if (!n.endsWith(".show")) continue;
    n = n.substring(n.lastIndexOf('/') + 1);
    n = n.substring(0, n.length() - 5);
    n.replace("\\", "\\\\");
    n.replace("\"", "\\\"");
    if (out.length() > 1) out += ",";
    out += "{\"name\":\"" + n + "\",\"size\":" + String(f.size()) + ",\"modified\":" + String((uint64_t)f.getLastWrite() * 1000) + "}";
  }
  r->send(200, "application/json", out + "]");
}

static void showRequest(AsyncWebServerRequest *r) {
  String path = showPath(showName(r));
  if (path.isEmpty()) return r->send(400, "text/plain", "bad name");
  switch (r->method()) {
    case HTTP_GET:
      if (!LittleFS.exists(path)) return r->send(404);
      return r->send(LittleFS, path, "text/xml");
    case HTTP_PUT:
      return r->send(r->_tempObject ? 200 : 500); // body written in showBody
    case HTTP_DELETE:
      LittleFS.remove(path);
      return r->send(200);
    case HTTP_POST: {
      String to = r->hasParam("to") ? showPath(r->getParam("to")->value()) : "";
      if (to.isEmpty() || !LittleFS.exists(path)) return r->send(400);
      LittleFS.remove(to);
      return r->send(LittleFS.rename(path, to) ? 200 : 500);
    }
    default:
      return r->send(405);
  }
}

// A page file name: letters, digits, . _ - only, not a hidden file, and a
// file the page is built of (gzipped or a picture). "" = refused.
static String pagePath(const String &name) {
  if (name.isEmpty() || name.length() > 48 || name.startsWith(".")) return "";
  for (char c : name) {
    if (!isalnum((unsigned char)c) && !strchr("._-", c)) return "";
  }
  if (!name.endsWith(".gz") && !name.endsWith(".png")) return "";
  return "/" + name;
}

// PUT /api/page/NAME: written to NAME.new first, then put in place, so a
// broken upload leaves the old file
static void pageBody(AsyncWebServerRequest *r, uint8_t *data, size_t len, size_t index, size_t total) {
  String path = pagePath(showName(r));
  if (path.isEmpty()) return;
  File f = LittleFS.open(path + ".new", index == 0 ? "w" : "a");
  if (!f) return;
  size_t n = f.write(data, len);
  f.close();
  if (n != len) return;
  if (index + len == total) {
    LittleFS.remove(path);
    if (LittleFS.rename(path + ".new", path)) r->_tempObject = (void *)1; // success (not freed: no malloc)
  }
}

static void pageRequest(AsyncWebServerRequest *r) {
  if (pagePath(showName(r)).isEmpty()) return r->send(400, "text/plain", "bad name");
  r->send(r->_tempObject ? 200 : 500);
}

// PUT body, in chunks: written straight into the file
static void showBody(AsyncWebServerRequest *r, uint8_t *data, size_t len, size_t index, size_t total) {
  String path = showPath(showName(r));
  if (path.isEmpty()) return;
  File f = LittleFS.open(path, index == 0 ? "w" : "a");
  if (!f) return;
  f.write(data, len);
  f.close();
  if (index + len == total) r->_tempObject = (void *)1; // marks success for showRequest (not freed: no malloc)
}

static void onEth(WiFiEvent_t event) {
  switch (event) {
    case ARDUINO_EVENT_ETH_START:
      ETH.setHostname("dled");
      break;
    case ARDUINO_EVENT_ETH_GOT_IP:
      ethUp = true;
      Serial.printf("Ethernet up: http://%s  (http://dled.local)\n", ETH.localIP().toString().c_str());
      break;
    case ARDUINO_EVENT_ETH_DISCONNECTED:
    case ARDUINO_EVENT_ETH_STOP:
      ethUp = false;
      Serial.println("Ethernet down");
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  Serial.println("\nDLED bridge");
  // a queue holds pointers only (the data is on the heap): long ones are cheap,
  // and a dropped reply costs the page a 600 ms wait before it asks again
  fromPages = xQueueCreate(128, sizeof(Msg));
  toPages = xQueueCreate(256, sizeof(Msg));
  loopTask = xTaskGetCurrentTaskHandle(); // setup() runs in the loop task
  if (!LittleFS.begin(true)) Serial.println("LittleFS failed");

  WiFi.onEvent(onEth);
  ETH.begin(ETH_ADDR, ETH_POWER_PIN, ETH_MDC_PIN, ETH_MDIO_PIN, ETH_PHY_LAN8720, ETH_CLOCK_GPIO0_IN);
  MDNS.begin("dled");
  MDNS.addService("http", "tcp", 80);
  ArduinoOTA.setHostname("dled");
  ArduinoOTA.setMdnsEnabled(false); // MDNS runs already
  ArduinoOTA.onStart([] { Serial.println("OTA: update started"); });
  ArduinoOTA.onEnd([] { Serial.println("OTA: done, restarting"); });
  ArduinoOTA.onError([](ota_error_t e) { Serial.printf("OTA: error %u\n", (unsigned)e); });
  ArduinoOTA.begin();

  ws.onEvent(onWs);
  server.addHandler(&ws);
  if (!LittleFS.exists("/shows")) LittleFS.mkdir("/shows");
  server.on("/api/shows", HTTP_GET, listShows);
  server.on("/api/shows/*", HTTP_GET | HTTP_PUT | HTTP_DELETE | HTTP_POST, showRequest, nullptr, showBody);
  server.on("/api/page/*", HTTP_PUT, pageRequest, nullptr, pageBody);
  // no icon (before serveStatic, which would look for it in LittleFS first)
  server.on("/favicon.ico", HTTP_GET, [](AsyncWebServerRequest *r) { r->send(204); });
  // index.html.gz etc.: served gzipped with the right content type; the
  // page names never change, so the browser always asks again
  server.serveStatic("/", LittleFS, "/").setDefaultFile("index.html").setCacheControl("no-cache");
  server.onNotFound([](AsyncWebServerRequest *r) { r->send(404, "text/plain", "not found"); });
  server.begin();
}

void loop() {
  // sleep until a message is queued (at most 50 ms, for the statistics and
  // the clean-up; 1 ms while replies wait for a page's acknowledgement,
  // which comes without a notification); relay() takes everything there is
  ulTaskNotifyTake(pdTRUE, pagesWaiting() ? 1 : pdMS_TO_TICKS(50));
  relay();
  statsTick();
  ArduinoOTA.handle(); // a firmware update (it runs to the end in here)
  static uint32_t cleaned = 0;
  if (millis() - cleaned > 1000) {
    cleaned = millis();
    ws.cleanupClients();
  }
}
