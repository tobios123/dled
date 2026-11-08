// lpu_session.dart -- a live, read-only connection to an LPU (dart:io).
//
// connect(): opens the lock-step client, downloads the whole show (what the
// reference app does on connect) and then follows the LPU's notifications:
// playback pushes are passed on as they are; "changed" events make the
// session read the object back and report the new state.
//
// Control (v0.6): GO, FLASH, RELEASE, RELEASE ALL, fader and knob are sent
// as the reference app sends them. The session does not change its own state for
// them: the LPU's notifications report the result, like for any other client.
// Fader / knob moves are coalesced: while one write waits for its echo, only
// the newest value per playback is kept and sent next.
//
// Everything the LPU reports is the truth: FINDINGS 20.12 showed that the real
// app gets confused when it tracks its own presses instead.

import 'dart:async';
import 'dart:typed_data';

import 'frame.dart';
import 'lpu_client.dart';
import 'lpu_io.dart';
import 'lpu_live.dart';
import 'show_file.dart';

class LpuSession {
  final LpuClient client;
  final Show show;
  final LpuInfo info;
  final Map<int, PlaybackStatus> states; // live state per downloaded playback
  final StreamController<LiveEvent> _events = StreamController.broadcast();
  late final StreamSubscription<Frame> _sub;
  Future<void> _work = Future.value();
  bool _closed = false;

  LpuSession._(this.client, this.show, this.info, this.states) {
    _sub = client.notifications.listen(_onNotification);
    _watchdog = Timer.periodic(watchdogInterval, (_) => _checkAlive());
  }

  /// How often a quiet connection is checked; a dead LPU is reported within
  /// about this plus the client's retry time (2.4 s).
  static Duration watchdogInterval = const Duration(seconds: 3);
  late final Timer _watchdog;
  bool _lostReported = false;

  /// Nothing heard from the LPU for a while (no one presses anything): check
  /// that it still answers, so a lost LPU is noticed without user action.
  void _checkAlive() {
    if (DateTime.now().difference(client.lastHeard) < watchdogInterval) return;
    _work = _work.then((_) async {
      if (_closed || _lostReported) return;
      if (DateTime.now().difference(client.lastHeard) < watchdogInterval) return;
      if (!await _answers()) _reportLost('the LPU stopped answering');
    });
  }

  /// ConnectionLost once per session.
  void _reportLost(String reason) {
    if (_lostReported) return;
    _lostReported = true;
    _emit(ConnectionLost(reason));
  }

  /// Live events: playback pushes plus the read-back results.
  Stream<LiveEvent> get events => _events.stream;

  /// The download as one event (for code that only listens to events).
  ShowDownloaded get downloaded => ShowDownloaded(show, info, states);

  /// Connect and download the show; throws [LpuError] when the LPU does not answer.
  static Future<LpuSession> connect(String ip,
      {int port = vnPort, void Function(int pb, int cue, int count)? progress}) async {
    final c = await LpuClient.connect(ip, port: port);
    try {
      final r = await download(c, progress: progress);
      return LpuSession._(c, r.show, r.info, await _states(c, r.show));
    } catch (_) {
      await c.close();
      rethrow;
    }
  }

  /// The live state of every playback of [show] (read together).
  static Future<Map<int, PlaybackStatus>> _states(LpuClient c, Show show) async {
    final bodies = await Future.wait([for (final p in show.playbacks) c.read(objPlayback, 0x30, i1: p.index)]);
    return {for (final (i, p) in show.playbacks.indexed) p.index: playbackState(bodies[i].body)};
  }

  void _emit(LiveEvent e) {
    if (!_closed) _events.add(e);
  }

  void _onNotification(Frame f) {
    final e = decodeNotification(f);
    if (e == null) return;
    if (e is Changed) {
      if (_uploading) return; // the upload ends with a full read-back anyway
      _readBack(e);
    } else {
      _emit(e);
    }
  }

  // Read-backs queued and not started yet. One edit makes the LPU announce
  // the same object several times; one read (made later) gets the newest state.
  final Set<(int, int, int)> _readBackQueued = {};

  /// Read the changed object back, one at a time (the client is lock-step).
  void _readBack(Changed e) {
    final key = switch (e.object) {
      objPlayback || objFixture => (e.object, e.i1, 0),
      objCue => (objCue, e.i1, e.i2),
      objDevice || objArtNet || objSacn => (objDevice, 0, 0),
      _ => null, // not read back (e.g. programmer / selection)
    };
    if (key != null && !_readBackQueued.add(key)) return;
    _work = _work.then((_) async {
      if (key != null) _readBackQueued.remove(key);
      if (_closed) return;
      try {
        switch (e.object) {
          case objPlayback:
            final pb = await readPlayback(client, e.i1);
            final st = playbackState((await client.read(objPlayback, 0x30, i1: e.i1)).body);
            _emit(PlaybackUpdated(e.i1, pb, st));
          case objCue:
            // The whole playback is read later anyway.
            if (_readBackQueued.contains((objPlayback, e.i1, 0))) return;
            // Deleted cues are announced too, but the LPU does not answer
            // reads of them (2.4 s wasted each): only read existing cues.
            final st = playbackState((await client.read(objPlayback, 0x30, i1: e.i1)).body);
            if (e.i2 >= st.cues) return;
            _emit(CueUpdated(e.i1, e.i2, await readCue(client, e.i1, e.i2)));
          case objFixture:
            _emit(FixtureUpdated(e.i1, await readFixture(client, e.i1)));
          case objDevice || objArtNet || objSacn:
            _emit(DeviceUpdated(await readDevice(client, Show())));
          default:
            _emit(e);
        }
      } on LpuError catch (err) {
        // One read the LPU did not answer is not a lost connection; it is
        // when the LPU does not answer at all any more.
        if (!await _answers()) _reportLost(err.message);
      }
    });
  }

  Future<bool> _answers() async {
    try {
      await client.read(objPlayback, 0x30, i1: 0);
      return true;
    } on LpuError {
      return false;
    }
  }

  // --- control ----------------------------------------------------------------

  /// Run one control action after the queued work; a failure is reported as
  /// ConnectionLost (when the LPU no longer answers at all) instead of thrown
  /// (the UI fires and forgets).
  Future<void> _control(Future<void> Function() action) {
    final f = _work.then((_) async {
      if (_closed) return;
      try {
        await action();
      } on LpuError catch (err) {
        if (!await _answers()) _reportLost(err.message);
      }
    });
    _work = f;
    return f;
  }

  /// GO button: press and release (29 02 22 = 1, 0), like the reference app.
  Future<void> go(int playback) => _control(() => pressButton(client, playback, 0x22));

  /// GO button down / up separately, as a tile is held (29 02 22 = 1 / 0): the
  /// LPU decides by its go mode: Go on letting go (held 1 s: release), Toggle
  /// on the press, Flash / Solo while held.
  Future<void> goButton(int playback, bool down) =>
      _control(() => client.write(objPlayback, tBool, 0x22, i1: playback, body: encBool(down)));

  /// FLASH button down / up (29 02 23 = 1 / 0): runs the playback while held.
  Future<void> flash(int playback, bool down) =>
      _control(() => client.write(objPlayback, tBool, 0x23, i1: playback, body: encBool(down)));

  /// RELEASE one playback (29 1d 42).
  Future<void> release(int playback) =>
      _control(() => client.write(objPlayback, tNoBody, 0x42, i1: playback));

  /// RELEASE ALL (28 1d 42).
  Future<void> releaseAll() => _control(() => client.write(objAction, tNoBody, 0x42));

  final Map<(int, int), double> _pending = {}; // (playback, prop) -> newest value
  final Set<(int, int)> _sending = {};

  /// Playback fader 0..1 (29 03 18).
  void setFader(int playback, double level) => _setLevel(playback, 0x18, level.clamp(0.0, 1.0));

  /// Playback knob / speed -1..1 (29 03 16).
  void setKnob(int playback, double speed) => _setLevel(playback, 0x16, speed.clamp(-1.0, 1.0));

  void _setLevel(int playback, int prop, double value) {
    final key = (playback, prop);
    _pending[key] = value;
    if (_sending.contains(key)) return; // the running sender picks up the newest value
    _sending.add(key);
    _control(() async {
      while (_pending.containsKey(key) && !_closed) {
        final v = _pending.remove(key)!;
        await client.write(objPlayback, tFloat, prop, i1: playback, body: encFloat(v));
      }
    }).whenComplete(() => _sending.remove(key));
  }

  // --- editing (v0.7) ---------------------------------------------------------
  // The LPU answers each edit with a "changed" event, which is read back, so
  // the app ends up with the LPU's version of the edited object.

  Future<void> writePlaybackLabel(int pb, String label) =>
      _control(() => client.write(objPlayback, tStr, 0x06, i1: pb, body: encStr(label)));

  /// Playback properties window: only the given values are written.
  Future<void> writePlaybackProps(int pb, {String? goMode, String? repeat, bool? background, bool? exclusive}) =>
      _control(() => setPlayback(client, pb,
          goMode: goMode, repeat: repeat, background: background, exclusive: exclusive));

  /// Add a cue at [position] (0-based; = cue count appends). The LPU copies the
  /// previous cue's settings with empty blocks (FINDINGS 20.2).
  Future<void> insertCue(int pb, int position) =>
      _control(() => client.write(objPlayback, tU32, 0x03, i1: pb, body: encU32(position)));

  /// Give an empty playback [count] cues (29 01 48, as the upload does).
  Future<void> allocateCues(int pb, int count) =>
      _control(() => client.write(objPlayback, tU32, 0x48, i1: pb, body: encU32(count)));

  /// Delete [count] cues starting at [first] (29 1d 04, index 2 / index 3).
  Future<void> deleteCues(int pb, int first, int count) =>
      _control(() => client.write(objPlayback, tNoBody, 0x04, i1: pb, i2: first, i3: count));

  /// Write one cue completely: its 4 blocks and its settings.
  Future<void> writeCue(int pb, int q, ShowCue cue) => _control(() async {
        for (var b = 0; b < 4; b++) {
          await client.write(objCue, tPage, 0x47, i1: pb, i2: q, i3: b,
              body: Uint8List.fromList(cue.block(b).take(blockSize).toList()));
        }
        await client.write(objCue, tStr, 0x06, i1: pb, i2: q, body: encStr(cue.label));
        await client.write(objCue, tU32, 0x2a, i1: pb, i2: q, body: encU32(cue.fadeMs));
        await client.write(objCue, tU32, 0x2c, i1: pb, i2: q, body: encU32(cue.delayMs));
        await client.write(objCue, tU32, 0x28, i1: pb, i2: q, body: encU32(cue.follow ? 1 : 0));
      });

  /// SWAP button: exchange two whole playbacks (28 1d 49, index 1 / index 2).
  Future<void> swapPlaybacks(int a, int b) =>
      _control(() => client.write(objAction, tNoBody, 0x49, i1: a, i2: b));

  /// PATCH, live: write [f] (only the given parts) or clear the slot
  /// ([f] null), then read it back and report it (FixtureUpdated).
  Future<void> patchFixture(int slot, ShowFixture? f,
          {bool definition = false, bool address = false, bool name = false, bool flags = false}) =>
      _control(() async {
        if (f == null) {
          await deleteFixture(client, slot);
        } else {
          await writeFixture(client, f, definition: definition, address: address, name: name, flags: flags);
        }
        _emit(FixtureUpdated(slot, await readFixture(client, slot)));
      });

  // --- programmer (v1.2, FINDINGS 20.5a) ---------------------------------------
  // The edit screen drives the LPU's programmer, so the lights follow the
  // sliders live, like in the reference app.

  /// Fixture selection (2c 05 3c): 64-bit mask, bit n = fixture slot n.
  Future<void> selectFixtures(Iterable<int> slotIndices) {
    final mask = Uint8List(8);
    for (final s in slotIndices) {
      if (s >= 0 && s < 64) mask[s >> 3] |= 1 << (s & 7);
    }
    return _control(() => client.write(objGlobal, tBlob, 0x3c, body: mask));
  }

  /// LOAD a cue into the programmer (2c 1d 36, index 1 = playback, 2 = cue).
  /// The LPU then outputs that cue's look and selects its fixtures. First
  /// the playback being edited (2c 01 3f), as the reference app sends it: while
  /// that is not a playback 0-63 (after a power cycle) the LPU drops LOAD
  /// and RECORD silently (lpd/DMX_ENGINE.md 12, 2026-10-28).
  Future<void> loadCue(int pb, int cue) => _control(() async {
        await client.write(objGlobal, tU32, 0x3f, body: encU32(pb));
        await client.write(objGlobal, tNoBody, 0x36, i1: pb, i2: cue);
      });

  /// CLEAR the programmer (2c 1d 38): the reference app's CLEAR button (captured
  /// 2026-10-24); the upload starts with it too. The show is not touched.
  Future<void> clearProgrammer() => _control(() => client.write(objGlobal, tNoBody, 0x38));

  /// Entering (true) / leaving (false) the edit screen: 2c 02 35 = 0 / 1, as
  /// the reference app sends it. Leaving does not clear the programmer.
  Future<void> setEditing(bool editing) =>
      _control(() => client.write(objGlobal, tBool, 0x35, body: encBool(!editing)));

  /// A different position for each fixture (POSITIONS recall): the
  /// programmer writes to the selected fixtures (lpd/DMX_ENGINE.md 12), so
  /// one fixture at a time - select it, write its position (attribute 2,
  /// [positions] = slot -> the 8-byte body) - then [selection]. One job, in
  /// order: setProgrammer would keep only the newest position.
  Future<void> programmerPositions(Map<int, Uint8List> positions, Iterable<int> selection) =>
      _control(() async {
        for (final e in positions.entries) {
          final mask = Uint8List(8);
          if (e.key >= 0 && e.key < 64) mask[e.key >> 3] |= 1 << (e.key & 7);
          await client.write(objGlobal, tBlob, 0x3c, body: mask);
          await client.write(objProgrammer, 0x06, 0x33, i1: 2, body: e.value); // tPosition
        }
        final mask = Uint8List(8);
        for (final s in selection) {
          if (s >= 0 && s < 64) mask[s >> 3] |= 1 << (s & 7);
        }
        await client.write(objGlobal, tBlob, 0x3c, body: mask);
      });

  final Map<int, (int, Uint8List)> _attrPending = {}; // attr -> newest (type, body)
  final Set<int> _attrSending = {};

  /// One programmer attribute (2d <type> 33, index 1 = attribute 0-16):
  /// 0 intensity, 1/3/5 FX, 2 position, 4 colour, 6-16 other channels.
  /// While one write waits for its echo only the newest value is kept.
  void setProgrammer(int attr, int type, Uint8List body) {
    _attrPending[attr] = (type, body);
    if (_attrSending.contains(attr)) return;
    _attrSending.add(attr);
    _control(() async {
      // The check for a newer value and the end of sending happen together
      // (no await between them): a value set while the last write waited
      // for its echo is always sent, never dropped (the last slider value
      // did not reach the LPU before).
      try {
        while (!_closed) {
          final next = _attrPending.remove(attr);
          if (next == null) break;
          await client.write(objProgrammer, next.$1, 0x33, i1: attr, body: next.$2);
        }
      } finally {
        _attrSending.remove(attr);
      }
    });
  }

  // --- device settings (v0.8) ------------------------------------------------

  /// The LPU's IP / mask (null ip = DHCP). The LPU moves to its new address
  /// at once, so this session is lost afterwards (the service reconnects).
  Future<void> setNetwork({List<int>? ip, List<int>? mask}) =>
      _control(() => writeNetwork(client, ip: ip, mask: mask));

  /// Change the LPU's own output / name settings; only the given values are
  /// written. The settings are read back afterwards and reported as
  /// DeviceUpdated (not relying on a "changed" notification for them).
  Future<void> writeDeviceSettings(
          {String? alias, bool? artNet, int? artNetUniverse, int? artNetRaw, bool? sacn, int? sacnUniverse}) =>
      _control(() async {
        if (alias != null) await setAlias(client, alias);
        if (artNet != null || artNetUniverse != null || artNetRaw != null) {
          await setArtNet(client, enabled: artNet, universe: artNetUniverse, raw: artNetRaw);
        }
        if (sacn != null || sacnUniverse != null) {
          await setSacn(client, enabled: sacn, universe: sacnUniverse);
        }
        _emit(DeviceUpdated(await readDevice(client, Show())));
      });

  // --- upload (v0.7) -------------------------------------------------------------

  bool _uploading = false;

  /// Replace the LPU's show with [newShow], like opening a show in the reference app:
  /// RELEASE ALL first (a show replaced under running playbacks can hang the
  /// LPU, FINDINGS 20.13), upload, read it back and compare. No backup is
  /// read first (it made OPEN slower than in the reference app). Read-backs are
  /// paused meanwhile; afterwards the LPU's show is reported as a fresh
  /// ShowDownloaded. Throws [LpuError] when the LPU stops answering (the LPU
  /// may then hold a partial show).
  ///
  /// [fraction] reports the progress (0..1) over sending and checking. When
  /// [cancelled] turns true while sending (Abort), the sending stops and
  /// [restore] (the show the LPU had, as the app knows it) is sent instead,
  /// so the LPU does not keep half a show; the result then has
  /// `aborted: true`.
  Future<({List<String> diffs, bool aborted})> uploadShow(Show newShow,
      {Show? restore,
      void Function(String step)? progress,
      void Function(double done)? fraction,
      bool Function()? cancelled}) {
    // Only forwards: the read-back reports its playbacks out of order (reads
    // overlap), and the restore after Abort counts down.
    var shown = 0.0;
    final forward = fraction;
    void Function(double)? onward = forward == null
        ? null
        : (f) {
            if (f >= shown || f == 0) forward(shown = f);
          };
    final done = Completer<({List<String> diffs, bool aborted})>();
    _work = _work.then((_) async {
      if (_closed) return done.completeError(LpuError('session closed'));
      _uploading = true;
      try {
        progress?.call('releasing all playbacks');
        onward?.call(0);
        await client.write(objAction, tNoBody, 0x42);
        progress?.call('uploading');
        var aborted = false;
        try {
          await upload(client, newShow, fraction: (f) => onward?.call(0.9 * f), cancelled: cancelled);
        } on UploadCancelled {
          aborted = true;
          if (restore != null) {
            progress?.call('restoring the previous show');
            await upload(client, restore, fraction: (f) => onward?.call(0.9 * (1 - f)));
          }
        }
        progress?.call('verifying');
        final r = await download(client, progress: (pb, _, __) => onward?.call(0.9 + 0.1 * pb / slots));
        _emit(ShowDownloaded(r.show, r.info, await _states(client, r.show)));
        onward?.call(1);
        final expected = aborted ? restore : newShow;
        done.complete((
          diffs: expected == null ? const <String>[] : compareShows(expected, r.show),
          aborted: aborted,
        ));
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        _uploading = false;
      }
    });
    return done.future;
  }

  Future<void> close() async {
    _closed = true;
    _watchdog.cancel();
    await _sub.cancel();
    await _work.catchError((_) {});
    await client.close();
    await _events.close();
  }
}
