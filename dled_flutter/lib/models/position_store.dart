// position_store.dart -- stored positions: up to 64
// tiles, each with a pan / tilt per fixture, kept per show.
//
// Only in our app: the LPU and the reference app know nothing of it. The
// reference app drops a <positions> section from a .show when it saves
// (2026-11-07), so on Windows the positions are a file next to the show,
// NAME.positions.json; in the app's internal storage they are part of the
// show's JSON.
//
// Pan / tilt are 16-bit (0-65535, 32768 ~ the centre), so a FINE position
// comes back as it was. EDIT works in 0-255 ([fromEdit] / [toEdit]).

import 'dart:convert';

class StoredFixture {
  final int slot;
  final String manufacturer, model, mode, name;
  final int pan, tilt; // 0-65535

  const StoredFixture({
    required this.slot,
    this.manufacturer = '',
    this.model = '',
    this.mode = '',
    this.name = '',
    required this.pan,
    required this.tilt,
  });

  /// EDIT's 0-255 slider value as 16 bits.
  static int fromEdit(double v) => (v.clamp(0.0, 255.0) / 255 * 65535).round();

  /// 16 bits as EDIT's 0-255 slider value.
  static double toEdit(int v) => v.clamp(0, 65535) / 65535 * 255;

  double get editPan => toEdit(pan);
  double get editTilt => toEdit(tilt);

  Map<String, dynamic> toJson() => {
        'slot': slot,
        if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
        if (model.isNotEmpty) 'model': model,
        if (mode.isNotEmpty) 'mode': mode,
        if (name.isNotEmpty) 'name': name,
        'pan': pan,
        'tilt': tilt,
      };

  static StoredFixture? fromJson(Object? j) {
    if (j is! Map) return null;
    final slot = j['slot'], pan = j['pan'], tilt = j['tilt'];
    if (slot is! int || slot < 0 || slot >= 64 || pan is! int || tilt is! int) return null;
    String s(String k) => j[k] is String ? j[k] as String : '';
    return StoredFixture(
      slot: slot,
      manufacturer: s('manufacturer'),
      model: s('model'),
      mode: s('mode'),
      name: s('name'),
      pan: pan.clamp(0, 65535),
      tilt: tilt.clamp(0, 65535),
    );
  }
}

class StoredPosition {
  String name;
  DateTime saved;
  final Map<int, StoredFixture> fixtures; // by slot

  StoredPosition({this.name = '', DateTime? saved, Map<int, StoredFixture>? fixtures})
      : saved = saved ?? DateTime.now(),
        fixtures = fixtures ?? {};

  Map<String, dynamic> toJson(int tile) => {
        'tile': tile,
        if (name.isNotEmpty) 'name': name,
        'saved': saved.toIso8601String(),
        'fixtures': [for (final s in fixtures.keys.toList()..sort()) fixtures[s]!.toJson()],
      };
}

class PositionStore {
  static const tiles = 64;
  static const version = 1;

  final Map<int, StoredPosition> positions = {};

  bool get isEmpty => positions.isEmpty;
  StoredPosition? operator [](int tile) => positions[tile];

  void clear() => positions.clear();

  /// STORE onto [tile]: merge (the user's choice, 2026-11-07) - these
  /// fixtures are added or updated, the others in the tile stay. Nothing
  /// happens without fixtures.
  bool store(int tile, Iterable<StoredFixture> fixtures, {DateTime? now}) {
    if (tile < 0 || tile >= tiles || fixtures.isEmpty) return false;
    final p = positions[tile] ??= StoredPosition();
    for (final f in fixtures) {
      p.fixtures[f.slot] = f;
    }
    p.saved = now ?? DateTime.now();
    return true;
  }

  bool delete(int tile) => positions.remove(tile) != null;

  bool rename(int tile, String name) {
    final p = positions[tile];
    if (p == null) return false;
    p.name = name.trim();
    return true;
  }

  /// SWAP: two tiles change places (an empty one too: a move).
  bool swap(int a, int b) {
    if (a == b || a < 0 || b < 0 || a >= tiles || b >= tiles) return false;
    final pa = positions.remove(a), pb = positions.remove(b);
    if (pa == null && pb == null) return false;
    if (pa != null) positions[b] = pa;
    if (pb != null) positions[a] = pb;
    return true;
  }

  // --- file -------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'version': version,
        'positions': [for (final t in positions.keys.toList()..sort()) positions[t]!.toJson(t)],
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// Replaces the contents with [j] (what [toJson] wrote). A newer version,
  /// or anything that is not a position store, leaves it empty; broken
  /// entries are skipped.
  void fromJson(Object? j) {
    positions.clear();
    if (j is! Map) return;
    final v = j['version'];
    if (v is! int || v < 1 || v > version) return;
    final list = j['positions'];
    if (list is! List) return;
    for (final e in list) {
      if (e is! Map) continue;
      final tile = e['tile'];
      if (tile is! int || tile < 0 || tile >= tiles || positions.containsKey(tile)) continue;
      final fx = <int, StoredFixture>{};
      for (final f in e['fixtures'] is List ? e['fixtures'] as List : const []) {
        final s = StoredFixture.fromJson(f);
        if (s != null) fx[s.slot] = s;
      }
      if (fx.isEmpty) continue;
      positions[tile] = StoredPosition(
        name: e['name'] is String ? e['name'] as String : '',
        saved: e['saved'] is String ? DateTime.tryParse(e['saved'] as String) : null,
        fixtures: fx,
      );
    }
  }

  /// [fromJson] from a file's text; not JSON = empty.
  void decode(String text) {
    try {
      fromJson(jsonDecode(text));
    } catch (_) {
      positions.clear();
    }
  }
}
