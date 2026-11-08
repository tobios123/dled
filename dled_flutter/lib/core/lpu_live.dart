// lpu_live.dart -- the LPU's live notifications as typed events. Pure Dart.
//
// Notifications are frames with value type | 0x80 and mask 0000 (FINDINGS
// 20.1/20.2/20.2a). Playback pushes:
//   29 81 2f  active cue (0xff = released)
//   29 81 24  cue phase: 0 no cues, 1 released, 2 running (timer), 3 holding, 4 releasing
//   29 82 50  GO button active state
//   29 83 17  intensity (fader), 29 83 15 speed (knob, -1..1)
//   29 81 3d  cue count
// Generic "changed" event: <object> 81 00, body = change code; the client
// reads the object back (lpu_session.dart).

import 'dart:typed_data';

import 'frame.dart';
import 'show_file.dart';

/// Device settings that have no place in a .show (alias, Art-Net, sACN ...).
class LpuInfo {
  String mac = '', subnet = '', firmware = '', pcb = '', alias = '';
  int artNetUniverseRaw = 0; // UI universe x 16
  bool artNetEnabled = false, sacnEnabled = false;
  int sacnUniverse = 0;
  int get artNetUniverse => artNetUniverseRaw ~/ 16;
}

/// Live state of one playback from its packed state (29 30).
typedef PlaybackStatus = ({int cues, int? activeCue, int state});

/// Packed playback state (29 30): cue count, active cue (null = released), state.
PlaybackStatus playbackState(Uint8List body) {
  if (body.length < 4) return (cues: 0, activeCue: null, state: 0);
  return (cues: body[2], activeCue: body[3] == 0xff ? null : body[3], state: body[1] & 0x0f);
}

abstract class LiveEvent {
  const LiveEvent();
}

/// The whole show was downloaded on connect, with each playback's live state.
class ShowDownloaded extends LiveEvent {
  final Show show;
  final LpuInfo info;
  final Map<int, PlaybackStatus> states;
  const ShowDownloaded(this.show, this.info, this.states);
}

/// A playback was read back after a change (null = the slot is now empty).
class PlaybackUpdated extends LiveEvent {
  final int index;
  final ShowPlayback? playback;
  final PlaybackStatus state;
  const PlaybackUpdated(this.index, this.playback, this.state);
}

/// A fixture slot was read back after a change (null = nothing patched).
class FixtureUpdated extends LiveEvent {
  final int slot;
  final ShowFixture? fixture;
  const FixtureUpdated(this.slot, this.fixture);
}

/// A cue was read back after a change.
class CueUpdated extends LiveEvent {
  final int playback, cueIndex;
  final ShowCue cue;
  const CueUpdated(this.playback, this.cueIndex, this.cue);
}

/// Device settings (alias, Art-Net, sACN) were read back after a change.
class DeviceUpdated extends LiveEvent {
  final LpuInfo info;
  const DeviceUpdated(this.info);
}

/// The LPU stopped answering.
class ConnectionLost extends LiveEvent {
  final String reason;
  const ConnectionLost(this.reason);
}

/// Active cue of a playback (0-based), or null when released.
class ActiveCue extends LiveEvent {
  final int playback;
  final int? cue;
  const ActiveCue(this.playback, this.cue);
  @override
  String toString() => 'ActiveCue(pb ${playback + 1}, ${cue == null ? 'released' : 'cue ${cue! + 1}'})';
}

/// 0 no cues, 1 released, 2 running with a timer, 3 holding, 4 releasing.
class CuePhase extends LiveEvent {
  final int playback, phase;
  const CuePhase(this.playback, this.phase);
  @override
  String toString() => 'CuePhase(pb ${playback + 1}, $phase)';
}

class GoActive extends LiveEvent {
  final int playback;
  final bool active;
  const GoActive(this.playback, this.active);
  @override
  String toString() => 'GoActive(pb ${playback + 1}, ${active ? 'pressed' : 'up'})';
}

class FaderLevel extends LiveEvent {
  final int playback;
  final double level; // 0..1
  const FaderLevel(this.playback, this.level);
  @override
  String toString() => 'FaderLevel(pb ${playback + 1}, $level)';
}

class KnobSpeed extends LiveEvent {
  final int playback;
  final double speed; // -1..1
  const KnobSpeed(this.playback, this.speed);
  @override
  String toString() => 'KnobSpeed(pb ${playback + 1}, $speed)';
}

class CueCount extends LiveEvent {
  final int playback, count;
  const CueCount(this.playback, this.count);
  @override
  String toString() => 'CueCount(pb ${playback + 1}, $count)';
}

/// "<object> 81 00": something about this object changed; read it back.
class Changed extends LiveEvent {
  final int object, i1, i2, code;
  const Changed(this.object, this.i1, this.i2, this.code);
  @override
  String toString() => 'Changed(${object.toRadixString(16)} [$i1,$i2] code 0x${code.toRadixString(16)})';
}

/// "2d 8x 32": a programmer attribute changed (by any app, or by LOAD), with
/// its new value: [attr] 0-16 as in services/programmer.dart.
class ProgrammerValue extends LiveEvent {
  final int attr;
  final Uint8List body;
  const ProgrammerValue(this.attr, this.body);
  @override
  String toString() => 'ProgrammerValue(attr $attr, ${body.length} bytes)';
}

/// Any other notification, kept for logging / later decoding.
class OtherNotification extends LiveEvent {
  final Frame frame;
  const OtherNotification(this.frame);
  @override
  String toString() => 'OtherNotification($frame)';
}

/// Decode a notification frame; null if [f] is not a notification.
LiveEvent? decodeNotification(Frame f) {
  if (!f.isNotification) return null;
  final v = f.value();
  final n = v is int ? v : 0;
  if (f.prop == 0x00 && f.baseType == tU32) return Changed(f.op, f.i1, f.i2, n);
  if (f.op == objProgrammer && f.prop == 0x32) return ProgrammerValue(f.i1, f.body);
  if (f.op == objPlayback) {
    switch ((f.baseType, f.prop)) {
      case (tU32, 0x2f):
        return ActiveCue(f.i1, n == 0xff ? null : n);
      case (tU32, 0x24):
        return CuePhase(f.i1, n);
      case (tBool, 0x50):
        return GoActive(f.i1, n != 0);
      case (tFloat, 0x17):
        return FaderLevel(f.i1, v is double ? v : 0);
      case (tFloat, 0x15):
        return KnobSpeed(f.i1, v is double ? v : 0);
      case (tU32, 0x3d):
        return CueCount(f.i1, n);
    }
  }
  return OtherNotification(f);
}
