import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/net.dart' as core_net;
import '../core/patch.dart';
import '../core/show_file.dart' as core;
import '../services/show_exporter.dart';
import 'position_store.dart';
export 'position_store.dart';
import '../services/programmer.dart' show ProgrammerWrite;
import '../services/show_folder.dart'
    if (dart.library.html) '../services/show_folder_web.dart';
import '../services/show_loader.dart';
import '../services/vn_service.dart'; // every platform (udp.dart: UDP or the bridge)

enum PlaybackState { released, releasing, playing, paused, indicated }

// FX slot data — one per FX category (intensity, position, colour) per cue.
// Mirrors the FxSlot class in edit_screen.dart but is persisted on the Cue.
class CueFxSlot {
  String waveform;
  double size;
  double speed;
  double phase;

  CueFxSlot({
    this.waveform = 'None',
    this.size     = 0,
    this.speed    = 0, // FX speed default in the reference app

    this.phase    = 0,
  });

  bool get active => waveform != 'None';

  Map<String, dynamic> toJson() => {
    'waveform': waveform,
    'size':     size,
    'speed':    speed,
    'phase':    phase,
  };

  factory CueFxSlot.fromJson(Map<String, dynamic> j) => CueFxSlot(
    waveform: j['waveform'] as String? ?? 'None',
    size:     (j['size']  as num?)?.toDouble() ?? 0,
    speed:    (j['speed'] as num?)?.toDouble() ?? 0,
    phase:    (j['phase'] as num?)?.toDouble() ?? 0,
  );

  // Copy values from this slot into a matching FxSlot-like object.
  // Used by edit_screen to restore the programmer FX state from a cue.
  CueFxSlot copyWith({String? waveform, double? size, double? speed, double? phase}) => CueFxSlot(
    waveform: waveform ?? this.waveform,
    size:     size     ?? this.size,
    speed:    speed    ?? this.speed,
    phase:    phase    ?? this.phase,
  );
}

enum CueCondition { always, follow, assert_, loop }

enum GoMode { go, toggle, flash, solo }
enum RepeatMode { loop, bounce, random, off }

/// The fixture slots with data (values or FX) in a cue's 4 blocks (base64,
/// '' = empty): 16 records of 50 bytes per block.
Set<int> slotsInBlocks(List<String> blocks) {
  final out = <int>{};
  for (final (b, text) in blocks.indexed) {
    if (text.isEmpty) continue;
    final bytes = base64Decode(text);
    for (var r = 0; r < 16 && (r + 1) * 50 <= bytes.length; r++) {
      if (bytes.sublist(r * 50, (r + 1) * 50).any((x) => x != 0)) out.add(b * 16 + r);
    }
  }
  return out;
}

class Cue {
  int number;
  String label;
  double fadeIn;
  double fadeOut;
  double delay;
  CueCondition condition;
  // Channel snapshot: key = 'fixtureSlot:attrKey', value = 0.0-1.0
  final Map<String, double> channels;
  // FX settings per category, persisted with the cue.
  final CueFxSlot fxIntensity;
  final CueFxSlot fxPosition;
  final CueFxSlot fxColour;
  // The fixture slots the cue holds (on the LPU: the records with data; the
  // FX apply to these too). Empty = not known (cues saved before this field).
  final Set<int> slots;
  // Fixtures whose FX differ from the cue's (intensity, position, colour):
  // on the LPU every record has its own FX, e.g. a phase spread.
  final Map<int, List<CueFxSlot>> slotFx;
  // True when this cue has been recorded (either loaded from a show file or
  // saved from the programmer). Drives the red border on the cue tile.
  bool isRecorded;
  // From an imported .show: the cue's 4 original blocks (base64, '' = empty)
  // and a signature of channels + FX at import. Export reuses the original
  // blocks while the signature still matches (services/show_exporter.dart).
  List<String>? rawBlocks;
  String? rawSignature;

  Cue({
    required this.number,
    this.label = '',
    this.fadeIn = 0.0,
    this.fadeOut = 0.0,
    this.delay = 0.0,
    this.condition = CueCondition.always,
    Map<String, double>? channels,
    CueFxSlot? fxIntensity,
    CueFxSlot? fxPosition,
    CueFxSlot? fxColour,
    this.isRecorded = false,
    this.rawBlocks,
    this.rawSignature,
    Set<int>? slots,
    Map<int, List<CueFxSlot>>? slotFx,
  })  : channels    = channels    ?? {},
        slots       = slots       ?? {},
        slotFx      = slotFx      ?? {},
        fxIntensity = fxIntensity ?? CueFxSlot(),
        fxPosition  = fxPosition  ?? CueFxSlot(),
        fxColour    = fxColour    ?? CueFxSlot();

  /// The FX of fixture [slot]: its own, or the cue's.
  List<CueFxSlot> fxOf(int slot) => slotFx[slot] ?? [fxIntensity, fxPosition, fxColour];

  Map<String, dynamic> toJson() => {
        'number':      number,
        'label':       label,
        'fadeIn':      fadeIn,
        'fadeOut':     fadeOut,
        'delay':       delay,
        'condition':   condition.index,
        'channels':    channels.map((k, v) => MapEntry(k, v)),
        'fxIntensity': fxIntensity.toJson(),
        'fxPosition':  fxPosition.toJson(),
        'fxColour':    fxColour.toJson(),
        'isRecorded':  isRecorded,
        if (slots.isNotEmpty) 'slots': (slots.toList()..sort()),
        if (slotFx.isNotEmpty)
          'slotFx': {for (final e in slotFx.entries) '${e.key}': [for (final f in e.value) f.toJson()]},
        if (rawBlocks != null) 'rawBlocks': rawBlocks,
        if (rawSignature != null) 'rawSignature': rawSignature,
      };

  factory Cue.fromJson(Map<String, dynamic> j) {
    final cue = Cue(
      number:      j['number'] as int,
      label:       j['label']  as String? ?? '',
      fadeIn:      (j['fadeIn']  as num?)?.toDouble() ?? 0.0,
      fadeOut:     (j['fadeOut'] as num?)?.toDouble() ?? 0.0,
      delay:       (j['delay']   as num?)?.toDouble() ?? 0.0,
      condition:   CueCondition.values[j['condition'] as int? ?? 0],
      channels:    (j['channels'] as Map<String, dynamic>? ?? {})
          .map((k, v) => MapEntry(k, (v as num).toDouble())),
      fxIntensity: j['fxIntensity'] != null
          ? CueFxSlot.fromJson(j['fxIntensity'] as Map<String, dynamic>)
          : null,
      fxPosition:  j['fxPosition']  != null
          ? CueFxSlot.fromJson(j['fxPosition']  as Map<String, dynamic>)
          : null,
      fxColour:    j['fxColour']    != null
          ? CueFxSlot.fromJson(j['fxColour']    as Map<String, dynamic>)
          : null,
      isRecorded:  j['isRecorded'] as bool? ?? false,
      rawBlocks:   (j['rawBlocks'] as List<dynamic>?)?.cast<String>(),
      rawSignature: j['rawSignature'] as String?,
      slots:       {...?(j['slots'] as List<dynamic>?)?.cast<int>()},
      slotFx: {
        for (final e in (j['slotFx'] as Map<String, dynamic>? ?? {}).entries)
          int.parse(e.key): [for (final f in e.value as List<dynamic>) CueFxSlot.fromJson(f as Map<String, dynamic>)],
      },
    );
    // Saved before the fixture list was kept: the original blocks have it.
    if (cue.slots.isEmpty && cue.rawBlocks != null) cue.slots.addAll(slotsInBlocks(cue.rawBlocks!));
    return cue;
  }
}

class Cuelist {
  final int id;
  String label;
  PlaybackState state;
  double level;
  double fadeIn;
  double fadeOut;
  double speed;
  final List<Cue> cues;
  int currentCueIndex;
  GoMode goMode;
  RepeatMode repeatMode;
  bool background;
  bool exclusive;
  // Internal bounce direction: true = forward, false = backward
  bool bounceForward = true;
  // [level] is a real fader value (from a show / the LPU, or the fader was
  // moved). Slots never touched in the app have level 0 meaning "not set";
  // the export sends those at full, the LPU default, but keeps a real 0.
  bool hasLevel;

  // Live values pushed by the LPU over VN protocol (not persisted).
  // liveLevel: fader/playback slider, 0.0-1.0 (sub=0x17 push from LPU)
  // liveSpeed: rotary knob speed, -1.0 to +1.0 (sub=0x15 push from LPU)
  double liveLevel = 0.0;
  double liveSpeed = 0.0;

  // Playing with a delay / fade still running (the LPU's cue phase 2): the
  // tile is green; when it is done the cue holds (phase 3, yellow).
  bool fading = false;
  // When the intensity / speed was last changed (here or on the LPU): the
  // tile shows "Intensity xx %" / "Speed xx %" for a moment, like the reference app.
  DateTime? levelChangedAt;
  DateTime? speedChangedAt;

  Cuelist({
    required this.id,
    this.label = '',
    this.state = PlaybackState.released,
    this.level = 0.0,
    this.fadeIn = 0.0,
    this.fadeOut = 0.0,
    this.speed = 0.0, // like the LPU: 0 = normal speed
    List<Cue>? cues,
    this.currentCueIndex = 0,
    this.goMode = GoMode.go,
    this.repeatMode = RepeatMode.loop,
    this.background = false,
    this.exclusive = false,
    this.hasLevel = false,
  }) : cues = cues ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'state': state.index,
        'level': level,
        'hasLevel': hasLevel,
        'fadeIn': fadeIn,
        'fadeOut': fadeOut,
        'speed': speed,
        'cues': cues.map((c) => c.toJson()).toList(),
        'currentCueIndex': currentCueIndex,
        'goMode': goMode.index,
        'repeatMode': repeatMode.index,
        'background': background,
        'exclusive': exclusive,
      };

  factory Cuelist.fromJson(Map<String, dynamic> j) => Cuelist(
        id: j['id'] as int,
        label: j['label'] as String? ?? '',
        state: PlaybackState.values[j['state'] as int? ?? 0],
        level: (j['level'] as num?)?.toDouble() ?? 0.0,
        fadeIn: (j['fadeIn'] as num?)?.toDouble() ?? 0.0,
        fadeOut: (j['fadeOut'] as num?)?.toDouble() ?? 0.0,
        speed: (j['speed'] as num?)?.toDouble() ?? 0.0,
        cues: (j['cues'] as List<dynamic>? ?? [])
            .map((c) => Cue.fromJson(c as Map<String, dynamic>))
            .toList(),
        currentCueIndex: j['currentCueIndex'] as int? ?? 0,
        goMode: GoMode.values[j['goMode'] as int? ?? 0],
        repeatMode: RepeatMode.values[j['repeatMode'] as int? ?? 0],
        background: j['background'] as bool? ?? false,
        exclusive: j['exclusive'] as bool? ?? false,
        hasLevel: j['hasLevel'] as bool? ?? false,
      );
}

/// The slots of fixtures whose DMX channels (address .. address + channels
/// - 1, per universe) overlap another fixture's. The LPU cannot drive those
/// properly, so PATCH shows their address in red (like the reference app).
/// (The rule itself is shared with the light page: core/patch.dart.)
Set<int> collidingSlots(List<FixturePatch> fixtures) => overlappingRanges([
      for (final f in fixtures)
        if (f.isPatched)
          (key: f.slot, start: f.address, count: f.channelCount < 1 ? 1 : f.channelCount, universe: f.universe)
    ]);

class FixturePatch {
  final int id;
  int slot;
  String label;
  String manufacturer;
  String model;
  String mode;
  int address;
  int universe;
  int channelCount; // derived from personality hex, 1 if unknown
  bool invertPan;
  bool invertTilt;
  bool swapPanTilt;
  bool virtualDimmer;
  // Attribute channels supported by this fixture (e.g. {'R','G','B'}).
  // Empty set means all channels are supported (backward-compatible default).
  Set<String> channels;
  // Fixture class from the personality library (e.g. 'Led', 'Yoke spot').
  String fixtureClass;
  // Profile hex from personalities.xml / the .show (one function code per DMX
  // channel); needed to write the fixture back into a .show file.
  String profile;

  FixturePatch({
    required this.id,
    required this.slot,
    this.label = '',
    this.manufacturer = '',
    this.model = '',
    this.mode = '',
    this.address = 1,
    this.universe = 0,
    this.channelCount = 1,
    this.invertPan = false,
    this.invertTilt = false,
    this.swapPanTilt = false,
    this.virtualDimmer = false,
    Set<String>? channels,
    this.fixtureClass = '',
    this.profile = '',
  }) : channels = channels ?? {};

  /// A personality is patched. An entry without one is an empty slot that
  /// only has a name / address / flags (the LPU keeps those for an empty
  /// slot too): it counts as empty everywhere else.
  bool get isPatched => manufacturer.isNotEmpty || model.isNotEmpty || profile.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'slot': slot,
        'label': label,
        'manufacturer': manufacturer,
        'model': model,
        'mode': mode,
        'address': address,
        'universe': universe,
        'channelCount': channelCount,
        'invertPan': invertPan,
        'invertTilt': invertTilt,
        'swapPanTilt': swapPanTilt,
        'virtualDimmer': virtualDimmer,
        'channels': channels.toList(),
        'fixtureClass': fixtureClass,
        'profile': profile,
      };

  factory FixturePatch.fromJson(Map<String, dynamic> j) => FixturePatch(
        id: j['id'] as int,
        slot: j['slot'] as int,
        label: j['label'] as String? ?? '',
        manufacturer: j['manufacturer'] as String? ?? '',
        model: j['model'] as String? ?? '',
        mode: j['mode'] as String? ?? '',
        address: j['address'] as int? ?? 1,
        universe: j['universe'] as int? ?? 0,
        channelCount: j['channelCount'] as int? ?? 1,
        invertPan: j['invertPan'] as bool? ?? false,
        invertTilt: j['invertTilt'] as bool? ?? false,
        swapPanTilt: j['swapPanTilt'] as bool? ?? false,
        virtualDimmer: j['virtualDimmer'] as bool? ?? false,
        channels: ((j['channels'] as List<dynamic>?) ?? [])
            .map((e) => e as String)
            .toSet(),
        fixtureClass: j['fixtureClass'] as String? ?? '',
        profile: j['profile'] as String? ?? '',
      );
}

class NetworkDevice {
  String ipAddress;
  String shortName;
  String longName;
  String label;
  bool artNetEnabled;
  bool sacnEnabled;
  int artNetUniverse;
  // Art-Net "sub.uni" as the LPU stores it: subnet x 16 + universe.
  int artNetRaw;
  int sacnUniverse;
  String firmware; // from discovery, e.g. 1.29
  String hardware; // PCB version, known once connected, e.g. 2.0

  // A discovered LPU. Art-Net / sACN / universe are the LPU's own output
  // settings (read from it when connected); the app sends no DMX itself.
  NetworkDevice({
    this.ipAddress = '',
    this.shortName = '',
    this.longName = '',
    this.label = '',
    this.artNetEnabled = false,
    this.sacnEnabled = false,
    this.artNetUniverse = 0,
    this.artNetRaw = 0,
    this.sacnUniverse = 1,
    this.firmware = '',
    this.hardware = '',
  });

  /// "sub.uni" like the reference app, e.g. 1.0
  String get artNetText => '${artNetRaw ~/ 16}.${artNetRaw % 16}';

  String get displayName => label.isNotEmpty
      ? label
      : shortName.isNotEmpty
          ? shortName
          : ipAddress;
}

// ---------------------------------------------------------------------------
// ShowFile: one saved show slot
// ---------------------------------------------------------------------------
class ShowFile {
  final String name;
  final DateTime savedAt;
  final int sizeBytes;
  ShowFile({required this.name, required this.savedAt, required this.sizeBytes});
}

class ShowModel extends ChangeNotifier {
  // VN protocol service (LPU devices, e.g. LPU-1).
  // Owned here so every screen can reach it.
  final VnService vnService = VnService();

  // App state
  String currentScreen = 'playback';
  bool blackout = false;
  bool blind = false;

  // Current show
  String showFileName = 'Untitled';
  bool showModified = false;
  final List<Cuelist> cuelists = [];
  final List<FixturePatch> fixtures = [];
  final List<NetworkDevice> networkDevices = [];

  /// The show's stored positions (POSITIONS in EDIT; models/position_store.dart).
  /// Saved with the show: on Windows as NAME.positions.json next to it.
  final PositionStore positions = PositionStore();

  /// POSITIONS recalls with its fixtures (true) or into the selected ones.
  bool positionsWithFixtures = false;

  /// A position was stored, renamed, deleted or moved.
  void positionsChanged() {
    showModified = true;
    notifyListeners();
  }

  // Fixture map populated from the most-recently loaded .show file or LPU sync.
  // Key = fixture block-record index (0-15), same as ShowFixture.index.
  // Used by live UDP cue-data packets to decode the 800-byte body.
  // Import show_loader.dart types here via a late import to avoid circular deps.
  dynamic liveFixtureMap; // Map<int, ShowFixture> set by ParsedShow.applyToModel

  // Saved show files (max 50)
  final List<ShowFile> showFiles = [];

  // <system><device> of an imported .show (mac, ip, firmware ...), written
  // back on export.
  Map<String, String> deviceInfo = {};

  // Settings
  bool soundEnabled = false;
  bool onscreenKeyboard = true;
  bool checkUpdatesAtStartup = true;
  String language = 'English';

  ShowModel() {
    _initDemoData();
    _initStorage();
    _rememberLpu();
  }

  /// A bare model for reading / writing one show (no storage set-up, no LPU).
  ShowModel._storage() {
    _initDemoData();
  }

  // Automatic connecting (VnService): the LPU the user chose last is kept
  // across app starts; the open show's LPU (<device><ip>) is the next choice.
  static const _prefLpu = 'lpu_ip';

  void _rememberLpu() {
    vnService.showDeviceIp = () => deviceInfo['ip'];
    vnService.onPreferredChanged = (ip) async {
      final prefs = await SharedPreferences.getInstance();
      if (ip.isEmpty) {
        await prefs.remove(_prefLpu); // deselected: nothing remembered
      } else {
        await prefs.setString(_prefLpu, ip);
      }
    };
    SharedPreferences.getInstance().then((prefs) {
      vnService.preferredIp ??= prefs.getString(_prefLpu);
    });
  }

  void _initDemoData() {
    cuelists.clear();
    for (int i = 0; i < 64; i++) {
      cuelists.add(Cuelist(id: i + 1, label: '', state: PlaybackState.released, level: 0.0));
    }
  }

  // ---------------------------------------------------------------------------
  // Screen
  // ---------------------------------------------------------------------------
  void setScreen(String screen) {
    currentScreen = screen;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Blackout
  // ---------------------------------------------------------------------------
  void toggleBlackout() {
    blackout = !blackout;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Cuelists
  // ---------------------------------------------------------------------------
  void setCuelistLevel(int id, double level) {
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.level = level.clamp(0.0, 1.0);
    cl.hasLevel = true;
    cl.levelChangedAt = DateTime.now();
    notifyListeners();
  }

  /// The fader level to show: the LPU's when connected; offline the app's,
  /// full (the LPU default) for a playback whose fader was never set.
  double shownLevel(Cuelist cl) =>
      liveConnected ? cl.liveLevel : (cl.hasLevel ? cl.level : 1.0);

  void setCuelistState(int id, PlaybackState state) {
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.state = state;
    notifyListeners();
  }

  void renameCuelist(int id, String name) {
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.label = name;
    showModified = true;
    notifyListeners();
    if (liveConnected) vnService.writePlaybackLabel(_indexOf(id), name);
  }

  // ---------------------------------------------------------------------------
  // Editing (v0.7). Offline: changes the app's show. Connected: changed in the
  // app at once and written to the LPU; the LPU's read-back then keeps the
  // app in step with what the LPU really stored.
  // ---------------------------------------------------------------------------

  // Playback properties window.
  void setCuelistProps(int id, {GoMode? goMode, RepeatMode? repeatMode, bool? background, bool? exclusive}) {
    final cl = _cuelist(id);
    if (cl == null) return;
    if (goMode != null) cl.goMode = goMode;
    if (repeatMode != null) cl.repeatMode = repeatMode;
    if (background != null) cl.background = background;
    if (exclusive != null) cl.exclusive = exclusive;
    showModified = true;
    notifyListeners();
    if (liveConnected) {
      vnService.writePlaybackProps(_indexOf(id),
          goMode: goMode == null ? null : core.goModes[goMode.index],
          repeat: repeatMode == null ? null : core.repeatModes[repeatMode.index],
          background: background,
          exclusive: exclusive);
    }
  }

  // SWAP: exchange two whole playbacks (label, settings and cues).
  void swapCuelists(int a, int b) {
    if (a == b || a < 0 || b < 0 || a >= cuelists.length || b >= cuelists.length) return;
    final x = cuelists[a], y = cuelists[b];
    final cues = [...x.cues];
    x.cues..clear()..addAll(y.cues);
    y.cues..clear()..addAll(cues);
    final label = x.label, level = x.level, has = x.hasLevel, live = x.liveLevel, speed = x.speed;
    final go = x.goMode, rep = x.repeatMode, bg = x.background, ex = x.exclusive;
    x..label = y.label..level = y.level..hasLevel = y.hasLevel..liveLevel = y.liveLevel..speed = y.speed
     ..goMode = y.goMode..repeatMode = y.repeatMode..background = y.background..exclusive = y.exclusive;
    y..label = label..level = level..hasLevel = has..liveLevel = live..speed = speed
     ..goMode = go..repeatMode = rep..background = bg..exclusive = ex;
    showModified = true;
    notifyListeners();
    if (liveConnected) vnService.swapPlaybacks(a, b);
  }

  /// A playback holds at most this many cues (LPU-1).
  static const int maxCues = 48;

  // Add a cue at the end of cuelist [index]; returns the new cue's index,
  // or -1 when the cuelist already has [maxCues].
  int addCue(int index) {
    final cl = cuelists[index];
    if (cl.cues.length >= maxCues) return -1;
    final num = cl.cues.isEmpty ? 1 : cl.cues.last.number + 1;
    cl.cues.add(Cue(number: num, label: 'Cue $num'));
    showModified = true;
    notifyListeners();
    if (liveConnected) {
      // An empty playback gets its first cue like the upload allocates it.
      if (cl.cues.length == 1) {
        vnService.allocateCues(index, 1);
      } else {
        vnService.insertCue(index, cl.cues.length - 1);
      }
    }
    return cl.cues.length - 1;
  }

  // Remove cues [cueIndices] of cuelist [index].
  void removeCues(int index, Iterable<int> cueIndices) {
    final cl = cuelists[index];
    final sorted = cueIndices.where((i) => i >= 0 && i < cl.cues.length).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    for (final i in sorted) {
      cl.cues.removeAt(i);
    }
    showModified = true;
    notifyListeners();
    if (!liveConnected) return;
    // Contiguous runs, from the end so earlier indices stay valid.
    var k = 0;
    while (k < sorted.length) {
      var first = sorted[k], count = 1;
      while (k + count < sorted.length && sorted[k + count] == first - 1) {
        first--;
        count++;
      }
      vnService.deleteCues(index, first, count);
      k += count;
    }
  }

  // A cue's content or settings changed in the edit screen (record, fade,
  // delay, condition): write the whole cue to the LPU when connected.
  void cueChanged(int index, int cueIndex) {
    showModified = true;
    notifyListeners();
    if (!liveConnected) return;
    final cl = cuelists[index];
    if (cueIndex < 0 || cueIndex >= cl.cues.length) return;
    vnService.writeCue(index, cueIndex,
        coreCueFromModel(cl.cues[cueIndex], cueIndex, [for (final f in fixtures) if (f.isPatched) f.slot]));
  }

  /// The app's show as it would go to the LPU. While live this is also what
  /// the LPU holds (OPEN keeps it to restore on Abort).
  Future<core.Show> showForLpu() async => showFromModel(
        cuelists: cuelists,
        fixtures: fixtures,
        device: deviceInfo,
        profiles: await loadPersonalityProfiles(),
      );

  /// Send the app's show to the connected LPU, like opening a show in the
  /// reference app: release all, upload, verify. Returns a message for the user.
  ///
  /// [fraction] reports the progress (0..1); [cancelled] = Abort: the sending
  /// stops and [restore] (the LPU's previous show) is sent back.
  Future<String> uploadShowToLpu(
      {core.Show? restore,
      void Function(String step)? progress,
      void Function(double)? fraction,
      bool Function()? cancelled}) async {
    if (!liveConnected) return 'Not connected to an LPU.';
    final show = await showForLpu();
    try {
      final r = await vnService.uploadShow(show,
          restore: restore, progress: progress, fraction: fraction, cancelled: cancelled);
      if (r == null) return 'Not connected to an LPU.';
      if (r.aborted) return 'Aborted: the LPU has its previous show again.';
      return r.diffs.isEmpty
          ? 'Sent to the LPU and verified.'
          : 'Sent to the LPU, but ${r.diffs.length} difference(s) found (first: ${r.diffs.first}).';
    } catch (e) {
      return 'Upload stopped: $e. The LPU may hold part of the show; open the show again.';
    }
  }

  void setCuelistFadeIn(int id, double value) {
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.fadeIn = value;
    showModified = true;
    notifyListeners();
  }

  void setCuelistFadeOut(int id, double value) {
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.fadeOut = value;
    showModified = true;
    notifyListeners();
  }

  void setCuelistSpeed(int id, double value) {
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.speed = value;
    showModified = true;
    notifyListeners();
  }

  void addCuelist() {
    final newId = cuelists.isEmpty ? 1 : cuelists.last.id + 1;
    cuelists.add(Cuelist(id: newId, label: 'Cuelist $newId'));
    showModified = true;
    notifyListeners();
  }

  void removeCuelist(int id) {
    cuelists.removeWhere((c) => c.id == id);
    showModified = true;
    notifyListeners();
  }

  // Connected to an LPU: presses are sent to the LPU and the playback state
  // comes only from what the LPU reports back (services/live_sync.dart),
  // never from local logic (FINDINGS 20.12). Offline, the local playback
  // logic below runs.
  bool liveConnected = false;

  int _indexOf(int id) => cuelists.indexWhere((c) => c.id == id);

  // Go: apply GoMode + RepeatMode logic on each tap/press.
  // No cues = just toggle playing state (empty cuelist).
  void goCuelist(int id) {
    if (liveConnected) {
      final i = _indexOf(id);
      if (i >= 0) vnService.sendGoCommand(i);
      return;
    }
    final cl = _cuelist(id);
    if (cl == null) return;

    // GoMode: toggle releases if already playing
    if (cl.goMode == GoMode.toggle && cl.state == PlaybackState.playing) {
      releaseCuelist(id);
      return;
    }

    // GoMode: solo releases all other playing cuelists first
    if (cl.goMode == GoMode.solo) {
      for (final other in cuelists) {
        if (other.id != id && other.state == PlaybackState.playing) {
          other.state = PlaybackState.released; // the fader stays where it is
          other.fading = false;
        }
      }
    }

    // No cues: just start/stay playing
    if (cl.cues.isEmpty) {
      cl.state = PlaybackState.playing;
      notifyListeners();
      return;
    }

    // Already playing: advance to next cue according to RepeatMode
    if (cl.state == PlaybackState.playing) {
      final last = cl.cues.length - 1;
      switch (cl.repeatMode) {
        case RepeatMode.loop:
          // Advance forward, wrap around forever
          cl.currentCueIndex = (cl.currentCueIndex + 1) % cl.cues.length;
          break;
        case RepeatMode.bounce:
          // Advance in current direction, flip at ends
          if (cl.bounceForward) {
            if (cl.currentCueIndex >= last) {
              cl.bounceForward = false;
              cl.currentCueIndex = last - 1 < 0 ? 0 : last - 1;
            } else {
              cl.currentCueIndex++;
            }
          } else {
            if (cl.currentCueIndex <= 0) {
              cl.bounceForward = true;
              cl.currentCueIndex = cl.cues.length > 1 ? 1 : 0;
            } else {
              cl.currentCueIndex--;
            }
          }
          break;
        case RepeatMode.random:
          // Jump to any cue (avoid same index if more than one cue)
          if (cl.cues.length > 1) {
            int next;
            do {
              next = math.Random().nextInt(cl.cues.length);
            } while (next == cl.currentCueIndex);
            cl.currentCueIndex = next;
          }
          break;
        case RepeatMode.off:
          // Advance; stop (release) after the last cue
          if (cl.currentCueIndex >= last) {
            releaseCuelist(id);
            return;
          }
          cl.currentCueIndex++;
          break;
      }
      _startCueTimer(cl);
      notifyListeners();
      _scheduleFollowIfNeeded(cl);
      return;
    }

    // Not playing yet: start at cue 0, reset bounce direction
    cl.currentCueIndex = 0;
    cl.bounceForward = true;
    cl.state = PlaybackState.playing;
    _startCueTimer(cl);
    notifyListeners();
    // Schedule follow-condition auto-advance for cue 0
    _scheduleFollowIfNeeded(cl);
  }

  // Offline, like the LPU's cue phases: green (fading) while the cue's delay
  // + fade run, then yellow (holding).
  void _startCueTimer(Cuelist cl) {
    final idx = cl.currentCueIndex;
    if (idx < 0 || idx >= cl.cues.length) return;
    final cue = cl.cues[idx];
    final ms = ((cue.delay + cue.fadeIn) * 1000).round();
    cl.fading = ms > 0;
    if (ms <= 0) return;
    Future.delayed(Duration(milliseconds: ms), () {
      if (cl.state != PlaybackState.playing || cl.currentCueIndex != idx) return;
      cl.fading = false;
      notifyListeners();
    });
  }

  // Schedule an automatic advance if the current cue has condition=follow.
  // The cue's delay field is used as the wait time (seconds); minimum 0.1 s.
  void _scheduleFollowIfNeeded(Cuelist cl) {
    if (cl.state != PlaybackState.playing) return;
    if (cl.cues.isEmpty) return;
    final idx = cl.currentCueIndex;
    if (idx < 0 || idx >= cl.cues.length) return;
    final cue = cl.cues[idx];
    if (cue.condition != CueCondition.follow) return;

    final waitMs = ((cue.delay > 0 ? cue.delay : 0.0) * 1000).round();
    final wait = waitMs < 100 ? 100 : waitMs;

    Future.delayed(Duration(milliseconds: wait), () {
      // Guard: still playing and still on the same cue
      if (cl.state != PlaybackState.playing) return;
      if (cl.currentCueIndex != idx) return;
      // Advance using the same repeat-mode logic
      goCuelist(cl.id);
    });
  }

  // Flash: force cuelist level to 1.0 while held, restore on release.
  // Does NOT change playback state — flash is a level bump, not a go.
  final Map<int, double> _flashPriorLevel = {};

  void flashCuelist(int id) {
    if (liveConnected) return;
    final cl = _cuelist(id);
    if (cl == null) return;
    _flashPriorLevel[id] = cl.level;
    cl.level = 1.0;
    notifyListeners();
  }

  void unflashCuelist(int id) {
    if (liveConnected) return;
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.level = _flashPriorLevel.remove(id) ?? cl.level;
    notifyListeners();
  }

  // FLASH button pressed / let go: runs the playback while held.
  // Offline this is GO on press and release on let-go (as before).
  /// A tile pressed / let go, connected: the GO button itself goes to the LPU.
  void goButton(int id, bool down) {
    if (!liveConnected) return;
    final i = _indexOf(id);
    if (i >= 0) vnService.goButton(i, down);
  }

  void flashPress(int id) {
    if (liveConnected) {
      final i = _indexOf(id);
      if (i >= 0) vnService.flash(i, true);
      return;
    }
    goCuelist(id);
  }

  void flashRelease(int id) {
    if (liveConnected) {
      final i = _indexOf(id);
      if (i >= 0) vnService.flash(i, false);
      return;
    }
    releaseCuelist(id);
  }

  // RELEASE ALL (hold the release button): one command to the LPU when
  // connected, else every playing / releasing cuelist locally.
  void releaseAll() {
    if (liveConnected) {
      vnService.releaseAll();
      return;
    }
    for (final cl in cuelists) {
      if (cl.state == PlaybackState.playing || cl.state == PlaybackState.releasing) {
        releaseCuelist(cl.id);
      }
    }
  }

  // Playback fader (0..1) moved in the app. Connected: shown at once and sent
  // to the LPU (the LPU's own pushes then keep it in step).
  void setPlaybackLevel(int index, double level) {
    if (index < 0 || index >= cuelists.length) return;
    if (liveConnected) {
      cuelists[index].liveLevel = level.clamp(0.0, 1.0);
      cuelists[index].levelChangedAt = DateTime.now();
      notifyListeners();
      vnService.sendFaderLevel(index, level);
      return;
    }
    setCuelistLevel(cuelists[index].id, level);
  }

  // Playback knob / speed (-1..1) turned in the app; sent to the LPU when
  // connected (offline it is only shown).
  void setPlaybackSpeed(int index, double speed) {
    if (index < 0 || index >= cuelists.length) return;
    cuelists[index].liveSpeed = speed.clamp(-1.0, 1.0);
    cuelists[index].speedChangedAt = DateTime.now();
    notifyListeners();
    if (liveConnected) vnService.sendRotaryLevel(index, speed);
  }

  // Release cuelist (stop playing, go to released state)
  void releaseCuelist(int id) {
    if (liveConnected) {
      final i = _indexOf(id);
      if (i >= 0) vnService.release(i);
      return;
    }
    final cl = _cuelist(id);
    if (cl == null) return;
    cl.fading = false;
    // Offline like the LPU: the cue fades out with its fade time (orange),
    // then released (red); the fader is not touched.
    final idx = cl.currentCueIndex;
    final fade = cl.state == PlaybackState.playing && idx >= 0 && idx < cl.cues.length
        ? cl.cues[idx].fadeIn
        : 0.0;
    if (fade <= 0) {
      cl.state = PlaybackState.released;
      notifyListeners();
      return;
    }
    cl.state = PlaybackState.releasing;
    notifyListeners();
    Future.delayed(Duration(milliseconds: (fade * 1000).round()), () {
      if (cl.state != PlaybackState.releasing) return;
      cl.state = PlaybackState.released;
      notifyListeners();
    });
  }

  Cuelist? _cuelist(int id) {
    try { return cuelists.firstWhere((c) => c.id == id); } catch (_) { return null; }
  }

  // ---------------------------------------------------------------------------
  // Fixtures
  // ---------------------------------------------------------------------------
  /// Two patched fixtures share DMX channels: like the reference app, playback and
  /// EDIT are locked (no message) until PATCH is fixed.
  bool get patchCollision => collidingSlots(fixtures).isNotEmpty;

  void addFixture(FixturePatch fixture) {
    fixtures.add(fixture);
    showModified = true;
    notifyListeners();
  }

  void removeFixture(int id) {
    fixtures.removeWhere((f) => f.id == id);
    showModified = true;
    notifyListeners();
  }

  void renameFixture(int id, String name) {
    try { fixtures.firstWhere((f) => f.id == id).label = name; } catch (_) {}
    showModified = true;
    notifyListeners();
  }

  void setFixtureAddress(int id, int address, int universe) {
    try {
      final f = fixtures.firstWhere((f) => f.id == id);
      f.address = address.clamp(1, 512);
      f.universe = universe.clamp(0, 255);
    } catch (_) {}
    showModified = true;
    notifyListeners();
  }

  void toggleFixtureInvertPan(int id) {
    try { final f = fixtures.firstWhere((f) => f.id == id); f.invertPan = !f.invertPan; } catch (_) {}
    showModified = true;
    notifyListeners();
  }

  void toggleFixtureInvertTilt(int id) {
    try { final f = fixtures.firstWhere((f) => f.id == id); f.invertTilt = !f.invertTilt; } catch (_) {}
    showModified = true;
    notifyListeners();
  }

  void toggleFixtureSwapPanTilt(int id) {
    try { final f = fixtures.firstWhere((f) => f.id == id); f.swapPanTilt = !f.swapPanTilt; } catch (_) {}
    showModified = true;
    notifyListeners();
  }

  void toggleFixtureVirtualDimmer(int id) {
    try { final f = fixtures.firstWhere((f) => f.id == id); f.virtualDimmer = !f.virtualDimmer; } catch (_) {}
    showModified = true;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Network Devices
  // ---------------------------------------------------------------------------
  // The list is filled by LPU discovery (main.dart). Art-Net / sACN / name
  // are the LPU's settings: for the connected LPU they are written to it (its
  // read-back then confirms them); other LPUs are only changed in the list.

  bool _isConnectedLpu(String ipAddress) =>
      liveConnected && vnService.connected?.ip == ipAddress;

  /// Art-Net output on / off, and optionally the sub.uni ([raw] = subnet x 16
  /// + universe). Only what changed is written.
  void setDeviceArtNet(String ipAddress, bool enabled, {int? raw}) {
    final d = _device(ipAddress);
    if (d == null) return;
    final on = d.artNetEnabled == enabled ? null : enabled;
    final r = raw == null || raw == d.artNetRaw ? null : raw.clamp(0, 255);
    if (on == null && r == null) return;
    d.artNetEnabled = enabled;
    if (r != null) {
      d.artNetRaw = r;
      d.artNetUniverse = r ~/ 16;
    }
    if (_isConnectedLpu(ipAddress)) vnService.writeDeviceSettings(artNet: on, artNetRaw: r);
    notifyListeners();
  }

  /// sACN output on / off, and optionally the universe (1..63999).
  void setDeviceSacn(String ipAddress, bool enabled, {int? universe}) {
    final d = _device(ipAddress);
    if (d == null) return;
    final on = d.sacnEnabled == enabled ? null : enabled;
    final u = universe == null || universe == d.sacnUniverse ? null : universe.clamp(1, 63999);
    if (on == null && u == null) return;
    d.sacnEnabled = enabled;
    if (u != null) d.sacnUniverse = u;
    if (_isConnectedLpu(ipAddress)) vnService.writeDeviceSettings(sacn: on, sacnUniverse: u);
    notifyListeners();
  }

  /// "192.168.1.12" -> its 4 bytes, or null (shared: core/net.dart).
  static List<int>? parseIpv4(String s) => core_net.parseIpv4(s);

  /// IP ADDRESS on the connected LPU: DHCP, or a static [ip] / [mask]. An
  /// invalid address changes nothing (like the reference app). Returns whether it
  /// was sent.
  bool setDeviceNetwork(String ipAddress, {required bool dhcp, String ip = '', String mask = ''}) {
    if (!_isConnectedLpu(ipAddress)) return false;
    if (dhcp) {
      vnService.setNetwork();
    } else {
      final i = parseIpv4(ip), m = parseIpv4(mask);
      if (i == null || m == null) return false;
      vnService.setNetwork(ip: i, mask: m);
    }
    deviceInfo = {...deviceInfo, 'dhcp': '$dhcp', if (!dhcp) 'subnet': mask.trim()};
    notifyListeners();
    return true;
  }

  /// The name shown in the device list; for the connected LPU also its alias.
  void renameDevice(String ipAddress, String label) {
    final d = _device(ipAddress);
    if (d == null) return;
    d.label = label;
    if (_isConnectedLpu(ipAddress) && label.isNotEmpty) vnService.writeDeviceSettings(alias: label);
    notifyListeners();
  }

  NetworkDevice? _device(String ipAddress) {
    try { return networkDevices.firstWhere((d) => d.ipAddress == ipAddress); } catch (_) { return null; }
  }

  // ---------------------------------------------------------------------------
  // Show serialization helpers
  // ---------------------------------------------------------------------------
  Map<String, dynamic> _showToJson() => {
        'showFileName': showFileName,
        'cuelists': cuelists.map((c) => c.toJson()).toList(),
        'fixtures': fixtures.map((f) => f.toJson()).toList(),
        if (deviceInfo.isNotEmpty) 'device': deviceInfo,
        if (!positions.isEmpty) 'positions': positions.toJson(),
      };

  void _showFromJson(Map<String, dynamic> j) {
    showFileName = j['showFileName'] as String? ?? 'Untitled';
    deviceInfo = (j['device'] as Map<String, dynamic>? ?? {}).cast<String, String>();
    positions.fromJson(j['positions']);
    cuelists.clear();
    for (final c in (j['cuelists'] as List<dynamic>? ?? [])) {
      cuelists.add(Cuelist.fromJson(c as Map<String, dynamic>));
    }
    // Pad cuelists to 64 slots
    for (int i = cuelists.length; i < 64; i++) {
      cuelists.add(Cuelist(id: i + 1));
    }
    fixtures.clear();
    for (final f in (j['fixtures'] as List<dynamic>? ?? [])) {
      fixtures.add(FixturePatch.fromJson(f as Map<String, dynamic>));
    }
  }

  // ---------------------------------------------------------------------------
  // Show file management. Windows: .show files in Documents\DLED\shows
  // (services/show_folder.dart). Elsewhere: SharedPreferences as JSON.
  // ---------------------------------------------------------------------------
  static const _prefKeys = 'show_file_names';
  static String _prefKey(String name) => 'show_file_$name';
  static String _prefDate(String name) => 'show_date_$name';
  static const _prefMoved = 'shows_moved_to_folder';

  ShowFolder? _folder;

  /// The show folder (Windows), or null when shows are stored in the app.
  ShowFolder? get showFolder => _folder;

  Future<void> _initStorage() async {
    final folder = await ShowFolder.open();
    if (!_storageChosen) await useShowFolder(folder); // an explicit choice wins
  }

  bool _storageChosen = false;

  /// Use [folder] for the saved shows (null = the app's internal storage).
  /// The shows saved in the app so far are copied into the folder once.
  Future<void> useShowFolder(ShowFolder? folder) async {
    _storageChosen = true;
    _folder = folder;
    if (folder != null) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefMoved) != true) {
        final profiles = await loadPersonalityProfiles();
        for (final name in prefs.getStringList(_prefKeys) ?? const <String>[]) {
          final data = prefs.getString(_prefKey(name));
          if (data == null || folder.exists(name)) continue;
          final tmp = ShowModel._storage();
          tmp._showFromJson(jsonDecode(data) as Map<String, dynamic>);
          folder.write(name, tmp._showText(profiles));
          folder.writePositions(name, tmp._positionsText);
          tmp.dispose();
        }
        await prefs.setBool(_prefMoved, true); // the app's copies stay as a fallback
      }
    }
    await loadShowFileList();
  }

  String _showText(Map<String, String> profiles) => core.writeShow(showFromModel(
        cuelists: cuelists,
        fixtures: fixtures,
        device: deviceInfo,
        profiles: profiles,
      ));

  String? get _positionsText => positions.isEmpty ? null : positions.encode();

  void _loadText(String text) {
    final parsed = ShowLoader.loadFromString(text);
    if (parsed != null) parsed.applyToModel(this);
  }

  Future<void> loadShowFileList() async {
    showFiles.clear();
    final folder = _folder;
    if (folder != null) {
      for (final f in folder.list()) {
        showFiles.add(ShowFile(name: f.name, savedAt: f.modified, sizeBytes: f.size));
      }
      notifyListeners();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final names = prefs.getStringList(_prefKeys) ?? [];
    for (final name in names) {
      final dateStr = prefs.getString(_prefDate(name)) ?? '';
      final data = prefs.getString(_prefKey(name)) ?? '';
      showFiles.add(ShowFile(
        name: name,
        savedAt: DateTime.tryParse(dateStr) ?? DateTime.now(),
        sizeBytes: data.length,
      ));
    }
    notifyListeners();
  }

  /// Is there a saved show called [name]? (SAVE / SAVE AS ask before overwriting.)
  bool showExists(String name) => showFiles.any((s) => s.name == name);

  /// The next free "show N" name (NEW).
  String nextShowName() {
    var n = 1;
    while (showExists('show $n')) {
      n++;
    }
    return 'show $n';
  }

  /// NEW: an empty show added to the list (the open show stays as it is).
  Future<String?> addEmptyShow() async {
    final name = nextShowName();
    final empty = ShowModel._storage().._folder = _folder;
    final ok = await empty.saveShow(name);
    empty.dispose();
    await loadShowFileList();
    return ok ? name : null;
  }

  Future<bool> saveShow(String name) async {
    if (showFiles.length >= 50 &&
        !showFiles.any((s) => s.name == name)) {
      return false; // max 50 files
    }
    final folder = _folder;
    if (folder != null) {
      folder.write(name, _showText(await loadPersonalityProfiles()));
      folder.writePositions(name, _positionsText);
    } else {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_showToJson());
      await prefs.setString(_prefKey(name), json);
      final now = DateTime.now().toIso8601String();
      await prefs.setString(_prefDate(name), now);

      // Update names list
      final names = prefs.getStringList(_prefKeys) ?? [];
      if (!names.contains(name)) names.add(name);
      await prefs.setStringList(_prefKeys, names);
    }

    showFileName = name;
    showModified = false;
    await loadShowFileList();
    return true;
  }

  Future<void> loadShow(String name) async {
    final folder = _folder;
    if (folder != null) {
      final text = folder.read(name);
      if (text == null) return;
      _loadText(text);
      positions.clear();
      final p = folder.readPositions(name);
      if (p != null) positions.decode(p);
    } else {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_prefKey(name));
      if (data == null) return;
      final j = jsonDecode(data) as Map<String, dynamic>;
      _showFromJson(j);
    }
    showFileName = name;
    showModified = false;
    notifyListeners();
  }

  /// The saved show [name] as a temporary model (for export), or null.
  Future<({List<Cuelist> cuelists, List<FixturePatch> fixtures, Map<String, String> device})?>
      savedShowContent(String name) async {
    final folder = _folder;
    if (folder != null) {
      final text = folder.read(name);
      if (text == null) return null;
      final tmp = ShowModel._storage().._loadText(text);
      final r = (cuelists: tmp.cuelists.toList(), fixtures: tmp.fixtures.toList(), device: tmp.deviceInfo);
      tmp.dispose();
      return r;
    }
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString(_prefKey(name));
    if (data == null) return null;
    final j = jsonDecode(data) as Map<String, dynamic>;
    return (
      cuelists: [for (final c in (j['cuelists'] as List<dynamic>? ?? [])) Cuelist.fromJson(c as Map<String, dynamic>)],
      fixtures: [for (final f in (j['fixtures'] as List<dynamic>? ?? [])) FixturePatch.fromJson(f as Map<String, dynamic>)],
      device: (j['device'] as Map<String, dynamic>? ?? {}).cast<String, String>(),
    );
  }

  Future<void> deleteShow(String name) async {
    final folder = _folder;
    if (folder != null) {
      folder.delete(name);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKey(name));
      await prefs.remove(_prefDate(name));
      final names = prefs.getStringList(_prefKeys) ?? [];
      names.remove(name);
      await prefs.setStringList(_prefKeys, names);
    }
    await loadShowFileList();
  }

  Future<bool> renameShow(String oldName, String newName) async {
    if (newName.trim().isEmpty) return false;
    if (showFiles.any((s) => s.name == newName)) return false;
    final folder = _folder;
    if (folder != null) {
      if (!folder.rename(oldName, newName)) return false;
    } else {
      final prefs = await SharedPreferences.getInstance();
      final data = prefs.getString(_prefKey(oldName));
      final date = prefs.getString(_prefDate(oldName));
      if (data == null) return false;
      await prefs.setString(_prefKey(newName), data);
      await prefs.setString(_prefDate(newName), date ?? DateTime.now().toIso8601String());
      await prefs.remove(_prefKey(oldName));
      await prefs.remove(_prefDate(oldName));
      final names = prefs.getStringList(_prefKeys) ?? [];
      final idx = names.indexOf(oldName);
      if (idx >= 0) names[idx] = newName;
      await prefs.setStringList(_prefKeys, names);
    }
    if (showFileName == oldName) showFileName = newName;
    await loadShowFileList();
    return true;
  }

  // ---------------------------------------------------------------------------
  // Programmer (v1.2): the edit screen drives the LPU's programmer when
  // connected, so the lights follow selection, LOAD and sliders live like in
  // the reference app. Offline nothing is output (the app sends no DMX itself).
  // ---------------------------------------------------------------------------

  void programmerSelect(Iterable<int> slots) {
    if (liveConnected) vnService.selectFixtures(slots);
  }

  void programmerLoad(int index, int cueIndex) {
    if (liveConnected) vnService.loadCue(index, cueIndex);
  }

  /// A pan / tilt per fixture (POSITIONS recall), then [selection]
  /// (lpu_session.dart programmerPositions).
  void programmerPositions(Map<int, Uint8List> positions, Iterable<int> selection) {
    if (liveConnected) vnService.programmerPositions(positions, selection);
  }

  void programmerClear() {
    if (liveConnected) vnService.clearProgrammer();
  }

  /// What the edit screen showed when it was last closed (selected cues and
  /// fixtures, slider values, FX): it opens again the same way, like the
  /// reference app, also when nothing was recorded. Owned by edit_screen.dart.
  Object? editMemory;

  /// The edit screen opened (true) / closed (false).
  void programmerEditing(bool editing) {
    if (liveConnected) vnService.setEditing(editing);
  }

  /// The LPU's programmer values as they change (any app, or a LOAD): the
  /// EDIT page follows them (services/programmer.dart decodes them).
  final StreamController<({int attr, Uint8List body})> programmerValues = StreamController.broadcast();

  void programmerWrite(Iterable<ProgrammerWrite> writes) {
    if (!liveConnected) return;
    for (final w in writes) {
      vnService.setProgrammer(w.attr, w.type, w.body);
    }
  }

  // ---------------------------------------------------------------------------
  // Live LPU updates (called from VN protocol callbacks in main.dart)
  // ---------------------------------------------------------------------------

  // Called when LPU pushes op=0x29 slot=3 sub=0x17 (fader level).
  // ch is 0-based cuelist channel index from the LPU packet.
  void setLiveFaderLevel(int ch, double level) {
    if (ch < 0 || ch >= cuelists.length) return;
    cuelists[ch].liveLevel = level.clamp(0.0, 1.0);
    // Mirror into the cuelist's playback level so UI sliders stay in sync.
    cuelists[ch].level = cuelists[ch].liveLevel;
    cuelists[ch].hasLevel = true;
    cuelists[ch].levelChangedAt = DateTime.now();
    notifyListeners();
  }

  // Called when LPU pushes op=0x29 slot=3 sub=0x15 (rotary speed).
  // ch is 0-based cuelist channel index from the LPU packet.
  void setLiveRotaryLevel(int ch, double speed) {
    if (ch < 0 || ch >= cuelists.length) return;
    cuelists[ch].liveSpeed = speed.clamp(-1.0, 1.0);
    cuelists[ch].speedChangedAt = DateTime.now();
    notifyListeners();
  }

  // Active cue pushed by the LPU (29 81 2f): null = released.
  void setLiveActiveCue(int pb, int? cue) {
    if (pb < 0 || pb >= cuelists.length) return;
    final cl = cuelists[pb];
    if (cue == null) {
      cl.state = PlaybackState.released;
    } else {
      cl.state = PlaybackState.playing;
      cl.currentCueIndex = cue;
    }
    notifyListeners();
  }

  // Cue phase pushed by the LPU (29 81 24): 0 no cues, 1 released,
  // 2 running with a timer, 3 holding, 4 releasing.
  void setLiveCuePhase(int pb, int phase) {
    if (pb < 0 || pb >= cuelists.length) return;
    final cl = cuelists[pb];
    cl.fading = phase == 2;
    switch (phase) {
      case 4:
        cl.state = PlaybackState.releasing;
      case 0 || 1:
        cl.state = PlaybackState.released;
      case 2 || 3:
        if (cl.state == PlaybackState.releasing) cl.state = PlaybackState.playing;
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // New show
  // ---------------------------------------------------------------------------
  /// The user deselected the LPU in OPTIONS: disconnect, forget it, and
  /// empty the app (playbacks, fixtures); the device list stays.
  void deselectLpu() {
    vnService.deselect();
    liveConnected = false;
    cuelists.clear();
    fixtures.clear();
    deviceInfo = {};
    showFileName = 'Untitled';
    showModified = false;
    positions.clear();
    _initDemoData();
    notifyListeners();
  }

  void newShow() {
    cuelists.clear();
    fixtures.clear();
    networkDevices.clear();
    deviceInfo = {};
    showFileName = 'Untitled';
    blackout = false;
    blind = false;
    showModified = false;
    positions.clear();
    _initDemoData();
    notifyListeners();
  }
}

