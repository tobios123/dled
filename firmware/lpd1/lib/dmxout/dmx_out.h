// dmx_out.h -- DMX512 out on a MAX485 the way WLED drives it: UART2, TX on
// GPIO2, no enable pin (the MAX485's DE / RE wired for sending), 250 kbaud
// 8N2, the break made by a 0 byte at 83333 baud.
//
// Credit: this follows SparkFunDMX.cpp as included in WLED
// (https://github.com/wled/WLED, wled00/src/dependencies/dmx/), by SparkFun
// Electronics and the WLED project, MIT licence. Listed in the README's
// "Credits and third-party code".
//
// Unlike WLED, send() does not wait for the 513 bytes (~23 ms): they go out
// from the UART's buffer while the next frame is computed. send() waits only
// for the previous frame to finish, so call it at most every ~23 ms (the
// engine's 25 ms frames).

#pragma once

#include <stdint.h>

namespace lpd {

class DmxOut {
 public:
  static constexpr int kDefaultTxPin = 2;  // as WLED

  // enPin: the MAX485's driver enable (DE / RE), held high; -1 when it is
  // wired for sending (as WLED).
  void begin(int txPin = kDefaultTxPin, int enPin = -1);
  // Break, mark-after-break, start code 0 and the 512 channels.
  void send(const uint8_t dmx[512]);

 private:
  int txPin_ = kDefaultTxPin;
  uint8_t frame_[513] = {};
};

}  // namespace lpd
