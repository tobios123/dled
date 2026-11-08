// A recorded empty (unpatched) slot survives the trip to the LPU and back:
// its values are read from its record directly (it has no channel list), so
// LOAD shows it on the EDIT page. Patched slots keep their own decoding.

import 'package:flutter_test/flutter_test.dart';
import 'package:dled/core/show_file.dart' as core;
import 'package:dled/models/show_model.dart';
import 'package:dled/services/show_exporter.dart';
import 'package:dled/services/show_loader.dart';

void main() {
  test('an empty slot recorded in a cue comes back', () {
    final cue = Cue(number: 1, label: 'Cue 1', channels: {'29:R': 0.5, '29:In': 1.0});
    final src = core.ShowCue(label: '', fadeMs: 0, delayMs: 0, follow: false, blocks: encodeCueBlocks(cue, const []));
    final back = ParsedShow.modelCue(ShowLoader.cueFromCore(src, const {}), 0, src);
    expect(back.channels['29:R'], closeTo(0.5, 0.001));
    expect(back.channels['29:In'], 1.0);
    expect(back.isRecorded, isTrue);

    // a patched slot is not read this way
    final skipped = ParsedShow.modelCue(ShowLoader.cueFromCore(src, const {}), 0, src, patched: {29});
    expect(skipped.channels.keys.where((k) => k.startsWith('29:')), isEmpty);
  });

  test('a pure-FX cue holds only the fixtures it was recorded on', () {
    // "Rainbow" on fixtures 1-3 only (the reference app's LOAD selects just those)
    final cue = Cue(number: 1, slots: {0, 1, 2})..fxColour.waveform = 'Rainbow';
    cue.fxColour.size = 50;
    final blocks = encodeCueBlocks(cue, List.generate(27, (i) => i)); // 27 patched
    final src = core.ShowCue(label: '', fadeMs: 0, delayMs: 0, follow: false, blocks: blocks);
    final back = ParsedShow.modelCue(ShowLoader.cueFromCore(src, const {}), 0, src, patched: {for (var i = 0; i < 27; i++) i});
    expect(back.slots, {0, 1, 2});
  });
}
