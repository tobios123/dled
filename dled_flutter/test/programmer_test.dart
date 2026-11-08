// v1.2 programmer live preview: the edit screen's selection, sliders, FX and
// LOAD reach the LPU's programmer (FINDINGS 20.5a), checked on the emulator
// through a second client; plus the attribute encodings.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dled/core/frame.dart';
import 'package:dled/core/lpu_client.dart';
import 'package:dled/models/show_model.dart';
import 'package:dled/services/live_sync.dart';
import 'package:dled/services/programmer.dart';
import 'package:dled/services/vn_service.dart';

import 'core/emulator.dart';

const _m400 = 'test/core_data/shows/m400.show';

double f32(Uint8List b, [int o = 0]) => b.buffer.asByteData(b.offsetInBytes).getFloat32(o, Endian.little);
int u16(Uint8List b, int o) => b.buffer.asByteData(b.offsetInBytes).getUint16(o, Endian.little);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  group('encodings', () {
    final attrs = {'In': 255.0, 'R': 255.0, 'G': 127.5, 'B': 0.0, 'A': 0.0, 'W': 51.0, 'Zoom': 102.0, 'UV': 200.0};
    test('intensity is attr 0, float 0..1', () {
      final w = sliderWrites(attrs, 128, 128, ['In']).single;
      expect([w.attr, w.type, f32(w.body)], [0, tFloat, 1.0]);
    });
    test('one colour slider sends all five colours (attr 4, u16 LE R G B A W)', () {
      final w = sliderWrites(attrs, 128, 128, ['G']).single;
      expect([w.attr, w.type, w.body.length], [4, tColour, 10]);
      expect([for (var i = 0; i < 5; i++) u16(w.body, i * 2)], [65535, 32768, 0, 0, 13107]);
    });
    test('joystick is attr 2: pan, tilt -1..+1', () {
      final w = sliderWrites(attrs, 0, 255, ['Pan']).single;
      expect([w.attr, w.type, f32(w.body), f32(w.body, 4)], [2, tPosition, -1.0, 1.0]);
    });
    test('other channels are attrs 6-16; UV has none', () {
      final w = sliderWrites(attrs, 128, 128, ['Zoom', 'UV']);
      expect(w.map((x) => x.attr), [14]);
      expect(f32(w.single.body), closeTo(0.4, 1e-6));
    });
    test('FX generators are attrs 1 / 3 / 5 with the cue-block bytes', () {
      final w = fxWrite('colour', CueFxSlot(waveform: 'Rainbow', size: 100, speed: 10, phase: 0));
      expect([w.attr, w.type, w.body[0], w.body[1]], [5, tFx, 10, 255]);
      expect(fxWrite('intensity', CueFxSlot()).attr, 1);
      expect(fxWrite('position', CueFxSlot()).attr, 3);
    });
  });

  group('on the emulator', () {
    final port = 35000 + pid % 1000;
    Emulator? emu;
    late ShowModel model;
    LpuClient? lpu;
    setUpAll(() async {
      emu = await Emulator.start(port, show: _m400);
      if (emu == null) return;
      model = ShowModel();
      model.vnService.onLiveEvent = (e) => LiveSync.apply(model, e, deviceIp: '127.0.0.1');
      await model.vnService.connect(
          VnDevice(label: 'LPU-1', ip: '127.0.0.1', port: port, version: '1.29', lastSeen: DateTime.now()));
      lpu = await LpuClient.connect('127.0.0.1', port: port);
    });
    tearDownAll(() async {
      await lpu?.close();
      if (emu != null) model.vnService.stop();
      emu?.stop();
    });
    bool skip() {
      if (emu == null) markTestSkipped('python / emulator not available');
      return emu == null;
    }

    Future<void> onLpu(Future<bool> Function() ok, String what) async {
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!await ok()) {
        if (DateTime.now().isAfter(end)) throw TimeoutException(what);
        await Future.delayed(const Duration(milliseconds: 30));
      }
    }

    Future<Uint8List> attr(int a) async => (await lpu!.read(objProgrammer, 0x32, i1: a)).body;

    test('selecting fixtures sets the LPU selection mask', () async {
      if (skip()) return;
      model.programmerSelect([0, 2, 9]);
      await onLpu(() async {
        final m = (await lpu!.read(objGlobal, 0x3b)).body;
        return m[0] == 0x05 && m[1] == 0x02;
      }, 'mask fixtures 1, 3, 10');
    });

    test('sliders, joystick and FX go to the programmer live', () async {
      if (skip()) return;
      final attrs = {'In': 255.0, 'R': 255.0, 'G': 0.0, 'B': 0.0, 'A': 0.0, 'W': 0.0, 'Zoom': 51.0};
      model.programmerWrite(sliderWrites(attrs, 255, 0, ['In', 'R', 'Pan', 'Zoom']));
      model.programmerWrite([fxWrite('intensity', CueFxSlot(waveform: 'Ramp', size: 100, speed: 0, phase: 0))]);
      await onLpu(() async => f32(await attr(0)) == 1.0, 'intensity full');
      expect(u16(await attr(4), 0), 65535);
      final pos = await attr(2);
      expect([f32(pos), f32(pos, 4)], [1.0, -1.0]);
      expect(f32(await attr(14)), closeTo(0.2, 1e-6));
      expect((await attr(1))[0], 2); // Ramp
    });

    test('a slider drag ends at the last value', () async {
      if (skip()) return;
      for (var i = 0; i <= 50; i++) {
        model.programmerWrite(sliderWrites({'In': i * 5.1}, 128, 128, ['In']));
      }
      await onLpu(() async => f32(await attr(0)) == 1.0, 'last value');
    });

    test('LOAD loads the cue on the LPU (its look and its fixtures)', () async {
      if (skip()) return;
      model.programmerSelect([]);
      model.programmerLoad(0, 1); // playback 1, cue 2
      await onLpu(() async => (await lpu!.read(objGlobal, 0x3b)).body.any((b) => b != 0), 'cue fixtures selected');
      expect(await lpu!.readValue(objGlobal, 0x45), isNot(0)); // programmer has data
    });

    test('CLEAR empties the programmer and leaves the show alone', () async {
      if (skip()) return;
      model.programmerWrite(sliderWrites({'In': 255}, 128, 128, ['In']));
      await onLpu(() async => await lpu!.readValue(objGlobal, 0x45) != 0, 'has data');
      final labels = [for (var p = 0; p < 3; p++) await lpu!.readValue(objPlayback, 0x05, i1: p)];
      model.programmerClear();
      await onLpu(() async => await lpu!.readValue(objGlobal, 0x45) == 0, 'programmer empty');
      expect(f32(await attr(0)), 0);
      expect([for (var p = 0; p < 3; p++) await lpu!.readValue(objPlayback, 0x05, i1: p)], labels);
      expect((await lpu!.read(objPlayback, 0x30, i1: 0)).body[2], isNot(0)); // cues still there
    });

    test('entering / leaving the edit screen sets 2c 35 = 0 / 1, programmer kept', () async {
      if (skip()) return;
      model.programmerWrite(sliderWrites({'In': 255}, 128, 128, ['In']));
      model.programmerEditing(true);
      await onLpu(() async => await lpu!.readValue(objGlobal, 0x34) == 0, 'editing');
      model.programmerEditing(false);
      await onLpu(() async => await lpu!.readValue(objGlobal, 0x34) == 1, 'left edit');
      expect(f32(await attr(0)), 1.0); // leaving does not clear
    });

    test('offline nothing is sent', () async {
      if (skip()) return;
      final offline = ShowModel(); // never connected
      offline.programmerSelect([1]);
      offline.programmerWrite(sliderWrites({'In': 255}, 128, 128, ['In']));
      offline.programmerLoad(0, 0);
      offline.programmerClear();
      offline.programmerEditing(true);
      expect(offline.vnService.isConnected, isFalse);
    });
  });
}
