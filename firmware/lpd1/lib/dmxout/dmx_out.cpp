// dmx_out.cpp -- see dmx_out.h. ESP32 (Arduino) only; the native tests do
// not build it.

#if defined(ARDUINO_ARCH_ESP32)

#include "dmx_out.h"

#include <Arduino.h>
#include <HardwareSerial.h>

namespace lpd {

namespace {

constexpr uint32_t kDmxBaud = 250000;    // 8N2
constexpr uint32_t kBreakBaud = 83333;   // a 0 byte = 108 us low, then the
                                         // stop bits = the mark after break
HardwareSerial dmxSerial(2);

}  // namespace

void DmxOut::begin(int txPin, int enPin) {
  txPin_ = txPin;
  if (enPin >= 0) {
    pinMode(enPin, OUTPUT);
    digitalWrite(enPin, HIGH);  // send
  }
  // room for a whole frame, so send() can return while it goes out
  dmxSerial.setTxBufferSize(1024);
  dmxSerial.begin(kDmxBaud, SERIAL_8N2, -1, txPin_);
}

void DmxOut::send(const uint8_t dmx[512]) {
  dmxSerial.flush();  // the previous frame is out
  dmxSerial.updateBaudRate(kBreakBaud);
  dmxSerial.write((uint8_t)0);
  dmxSerial.flush();  // ~130 us
  dmxSerial.updateBaudRate(kDmxBaud);
  frame_[0] = 0;  // start code
  for (int i = 0; i < 512; i++) frame_[i + 1] = dmx[i];
  dmxSerial.write(frame_, sizeof frame_);
}

}  // namespace lpd

#endif
