// fixture_codes.dart -- the one table for DMX function codes.
//
// A fixture's profile (personalities.xml / .show `profile`) is a hex string,
// two digits per DMX channel = function code. The LPU stores each cue as a
// 50-byte record per fixture with a fixed slot per fader (u16 little-endian;
// pan / tilt signed around the centre), whatever the fixture's channel order
// is. Measured from the LPU's DMX output: lpd/DMX_ENGINE.md section 2.
//
// Source: analysis/FINDINGS.md 20.11 and dled_flutter/SHOW_FORMAT.md,
// confirmed with app-saved cues (one fader per cue) on 2026-10-23.
//
// Attr keys are the ones the edit screen's faders already use; this file only
// decides which code / record byte belongs to which key.

/// Record bytes 0-11 are the three FX slots: intensity 0-3, position 4-7,
/// colour 8-11 ([waveform, size, speed, phase]). Never channel data.
const int kFxIntensityOffset = 0;
const int kFxPositionOffset = 4;
const int kFxColourOffset = 8;

/// Function code -> attr key.
const Map<int, String> kCodeToAttr = {
  0x01: 'In',
  0x02: 'Pan',
  0x03: 'Tilt',
  0x04: 'R',
  0x05: 'G',
  0x06: 'B',
  0x07: 'A',
  0x08: 'W',
  0x09: 'Col',
  0x0A: 'Go',
  0x0B: 'Rota',
  0x0C: 'Sh',
  0x0D: 'Iris',
  0x0E: 'Frost',
  0x0F: 'Focus',
  0x10: 'Prism',
  0x11: 'Zoom',
  0x12: 'Custom', // probably custom 1 (only one fixture backs it)
  0x13: 'UV',     // no fader of its own in the LPU; which record slot it uses is open
};

/// Attr key -> byte offset of its u16 BE value in the 50-byte record.
/// UV has no record slot (see kCodeToAttr).
const Map<String, int> kAttrRecordOffset = {
  'Pan': 12,
  'Tilt': 14,
  'In': 16,
  'Col': 18,
  'R': 20,
  'G': 22,
  'B': 24,
  'A': 26,
  'W': 28,
  'Go': 30,
  'Rota': 32,
  'Sh': 34,
  'Iris': 36,
  'Frost': 38,
  'Focus': 40,
  'Prism': 42,
  'Zoom': 44,
  'Custom': 46,
  'Custom2': 48,
};

/// Record offset -> fader name as the reference app and the Python tools call it
/// (analysis/lpu/showfile.py ATTR_OFFSETS). Pan/tilt/intensity/RGBAW are
/// separate fields of a record.
const Map<int, String> kFaderNames = {
  18: 'colour wheel',
  30: 'gobo',
  32: 'gobo rotation',
  34: 'shutter',
  36: 'iris',
  38: 'frost',
  40: 'focus',
  42: 'prism',
  44: 'zoom',
  46: 'custom 1',
  48: 'custom 2',
};

/// Fine channels: code + 0x20 is the low byte of that code's value
/// (0x22 pan fine and 0x23 tilt fine are confirmed; the rest follow the pattern).
const int kFineCodeStep = 0x20;

/// The attr a code belongs to, fine channels included (0x22 -> 'Pan').
String? attrForCode(int code) =>
    kCodeToAttr[code] ??
    (code > kFineCodeStep ? kCodeToAttr[code - kFineCodeStep] : null);

/// True for a fine channel (0x22 pan fine, 0x23 tilt fine, ...).
bool isFineCode(int code) =>
    !kCodeToAttr.containsKey(code) &&
    code > kFineCodeStep &&
    kCodeToAttr.containsKey(code - kFineCodeStep);

/// Byte within the 50-byte record that holds this channel's 8-bit value:
/// the high byte of the attr's u16 (offset + 1, little-endian) for a coarse
/// channel, the low byte for a fine channel. Null when the code has no record
/// slot. (Pan / tilt are signed: their DMX value is [recordDmx], not this byte.)
int? recordByteForCode(int code) {
  final attr = attrForCode(code);
  final offset = attr == null ? null : kAttrRecordOffset[attr];
  if (offset == null) return null;
  return isFineCode(code) ? offset : offset + 1;
}

// --- record values -----------------------------------------------------------

/// Pan and tilt are stored signed (int16) around the centre.
bool isSignedAttr(String attr) => attr == 'Pan' || attr == 'Tilt';

/// The raw u16 at [offset] of a record starting at [base] (little-endian).
int recordU16(List<int> b, int base, int offset) => b[base + offset] | b[base + offset + 1] << 8;

/// The 16-bit DMX value of [attr] in a record, 0..65535: the u16 itself,
/// for pan / tilt 32767 + the signed value (all zero bytes = the centre).
int recordDmx(List<int> b, int base, String attr) {
  final v = recordU16(b, base, kAttrRecordOffset[attr]!);
  return isSignedAttr(attr) ? (v.toSigned(16) + 32767).clamp(0, 65535) : v;
}

/// Store a 16-bit DMX value of [attr] (the inverse of [recordDmx]); pan /
/// tilt are kept within -32767..32767 like the reference app (full right ff 7f,
/// full left 01 80).
void setRecordDmx(List<int> b, int base, String attr, int dmx) {
  var v = dmx.clamp(0, 65535);
  if (isSignedAttr(attr)) v = (v - 32767).clamp(-32767, 32767) & 0xffff;
  final o = base + kAttrRecordOffset[attr]!;
  b[o] = v & 0xff;
  b[o + 1] = v >> 8;
}

/// The 8-bit DMX value a record gives a channel with function [code] at
/// full (coarse = high byte, fine = low byte of [recordDmx]). Null: no slot.
int? recordDmxForCode(List<int> b, int base, int code) {
  final attr = attrForCode(code);
  if (attr == null || !kAttrRecordOffset.containsKey(attr)) return null;
  final v = recordDmx(b, base, attr);
  return isFineCode(code) ? v & 0xff : v >> 8;
}
