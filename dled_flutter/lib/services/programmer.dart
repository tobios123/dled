// programmer.dart -- the edit screen's values as LPU programmer attributes.
// The logic is shared with the light page (core/cue_codec.dart); this file
// only adds the app model's FX type.

import '../core/cue_codec.dart' as codec;
import '../models/show_model.dart' show CueFxSlot;
import 'show_exporter.dart' show fxValues;

export '../core/cue_codec.dart'
    show ProgrammerWrite, sliderWrites, decodeProgrammer, tFx, tPosition, tColour, colourKeys, otherAttrs;

/// The write for one FX generator ('intensity' / 'position' / 'colour').
codec.ProgrammerWrite fxWrite(String generator, CueFxSlot fx) => codec.fxWrite(generator, fxValues(fx));
