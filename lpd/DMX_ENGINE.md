# The LPU's DMX engine: findings

What the LPU-1 (firmware 1.29) puts on DMX, measured from its Art-Net
output. Every finding names the test (`lpd/tests/`) and the
recording (`lpd/recordings/`) that shows it. Rerun a test with
`dart run tool/lpd_run.dart NAME` in `dled_flutter`.

## 1. Output

- Art-Net ArtDmx to UDP 6454 and sACN to 239.255.0.U:5568, both at the
  same time, **40 frames/s, always all 512 channels**, also when nothing
  changes. Universe on the wire: Art-Net 16 (the LPU's setting raw 16 =
  subnet 1, universe 0), sACN 1 (the LPU's setting reads 2: our decoding of
  that setting or the LPU's numbering is one off; open).
- A change (GO, fader) shows up 1-4 frames (25-105 ms) after the command.
- Over Wi-Fi the PC sometimes gets fewer frames (11-26/s for a few seconds):
  that is the Wi-Fi, not the LPU. Use Ethernet for timing tests.

## 2. Cue record -> DMX (test `static`, 2026-10-27)

Probe fixture (one channel per function code), a cue with a different
value in every record byte, playback at full, fade 0:

- **Record values are u16 little-endian**: the byte at the higher offset
  is the coarse DMX channel, the byte at the lower offset the fine channel.
  The reference app's own .show files agree: pan full right is stored `ff 7f`,
  full left `01 80`. (Our code read them big-endian until 2026-10-27; now
  `fixture_codes.dart` recordDmx / setRecordDmx and `analysis/lpu/showfile.py`.)
- **Pan and tilt are signed** (int16) around the centre: DMX 16-bit =
  32767 + value. Idle (no cue) pan / tilt = 127 / 255 (32767).
- Every other attribute: DMX 16-bit = the value as is. Idle = 0.
- **Fine channels are code + 0x20** for every attribute: 21 intensity fine
  and 24 red fine work like 22 / 23 (pan / tilt fine).
- **Code 13 = custom 2** (record offset 48). Code 12 = custom 1 (46).
- Code 14 (pan/tilt speed) and 80 (no fader): 0, from no record slot.
- Profile codes 00 and 15 at the end of the probe were **not stored**: the
  LPU kept the profile up to code 80 (25 channels): code 00 ends a profile
  (section 14).
- A fixture that is in no cue gives the idle values (fixture 2 of `static`).

- Test `encode` (2026-10-27): a cue made by the apps' encoder (pan full
  left, tilt 3/4, red 50 %, gobo 1/3, intensity 200/255) comes out exactly
  as meant, except intensity fine 199 instead of 200 (51400 -> 51399): the
  intensity path loses 1 in the lowest bit at times (float maths?), the
  other attributes do not. In `static` 6434 came out exact.

## 3. Playback fader (test `static`)

- The playback's intensity scales **only intensity** (code 01 and its fine
  channel), at 16 bits: 6434 at full -> 3216 at 50 % -> 0 at 0 %.
  Colour, pan / tilt and the rest stay at the cue values, also at 0 %.
  (A fixture without an intensity channel: still to test, with and without
  the virtual dimmer flag.)
- At fader 0 the playback stays active: the other attributes keep their
  values until RELEASE.
- RELEASE (cue fade 0) puts everything back to idle at once.

## 4. FX generators: intensity (test `fx_intensity`, 2026-10-27)

8 fixtures, phase spread 0, 12.5 ... 87.5 %, FX speed 50 % (byte 64):

- **The FX is added to the cue's intensity and clipped** to 0..65535:
  out = clamp(In + size x 65535 x w(t)), w between -1 and +1.
  - In 100 %, size 100: 0..255 with the top half clipped (flat 255).
  - In 100 %, size 50: 128..255; size 25: 192..255.
  - In 50 %: clipped at both ends. No intensity in the cue (In 0):
    only the positive half of the wave comes out.
- **Waveforms** (one period, from the upward crossing of the middle):
  - Sinus: a sine.
  - Ramp: rises linearly from -1 to +1 over the period, then jumps back.
  - Inversed Ramp: the same falling.
  - Square: -1 / +1, 50 % duty (with In 100 %: 0 / 255).
  - Random: on about 10 % of the half-period ticks a fixture gets a random
    dip (mean ~90 of 255 when visible), which ramps back to 0 at "dip per
    period"; the next tick can cut it short (test `random_long`, 90 s x 8
    fixtures; at 100 % speed about the same share).
- **At GO** (phase 0): Sinus at 0 rising, Ramp at -1 rising, Inversed
  Ramp at +1 falling, Square +1 for the first half. Phase and size bytes:
  value / 255.
- **Period at FX speed 50 % = 0.778 s** (the same for every fixture and
  waveform). Speed: see section 7.
- **Phase** p (0..100 %) moves a fixture's wave *earlier* by p of the
  period: with the spread 0, 12.5 ... 87.5 %, fixture k is 0.125 k ahead of
  fixture 1 (measured 0.126, 0.252 ... 0.875).
- **The FX clock starts at GO**: w(t) = wave(t / period + phase), t from
  GO, the Sinus starting at 0 and rising (In 100 %: flat 255 for half a
  period, the minimum at 3/4). First frame +50 ms. RELEASE (fade 0) drops
  intensity to 0 at once.

## 5. FX generators: position (test `fx_position`)

- Added to the cue's pan / tilt (16 bit, centre 32767) and clipped:
  out = clamp(pos + size x 32767 x w(t)); size 100 at the centre = the
  full range, size 50 = 64..192 (of 256).
- **Circle**: pan = sin, tilt = cos (starts at pan centre, tilt top).
- **Eight**: pan = sin at double frequency, tilt = cos.
- **Square**: a square path, one side per quarter period, linear: starts at
  the corner pan -1 / tilt +1, pan goes to +1 first, then tilt to -1, pan
  back to -1, tilt back to +1.
- **Pan** / **Tilt**: only that axis, a sine (rising from the centre at GO).
- **Random**: once per period a new random pan and tilt, jumped to (no
  glide); the moments are shifted by the fixture's phase.
- **Period = 143 / speed byte s** (2.23 s at 50 %, 1.12 s at 100 %), so
  2.86 x slower than the intensity FX at the same setting.
- The phase spread works as for intensity (exactly 1/8 apart); an intensity
  and a position FX in one cue run each at their own period.

## 6. FX generators: colour (test `fx_colour`)

- Only R, G and B (amber and white are not touched). Added to the cue's
  colour as size x 65535 x f(t) with **f between 0 and 1** (not -1..1) and
  clipped: size 50 gives 0..127; on red 100 % red stays 255; on G 20 % green
  never goes below 51.
- **Rainbow**: the HSV hue wheel: each of R, G, B is 1 for 1/3 of the
  period, ramps down over 1/6, is 0 for 1/3, ramps up over 1/6; G is 1/3 of
  a period behind R, B 2/3. Starts at red (R 1, G rising).
- **Full Sinus**: R = G = B = (1 + sin) / 2 (white pulsing), at GO 0.5 rising.
- **Full Twinkle**: R = G = B jump to 1 and fall linearly to 0 in half a
  period, about 1.2 times per period per fixture at random (`random_long`).
- **Random**: at random moments the colour moves along the rainbow wheel
  (one 1/6 segment at a time, at rainbow speed), then stays.
- **Period = 100 / speed byte s** (1.56 s at 50 %, 0.785 s at 100 %), twice
  the intensity period.
- The random waveforms (intensity, colour, twinkle) may do nothing on a
  fixture for 20-30 s; position Random always moves.

## 7. FX speed and the playback speed knob (tests `fx_speed`, `fx_knob`)

- FX speed byte b, a signed byte (the app writes -100..+100 % as
  -127..+127, but +100 % as 128): **frequency proportional to b**. Periods:
  intensity 50 / b s, colour 100 / b s, position ~143 / b s (5 % = 6 ->
  8.3 s, 10 % -> 3.8 s, 25 % -> 1.56 s, 75 % -> 0.52 s). Against the PC's
  clock the LPU runs 0.4 % fast: 49.8 / 99.6 / 142.5 per b in PC seconds
  (what the replay tests use).
- **Negative b runs the wave backwards** (Ramp at -50 % falls); same period.
- **+100 % (byte 128) is -128 for the LPU: the FX runs backwards** at full
  speed (period 0.39 s). The Sinus starts falling instead of rising. Seen in
  the replay of `fx_speed` / `fx_knob`; the reference app has the same effect.
  **Our apps write +100 % as 127** (since 2026-10-28), which runs forwards
  at 127; they still read 128 as +100 %.
- **Playback speed knob** (the playback's speed property s, -1..+1) is a
  factor on every FX of that playback: **about 1 + 2 s, at most x2**: s 0 =
  x1, +0.25 = x1.5, **+0.5 .. +1 = x2 (no faster)**, -0.5 = stopped, below
  -0.5 backwards, -1 = backwards at normal speed. The reference app shows the
  same: half of the knob's travel does nothing. (For the LPD-1: copy it, or
  give the knob a useful range.) Measured in steps of 0.1 from the Ramp's
  slope (clean stretches, `fx_knob`):

  | s | -1 | -0.9 | -0.8 | -0.7 | -0.6 | -0.5 | -0.4 | -0.3 | -0.2 | -0.1 | 0 |
  |---|---|---|---|---|---|---|---|---|---|---|---|
  | factor | -0.98 | -0.78 | -0.58 | -0.375 | -0.19 | 0 | 0.20 | 0.39 | 0.59 | 0.80 | 1 |

  | s | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 .. 1 |
  |---|---|---|---|---|---|
  | factor | 1.195 | 1.39 | 1.595 | 1.78 | 1.99 |
- Changing the knob changes the speed at once, without a jump in the wave.
- **The LPD-1 differs on purpose for s < 0** (the user, 2026-10-29: on a
  rainbow the LPU's backwards run below -0.5 looks like "faster again"):
  factor 1 + s, slower over the whole left half, x0.5 at -0.5, standing
  at -1, never backwards. s >= 0 as the LPU. (Measured on the board: a
  rainbow x2 / x1 / x0.75 / x0.5 / x0.25 / x0.1 / 0 at +1 / 0 / -0.25 /
  -0.5 / -0.75 / -0.9 / -1.)

## 8. Fades (tests `fades`, `extra`, `follow_delay`, `gomodes`)

- **Every attribute fades linearly** over the cue's fade time, in 16 bit:
  intensity, colour, pan / tilt, and also colour wheel, gobo, shutter and
  the other "wheel" channels (nothing snaps). From cue to cue the fade
  starts at the values on the output at that moment: GO halfway through a
  3 s fade starts the next 3 s fade from there (red 128, pan 192 -> 0).
- **Intensity on GO fades from the playback's remembered level, not from
  the output** (test `open`, playbacks never used before). The playback
  remembers per fixture the intensity of the cue it was on (the cue's own
  level, not what was on the output); RELEASE does not reset it. So:
  - the first GO ever: fades up from 0;
  - cue 1 (80 %) -> cue 2 (30 %) -> RELEASE -> GO: jumps to 30 %, fades to 80 %;
  - RELEASE halfway through a fade-in, GO again: jumps to the full cue level;
  - not reset by the playback fader, RELEASE ALL or a show upload (the
    `fades` test started at 128 / 255 = levels of earlier tests);
  - **reset by a power cycle** (test `memory_reset`, 2026-10-28, the first
    GOs after one: playbacks that remembered 80 / 100 / 100 % faded up
    from 0). So the memory lives in RAM only.
  Colour, position and the rest always fade from the output. FLASH of a cue
  with a fade: intensity at full at once, colour fades in.
  **Flash and Solo go modes and the FLASH button use and set the memory
  like GO** (test `memory_flash`): GO held the first time fades up from 0,
  held again jumps to the cue level; a GO after a FLASH jumps to it too.
- **The playback fader during a fade**: output = fade level x fader at every
  moment (a fader move jumps, the fade goes on underneath).
- **FX and fades**: only the base level fades; an FX runs at full size from
  the first frame of the GO (a cue that adds an FX with a 3 s fade: the FX
  is there at once) until the end of the release fade, then the output
  drops to 0 at once (mid-wave).
- **Delay does not delay the fade.** It is the wait after the fade before a
  **follow** fires: with follow, the next cue starts at fade + delay after
  the cue started (0.5 s fade, 1 s delay: the next cue at +1.5 s); with
  delay 0 at the end of the fade. With a manual GO, delay does nothing.
- **RELEASE fades out over the current cue's fade time** (to idle: 0,
  pan / tilt centre). FLASH up from a playback that faded in: fades out the
  same way.
- **The speed knob does not change fade times** (3.00 s at +0.5 and -0.5).

## 9. Playback fader and fixture flags (test `fader_flags`)

- **Fader = intensity x fader**, linear, rounded (255 x 0.9 = 230, x 0.25 =
  63). Only intensity (and its fine channel).
- A fixture **without an intensity channel**: the fader does nothing (RGB
  stays at full). With **virtual dimmer**: R, G, B are scaled like
  intensity (and the fixture has no intensity channel of its own).
- **Invert pan / tilt**: DMX 16 bit = 65535 - value (the centre 32767 comes
  out as 32768 = 128 / 0). **Swap pan / tilt**: pan gets the tilt value and
  the other way round. The flags work on the output, after the FX: a Circle
  on an inverted fixture is the mirror image (test `open`).

## 10. Cue lists and go modes (tests `cuelist`, `extra`, `gomodes`)

- Repeat **Loop** 1 2 3 1 2 ...; **Bounce** 1 2 3 2 1 2 3 2 ...; **Off** stays
  on the last cue (more GOs do nothing); **Random** a random cue each GO
  (the same one can come again).
- Go mode **Go**: GO = next cue, **on letting go** of the button, if it was
  held under 1 s; **held 1 s it releases the playback** (at 998 ms, while
  still held; nothing on letting go, nothing from idle). Holds of
  0.1-0.9 s all advanced (test `go_hold`, 2026-10-28). **GO during a
  release** goes on with the next cue from where it was (repeat mode as
  usual, Loop wraps), fading from where the release is; only after the
  release is over does GO start at cue 1 (test `release_go`,
  2026-10-29). **Toggle**: GO on,
  GO again releases (on the press).
  **Flash**: on only while GO is held. **Solo**: on only while GO is held,
  and while held every other playback's intensity is 0 (their colour /
  position stay); let go, they come back. **Both ignore the playback fader**
  (fader 30 %: In 255; test `flash_solo`, 2026-10-30).
- **The LPD-1 differs on purpose for a Solo with a fade** (the user: follow
  what the manual's text says). LPU, Solo with fade 1 s: the other
  playbacks' intensity fades to 0 over that second, and unused fixtures get
  an intensity that falls to 0 too (In 127 at 0.5 s; a flash on dimmers).
  LPD-1: the others are 0 at once, unused fixtures stay dark. Solo with fade
  0: no difference. (`flash_solo`, 2026-10-31, box against LPU with
  `lpd/compare.py`: 485624 of 485875 values equal. 195 of the 251 others are
  this, after pressing the Solo with the fade. The other 56 are timing of a
  frame or two around a press, let go or GO, not behaviour: 35 in fades of
  pb11 / pb12 and 21 at hard switches, e.g. pb2's GO: box 0, LPU 255.)
- **FLASH button**: the playback at full (its fader ignored) while held,
  from idle or running; let go: back to the fader level (or released if it
  was idle).

### 10a. The speed knob on follow cues (test `knob_follow`, 2026-10-29)

The knob is also the chase speed: a **follow cue's fade and delay** run
on a cue clock the knob scales; a cue without follow fades in real time
(test `fades`: 3 s at knob +-0.5 took 3 s). Factor (a 2 s / 20 s delay
timed on playback 11 of the user's show):

| knob | -1 / -0.9 | -0.8 | -0.6 | -0.5 | -0.3 | -0.1 | 0 | +0.5 | +1 |
|---|---|---|---|---|---|---|---|---|---|
| factor | stands | 0.08 | 0.16 | 0.24 | 0.32 | 0.44 | 1 | 5.5 | 10.1 |

Positive: 1 + 9 k. A knob change acts at once on what is left (no jump);
the next cue starts on a 25 ms frame (+0.5, 2 s: 375 ms, not 364). Near 0
the LPU is irregular (-0.05 ran x1, -0.02 slower than -0.1; it also keeps
some knob values rounded: -0.85 -> -0.9, +0.08 -> +0.1); not copied.
Release fades: not measured with the knob (real time in the engine).

### Exclusive, repeat Off, Background (test `pb_props`, 2026-10-30)

- **Exclusive works per bank, a row of 8**: pb8 releases pb1, pb16 releases
  pb9; pb9 and pb64 release nothing in another row.
- **Repeat Off with follow cues: released** after the last cue's fade +
  delay. A last cue without follow stays; GO past it starts it again.
- **Background**: ignores RELEASE ALL (its own RELEASE works). The LPD-1
  also starts it at power-up, as the manual says; not measured on the LPU
  (needs a power cycle).

### Live edits (test `live_edit`, 2026-10-28)

- **INSERT** a cue after the running one: nothing changes until GO.
- **DELETE the cue a playback is on**: it goes at once to the cue that
  now has that place (fade as that cue; here 0), no active-cue
  notification; a later GO goes on from there.
- **SWAP two running playbacks**: both stop at once (DMX 0, no fade;
  2f ff and phase 1 for both); a GO starts each from its first cue.
- **RECORD** while a playback runs on another cue: the recorded cue is
  played on the next GO (section 12: needs 2c 3f set, and a cue that
  exists).

### Notifications (tests `cuelist`, `gomodes`, `go_hold`, `live_edit`)

Active cue `29 81 2f` and phase `29 81 24` as the LPU sends them (the
LPD-1 sends the same, `lib/vn` announce(); `lpd/compare_notes.py`):
- a cue started by GO / FLASH: 2f (only when another cue than before),
  phase 2; **phase 3 when its fade + delay is over** (a frame later with
  fade 0; after the delay of a cue with a delay).
- a follow cue: 2f only; phase 3 after the last cue's fade.
- GO at the end of a repeat-Off list: phase 4 then 2 (the cue again; no
  change on DMX), then 3. Random choosing the same cue: phase 2, 3.
- release: phase 4 at once, 2f ff and phase 1 when the release fade is
  over; released before phase 3 (Solo let go at once): no 3.
- swap: 2f ff and phase 1 for the second then the first playback, then
  "changed" 3 for both, then 0x121 and 0 for each.
- insert: "changed" 0 for the new cue, 3 for the playback. Delete: 3.
- selection: 3b, then the 17 programmer values (2c 32). A programmer value:
  2d 32, and after the first one 2c 45 = 1. CLEAR: 2d 32 (cleared) for each
  attribute that had a value, then 45 = 0; nothing when empty.

## 11. More than one playback (tests `mixing`, `extra`)

- **Intensity: HTP** (highest wins), each playback after its fader. With an
  intensity FX the highest *cue level* wins and its FX then applies: a
  static 50 % playback and a 100 % playback with a Sinus give the full
  Sinus, also below 50 % (test `open`). A releasing playback competes with
  its level from the moment of the release: its FX stay on top until the
  release is done, then the other one takes over.
- **Everything else is HTP too** (test `colour_mix`): per attribute the
  highest value of the playbacks that set it, whatever the order: red 80 %
  and 30 % give 80 % both ways, pan 25 % and 75 % give 75 %, the same for
  colour wheel and gobo. Only the attributes in a cue take part (a cue
  without blue leaves blue to the others). (Earlier this said LTP: the
  `mixing` values happened to fit both.)
- **Background** playbacks are not released by RELEASE ALL.
- **Exclusive**: starting an exclusive playback releases the other exclusive
  playbacks; normal playbacks stay.

## 12. EDIT and the programmer (test `programmer`)

- **While the EDIT page is open (2c 02 35 = 0) the playbacks give nothing**:
  every fixture 0 / idle except what the programmer holds; GO then leaves
  playbacks in "releasing". Closing EDIT brings the playbacks back (the
  programmer values are then not output, but kept: opening EDIT again shows
  them).
- Programmer values go to the selected fixtures; another selection keeps
  the values of the first. The colour attribute sets R, G, B, A, W together.
- **Programmer FX** (attributes 1 / 3 / 5) work like cue FX on the selected
  fixtures (Sinus on the programmer's intensity, period 0.779 s at 50 %;
  a Circle at the same time); the same phase on every selected fixture.
  CLEAR drops the programmer to idle at once (no fade). **CLEAR in EDIT
  clears every fixture; with EDIT closed only the selected ones** (test
  `clear_closed`: F2 selected last -> F1 kept, F2 cleared; F1 selected last
  -> the other way round). Closing EDIT alone keeps everything (it shows
  again when EDIT opens).
- Checked again with the reference app's frames (2026-10-28, the user's show):
  EDIT open blacks out the running playback on the LPU too (the board the
  same). A playback GOne while EDIT is open reads state 2 (`29 30`), and
  stays 2 after EDIT closes (the board: 3); what it outputs then is not
  measured yet.
- **Bodies are 4 bytes**: a bool / u32 write with a 1-byte body is echoed
  but ignored by the LPU (GO, EDIT; our probes sent 1 byte by mistake).
- **LOAD** (2c 1d 36) and **RECORD** (2c 1d 37) **only work while the
  edited playback `2c 01 3f` is a playback 0-63**. The reference app writes it
  when it opens the edit window; ours did not, and after a power cycle it
  is not one: then the LPU drops LOAD without any answer and echoes RECORD
  but records nothing (3f = 64, 0xff, -1: dropped; 0: works; found
  2026-10-28 with a tshark capture of the reference app's LOAD). It need not
  be the loaded / recorded playback; a show upload keeps it. Our apps now
  write 3f = the playback first (`lpu_session.dart` loadCue, the LPD
  runner), and the LPD-1 and the emulator drop LOAD / RECORD the same way.
  LOAD answers with 17 programmer notifications (2c 32), 2c 45 = 1, then
  the echo.
- **RECORD only into a cue that exists**: one past the end is ignored (the
  app INSERTs it first). **INSERT** makes a cue with fade 2 s, delay 2 s,
  follow on (read back), not a copy of the cue before it.
- **The programmer is per fixture** (2026-11-02, m400 pb5 cue 1: red and
  yellow fixtures; LOAD / changes / RECORD by VN on the LPU and the board,
  then the cue read back). LOAD gives every fixture its own values and FX;
  a programmer write goes to the selected fixtures only (colour = R G B A W
  at once, position = pan and tilt); RECORD keeps the rest per fixture.
  LOAD + RECORD into the same or another cue: an exact copy. LOAD, In 50 %
  on all, RECORD: In 127 on all, each its own colour.
- **RECORD replaces the whole cue by the programmer**: LOAD cue 1 (9
  fixtures), select 2 of them, blue, RECORD into cue 3: cue 3 = the 2 blue
  plus the other 7 as in cue 1, and a fixture cue 3 had that the programmer
  did not (slot 39) is gone. Not the selection only. A fixture selected
  without any value is not recorded: CLEAR, select 2, RECORD gives an empty
  cue; 2 at In 50 % then fixture 3 selected: only the 2.
- **Values are cut off, not rounded**: pan / tilt 0.5 / -0.25 records
  16383 / -8191, 0.3 / -0.3 9830 / -9830 (x 32767, toward zero); In and the
  other faders 0.5 -> 7fff (x 65535, down).
- **The LPD-1, the app and the light page do the same** since 2026-11-02:
  before, the board wrote the first fixture's LOAD values into every
  selected fixture and only those, the app and the light page the highest
  of the selected. The 9 cases above (`prog_cases.py`: m400 pb5, LOAD /
  writes / RECORD, the cue read back) give the same bytes on the LPU and
  the board's code (PC build); test_vn `recordKeepsEachFixture`, Flutter
  `record_per_fixture_test.dart`.

## 12a. Limits (2026-10-28)

- **Cue count above 48: the LPU hangs.** A cue count of 48 (`29 01 48`) is
  echoed; 49 got no echo, and from then on the LPU answered nothing (no VN
  frames, no discovery, no ping) and sent no DMX - still so after 5 min:
  only a power cycle helps. Our uploads (Flutter `lpu_io.dart`, Python
  `lpu_io.py`) now refuse a show with more than 48 cues in a playback
  before sending anything; the LPD-1 drops such a write without an answer.
- **The LPU holds a completely full show**: 64 playbacks x 48 cues x 4
  blocks (every fixture in every cue, 196 608 records) written in 306 s,
  every write answered, a sample of 24 blocks read back the same
  (`lpd/probe_full_show.py`, 2026-10-28). The LPD-1 holds far fewer
  (`kMaxRecords` 3000, ESP32 RAM) and drops a block that would go over.

## 13. 64 fixtures (test `all64`)

- 64 fixtures x 8 channels fill DMX 1-512 exactly; every one outputs its
  own values (fixture 64 at 505: In 255, pan 255, tilt 0, R 252, G 3).
- FX phase spread over 64 fixtures: exactly 1/64 apart, for intensity,
  colour and position.

## 14. Profiles

- Unknown function codes are kept in the profile. On DMX (test `codes`):
  **15 is always 127, 16 always 255**; 14, 17-20, 34-40, 7F, 80, 81, FF
  always 0 (no record value reaches them).
- **Code 00 ends the profile**: "01 00 04 05" is stored as "01" (a 1-channel
  fixture). (Test `open`; in `static` the probe lost its last 00 / 15.)

## 15. The engine (firmware/lpd1)

These rules are implemented in C++ in `firmware/lpd1/lib/engine` and
checked against every recording here: `python lpd/make_replay.py`, then
`python -m platformio test -e native` in `firmware/lpd1` replays each test
into the engine and compares the DMX (within 1 value and +-37.5 ms). All
tests match 99.9-100 % (2026-10-27); what is left are moments the LPU
itself acted oddly (a GO it ignored after an upload, the Bounce glitch in
`cuelist`, LOAD) and the first frames after a GO.

## Not covered yet

- LOAD: why the LPU drops ours (see 12).
