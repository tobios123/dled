"""Tests for analysis/lpu. Run from the project folder:

    python -m unittest discover -s analysis/tests -v

Uses only the standard library. Tests that need the sample .show files skip
themselves if the files are missing; emulator tests run on 127.0.0.1.
"""
import os
import socket
import struct
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYSIS = os.path.dirname(HERE)
ROOT = os.path.dirname(ANALYSIS)
sys.path.insert(0, ANALYSIS)

from lpu import lpu_io, personalities, protocol, report, showfile, simulator  # noqa: E402

SAMPLES = os.path.join(ROOT, "samples")
M400 = os.path.join(SAMPLES, "m400_12x12_rgb_dim_shut.show")
FX = os.path.join(SAMPLES, "show_all_fx_options.show")


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class TimesAndFx(unittest.TestCase):
    def test_time_format(self):
        self.assertEqual(showfile.parse_time_ms("00-00-01-00"), 1000)
        self.assertEqual(showfile.parse_time_ms("00-00-02-50"), 2500)
        self.assertEqual(showfile.parse_time_ms("01-02-03-04"), 3723040)
        self.assertEqual(showfile.parse_time_ms(None), 0)
        for ms in (0, 10, 1000, 2500, 3723040):
            self.assertEqual(showfile.parse_time_ms(showfile.format_time_ms(ms)), ms)

    def test_fx_speed_is_signed(self):
        # UI-verified edge values (FINDINGS 20.5a)
        for byte, pct in {0: 0, 13: 10, 127: 100, 128: 100, 129: -100, 255: -1}.items():
            self.assertEqual(showfile.fx_speed_percent(byte), pct, byte)

    def test_describe_fx(self):
        self.assertIsNone(showfile.describe_fx("colour", (0, 0, 0, 0)))
        self.assertTrue(showfile.describe_fx("colour", (12, 255, 42, 132)).startswith("Full Twinkle"))


class Records(unittest.TestCase):
    def test_decode_record_layout(self):
        rec = bytearray(50)
        rec[0:4] = bytes([2, 255, 21, 75])          # intensity FX Ramp
        # u16 little-endian; pan / tilt int16 around the centre (lpd/DMX_ENGINE.md 2)
        rec[12:16] = bytes([0xff, 0x7f, 0x01, 0x80])  # pan full right, tilt full left (as the app stores them)
        rec[16:18] = b"\xff\xff"                     # intensity
        rec[20:30] = bytes.fromhex("ffff0000ffff00003412")  # R G B A W
        rec[34:36] = b"\xc2\x44"
        r = showfile.decode_record(bytes(rec))
        self.assertEqual(r.fx_intensity, (2, 255, 21, 75))
        self.assertEqual((r.pan, r.tilt, r.intensity), (65534, 0, 0xFFFF))
        self.assertEqual(r.rgbaw, (0xFFFF, 0, 0xFFFF, 0, 0x1234))
        self.assertEqual(r.attrs, {"shutter": 0x44C2})
        self.assertEqual(showfile.decode_record(bytes(50)).pan, 32767)  # nothing = centre
        self.assertEqual(showfile.dmx_to_signed(0), 0x8001)
        self.assertEqual(r.other, {})

    def test_channel_offsets_from_app_cues(self):
        # pb5 "new channels de": cue 1 has every fader up, each later cue switches
        # exactly the fader in its label off (fixture 17, a CLF Aorun spot).
        show = showfile.load_show(os.path.join(HERE, "data", "app_saved_channels.show"))
        pb = next(p for p in show.playbacks if p.index == 4)
        rec = lambda c: showfile.decode_record(c.blocks[1][0:50])   # fixture 17 = bank 1, record 0
        on = set(rec(pb.cues[0]).attrs)
        for cue in pb.cues[1:]:
            fader = cue.label.replace(" off", "").replace("color", "colour")
            if fader == "intensity":
                self.assertEqual(rec(cue).intensity, 0)
                continue
            self.assertIn(fader, on)
            self.assertNotIn(fader, rec(cue).attrs, cue.label)

    def test_every_fader_offset(self):
        # pb6 "missing channel": each cue sets exactly one fader to full on a
        # SilverStar PLUTO 200 (fixture 25 = bank 1, record 8).
        show = showfile.load_show(os.path.join(HERE, "data", "app_saved_channels.show"))
        pb = next(p for p in show.playbacks if p.index == 5)
        want = {"custum 2 on": "custom 2", "custem 1 on": "custom 1", "zoom": "zoom",
                "iris": "iris", "rotation": "gobo rotation", "frost": "frost",
                "focus": "focus", "prism": "prism", "gobo": "gobo", "color wheel": "colour wheel"}
        for cue in pb.cues[1:]:
            r = showfile.decode_record(cue.blocks[1][8 * 50:9 * 50])
            self.assertEqual(r.attrs, {want[cue.label]: 0xFFFF}, cue.label)
            self.assertEqual(r.other, {})
        # The offset order is the function-code order 0x0A..0x11 (FINDINGS 20.11).
        for code, name in ((0x0B, "gobo rotation"), (0x0D, "iris"), (0x0E, "frost"),
                           (0x0F, "focus"), (0x10, "prism"), (0x11, "zoom")):
            self.assertEqual(showfile.ATTR_OFFSETS[30 + 2 * (code - 0x0A)], name)
            self.assertEqual(personalities.function_name(code), name)

    def test_cue_record_bank(self):
        blocks = [b"", b"", bytearray(800), b""]
        blocks[2][5 * 50 + 16:5 * 50 + 18] = b"\x00\x80"     # fixture 2*16+5 = 37 (u16 LE)
        cue = showfile.Cue(blocks=[bytes(b) for b in blocks])
        self.assertEqual(cue.record(37).intensity, 0x8000)
        self.assertTrue(cue.record(5).empty)


class Personalities(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.p = personalities.Personalities()

    def test_loaded(self):
        if not self.p.loaded:
            self.skipTest("personalities.xml not found")
        # the example fixture is in the public library and in a local one
        self.assertEqual(self.p.lookup("Generic", "RGBW Par", "8 ch")[0], "01040506080C8012")

    def test_lookup_and_truncation(self):
        # needs a full library of your own (personalities.local.xml)
        if not self.p.loaded or len(self.p.entries) < 1000:
            self.skipTest("no full fixture library here")
        self.assertEqual(self.p.lookup("Showtec", "Kanjo spot 60", "10 ch")[0], "0222032314090A010C80")
        # the LPU stores model names cut to 29 characters
        self.assertIsNotNone(self.p.lookup("Shehds", "LED BEAM 12x12W RGBW Moving H", "16 ch"))
        self.assertEqual(self.p.full_model_name("Shehds", "LED BEAM 12x12W RGBW Moving H", "16 ch"),
                         "LED BEAM 12x12W RGBW Moving Head")

    def test_channel_names(self):
        names = [n for _, _, n in personalities.channel_list("040506080713")]
        self.assertEqual(names, ["red", "green", "blue", "white", "amber", "UV"])


class Frames(unittest.TestCase):
    def test_frame_roundtrip(self):
        f = protocol.make_frame(0x2b, 0x0a, 0x47, 1, 3, 2, bytes(800), seq=0x1234)
        self.assertEqual(f[:12].hex(" "), "2b 0a 47 00 01 00 03 00 02 00 ff ff")
        p = protocol.parse_frame(f)
        self.assertEqual(p[:6], (0x2b, 0x0a, 0x47, 1, 3, 2))
        self.assertEqual((p[7], len(p[8])), (0x1234, 800))

    def test_strings(self):
        self.assertEqual(protocol.enc_str("None"), b"None\0")
        self.assertEqual(protocol.dec_str(b"LPU\0junk"), "LPU")

    def test_definition_parse(self):
        self.assertEqual(lpu_io.parse_definition('"Showtec","Kanjo spot 60","10 ch","0222"'),
                         ["Showtec", "Kanjo spot 60", "10 ch", "0222"])
        self.assertIsNone(lpu_io.parse_definition('"","","",""'))


@unittest.skipUnless(os.path.exists(M400) and os.path.exists(FX), "sample shows missing")
class ShowFiles(unittest.TestCase):
    def test_save_load_roundtrip(self):
        for path in (M400, FX):
            a = showfile.load_show(path)
            with tempfile.TemporaryDirectory() as d:
                out = os.path.join(d, "x.show")
                showfile.save_show(a, out)
                b = showfile.load_show(out)
            self.assertEqual(lpu_io.compare(a, b), [], path)

    def test_m400_content(self):
        s = showfile.load_show(M400)
        self.assertEqual((len(s.fixtures), len(s.playbacks)), (9, 19))
        self.assertEqual(sum(len(p.cues) for p in s.playbacks), 45)
        pb1 = s.playbacks[0]
        self.assertEqual(pb1.label, "Basic col")
        self.assertAlmostEqual(pb1.intensity, 0.975104, places=5)
        self.assertEqual(pb1.cues[1].record(0).rgbaw[:3], (0, 0xFFFF, 0xFFFF))   # cyan
        self.assertEqual(pb1.cues[0].fade_ms, 1000)

    def test_report_renders(self):
        text = report.render(showfile.load_show(FX), source="fx")
        self.assertIn("Kanjo spot 60", text)
        self.assertIn("colour FX Rainbow", text)


@unittest.skipUnless(os.path.exists(M400), "sample shows missing")
class Emulator(unittest.TestCase):
    def setUp(self):
        self.port = free_port()
        self.emu = simulator.run(bind_ip="127.0.0.1", port=self.port, log=lambda *a: None)

    def tearDown(self):
        self.emu.stop()
        time.sleep(0.1)

    def test_upload_download_roundtrip(self):
        show = showfile.load_show(M400)
        lpu_io.upload("127.0.0.1", show, port=self.port, log=lambda *a: None)
        back = lpu_io.download("127.0.0.1", port=self.port, log=lambda *a: None)
        self.assertEqual(lpu_io.compare(show, back), [])

    def test_packed_states(self):
        show = showfile.load_show(M400)
        show.playbacks[0].gomode, show.playbacks[0].repeat = "Solo", "Off"
        show.playbacks[0].background = True
        show.fixtures[-1].invert_pan = True                     # a moving head
        lpu_io.upload("127.0.0.1", show, port=self.port, log=lambda *a: None)
        with protocol.LpuClient("127.0.0.1", port=self.port) as c:
            body = c.read(protocol.OBJ_PLAYBACK, 0x30, 0)[1]
            self.assertEqual(body[:4], bytes([0x31, 0x31, 6, 0xFF]))
            st = c.read_value(protocol.OBJ_FIXTURE, 0x30, show.fixtures[-1].index)
            self.assertEqual(st, show.fixtures[-1].address << 16 | 1)
            self.assertEqual(c.read_value(protocol.OBJ_FIXTURE, 0x30, 60), 0xFFFF0000)

    def test_names_and_flags_through_show_file(self):
        # Fixture names and patch flags: LPU -> download -> .show -> upload -> LPU
        show = showfile.load_show(M400)
        mover = show.fixtures[-1]                       # a moving head (has pan/tilt)
        mover.name, mover.invert_pan, mover.virtual_dimmer = "spot L", True, True
        lpu_io.upload("127.0.0.1", show, port=self.port, log=lambda *a: None)
        back = lpu_io.download("127.0.0.1", port=self.port, log=lambda *a: None)
        self.assertEqual(lpu_io.compare(show, back), [])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.show")
            showfile.save_show(back, path)
            with open(path, encoding="utf-8") as fh:
                text = fh.read()
            again = showfile.load_show(path)
        self.assertIn('label="spot L"', text)
        self.assertIn('invert_pan="true"', text)
        f = again.fixture(mover.index)
        self.assertEqual((f.name, f.invert_pan, f.invert_tilt, f.virtual_dimmer),
                         ("spot L", True, False, True))
        # A .show without the attributes means "off": uploading it clears them.
        lpu_io.upload("127.0.0.1", showfile.load_show(M400), port=self.port, log=lambda *a: None)
        f = lpu_io.download("127.0.0.1", port=self.port, log=lambda *a: None).fixture(mover.index)
        self.assertEqual((f.name, f.invert_pan, f.virtual_dimmer), ("", False, False))

    def test_unknown_xml_is_kept(self):
        xml = ('<show application="DLED" version="1.19.0" readonly="true"><fixtures>'
               '<fixture index="0" address="1" manufacturer="A" model="B" mode="" '
               'profile="01" personality="3:7" /></fixtures><playbacks>'
               '<playback index="0" level="0.5"><cues><cue label="x" mystery="1"><blocks>'
               '<block /><block /><block /><block /></blocks></cue></cues></playback>'
               '</playbacks><buttons><button index="2" /></buttons></show>')
        with tempfile.TemporaryDirectory() as d:
            src, dst = os.path.join(d, "a.show"), os.path.join(d, "b.show")
            with open(src, "w", encoding="utf-8") as fh:
                fh.write(xml)
            showfile.save_show(showfile.load_show(src), dst)
            with open(dst, encoding="utf-8") as fh:
                out = fh.read()
        for piece in ('readonly="true"', 'personality="3:7"', 'level="0.5"', 'mystery="1"',
                      '<button index="2" />'):
            self.assertIn(piece, out)

    def test_app_saved_names_and_flags(self):
        # Saved by the reference app: labels and one flag per fixture.
        src = os.path.join(HERE, "data", "app_saved_flags.show")
        show = showfile.load_show(src)
        got = [(f.name, f.invert_pan, f.invert_tilt, f.swap_pan_tilt, f.virtual_dimmer)
               for f in show.fixtures]
        self.assertEqual(got, [("fixt 1", True, False, False, False),
                               ("fixt 2", False, True, False, False),
                               ("", False, False, True, False),
                               ("", False, False, False, True)])
        with tempfile.TemporaryDirectory() as d:
            dst = os.path.join(d, "b.show")
            showfile.save_show(show, dst)
            with open(dst, encoding="utf-8") as fh:
                out = fh.read()
        with open(src, encoding="utf-8") as fh:
            want = fh.read()
        # Same fixture lines as the app writes, attribute order included.
        lines = lambda t: [l.strip() for l in t.splitlines() if "<fixture " in l]
        self.assertEqual(lines(out), lines(want))

    def test_go_notifications(self):
        lpu_io.upload("127.0.0.1", showfile.load_show(M400), port=self.port, log=lambda *a: None)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0))
        s.settimeout(0.3)
        try:
            for v in (1, 0):                                   # GO press + release on pb1
                s.sendto(protocol.make_frame(0x29, 0x02, 0x22, 0, body=protocol.enc_u32(v)),
                         ("127.0.0.1", self.port))
            got = []
            end = time.time() + 1
            while time.time() < end:
                try:
                    d, _ = s.recvfrom(4096)
                except socket.timeout:
                    break
                p = protocol.parse_frame(d)
                if p and p[1] & 0x80 and p[0] == 0x29:
                    got.append((p[2], struct.unpack("<I", p[8])[0]))
        finally:
            s.close()
        self.assertIn((0x2f, 0), got)       # active cue 1
        self.assertIn((0x24, 3), got)       # cue phase holding
        self.assertIn((0x50, 1), got)       # active

    def test_short_properties(self):
        with protocol.LpuClient("127.0.0.1", port=self.port) as c:
            self.assertEqual(protocol.dec_str(c.short_read(0x11)), "LPU")
            self.assertEqual(c.short_read(0x09), bytes([1, 29]))


if __name__ == "__main__":
    unittest.main()
