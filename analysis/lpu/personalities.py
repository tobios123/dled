"""personalities.xml lookup and DMX function-code names.

personalities.xml (the app's fixture library, dled_flutter/assets/personalities.xml):
    <manufacturer label=..><model label=.. class=..>PROFILE</model>
    or <model ..><mode label=..>PROFILE</mode></model>
PROFILE is a hex string, two digits per DMX channel = function code.

Function names: codes marked confirmed were matched against fixture names and
manuals (e.g. "RGBWA+UV" = 04 05 06 08 07 13; Kanjo spot 60 = pan, pan fine,
tilt, tilt fine, PT speed, colour, gobo, dimmer, strobe, function). The rest
come from older notes and are marked with '?'.
"""

import os
import xml.etree.ElementTree as ET

_ASSETS = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", "dled_flutter", "assets"))
# your own fuller library (not in Git) when it is there, else the public example
DEFAULT_PATH = next((p for p in (os.path.join(_ASSETS, "personalities.local.xml"),
                                 os.path.join(_ASSETS, "personalities.xml")) if os.path.exists(p)),
                    os.path.join(_ASSETS, "personalities.xml"))

FUNCTION_NAMES = {
    0x01: "dimmer",
    0x02: "pan",
    0x03: "tilt",
    0x04: "red",
    0x05: "green",
    0x06: "blue",
    0x07: "amber",
    0x08: "white",
    0x09: "colour wheel",
    0x0A: "gobo",
    # 0x0A-0x12 follow the record order of the faders (FINDINGS 20.11): cues
    # only store faders whose code the fixture has. 0x12 rests on one fixture.
    0x0B: "gobo rotation",
    0x0C: "shutter/strobe",
    0x0D: "iris",
    0x0E: "frost",
    0x0F: "focus",
    0x10: "prism",
    0x11: "zoom",
    0x12: "custom 1?",
    0x13: "UV",
    0x14: "pan/tilt speed",
    0x22: "pan fine",
    0x23: "tilt fine",
    # Spots with CMY mixing use 44 45 46 where RGB fixtures use 04 05 06.
    0x44: "cyan?",
    0x45: "magenta?",
    0x46: "yellow?",
    0x80: "generic/function",
}


def function_name(code):
    if code in FUNCTION_NAMES:
        return FUNCTION_NAMES[code]
    # 0x22/0x23 are pan/tilt fine: code + 0x20 = fine channel of that code
    # (0x24 red fine, 0x28 white fine, 0x64 cyan fine ... - inferred).
    base = FUNCTION_NAMES.get(code - 0x20)
    if base:
        return base.rstrip("?") + " fine?"
    return f"fn 0x{code:02X}"


def split_profile(profile):
    p = (profile or "").strip()
    return [int(p[i:i + 2], 16) for i in range(0, len(p) - 1, 2)]


def channel_list(profile):
    """-> [(dmx offset 1-based, code, name), ...]"""
    return [(i + 1, c, function_name(c)) for i, c in enumerate(split_profile(profile))]


class Personalities:
    def __init__(self, path=DEFAULT_PATH):
        self.path = path
        self.entries = {}          # (manufacturer, model, mode) lowercase -> (profile, class)
        self.names = {}            # same key -> model name as written in the file
        self.by_profile = {}
        if path and os.path.exists(path):
            self._load(path)

    def _load(self, path):
        root = ET.parse(path).getroot()
        for man in root.iter("manufacturer"):
            m = man.get("label", "")
            for model in man.findall("model"):
                ml = model.get("label", "")
                cls = model.get("class", "")
                modes = model.findall("mode")
                if modes:
                    for mode in modes:
                        self._add(m, ml, mode.get("label", ""), (mode.text or "").strip(), cls)
                else:
                    self._add(m, ml, "", (model.text or "").strip(), cls)

    def _add(self, man, model, mode, profile, cls):
        self.entries[(man.lower(), model.lower(), mode.lower())] = (profile.upper(), cls)
        self.names[(man.lower(), model.lower(), mode.lower())] = model
        self.by_profile.setdefault(profile.upper(), []).append((man, model, mode))

    @property
    def loaded(self):
        return bool(self.entries)

    def lookup(self, manufacturer, model, mode=""):
        """-> (profile, class) or None. The LPU truncates long model names
        (29 chars seen), so a prefix match on the model is accepted."""
        key = (manufacturer.lower(), model.lower(), (mode or "").lower())
        if key in self.entries:
            return self.entries[key]
        for (m, mo, md), v in self.entries.items():
            if m == key[0] and md == key[2] and mo.startswith(key[1]) and len(key[1]) >= 20:
                return v
        return None

    def full_model_name(self, manufacturer, model, mode=""):
        """Undo LPU truncation if a unique longer name exists."""
        hits = [self.names[k] for k in self.entries
                if k[0] == manufacturer.lower() and k[2] == (mode or "").lower()
                and k[1].startswith(model.lower()) and k[1] != model.lower()]
        return hits[0] if len(hits) == 1 else None
