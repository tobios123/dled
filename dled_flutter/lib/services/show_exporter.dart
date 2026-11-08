// show_exporter.dart -- app model -> .show file (the EXPORT button).
//
// Written by core/show_file.dart, so the file is exactly what the reference app
// and the Python tools write. Cue data:
//   - a cue that is unchanged since import keeps its original 16-bit blocks
//     (per-fixture FX, unpatched-slot data, fine values: nothing is lost);
//   - a changed or new cue is encoded from its channel values (0.0-1.0 ->
//     u16 at the fader's record offset) and its one FX setting per category,
//     which is written into the record of every fixture the cue uses.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:xml/xml.dart';

import '../core/cue_codec.dart' as codec;
import '../core/show_file.dart' as core;
import '../models/show_model.dart';

/// A cue's content as one string: equal strings = unchanged cue. Stored at
/// import (Cue.rawSignature) and compared at export.
String cueSignature(Cue c) {
  final keys = c.channels.keys.toList()..sort();
  return jsonEncode({
    'ch': [for (final k in keys) '$k=${(c.channels[k]! * 255).round()}'],
    'fx': [c.fxIntensity.toJson(), c.fxPosition.toJson(), c.fxColour.toJson()],
    if (c.slots.isNotEmpty) 'sl': (c.slots.toList()..sort()),
    if (c.slotFx.isNotEmpty)
      'sfx': [for (final s in c.slotFx.keys.toList()..sort()) [s, for (final f in c.slotFx[s]!) f.toJson()]],
  });
}

/// UI FX speed (-100..100 %) -> signed byte (core/cue_codec.dart).
int fxSpeedByte(double pct) => codec.fxSpeedByte(pct);

codec.FxValues fxValues(CueFxSlot fx) => (waveform: fx.waveform, size: fx.size, speed: fx.speed, phase: fx.phase);

/// The 4 bytes of one FX generator ('intensity' / 'position' / 'colour'), as
/// in a cue block and in the LPU programmer (attributes 1 / 3 / 5).
List<int> fxGeneratorBytes(String generator, CueFxSlot fx) => codec.fxBytes(generator, fxValues(fx));

/// Encode a cue from the app model into 4 blocks of 16 x 50-byte records
/// (core/cue_codec.dart).
List<Uint8List> encodeCueBlocks(Cue cue, Iterable<int> patchedSlots) => codec.encodeCueBlocks(
    cue.channels, cue.slots, [fxValues(cue.fxIntensity), fxValues(cue.fxPosition), fxValues(cue.fxColour)], patchedSlots,
    slotFx: {for (final e in cue.slotFx.entries) e.key: [for (final f in e.value) fxValues(f)]});

/// The fixture library's text: assets/personalities.local.xml when it is there
/// (a fuller library of your own, not in Git), else assets/personalities.xml
/// (the public copy: one example fixture).
Future<String> loadPersonalityXml() async {
  try {
    return await rootBundle.loadString('assets/personalities.local.xml');
  } catch (_) {
    return rootBundle.loadString('assets/personalities.xml');
  }
}

/// personalities.xml -> "manufacturer|model|mode" -> profile hex, for fixtures
/// patched before the app kept profiles.
Future<Map<String, String>> loadPersonalityProfiles() async {
  final xml = XmlDocument.parse(await loadPersonalityXml());
  final out = <String, String>{};
  for (final man in xml.findAllElements('manufacturer')) {
    for (final mod in man.findElements('model')) {
      final modes = mod.findElements('mode').toList();
      final key = '${man.getAttribute('label')}|${mod.getAttribute('label')}';
      if (modes.isEmpty) {
        out['$key|'] = mod.innerText.trim();
      } else {
        for (final m in modes) {
          out['$key|${m.getAttribute('label')}'] = m.innerText.trim();
        }
      }
    }
  }
  return out;
}

/// Build the .show content for a show held in the app model.
core.Show showFromModel({
  required List<Cuelist> cuelists,
  required List<FixturePatch> fixtures,
  Map<String, String> device = const {},
  Map<String, String> profiles = const {},
}) {
  final show = core.Show(device: {...device});
  final sortedFixtures = [...fixtures]..sort((a, b) => a.slot.compareTo(b.slot));
  for (final f in sortedFixtures) {
    if (f.slot < 0 || f.slot > 63) continue;
    show.fixtures.add(core.ShowFixture(
      index: f.slot,
      address: f.address,
      manufacturer: f.manufacturer,
      model: f.model,
      mode: f.mode,
      profile: f.profile.isNotEmpty ? f.profile : profiles['${f.manufacturer}|${f.model}|${f.mode}'] ?? '',
      name: f.label,
      invertPan: f.invertPan,
      invertTilt: f.invertTilt,
      swapPanTilt: f.swapPanTilt,
      virtualDimmer: f.virtualDimmer,
    ));
  }
  final patched = sortedFixtures.map((f) => f.slot);
  for (var i = 0; i < cuelists.length && i < 64; i++) {
    final cl = cuelists[i];
    // Slots never touched in the app have no level; playbacks that came from a
    // show file (even empty ones, <playback index=".." />) have one.
    final used = cl.label.isNotEmpty ||
        cl.cues.isNotEmpty ||
        cl.goMode != GoMode.go ||
        cl.repeatMode != RepeatMode.loop ||
        cl.background ||
        cl.exclusive ||
        cl.hasLevel ||
        cl.level > 0 ||
        cl.speed != 0;
    if (!used) continue;
    show.playbacks.add(core.ShowPlayback(
      index: i,
      label: cl.label,
      // Playbacks made in the app have no level yet: the LPU default is full.
      // A real fader at 0 (from a show / the LPU) stays 0.
      intensity: cl.hasLevel || cl.level > 0 ? cl.level : 1.0,
      speed: cl.speed,
      goMode: core.goModes[cl.goMode.index],
      repeat: core.repeatModes[cl.repeatMode.index],
      background: cl.background,
      exclusive: cl.exclusive,
      cues: [for (final (q, c) in cl.cues.indexed) coreCueFromModel(c, q, patched)],
    ));
  }
  return show;
}

/// One app cue as the LPU / .show stores it (cue [q] of its playback).
core.ShowCue coreCueFromModel(Cue c, int q, Iterable<int> patchedSlots) => core.ShowCue(
      // "Cue N" is only what the app shows for an unnamed cue.
      label: c.label == 'Cue ${q + 1}' ? '' : c.label,
      fadeMs: (c.fadeIn * 1000).round(),
      delayMs: (c.delay * 1000).round(),
      follow: c.condition == CueCondition.follow,
      blocks: c.rawBlocks != null && c.rawSignature == cueSignature(c)
          ? [for (final b in c.rawBlocks!) b.isEmpty ? Uint8List(0) : base64Decode(b)]
          : encodeCueBlocks(c, patchedSlots),
    );
