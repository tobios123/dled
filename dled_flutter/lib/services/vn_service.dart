import 'dart:async';
import 'dart:typed_data';


import '../core/lpu_client.dart' show LpuError;
import '../core/udp.dart';
import '../core/lpu_live.dart';
import '../core/lpu_session.dart';
import '../core/show_file.dart';

// Discovered LPU device (via VN protocol on UDP 16945).
class VnDevice {
  final String label;    // e.g. "LPU-1"
  final String ip;
  final int port;        // 16945 (an emulator may announce another port)
  final String version;  // firmware version string, e.g. "1.29"
  final DateTime lastSeen;

  const VnDevice({
    required this.label,
    required this.ip,
    required this.port,
    required this.version,
    required this.lastSeen,
  });

  VnDevice copyWith({DateTime? lastSeen}) => VnDevice(
        label: label,
        ip: ip,
        port: port,
        version: version,
        lastSeen: lastSeen ?? this.lastSeen,
      );

  @override
  String toString() => '$label @ $ip (v$version)';
}

// VN protocol service for LPU devices (LPU-1).
//
//   Discovery: broadcast ASCII "visual_identify" every 4 s; devices reply with
//              identify XML (label, version, ip, port).
//   Connect:   a live session on the shared core (core/lpu_session.dart):
//              download the whole show, then follow the LPU's notifications.
//              Results arrive as LiveEvents (onLiveEvent; services/live_sync.dart
//              applies them to the model).
//
// Control (v0.6): GO / FLASH / RELEASE / RELEASE ALL / fader / knob go to the
// LPU through the session; the result comes back as live events like any
// other change. There is no per-DMX-channel command: the edit screen drives
// the LPU's programmer instead (selectFixtures / loadCue / setProgrammer).
//
// Automatic connecting (v1.1): after start(), after a lost connection and
// when OPTIONS opens while not connected, the service connects on its own
// for [autoConnectWindow], then stops trying (OPTIONS starts it again):
//   - a lost LPU is retried every [retryInterval] until it answers again;
//   - otherwise an LPU from discovery is picked by [chooseAuto]: the one the
//     user chose last, else the one the open show came from, else the only
//     LPU on the network. Several LPUs and no match: the user chooses.
// The LPU runs the show without the app, so losing the app is harmless; the
// reconnect downloads the LPU's show again (the LPU is the truth).
class VnService {
  static const int _vnPort = 16945;
  static const Duration _discoveryInterval = Duration(seconds: 4);
  static const Duration _deviceTimeout = Duration(seconds: 15);

  final List<VnDevice> _devices = [];
  VnDevice? _connected;
  VnDevice? _connecting;
  LpuSession? _session;
  StreamSubscription<LiveEvent>? _sessionSub;

  UdpPort? _socket;
  Timer? _discoveryTimer;
  bool _running = false;

  // Kept for the screens; not used for sending any more.
  int cuelistIndex = 0;

  // Callbacks
  void Function(List<VnDevice>)? onDevicesChanged;
  void Function(VnDevice?)? onConnectionChanged;
  // Fires once per connect(): true = show downloaded, false = no answer.
  void Function(bool success, String message)? onConnectResult;
  // Everything the connected LPU reports: first ShowDownloaded, then live events.
  void Function(LiveEvent event)? onLiveEvent;

  List<VnDevice> get devices => List.unmodifiable(_devices);
  VnDevice? get connected => _connected;
  VnDevice? get connecting => _connecting;
  bool get isConnected => _connected != null;
  bool get isConnecting => _connecting != null;

  // ---------------------------------------------------------------------------

  // Bumped by stop(), so a start() still waiting for its socket can tell that
  // it was stopped meanwhile and must not start timers.
  int _generation = 0;
  Future<void>? _starting;

  // main.dart and the splash screen both call start(); a second call while the
  // first is still binding joins it instead of opening a second socket + timer.
  Future<void> start() {
    if (_running) return Future.value();
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<void> _start() async {
    final generation = _generation;
    try {
      // An ephemeral port (not 16945): we SEND to port 16945, the LPU
      // replies to our source port. (In a browser: through the bridge.)
      final socket = await UdpPort.open();
      if (generation != _generation) {
        socket.close();
        return;
      }
      _socket = socket;
      _running = true;
      socket.packets.listen(_onPacket);
      _discoveryTimer = Timer.periodic(_discoveryInterval, (_) {
        _sendDiscovery();
        _expireDevices();
      });
      _sendDiscovery(); // immediate first scan
      startAutoConnect();
    } catch (e) {
      // UDP bind may fail on web or if port is already in use.
      _running = false;
    }
  }

  void stop() {
    _generation++;
    _running = false;
    _stopAuto();
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _socket?.close();
    _socket = null;
    _closeSession();
    final was = _connected;
    _connected = null;
    _connecting = null;
    _devices.clear();
    // Never leave the app believing it is connected to a closed session.
    if (was != null) onConnectionChanged?.call(null);
  }

  /// Connect to [device]: download its show, then follow it live. A connect
  /// the user asked for (not [auto]) ends the automatic connecting and makes
  /// [device] the remembered LPU.
  Future<void> connect(VnDevice device, {bool auto = false}) async {
    if (!auto) {
      _stopAuto();
      _userDeselected = false;
      preferredIp = device.ip;
      onPreferredChanged?.call(device.ip);
    }
    await _closeSession();
    _connected = null;
    _connecting = device;
    try {
      final session = await LpuSession.connect(device.ip, port: device.port);
      if (_connecting != device) {
        await session.close(); // disconnect() or another connect() meanwhile
        return;
      }
      _session = session;
      _connecting = null;
      _connected = device;
      onLiveEvent?.call(session.downloaded);
      _sessionSub = session.events.listen((e) {
        if (_isOwnEcho(e)) return;
        onLiveEvent?.call(e);
        if (e is ConnectionLost && _session == session) _lost(device);
      });
      _stopAuto();
      onConnectionChanged?.call(device);
      onConnectResult?.call(true, '${device.label} v${device.version} @ ${device.ip}');
    } on LpuError catch (e) {
      if (_connecting == device) _connecting = null;
      onConnectResult?.call(false, e.message);
      onConnectionChanged?.call(null);
    } catch (e) {
      // a network error (no route, socket refused)
      if (_connecting == device) _connecting = null;
      onConnectResult?.call(false, 'network error: $e');
      onConnectionChanged?.call(null);
    }
  }

  /// The user deselected the LPU in OPTIONS: disconnect, forget it, and no
  /// automatic connecting until the app restarts (or an LPU is selected).
  void deselect() {
    _userDeselected = true;
    preferredIp = null;
    onPreferredChanged?.call('');
    disconnect();
  }

  bool _userDeselected = false;

  /// Disconnect on the user's request: no automatic reconnect.
  void disconnect() {
    _stopAuto();
    _connecting = null;
    _closeSession();
    _connected = null;
    onConnectionChanged?.call(null);
  }

  /// The connection to [device] was lost: offline, and try to get it back.
  void _lost(VnDevice device) {
    _connecting = null;
    _closeSession();
    _connected = null;
    onConnectionChanged?.call(null);
    startAutoConnect(reconnectTo: device);
  }

  // --- automatic connecting (see the class comment) ---------------------------

  Duration autoConnectWindow = const Duration(seconds: 60);
  Duration retryInterval = const Duration(seconds: 3);

  /// The LPU the user chose last (kept by the model across app starts).
  String? preferredIp;
  void Function(String ip)? onPreferredChanged;

  /// The LPU the open show came from (its `<device><ip>`), if any.
  String? Function()? showDeviceIp;

  /// The automatic connecting gave up after [autoConnectWindow].
  void Function()? onAutoConnectEnded;

  /// "The only LPU" is only believed after discovery had this long to hear
  /// all of them (else the first to answer would win).
  Duration discoverySettle = const Duration(seconds: 2);

  DateTime? _autoUntil;
  DateTime _autoSince = DateTime.now();
  VnDevice? _reconnectTo;
  Timer? _autoTimer;

  bool get isAutoConnecting => _autoUntil != null;

  /// Connect on its own for [autoConnectWindow] (again from now). With
  /// [reconnectTo] only that LPU is tried (a lost connection).
  void startAutoConnect({VnDevice? reconnectTo}) {
    if (isConnected || (_userDeselected && reconnectTo == null)) return;
    if (reconnectTo != null) _reconnectTo = reconnectTo;
    if (_autoUntil == null) _autoSince = DateTime.now();
    _autoUntil = DateTime.now().add(autoConnectWindow);
    _autoTimer ??= Timer.periodic(retryInterval, (_) => _autoTick());
    _sendDiscovery();
    _autoTick();
  }

  void _stopAuto() {
    _autoUntil = null;
    _reconnectTo = null;
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  void _autoTick() {
    final until = _autoUntil;
    if (until == null || isConnected || isConnecting) return;
    if (DateTime.now().isAfter(until)) {
      _stopAuto();
      onAutoConnectEnded?.call();
      return;
    }
    final settled = DateTime.now().difference(_autoSince) >= discoverySettle;
    final target = _reconnectTo ??
        chooseAuto([for (final d in _devices) if (reachable(d.ip, ownIps)) d],
            preferredIp: preferredIp, showIp: showDeviceIp?.call(), settled: settled);
    if (target != null) connect(target, auto: true);
  }

  /// This device's IPv4 addresses (refreshed with every discovery round).
  List<String> ownIps = const [];

  /// Can we talk to an LPU at [ip]? An LPU that gave itself a link-local
  /// 169.254.x.x address (no DHCP answer when it booted) still answers the
  /// discovery broadcast, but nothing else gets through unless this device
  /// is on 169.254 too. Such an LPU is
  /// not connected automatically; choosing it in OPTIONS still works.
  static bool reachable(String ip, Iterable<String> ownIps) =>
      !ip.startsWith('169.254.') || ownIps.any((a) => a.startsWith('169.254.'));

  /// Which LPU to connect to without asking: the one the user chose last,
  /// else the one the open show came from, else the only one found.
  /// Until discovery has [settled], only the best possible choice is taken
  /// (a better one may not have answered yet).
  static VnDevice? chooseAuto(List<VnDevice> found,
      {String? preferredIp, String? showIp, bool settled = true}) {
    VnDevice? byIp(String? ip) {
      if (ip == null || ip.isEmpty) return null;
      for (final d in found) {
        if (d.ip == ip) return d;
      }
      return null;
    }

    final hasPreferred = preferredIp != null && preferredIp.isNotEmpty;
    final preferred = byIp(preferredIp);
    if (preferred != null) return preferred;
    final show = byIp(showIp);
    if (show != null && (settled || !hasPreferred)) return show;
    if (!settled) return null;
    return found.length == 1 ? found.single : null;
  }

  Future<void> _closeSession() async {
    final s = _session;
    _session = null;
    await _sessionSub?.cancel();
    _sessionSub = null;
    await s?.close();
  }

  // --- editing (v0.7; playback / cue index 0-based) ---------------------------

  void writePlaybackLabel(int pb, String label) => _session?.writePlaybackLabel(pb, label);
  void writePlaybackProps(int pb, {String? goMode, String? repeat, bool? background, bool? exclusive}) =>
      _session?.writePlaybackProps(pb, goMode: goMode, repeat: repeat, background: background, exclusive: exclusive);
  void insertCue(int pb, int position) => _session?.insertCue(pb, position);
  void allocateCues(int pb, int count) => _session?.allocateCues(pb, count);
  void deleteCues(int pb, int first, int count) => _session?.deleteCues(pb, first, count);
  void writeCue(int pb, int q, ShowCue cue) => _session?.writeCue(pb, q, cue);
  void swapPlaybacks(int a, int b) => _session?.swapPlaybacks(a, b);
  void patchFixture(int slot, ShowFixture? f,
          {bool definition = false, bool address = false, bool name = false, bool flags = false}) =>
      _session?.patchFixture(slot, f, definition: definition, address: address, name: name, flags: flags);

  // --- programmer (v1.2): the edit screen, live on the LPU -------------------

  void selectFixtures(Iterable<int> slots) => _session?.selectFixtures(slots);
  void loadCue(int pb, int cue) => _session?.loadCue(pb, cue);
  void setProgrammer(int attr, int type, Uint8List body) => _session?.setProgrammer(attr, type, body);
  void clearProgrammer() => _session?.clearProgrammer();
  void programmerPositions(Map<int, Uint8List> positions, Iterable<int> selection) =>
      _session?.programmerPositions(positions, selection);
  void setEditing(bool editing) => _session?.setEditing(editing);

  // --- device settings (v0.8): the LPU's alias and its Art-Net / sACN output --

  void writeDeviceSettings(
          {String? alias, bool? artNet, int? artNetUniverse, int? artNetRaw, bool? sacn, int? sacnUniverse}) =>
      _session?.writeDeviceSettings(
          alias: alias,
          artNet: artNet,
          artNetUniverse: artNetUniverse,
          artNetRaw: artNetRaw,
          sacn: sacn,
          sacnUniverse: sacnUniverse);

  /// Set the connected LPU's IP (static, with [mask]) or DHCP ([ip] null),
  /// like the reference app. It moves to the new address at once: the app
  /// follows it there (static) or connects again once discovery shows where
  /// it went (DHCP: the only LPU, as its address is not known beforehand).
  Future<void> setNetwork({List<int>? ip, List<int>? mask}) async {
    final s = _session;
    if (s == null) return;
    await s.setNetwork(ip: ip, mask: mask);
    final next = ip?.join('.');
    preferredIp = next;
    onPreferredChanged?.call(next ?? '');
    disconnect();
    startAutoConnect();
  }

  /// Replace the LPU's show (release all, upload, verify); null when
  /// not connected. Throws LpuError when the LPU stops answering.
  Future<({List<String> diffs, bool aborted})?> uploadShow(Show show,
          {Show? restore,
          void Function(String)? progress,
          void Function(double)? fraction,
          bool Function()? cancelled}) async =>
      _session?.uploadShow(show, restore: restore, progress: progress, fraction: fraction, cancelled: cancelled);

  // --- control (playback index 0-63) ---------------------------------------

  void sendGoCommand(int playback) => _session?.go(playback);
  void goButton(int playback, bool down) => _session?.goButton(playback, down);
  void flash(int playback, bool down) => _session?.flash(playback, down);
  void release(int playback) => _session?.release(playback);
  void releaseAll() => _session?.releaseAll();

  void sendFaderLevel(int playback, double level) {
    _ownMove[(playback, 0)] = DateTime.now();
    _session?.setFader(playback, level);
  }

  void sendRotaryLevel(int playback, double speed) {
    _ownMove[(playback, 1)] = DateTime.now();
    _session?.setKnob(playback, speed);
  }

  // While a fader / knob is being moved here, the LPU's pushes of the same
  // control (its echo of our moves, slightly behind) are ignored for a moment,
  // so the slider does not jump back under the finger.
  static const Duration _ownMoveHold = Duration(milliseconds: 500);
  final Map<(int, int), DateTime> _ownMove = {};

  bool _isOwnEcho(LiveEvent e) {
    final key = switch (e) {
      FaderLevel() => (e.playback, 0),
      KnobSpeed() => (e.playback, 1),
      _ => null,
    };
    final t = key == null ? null : _ownMove[key];
    return t != null && DateTime.now().difference(t) < _ownMoveHold;
  }

  // ---------------------------------------------------------------------------
  // Discovery

  // Trigger an immediate discovery scan (public — called from options screen).
  void rescan() => _sendDiscovery();

  void _sendDiscovery() {
    if (_socket == null) return;
    final payload = Uint8List.fromList('visual_identify'.codeUnits);
    // Always send the global broadcast first.
    _sendTo(payload, '255.255.255.255');
    // Also send to subnet-specific broadcasts (e.g. 192.168.1.255).
    // This is required on many OS/network configurations where the global
    // 255.255.255.255 broadcast is silently dropped by the routing layer
    // (confirmed: Python debug_lpu_discover_v2.py does the same and finds the LPU).
    _sendSubnetBroadcasts(payload);
  }

  // Compute subnet broadcast addresses from all active IPv4 interfaces
  // and send the payload to each one.  Runs asynchronously so it does not
  // block the calling thread.
  void _sendSubnetBroadcasts(Uint8List payload) async {
    try {
      // (A browser knows none: the bridge broadcasts on its own networks.)
      ownIps = await UdpPort.localIps();
      for (final ip in ownIps) {
        final parts = ip.split('.');
        if (parts.length != 4 || parts[0] == '127') continue;
        // Simple /24 subnet broadcast: replace last octet with 255.
        _sendTo(payload, '${parts[0]}.${parts[1]}.${parts[2]}.255');
      }
    } catch (_) {}
  }

  // A refused send (no network, broadcast blocked) only means no discovery
  // this round; it must never become an unhandled error.
  void _sendTo(Uint8List payload, String ip) {
    _socket?.send(payload, ip, _vnPort);
  }

  void _onPacket(UdpPacket datagram) {
    final data = datagram.data;
    // XML identify reply: starts with '<'.
    if (data.length > 10 && data[0] == 0x3C) {
      _parseIdentifyReply(datagram.ip, data);
    }
  }

  void _parseIdentifyReply(String fromIp, Uint8List data) {
    try {
      final xml = String.fromCharCodes(data);
      if (!xml.contains('visual_identify')) return;

      final label = _extractXml(xml, 'visual_identify', attr: 'label') ??
          _extractXml(xml, 'label') ??
          'Unknown';
      final version = _extractXml(xml, 'version') ?? '?';
      final ip = _extractXml(xml, 'ip') ?? fromIp;
      final portStr = _extractXml(xml, 'port') ?? '$_vnPort';
      final port = int.tryParse(portStr) ?? _vnPort;

      deviceSeen(VnDevice(label: label, ip: ip, port: port, version: version, lastSeen: DateTime.now()));
    } catch (_) {}
  }

  /// An LPU answered discovery (also used by tests and emulators on other ports).
  void deviceSeen(VnDevice device) {
    final existing = _devices.indexWhere((d) => d.ip == device.ip);
    if (existing >= 0) {
      _devices[existing] = _devices[existing].copyWith(lastSeen: device.lastSeen);
      if (_connected?.ip == device.ip) _connected = _devices[existing];
    } else {
      _devices.add(device);
    }
    onDevicesChanged?.call(devices);
    _autoTick(); // a wanted LPU just appeared: no need to wait for the next try
  }

  void _expireDevices() {
    final cutoff = DateTime.now().subtract(_deviceTimeout);
    final gone = _devices.where((d) => d.lastSeen.isBefore(cutoff)).toList();
    if (gone.isEmpty) return;
    _devices.removeWhere(gone.contains);
    // The connected LPU stopped answering discovery: lost, try to get it back.
    // (One connected by IP and never seen in discovery is not affected.)
    final c = _connected;
    if (c != null && gone.any((d) => d.ip == c.ip)) _lost(c);
    onDevicesChanged?.call(devices);
  }

  // Extract XML tag content or attribute value.
  // e.g. _extractXml(xml, 'version') -> content between <version>...</version>
  // e.g. _extractXml(xml, 'visual_identify', attr: 'label') -> attribute value
  String? _extractXml(String xml, String tag, {String? attr}) {
    if (attr != null) {
      final re = RegExp('$tag[^>]*$attr="([^"]*)"');
      final m = re.firstMatch(xml);
      return m?.group(1);
    }
    final re = RegExp('<$tag>([^<]*)</$tag>');
    final m = re.firstMatch(xml);
    return m?.group(1)?.trim();
  }
}
