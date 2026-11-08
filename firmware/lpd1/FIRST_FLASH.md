# LPD-1: first flash (milestones 1-2)

Everything is built and ready. At home,
on the board with the DMX output (your own PCB, the one WLED runs on now).
Not on the DLED bridge.

## 1. Look up on the PCB

- **The ESP32 module**: a WT32-ETH01? The firmware uses its Ethernet pins
  (LAN8720, PHY 1, power GPIO16, clock in GPIO0, MDC 23, MDIO 18). Another
  module: set its Ethernet pins in `platformio.ini` before flashing.
- **DMX TX pin**: the GPIO that goes to the MAX485's DI (WLED's default is
  GPIO2).
- **Driver enable**: the MAX485's DE / RE - tied to 3.3 V (then -1), or to
  a GPIO (then that GPIO; WT32-ETH01's header calls IO33 "485_EN").

Put them in `firmware/lpd1/platformio.ini`, `[env:wt32-eth01]`:

```
build_flags =
  -D LPD_DMX_TX_PIN=2
  -D LPD_DMX_EN_PIN=-1
```

## 2. Keep WLED

In WLED: Settings > Security & Updates > **Backup presets** and **Backup
configuration** (two .json files). To put WLED back later: flash a WLED
`_dmx` build (https://install.wled.me, or the .bin with
`python -m esptool write_flash 0x0 <file>`), then restore the two files
on the same page.

## 3. Flash

USB-serial adapter: its TX to the board's RX0 (IO3), RX to TX0 (IO1), GND,
5 V. **IO0 to GND** while the board starts (power or reset), then:

```bash
python -m platformio run -e wt32-eth01 -t upload
```

(in `firmware/lpd1`; add `--upload-port COMn` if needed). If it does not connect: GPIO2 must not be pulled high
while the board starts in download mode - unplug the DMX side and try
again. After the upload: IO0 free, reset.

## 4. Check

Serial log (Ethernet cable in):

```bash
python -m platformio device monitor
```

(An adapter without RTS on EN cannot reset the board: press reset
yourself to see the first lines. Another program holding the COM port
blocks the monitor.)

- `LPD-1: VN server on UDP 16945, test show running, DMX TX GPIO2
  (enable -1) ...` with your pins;
- `Ethernet: 192.168.1.x`;
- every 10 s `render: N us per frame (max M) ...`: **N and M well under
  25000** (the estimate was 7000-17000 for the worst case; this test show
  is lighter).

Art-Net on the PC (in `dled_flutter`, the box's IP from the log):

```bash
dart run tool/lpd_capture.dart 192.168.1.x --ch 1-24 --secs 20
```

- about **40 frames / s** at the end;
- ch 1 (fixture 1 intensity) going up and down (Sinus, ~8 s), ch 2 / 3
  (pan / tilt) a circle, ch 4-6 (RGB) a rainbow; ch 9-16 the same a bit
  later in phase.

DMX: a fixture on the XLR at **address 1** with channels In, pan, tilt, R,
G, B (A, W) should do the same; an RGB par at 1 with R G B at 1-3 shows the
first three channels.

## 5. The reference app

The box announces itself as **LPD-1** (firmware 1.0, its own; it speaks the
same protocol as an LPU-1, the app lists both). In our app or the reference app:
OPTIONS > devices > choose LPD-1. It should connect and download the test
show (empty labels; 64 fixtures). Then open one of your shows (it is sent
to the box), GO a playback: the fixtures on the XLR should do what they do
on the LPU. RELEASE ALL, a fader, EDIT with the sliders: the same.

The show is saved (LittleFS, 2 s after the last change; the log says
`show saved (N bytes)`): reset the box, it should come back with your show
(`saved show: loaded`). The test show only runs while nothing is saved.

Send Claude the log lines and what worked or not.

## 6. Later updates over the network

Since 2026-10-28 the firmware takes updates over Ethernet (ArduinoOTA,
UDP 3232). After one flash by cable with it, no adapter or IO0 any more:

```bash
python -m platformio run -e wt32-eth01-ota -t upload
```

(in `firmware/lpd1`; `--upload-port <IP>` when the box is not at
192.168.1.102). The PC must be allowed to accept the box's connection back
(Windows firewall may ask for Python once). The show stays (it is in
LittleFS, not in the firmware). The log says `OTA: update started` and
`OTA: done, restarting`.

**Password**: set `LPD_OTA_PASSWORD` in the environment before building;
the box then only takes an update with that password, and the OTA upload
sends it from the same variable. Without it anyone on the network could
flash the box. Empty (the default): no password.
