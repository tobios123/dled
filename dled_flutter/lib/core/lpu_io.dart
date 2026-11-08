// lpu_io.dart -- whole-show download/upload, comparison and live actions.
//
// Download (what the reference app does on connect, FINDINGS 20.7/20.8):
//   device:    short properties MAC, subnet, firmware, PCB, alias, Art-Net
//              universe (UI x 16) / enabled, sACN enabled / universe
//   fixtures:  per slot 0-63: 1f 30 state (address << 16 | pan/tilt flags),
//              1f 07 definition, 1f 05 name, 1f 13 virtual dimmer
//   playbacks: per slot 0-63: 29 30 packed state, 29 05 label, 29 17 intensity,
//              29 15 speed
//   cues:      per existing cue: 2b 05 label, 27 condition, 29 fade, 2b delay,
//              46 blocks 0-3
// Only indexes the LPU itself reported are read.
//
// Upload (what the reference app does when it opens a .show, VN_PROTOCOL.md 12):
//   2c 1d 38 reset, 2c 05 3c clear selection, then for slots 0-63 either the
//   fixture/playback writes or a delete, every frame lock-step on its echo.
//
// Mirrors analysis/lpu/lpu_io.py.

import 'dart:typed_data';

import 'frame.dart';
import 'lpu_client.dart';
import 'lpu_live.dart';
import 'show_file.dart';

export 'lpu_live.dart' show LpuInfo, PlaybackStatus, playbackState;

const int slots = 64;

int _u32(Uint8List b) => b.length >= 4 ? ByteData.sublistView(b).getUint32(0, Endian.little) : 0;

/// '"Mfr","Model","Mode","PROFILE"' -> 4 strings, or null when empty.
List<String>? parseDefinition(String s) {
  final parts = s.split('","').map((p) => p.trim().replaceAll('"', '')).toList();
  if (parts.length != 4 || parts.every((p) => p.isEmpty)) return null;
  return parts;
}

typedef Log = void Function(String message);

void _quiet(String _) {}

// --- download -----------------------------------------------------------------

Future<LpuInfo> readDevice(LpuClient c, Show show, {Log log = _quiet}) async {
  final info = LpuInfo();
  final d = <String, String>{};
  try {
    final mac = await c.shortRead(ShortProp.mac);
    info.mac = d['mac'] = mac.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(':');
    final sub = await c.shortRead(ShortProp.subnet);
    info.subnet = d['subnet'] = sub.take(4).join('.');
    final fw = await c.shortRead(ShortProp.firmware);
    info.firmware =
        d['firmware_version'] = fw.length >= 2 ? '${fw[0]}.${fw[1].toString().padLeft(2, '0')}' : '';
    final pcb = await c.shortRead(ShortProp.pcb);
    info.pcb = d['pcb_version'] = pcb.length >= 2 ? '${pcb[0]}.${pcb[1]}' : '';
    info.alias = decStr(await c.shortRead(ShortProp.alias));
    info.artNetUniverseRaw = _u32(await c.shortRead(ShortProp.artNetUniverse));
    info.artNetEnabled = _u32(await c.shortRead(ShortProp.artNetEnabled)) != 0;
    info.sacnEnabled = _u32(await c.shortRead(ShortProp.sacnEnabled)) != 0;
    info.sacnUniverse = _u32(await c.shortRead(ShortProp.sacnUniverse));
  } on LpuError catch (e) {
    log('  device info incomplete: $e'); // device info is optional
  }
  d['ip'] = c.address.address;
  d['type'] = 'LPU-1';
  show.device = d;
  return info;
}

// The reads below are started together where they do not depend on each
// other; the client keeps up to readWindow in flight (lpu_client.dart).
// Results keep their slot / cue order.

Future<void> readFixtures(LpuClient c, Show show, {Log log = _quiet}) async {
  final all = await Future.wait([for (var i = 0; i < slots; i++) readFixture(c, i)], eagerError: true);
  show.fixtures.addAll(all.whereType<ShowFixture>());
  log('  fixtures: ${show.fixtures.length} patched');
}

/// One fixture slot (0-63); null when nothing is patched there.
Future<ShowFixture?> readFixture(LpuClient c, int i) async {
  final state = _u32((await c.read(objFixture, 0x30, i1: i)).body);
  final addr = state >> 16;
  if (addr == 0xffff) {
    // No address: empty, unless the user named the slot (the LPU keeps a
    // name for an empty slot).
    final name = await c.readValue(objFixture, 0x05, i1: i) as String;
    return name.isEmpty ? null : ShowFixture(index: i, address: 1, manufacturer: '', model: '', mode: '', profile: '', name: name);
  }
  final r = await Future.wait([
    c.read(objFixture, 0x07, i1: i),
    c.readValue(objFixture, 0x05, i1: i),
    c.readValue(objFixture, 0x13, i1: i).then<Object?>((v) => v, onError: (_) => null), // optional
  ]);
  // No personality but an address: a slot the user addressed (and maybe
  // named), kept with an empty definition.
  final parts = parseDefinition(decStr((r[0] as Frame).body)) ?? ['', '', '', ''];
  final f = ShowFixture(
    index: i,
    address: addr,
    manufacturer: parts[0],
    model: parts[1],
    mode: parts[2],
    profile: parts[3],
    name: r[1] as String,
    invertPan: state & 1 != 0,
    invertTilt: state & 2 != 0,
    swapPanTilt: state & 4 != 0,
  );
  if (r[2] != null) f.virtualDimmer = r[2] != 0;
  return f;
}

Future<void> readPlaybacks(LpuClient c, Show show,
    {Log log = _quiet, void Function(int pb, int cue, int count)? progress}) async {
  final all = await Future.wait([for (var p = 0; p < slots; p++) readPlayback(c, p, progress: progress)], eagerError: true);
  show.playbacks.addAll(all.whereType<ShowPlayback>());
  log('  playbacks: ${show.playbacks.length}, cues: '
      '${show.playbacks.fold<int>(0, (n, p) => n + p.cues.length)}');
}

/// One cue of a playback: settings and its 4 blocks.
Future<ShowCue> readCue(LpuClient c, int p, int q) async {
  final r = await Future.wait<Object>([
    c.readValue(objCue, 0x05, i1: p, i2: q),
    c.readValue(objCue, 0x27, i1: p, i2: q),
    c.readValue(objCue, 0x29, i1: p, i2: q),
    c.readValue(objCue, 0x2b, i1: p, i2: q),
    for (var b = 0; b < 4; b++) c.read(objCue, 0x46, i1: p, i2: q, i3: b),
  ]);
  final cue = ShowCue(
    label: r[0] as String,
    follow: r[1] != 0,
    fadeMs: r[2] as int,
    delayMs: r[3] as int,
  );
  for (var b = 0; b < 4; b++) {
    final data = (r[4 + b] as Frame).body;
    cue.blocks[b] = data.any((x) => x != 0) ? data : Uint8List(0);
  }
  return cue;
}

/// One playback slot (0-63) with its cues; null when the slot is empty.
Future<ShowPlayback?> readPlayback(LpuClient c, int p,
    {void Function(int pb, int cue, int count)? progress}) async {
  final r = await Future.wait<Object>([
    c.read(objPlayback, 0x30, i1: p),
    c.readValue(objPlayback, 0x05, i1: p),
    c.readValue(objPlayback, 0x17, i1: p),
    c.readValue(objPlayback, 0x15, i1: p),
  ]);
  final body = (r[0] as Frame).body;
  final b0 = body.length >= 4 ? body[0] : 0, b1 = body.length >= 4 ? body[1] : 0;
  final count = body.length >= 4 ? body[2] : 0;
  final label = r[1] as String;
  final intensity = r[2] as double;
  final speed = r[3] as double;
  final goMode = b0 >> 4, repeat = b1 >> 4, state = b1 & 0x0f;
  final pb = ShowPlayback(
    index: p,
    label: label,
    intensity: intensity,
    speed: speed,
    goMode: goMode < 4 ? goModes[goMode] : 'Go',
    repeat: repeat < 4 ? repeatModes[repeat] : 'Loop',
    background: b0 & 1 != 0,
    exclusive: b0 & 2 != 0,
  );
  final nonDefault = label.isNotEmpty ||
      (intensity - 1).abs() > 1e-6 ||
      speed.abs() > 1e-6 ||
      goMode != 0 ||
      repeat != 0 ||
      pb.background ||
      pb.exclusive;
  if (state == 0 && count == 0 && !nonDefault) return null;
  var done = 0;
  pb.cues.addAll(await Future.wait([
    for (var q = 0; q < count; q++)
      readCue(c, p, q).then((cue) {
        progress?.call(p, done++, count);
        return cue;
      }),
  ]));
  return pb;
}

/// Read the whole show (and the device settings) from an open client.
Future<({Show show, LpuInfo info})> download(LpuClient c,
    {Log log = _quiet, void Function(int pb, int cue, int count)? progress}) async {
  final show = Show(application: 'DLED', version: showFormatVersion);
  log('Reading show from LPU ${c.address.address} ...');
  // One read on its own first: an LPU that is not there fails here in one
  // timeout, not after hundreds of reads in flight.
  await c.read(objPlayback, 0x30, i1: 0);
  final info = await readDevice(c, show, log: log);
  await readFixtures(c, show, log: log);
  await readPlaybacks(c, show, log: log, progress: progress);
  return (show: show, info: info);
}

// --- upload -------------------------------------------------------------------

/// Write [show] to the LPU, replacing everything on it.
/// [fraction] reports how much is sent (0..1); when [cancelled] returns true
/// the upload stops before the next frame with [UploadCancelled] (the LPU then
/// holds part of the show).
Future<void> upload(LpuClient c, Show show,
    {Log log = _quiet,
    void Function(int pb, int cue, int count)? progress,
    void Function(double done)? fraction,
    bool Function()? cancelled}) async {
  // A cue count above 48 hangs the LPU (no answers, no DMX, until a power
  // cycle; lpd/DMX_ENGINE.md 12): refuse before anything is sent.
  for (final pb in show.playbacks) {
    if (pb.cues.length > 48) {
      throw LpuError('playback ${pb.index + 1} has ${pb.cues.length} cues; the LPU takes at most 48');
    }
  }
  // frames to send: 3 + per fixture slot 1 or 7 + per playback slot 1 or
  // 8 + 8 per cue
  final total = 3 +
      show.fixtures.length * 6 +
      slots * 2 +
      show.playbacks.fold<int>(0, (n, p) => n + 7 + 8 * p.cues.length);
  var sent = 0;
  void sentOne() => fraction?.call((++sent / total).clamp(0.0, 1.0));
  void stopIfCancelled() {
    if (cancelled?.call() ?? false) throw UploadCancelled();
  }

  // Writes that create something (a fixture's definition, a playback's cue
  // count) go one by one, in order; the rest is queued with q() and sent by
  // flush() several at once (their order does not matter).
  final queued = <VnWrite>[];
  void q(int op, int type, int prop, {int i1 = 0, int i2 = 0, int i3 = 0, Uint8List? body}) =>
      queued.add((op: op, type: type, prop: prop, i1: i1, i2: i2, i3: i3, body: body));
  Future<void> flush() async {
    if (queued.isNotEmpty) {
      final writes = List.of(queued);
      queued.clear();
      await c.writeAll(writes, onEach: sentOne, cancelled: cancelled);
    }
    stopIfCancelled();
  }

  Future<void> w(int op, int type, int prop, {int i1 = 0, int i2 = 0, int i3 = 0, Uint8List? body}) async {
    await flush();
    await c.write(op, type, prop, i1: i1, i2: i2, i3: i3, body: body);
    sentOne();
  }

  // RELEASE ALL first: replacing the show under running playbacks can leave
  // the LPU stuck in "releasing" until a power cycle (FINDINGS 20.13).
  await w(objAction, tNoBody, 0x42);
  await w(objGlobal, tNoBody, 0x38); // CLEAR programmer (FINDINGS 20.17)
  await w(objGlobal, tBlob, 0x3c, body: Uint8List(8)); // clear fixture selection
  final fixtures = {for (final f in show.fixtures) f.index: f};
  for (var i = 0; i < slots; i++) {
    if (fixtures[i] == null) q(objFixture, tNoBody, 0x38, i1: i); // empty slots
  }
  for (final f in fixtures.values) {
    await w(objFixture, tStr, 0x08, i1: f.index, body: encStr(f.definition));
  }
  for (final f in fixtures.values) {
    final i = f.index;
    q(objFixture, tU32, 0x0c, i1: i, body: encU32(f.address));
    // Name and flags from the file (absent = empty / off), always written.
    q(objFixture, tStr, 0x06, i1: i, body: encStr(f.name));
    for (final (prop, on) in [
      (0x0e, f.invertPan),
      (0x10, f.invertTilt),
      (0x12, f.swapPanTilt),
      (0x14, f.virtualDimmer),
    ]) {
      q(objFixture, tBool, prop, i1: i, body: encBool(on));
    }
  }
  await flush();
  log('  fixtures written: ${fixtures.length}');
  final playbacks = {for (final p in show.playbacks) p.index: p};
  var blocks = 0;
  for (var p = 0; p < slots; p++) {
    if (playbacks[p] == null) q(objPlayback, tNoBody, 0x38, i1: p); // empty slots
  }
  for (final pb in playbacks.values) {
    await w(objPlayback, tU32, 0x48, i1: pb.index, body: encU32(pb.cues.length));
  }
  for (final pb in playbacks.values) {
    final p = pb.index;
    for (var n = 0; n < pb.cues.length; n++) {
      final cue = pb.cues[n];
      for (var b = 0; b < 4; b++) {
        q(objCue, tPage, 0x47,
            i1: p, i2: n, i3: b, body: Uint8List.fromList(cue.block(b).take(blockSize).toList()));
        blocks++;
      }
      q(objCue, tStr, 0x06, i1: p, i2: n, body: encStr(cue.label));
      q(objCue, tU32, 0x2a, i1: p, i2: n, body: encU32(cue.fadeMs));
      q(objCue, tU32, 0x2c, i1: p, i2: n, body: encU32(cue.delayMs));
      q(objCue, tU32, 0x28, i1: p, i2: n, body: encU32(cue.follow ? 1 : 0));
    }
    q(objPlayback, tStr, 0x06, i1: p, body: encStr(pb.label));
    q(objPlayback, tFloat, 0x18, i1: p, body: encFloat(pb.intensity));
    q(objPlayback, tFloat, 0x16, i1: p, body: encFloat(pb.speed));
    q(objPlayback, tU32, 0x21, i1: p, body: encU32(goModes.indexOf(pb.goMode).clamp(0, 3)));
    q(objPlayback, tU32, 0x2e, i1: p, body: encU32(repeatModes.indexOf(pb.repeat).clamp(0, 3)));
    q(objPlayback, tBool, 0x1e, i1: p, body: encBool(pb.background));
    q(objPlayback, tBool, 0x3a, i1: p, body: encBool(pb.exclusive));
    await flush(); // one playback at a time, for [progress]
    progress?.call(p, pb.cues.length - 1, pb.cues.length);
  }
  await flush();
  log('  playbacks written: ${playbacks.length} ($blocks cue blocks)');
}

/// The upload was stopped on request (Abort).
class UploadCancelled implements Exception {
  @override
  String toString() => 'upload cancelled';
}

// --- compare ------------------------------------------------------------------

/// Human-readable differences; empty = identical show content.
List<String> compareShows(Show expected, Show actual) {
  final diffs = <String>[];
  final ef = {for (final f in expected.fixtures) f.index: f};
  final af = {for (final f in actual.fixtures) f.index: f};
  for (final i in ({...ef.keys, ...af.keys}.toList()..sort())) {
    final a = ef[i], b = af[i];
    if (a == null || b == null) {
      diffs.add('fixture ${i + 1}: ${b == null ? 'missing on LPU' : 'extra on LPU'}');
      continue;
    }
    if (a.address != b.address) diffs.add('fixture ${i + 1}: address ${a.address} != ${b.address}');
    if (a.manufacturer != b.manufacturer ||
        a.mode != b.mode ||
        a.profile.toUpperCase() != b.profile.toUpperCase()) {
      diffs.add('fixture ${i + 1}: definition differs');
    }
    if (!(a.model == b.model || a.model.startsWith(b.model))) {
      diffs.add("fixture ${i + 1}: model '${a.model}' != '${b.model}'"); // LPU truncates names
    }
    if (a.name != b.name) diffs.add("fixture ${i + 1}: name '${a.name}' != '${b.name}'");
    // The LPU only keeps pan/tilt flags on fixtures that have pan or tilt.
    final hasPanTilt = a.codes.contains(0x02) || a.codes.contains(0x03);
    final flags = <(String, bool, bool)>[
      ('virtual_dimmer', a.virtualDimmer, b.virtualDimmer),
      if (hasPanTilt) ...[
        ('invert_pan', a.invertPan, b.invertPan),
        ('invert_tilt', a.invertTilt, b.invertTilt),
        ('swap_pan_tilt', a.swapPanTilt, b.swapPanTilt),
      ],
    ];
    for (final (name, x, y) in flags) {
      if (x != y) diffs.add('fixture ${i + 1}: $name $x != $y');
    }
  }
  final ep = {for (final p in expected.playbacks) p.index: p};
  final ap = {for (final p in actual.playbacks) p.index: p};
  for (final i in ({...ep.keys, ...ap.keys}.toList()..sort())) {
    final a = ep[i], b = ap[i];
    if (a == null || b == null) {
      diffs.add('playback ${i + 1}: ${b == null ? 'missing on LPU' : 'extra on LPU'}');
      continue;
    }
    for (final (name, x, y) in <(String, Object, Object)>[
      ('label', a.label, b.label),
      ('gomode', a.goMode, b.goMode),
      ('repeat', a.repeat, b.repeat),
      ('background', a.background, b.background),
      ('exclusive', a.exclusive, b.exclusive),
    ]) {
      if (x != y) diffs.add("playback ${i + 1}: $name '$x' != '$y'");
    }
    if ((a.intensity - b.intensity).abs() > 1e-4) {
      diffs.add('playback ${i + 1}: intensity ${formatG(a.intensity)} != ${formatG(b.intensity)}');
    }
    if ((a.speed - b.speed).abs() > 1e-4) {
      diffs.add('playback ${i + 1}: speed ${formatG(a.speed)} != ${formatG(b.speed)}');
    }
    if (a.cues.length != b.cues.length) {
      diffs.add('playback ${i + 1}: ${a.cues.length} cues != ${b.cues.length}');
    }
    for (var q = 0; q < a.cues.length && q < b.cues.length; q++) {
      final ca = a.cues[q], cb = b.cues[q];
      for (final (name, x, y) in <(String, Object, Object)>[
        ('label', ca.label, cb.label),
        ('fade_ms', ca.fadeMs, cb.fadeMs),
        ('delay_ms', ca.delayMs, cb.delayMs),
        ('follow', ca.follow, cb.follow),
      ]) {
        if (x != y) diffs.add("playback ${i + 1} cue ${q + 1}: $name '$x' != '$y'");
      }
      for (var blk = 0; blk < 4; blk++) {
        if (!_sameBytes(ca.block(blk), cb.block(blk))) {
          diffs.add('playback ${i + 1} cue ${q + 1}: block $blk differs');
        }
      }
    }
  }
  return diffs;
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// --- live actions ---------------------------------------------------------------

/// Press and release a playback button (GO 0x22 / FLASH 0x23), like the app.
Future<void> pressButton(LpuClient c, int playback, int prop, {Duration hold = Duration.zero}) async {
  await c.write(objPlayback, tBool, prop, i1: playback, body: encBool(true));
  if (hold > Duration.zero) await Future.delayed(hold);
  await c.write(objPlayback, tBool, prop, i1: playback, body: encBool(false));
}

Future<void> go(LpuClient c, int playback) => pressButton(c, playback, 0x22);

Future<void> flash(LpuClient c, int playback, {Duration hold = const Duration(milliseconds: 500)}) =>
    pressButton(c, playback, 0x23, hold: hold);

Future<void> release(LpuClient c, int playback) => c.write(objPlayback, tNoBody, 0x42, i1: playback);

Future<void> releaseAll(LpuClient c) => c.write(objAction, tNoBody, 0x42);

/// Playback properties window (only the given values are sent).
Future<void> setPlayback(LpuClient c, int playback,
    {String? goMode,
    String? repeat,
    bool? background,
    bool? exclusive,
    String? label,
    double? intensity,
    double? speed}) async {
  Future<void> w(int type, int prop, Uint8List body) =>
      c.write(objPlayback, type, prop, i1: playback, body: body);
  if (goMode != null) {
    final i = goModes.indexOf(goMode);
    if (i < 0) throw ArgumentError('go mode must be one of $goModes');
    await w(tU32, 0x21, encU32(i));
  }
  if (repeat != null) {
    final i = repeatModes.indexOf(repeat);
    if (i < 0) throw ArgumentError('repeat must be one of $repeatModes');
    await w(tU32, 0x2e, encU32(i));
  }
  if (background != null) await w(tBool, 0x1e, encBool(background));
  if (exclusive != null) await w(tBool, 0x3a, encBool(exclusive));
  if (label != null) await w(tStr, 0x06, encStr(label));
  if (intensity != null) await w(tFloat, 0x18, encFloat(intensity));
  if (speed != null) await w(tFloat, 0x16, encFloat(speed));
}

/// Patch one fixture slot live (PATCH): only the given parts, in the order
/// the upload writes them - the personality first (it creates the fixture),
/// then address, name and flags. An empty definition keeps a named / addressed
/// empty slot (FINDINGS: the LPU stores those).
Future<void> writeFixture(LpuClient c, ShowFixture f,
    {bool definition = false, bool address = false, bool name = false, bool flags = false}) async {
  if (definition) await c.write(objFixture, tStr, 0x08, i1: f.index, body: encStr(f.definition));
  if (address) await c.write(objFixture, tU32, 0x0c, i1: f.index, body: encU32(f.address));
  if (name) await c.write(objFixture, tStr, 0x06, i1: f.index, body: encStr(f.name));
  if (flags) {
    for (final (prop, on) in [
      (0x0e, f.invertPan),
      (0x10, f.invertTilt),
      (0x12, f.swapPanTilt),
      (0x14, f.virtualDimmer),
    ]) {
      await c.write(objFixture, tBool, prop, i1: f.index, body: encBool(on));
    }
  }
}

/// Clear a fixture slot (PATCH CLEAR). The delete keeps the slot's name, so
/// the name is cleared too (else the slot stays as a named empty slot).
Future<void> deleteFixture(LpuClient c, int slot) async {
  await c.write(objFixture, tNoBody, 0x38, i1: slot);
  await c.write(objFixture, tStr, 0x06, i1: slot, body: encStr(''));
}

Future<void> setAlias(LpuClient c, String alias) => c.shortWrite(ShortProp.aliasWrite, encStr(alias));

/// The LPU's own network settings, as the reference app's IP ADDRESS dialog writes
/// them (FINDINGS 20.18): device property 0x02 = IP, 0x04 = subnet mask, each
/// 4 bytes + 00 00. DHCP = both all zeros (IP first, like the reference app).
/// Static: the mask first, then the IP - the LPU moves to a new IP at once, so
/// a write after it would go to the old address.
Future<void> writeNetwork(LpuClient c, {List<int>? ip, List<int>? mask}) async {
  Uint8List six(List<int> four) => Uint8List.fromList([...four, 0, 0]);
  if (ip == null) {
    await c.shortWrite(ShortProp.ipWrite, six(const [0, 0, 0, 0]));
    await c.shortWrite(ShortProp.subnetWrite, six(const [0, 0, 0, 0]));
    return;
  }
  if (mask != null) await c.shortWrite(ShortProp.subnetWrite, six(mask));
  await c.shortWrite(ShortProp.ipWrite, six(ip));
}

/// Art-Net: [universe] is the UI value 0-15 (sent as x 16).
/// Art-Net output: [universe] is the UI universe (x 16 on the wire), [raw]
/// the wire value itself = subnet x 16 + universe (the reference app's "sub.uni").
Future<void> setArtNet(LpuClient c, {bool? enabled, int? universe, int? raw}) async {
  if (raw != null) await c.write(objArtNet, tU32, 0x33, body: encU32(raw));
  if (universe != null) await c.write(objArtNet, tU32, 0x33, body: encU32(universe * 16));
  if (enabled != null) await c.write(objArtNet, tBool, 0x26, body: encBool(enabled));
}

Future<void> setSacn(LpuClient c, {bool? enabled, int? universe}) async {
  if (universe != null) await c.write(objSacn, tU32, 0x33, body: encU32(universe));
  if (enabled != null) await c.write(objSacn, tBool, 0x26, body: encBool(enabled));
}

