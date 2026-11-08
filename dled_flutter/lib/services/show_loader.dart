// show_loader.dart -- .show file parser
//
// .show format: plain UTF-8 XML (format version 1.19.0), as the reference app writes it.
//
// Block binary format (800 bytes per <block>, four <block> elements per cue):
//   The four blocks are four banks of 16 fixtures each. A non-empty block is
//   16 records x 50 bytes. The global fixture index is: block*16 + record
//     block 0 -> fixtures  0-15
//     block 1 -> fixtures 16-31
//     block 2 -> fixtures 32-47
//     block 3 -> fixtures 48-63  (max 64 fixtures)
//   Only the number of banks holding patched data differs per file; the layout
//   is universal. Within each 50-byte record every fader has a fixed slot,
//   a uint16 BE (coarse, fine), whatever the fixture's channel order is; see
//   core/fixture_codes.dart for the code -> attr -> record byte tables.
//
// The XML itself is read by core/show_file.dart (shared with the CLI and
// checked against the Python tools); this file turns it into the app model.
//
// Usage:
//   final show = ShowLoader.loadFromString(xmlString);
//   if (show != null) show.applyToModel(showModel);

import 'dart:convert';
import 'dart:typed_data';
import '../core/fixture_codes.dart';
import '../core/show_file.dart' as core;
import '../models/show_model.dart';
import '../core/cue_codec.dart' as codec show fxBytes, fxGenerators;
import 'show_exporter.dart' show cueSignature, fxValues;

// ---------------------------------------------------------------------------
// FX waveform IDs confirmed from show_all_fx_options.show.
// Each FX category has its own fixed byte offset within the 50-byte record:
//   Bytes  0-3  = Intensity FX
//   Bytes  4-7  = Position  FX
//   Bytes  8-11 = Colour    FX
// Layout of each 4-byte slot: [waveform_id, size, speed, phase]
//   size  0-255 maps to app slider 0-100%
//   speed signed int8 -> app slider -100..100%, about 1.27 per %:
//         0 = 0%, 1..127 = forward, 255 = -1%, 129 = -100%; we write +100%
//         as 127. The reference app writes it as 128 (wraps: the LPU runs that
//         FX backwards), so 128 reads as +100% too. Verified against the
//         UI and fx_rainbow_size=18_speed=10_phase=85 (speed byte 0x0d).
//   phase 0-255 maps to app slider 0-100%
// ---------------------------------------------------------------------------

// Intensity FX waveforms (bytes 0-3)
const Map<int, String> _kWaveformIntens = {
  0: 'None',
  1: 'Sinus',
  2: 'Ramp',
  3: 'Inversed Ramp',
  4: 'Square',
  5: 'Random',
};

// Position FX waveforms (bytes 4-7)
const Map<int, String> _kWaveformPosition = {
  0: 'None',
  4: 'Square',
  5: 'Random',
  6: 'Circle',
  7: 'Eight',
  8: 'Pan',
  9: 'Tilt',
};

// Colour FX waveforms (bytes 8-11)
const Map<int, String> _kWaveformColour = {
  0:  'None',
  5:  'Random',
  10: 'Rainbow',
  11: 'Full Sinus',
  12: 'Full Twinkle',
};

// FX speed byte -> app slider percent (see the slot layout above).
double fxSpeedPercent(int b) {
  if (b == 128) return 100.0;
  final s = b > 128 ? b - 256 : b;
  return s / 127.0 * 100.0;
}

/// One FX generator's 4 bytes [waveform, size, speed, phase] ('intensity' /
/// 'position' / 'colour'), as in a cue record and the LPU's programmer.
CueFxSlot fxFromBytes(String generator, List<int> b) {
  final names = switch (generator) {
    'intensity' => _kWaveformIntens,
    'position' => _kWaveformPosition,
    _ => _kWaveformColour,
  };
  return CueFxSlot(
    waveform: names[b[0]] ?? 'None',
    size: b[1] / 255.0 * 100.0,
    speed: fxSpeedPercent(b[2]),
    phase: b[3] / 255.0 * 100.0,
  );
}

CueFxSlot? _decodeFxSlot(
    Uint8List raw, int recStart, int slotOffset, Map<int, String> names) {
  final w  = raw[recStart + slotOffset];
  final sz = raw[recStart + slotOffset + 1];
  final sp = raw[recStart + slotOffset + 2];
  final ph = raw[recStart + slotOffset + 3];
  if (w == 0 && sz == 0 && sp == 0) return null;
  return CueFxSlot(
    waveform: names[w] ?? 'FX_$w',
    size:     sz / 255.0 * 100.0,
    speed:    fxSpeedPercent(sp),
    phase:    ph / 255.0 * 100.0,
  );
}

// Decode all three FX slots (intensity, position, colour) from an 800-byte
// block. Each slot is scanned across all fixture records so that a slot whose
// data lives only on certain fixture types (e.g. Position FX on Pan/Tilt
// movers) is still found even when the first fixture in the map lacks it.
// bankOffset is the global index of record 0 in this block (block * 16), so
// a fixture map keyed by global index maps onto the local 0-15 records.
({CueFxSlot? intens, CueFxSlot? pos, CueFxSlot? colour}) decodeFxFromBlock(
    Uint8List raw, Map<int, ShowFixture> fixtureMap, {int bankOffset = 0}) {
  const noFx = (intens: null, pos: null, colour: null);
  if (raw.length < 800) return noFx;

  // Return the record start of the first fixture that has non-zero FX data
  // at the given slot offset (bytes slotOffset..slotOffset+2).
  int? findRecordForSlot(int slotOffset) {
    for (final k in fixtureMap.keys) {
      final rec = k - bankOffset;
      if (rec < 0 || rec >= 16) continue;
      final rs = rec * 50;
      final w  = raw[rs + slotOffset];
      final sz = raw[rs + slotOffset + 1];
      final sp = raw[rs + slotOffset + 2];
      if (w != 0 || sz != 0 || sp != 0) return rs;
    }
    return null;
  }

  final intensStart = findRecordForSlot(0);
  final posStart    = findRecordForSlot(4);
  final colStart    = findRecordForSlot(8);
  return (
    intens:  intensStart == null ? null : _decodeFxSlot(raw, intensStart, 0, _kWaveformIntens),
    pos:     posStart    == null ? null : _decodeFxSlot(raw, posStart,    4, _kWaveformPosition),
    colour:  colStart    == null ? null : _decodeFxSlot(raw, colStart,    8, _kWaveformColour),
  );
}

GoMode _parseGoMode(String? s) {
  switch (s?.toLowerCase()) {
    case 'go':     return GoMode.go;
    case 'toggle': return GoMode.toggle;
    case 'flash':  return GoMode.flash;
    case 'solo':   return GoMode.solo;
    default:       return GoMode.go;
  }
}

RepeatMode _parseRepeatMode(String? s) {
  switch (s?.toLowerCase()) {
    case 'loop':   return RepeatMode.loop;
    case 'bounce': return RepeatMode.bounce;
    case 'random': return RepeatMode.random;
    case 'off':    return RepeatMode.off;
    default:       return RepeatMode.loop;
  }
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

class ShowFixture {
  final int index;        // block record index (0-15)
  final int address;      // DMX start address (1-based)
  final int universe;     // DMX universe (0-based)
  final String manufacturer;
  final String model;
  final String mode;
  final String fixtureClass; // personality class (e.g. 'Led', 'Yoke spot')
  final String profileHex;
  final List<int> functionCodes; // channel function codes in channel order
  // Patch-screen name and flags (<fixture label=.. invert_pan="true" ..>).
  final String name;
  final bool invertPan;
  final bool invertTilt;
  final bool swapPanTilt;
  final bool virtualDimmer;

  ShowFixture._({
    required this.index,
    required this.address,
    required this.universe,
    required this.manufacturer,
    required this.model,
    required this.mode,
    required this.fixtureClass,
    required this.profileHex,
    required this.functionCodes,
    this.name = '',
    this.invertPan = false,
    this.invertTilt = false,
    this.swapPanTilt = false,
    this.virtualDimmer = false,
  });

  // `universe` and `class` are not in real .show files; kept for older test files.
  factory ShowFixture.fromCore(core.ShowFixture f) => ShowFixture._(
        index:         f.index,
        address:       f.address,
        universe:      int.tryParse(f.extraAttrs['universe'] ?? '0') ?? 0,
        manufacturer:  f.manufacturer,
        model:         f.model,
        mode:          f.mode,
        fixtureClass:  f.extraAttrs['class'] ?? '',
        profileHex:    f.profile,
        functionCodes: f.codes,
        name:          f.name,
        invertPan:     f.invertPan,
        invertTilt:    f.invertTilt,
        swapPanTilt:   f.swapPanTilt,
        virtualDimmer: f.virtualDimmer,
      );

  int get channelCount => functionCodes.length;
}

class ShowCue {
  final String label;
  final double fadeSeconds;
  final double delaySeconds;
  final CueCondition condition;
  // Key: 'fixtureIndex:attrKey' (attr string used by edit_screen), value: DMX level 0-255.
  final Map<String, int> channels;
  // FX slots decoded from the block's fixed byte positions (null = no FX).
  final CueFxSlot? fxIntensity;
  final CueFxSlot? fxPosition;
  final CueFxSlot? fxColour;
  const ShowCue({
    this.label = '',
    required this.fadeSeconds,
    this.delaySeconds = 0.0,
    this.condition = CueCondition.always,
    required this.channels,
    this.fxIntensity,
    this.fxPosition,
    this.fxColour,
  });
}

class ShowPlayback {
  final int index;
  final String label;
  final double intensity;
  final GoMode goMode;
  final RepeatMode repeatMode;
  final double speed;
  // "Playback Properties" window checkboxes. Rarely used; both default false.
  // Proven real lowercase .show attributes (background="true"/exclusive="true")
  // from 64fixtures_playback_menu.show.
  final bool background;
  final bool exclusive;
  final List<ShowCue> cues;
  const ShowPlayback({
    required this.index,
    required this.label,
    required this.intensity,
    this.goMode = GoMode.go,
    this.repeatMode = RepeatMode.loop,
    this.speed = 1.0,
    this.background = false,
    this.exclusive = false,
    required this.cues,
  });
}


// ---------------------------------------------------------------------------
// ParsedShow
// ---------------------------------------------------------------------------

class ParsedShow {
  final String appVersion;
  final String deviceType;
  final String firmwareVersion;
  final String deviceIp;
  final List<ShowFixture> fixtures;
  final List<ShowPlayback> playbacks;
  // The file as read by the core, with everything the app model does not
  // hold (16-bit values, per-fixture FX, unknown attributes) - for export.
  final core.Show? source;

  const ParsedShow({
    required this.appVersion,
    required this.deviceType,
    required this.firmwareVersion,
    required this.deviceIp,
    required this.fixtures,
    required this.playbacks,
    this.source,
  });

  /// Put one playback into a cuelist slot (settings and cues). [src] is the
  /// same playback as read by the core, kept for a lossless export.
  /// [patched]: the patched slots (an empty slot's values are read from its
  /// record directly, see [modelCue]).
  static void fillCuelist(Cuelist cl, ShowPlayback pb, core.ShowPlayback? src, {Set<int> patched = const {}}) {
    cl.label      = pb.label;
    cl.level      = pb.intensity;
    cl.hasLevel   = true;
    cl.speed      = pb.speed;
    cl.goMode     = pb.goMode;
    cl.repeatMode = pb.repeatMode;
    cl.background = pb.background;
    cl.exclusive  = pb.exclusive;
    cl.cues.clear();
    for (int ci = 0; ci < pb.cues.length; ci++) {
      cl.cues.add(modelCue(pb.cues[ci], ci,
          src != null && ci < src.cues.length ? src.cues[ci] : null, patched: patched));
    }
  }

  /// One cue for the app model. [src] keeps the original blocks.
  static Cue modelCue(ShowCue sc, int ci, core.ShowCue? src, {Set<int> patched = const {}}) {
    // Translate numeric fn-code keys -> attr string keys used by edit_screen.
    final cueChannels = <String, double>{};
    for (final e in sc.channels.entries) {
      final sep = e.key.indexOf(':');
      if (sep < 0) continue;
      final fixtureIdx = e.key.substring(0, sep);
      final fnCode = int.tryParse(e.key.substring(sep + 1));
      if (fnCode == null) continue;
      final attrKey = kCodeToAttr[fnCode]; // coarse channels only
      if (attrKey == null) continue;
      final newKey = '$fixtureIdx:$attrKey';
      final val = e.value / 255.0;
      if ((cueChannels[newKey] ?? 0) < val) cueChannels[newKey] = val;
    }
    // A recorded empty (unpatched) slot has no channel list to decode by:
    // read its values straight from its record, by the fixed attribute
    // offsets, so it is part of the cue (white on the EDIT page after LOAD).
    if (src != null) {
      for (var slot = 0; slot < 64; slot++) {
        if (patched.contains(slot)) continue;
        final block = slot ~/ 16 < src.blocks.length ? src.blocks[slot ~/ 16] : Uint8List(0);
        final base = (slot % 16) * core.recordSize;
        if (block.length < base + core.recordSize) continue;
        for (final attr in kAttrRecordOffset.keys) {
          if (recordU16(block, base, kAttrRecordOffset[attr]!) != 0) {
            cueChannels['$slot:$attr'] = recordDmx(block, base, attr) / 65535;
          }
        }
      }
    }
    // The fixtures the cue holds: every record with data (values or FX), like
    // the reference app shows them after LOAD.
    final cueSlots = <int>{};
    if (src != null) {
      for (var slot = 0; slot < 64; slot++) {
        final block = slot ~/ 16 < src.blocks.length ? src.blocks[slot ~/ 16] : Uint8List(0);
        final base = (slot % 16) * core.recordSize;
        if (block.length < base + core.recordSize) continue;
        if (block.sublist(base, base + core.recordSize).any((x) => x != 0)) cueSlots.add(slot);
      }
    }
    // Fixtures with other FX than the cue's (the EDIT page shows one FX):
    // kept, so a RECORD or an export does not give them the cue's.
    final slotFx = <int, List<CueFxSlot>>{};
    if (src != null) {
      final cueFx = [sc.fxIntensity ?? CueFxSlot(), sc.fxPosition ?? CueFxSlot(), sc.fxColour ?? CueFxSlot()];
      final cueBytes = [for (final (g, f) in cueFx.indexed) codec.fxBytes(codec.fxGenerators[g], fxValues(f))];
      const offsets = [kFxIntensityOffset, kFxPositionOffset, kFxColourOffset];
      for (final slot in cueSlots) {
        final block = src.blocks[slot ~/ 16];
        final base = (slot % 16) * core.recordSize;
        final own = [for (final o in offsets) block.sublist(base + o, base + o + 4)];
        var differs = false;
        for (var g = 0; g < 3; g++) {
          for (var i = 0; i < 4; i++) {
            if (own[g][i] != cueBytes[g][i]) differs = true;
          }
        }
        if (differs) {
          slotFx[slot] = [for (final (g, b) in own.indexed) fxFromBytes(codec.fxGenerators[g], b)];
        }
      }
    }
    final cue = Cue(
      number:      ci + 1,
      label:       sc.label.isNotEmpty ? sc.label : 'Cue ${ci + 1}',
      // Red on the EDIT page only when the cue holds something (a new cue
      // the LPU reports back is empty: white, like the reference app).
      isRecorded:  cueChannels.isNotEmpty ||
          (sc.fxIntensity?.active ?? false) || (sc.fxPosition?.active ?? false) || (sc.fxColour?.active ?? false) ||
          (src?.blocks.any((b) => b.any((x) => x != 0)) ?? false),
      fadeIn:      sc.fadeSeconds,
      fadeOut:     sc.fadeSeconds,
      delay:       sc.delaySeconds,
      condition:   sc.condition,
      channels:    cueChannels,
      fxIntensity: sc.fxIntensity,
      fxPosition:  sc.fxPosition,
      fxColour:    sc.fxColour,
      slots:       cueSlots,
      slotFx:      slotFx,
    );
    // Keep the original blocks so an unchanged cue exports byte for byte.
    if (src != null) {
      cue.rawBlocks = [for (final b in src.blocks) b.isEmpty ? '' : base64Encode(b)];
      cue.rawSignature = cueSignature(cue);
    }
    return cue;
  }

  /// One fixture slot for the app model.
  static FixturePatch modelFixture(ShowFixture sf, int id) {
    // Build the set of attr keys this fixture supports from its function codes.
    final attrChannels = <String>{};
    for (final fn in sf.functionCodes) {
      final k = kCodeToAttr[fn];
      if (k != null) attrChannels.add(k);
    }
    return FixturePatch(
      id:           id,
      slot:         sf.index,
      // The patch-screen name; empty = unnamed (the patch tile shows the number).
      label:        sf.name,
      invertPan:     sf.invertPan,
      invertTilt:    sf.invertTilt,
      swapPanTilt:   sf.swapPanTilt,
      virtualDimmer: sf.virtualDimmer,
      manufacturer: sf.manufacturer,
      model:        sf.model,
      mode:         sf.mode,
      address:      sf.address,
      universe:     sf.universe,
      channelCount: sf.channelCount,
      channels:     attrChannels,
      fixtureClass: sf.fixtureClass,
      profile:      sf.profileHex,
    );
  }

  // Populate a ShowModel from this parsed file.
  // Fills cuelist labels, cues (with fade times and channel snapshots), and
  // fixture patch list.  All states are left as released.
  void applyToModel(ShowModel model) {
    // Rebuild 64-slot cuelist array.
    model.cuelists.clear();
    for (int i = 0; i < 64; i++) {
      model.cuelists.add(Cuelist(id: i + 1));
    }

    for (final pb in playbacks) {
      final slotIndex = pb.index;
      if (slotIndex < 0 || slotIndex >= model.cuelists.length) continue;
      fillCuelist(model.cuelists[slotIndex], pb, source?.playback(pb.index),
          patched: {for (final f in fixtures) if (f.manufacturer.isNotEmpty || f.model.isNotEmpty) f.index});
    }

    // Rebuild fixture list.
    model.fixtures.clear();
    for (int i = 0; i < fixtures.length; i++) {
      model.fixtures.add(modelFixture(fixtures[i], i + 1));
    }

    // The fixture map, so live updates of single cues can be decoded.
    model.liveFixtureMap = <int, ShowFixture>{
      for (final f in fixtures) f.index: f,
    };

    model.deviceInfo = {...?source?.device};
    model.showModified = false;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    model.notifyListeners();
  }
}

// ---------------------------------------------------------------------------
// ShowLoader
// ---------------------------------------------------------------------------

class ShowLoader {
  /// Parse a .show file from raw bytes (UTF-8 XML).
  static ParsedShow? loadFromBytes(Uint8List bytes) {
    try {
      return _parse(utf8.decode(bytes));
    } catch (e) {
      // ignore: avoid_print
      print('ShowLoader.loadFromBytes error: $e');
      return null;
    }
  }

  /// Parse a .show file from a UTF-8 string.
  static ParsedShow? loadFromString(String xmlStr) {
    try {
      return _parse(xmlStr);
    } catch (e) {
      // ignore: avoid_print
      print('ShowLoader.loadFromString error: $e');
      return null;
    }
  }

  static ParsedShow _parse(String xmlStr) => fromShow(core.parseShow(xmlStr));

  /// A show read by the core (from a file or downloaded from the LPU).
  static ParsedShow fromShow(core.Show show) {
    final fixtures = show.fixtures.map(ShowFixture.fromCore).toList();
    final fixtureMap = <int, ShowFixture>{
      for (final f in fixtures) f.index: f,
    };
    return ParsedShow(
      appVersion:      show.version,
      deviceType:      show.device['type'] ?? '',
      firmwareVersion: show.device['firmware_version'] ?? '',
      deviceIp:        show.device['ip'] ?? '',
      fixtures:        fixtures,
      playbacks:       [for (final p in show.playbacks) playbackFromCore(p, fixtureMap)],
      source:          show,
    );
  }

  static ShowPlayback playbackFromCore(core.ShowPlayback pb, Map<int, ShowFixture> fixtureMap) =>
      ShowPlayback(
        index:      pb.index,
        label:      pb.label,
        intensity:  pb.intensity,
        goMode:     _parseGoMode(pb.goMode),
        repeatMode: _parseRepeatMode(pb.repeat),
        speed:      pb.speed, // absent in the file = 0 (normal speed), like the LPU
        background: pb.background,
        exclusive:  pb.exclusive,
        cues:       [for (final c in pb.cues) cueFromCore(c, fixtureMap)],
      );

  static ShowCue cueFromCore(core.ShowCue cue, Map<int, ShowFixture> fixtureMap) {
    // 4 blocks = 4 banks of 16 fixtures; global fixture index = block*16 + record.
    final channels = <String, int>{};
    CueFxSlot? fxIntensity;
    CueFxSlot? fxPosition;
    CueFxSlot? fxColour;
    for (int b = 0; b < cue.blocks.length; b++) {
      final raw = cue.blocks[b];
      if (raw.length < core.blockSize) continue;
      final bankOffset = b * 16;
      channels.addAll(decodeBlock800(raw, fixtureMap, bankOffset: bankOffset));
      // The app model holds one FX per cue: taken from the first fixture with FX.
      final fx = decodeFxFromBlock(raw, fixtureMap, bankOffset: bankOffset);
      fxIntensity ??= fx.intens;
      fxPosition  ??= fx.pos;
      fxColour    ??= fx.colour;
    }
    return ShowCue(
        label:        cue.label,
        fadeSeconds:  cue.fadeMs / 1000.0,
        delaySeconds: cue.delayMs / 1000.0,
        // The LPU knows Halt (here CueCondition.always) and Follow only.
        condition:    cue.follow ? CueCondition.follow : CueCondition.always,
        channels:     channels,
        fxIntensity:  fxIntensity,
        fxPosition:   fxPosition,
        fxColour:     fxColour);
  }

  // Decode a raw 800-byte fixture-record block (16 records x 50 bytes).
  // Called both from .show XML parsing and from live LPU UDP sync packets.
  // Returns 'fixtureIndex:functionCode' -> uint8 DMX level (0-255).
  // bankOffset is the global index of record 0 in this block (block * 16).
  // Fixtures are keyed by global index; the channel key stays global so banks
  // 1-3 (fixtures 16-63) do not collide with bank 0.
  static Map<String, int> decodeBlock800(
      Uint8List raw, Map<int, ShowFixture> fixtureMap, {int bankOffset = 0}) {
    if (raw.length < 800) return {};

    final channels = <String, int>{};

    for (final entry in fixtureMap.entries) {
      final fixtureIndex = entry.key;
      final fixture      = entry.value;
      final rec = fixtureIndex - bankOffset;
      if (rec < 0 || rec >= 16) continue;

      final recStart = rec * 50;

      for (final fnCode in fixture.functionCodes) {
        final attr = attrForCode(fnCode);
        final off = attr == null ? null : kAttrRecordOffset[attr];
        // a slot left at zero is not part of the cue (pan / tilt: the centre)
        if (off == null || recordU16(raw, recStart, off) == 0) continue;
        final value = recordDmxForCode(raw, recStart, fnCode)!;

        final key = '$fixtureIndex:$fnCode';
        final existing = channels[key] ?? 0;
        if (value > existing) channels[key] = value;
      }
    }

    return channels;
  }
}
