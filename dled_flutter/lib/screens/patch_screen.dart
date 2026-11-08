import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xml/xml.dart' as xml;
import '../core/fixture_codes.dart';
import '../core/patch.dart';
import '../models/show_model.dart';
import '../services/show_exporter.dart' show loadPersonalityXml;
import 'options_screen.dart';
import '../widgets/app_button.dart';
import '../widgets/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/fixture_grid.dart';

// ---------------------------------------------------------------------------
// Utility: count DMX channels from personality hex string
// Each pair of hex chars = 1 channel (e.g. "090A0B" = 3 channels)
// ---------------------------------------------------------------------------
int _channelCountFromHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final count = clean.length ~/ 2;
  return count < 1 ? 1 : count;
}

// ---------------------------------------------------------------------------
// Utility: derive Set<String> attribute names from personality hex string
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Utility: derive a fixture class label from the channel set
// e.g. "RGB", "RGBW", "RGBWA", "Dimmer", "Moving Head", "Generic"
// ---------------------------------------------------------------------------
String _classFromChannels(Set<String> ch) {
  final hasPan  = ch.contains('Pan')  || ch.contains('Tilt');
  final hasRgb  = ch.contains('R') && ch.contains('G') && ch.contains('B');
  final hasW    = ch.contains('W');
  final hasA    = ch.contains('A');
  final hasUv   = ch.contains('UV');
  final hasDim  = ch.contains('In');

  if (hasPan) return 'Moving';
  if (hasRgb && hasA && hasW) return 'RGBAW';
  if (hasRgb && hasW && hasUv) return 'RGBWUV';
  if (hasRgb && hasW) return 'RGBW';
  if (hasRgb && hasA) return 'RGBA';
  if (hasRgb) return 'RGB';
  if (hasDim) return 'Dimmer';
  return 'Generic';
}

// Which sliders a patched fixture gets: the shared code table
// (core/fixture_codes.dart; fine channels count as their main channel), plus
// the colour-mixing codes on the RGB sliders.
const Map<int, String> _colourMixCodes = {
  0x44: 'R', 0x64: 'R', // cyan (+ fine)
  0x45: 'G', 0x65: 'G', // magenta (+ fine)
  0x46: 'B', 0x66: 'B', // yellow (+ fine)
  0x47: 'A', 0x48: 'W',
};

Set<String> _channelsFromHex(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  final result = <String>{};
  for (int i = 0; i + 1 < clean.length; i += 2) {
    final code = int.parse(clean.substring(i, i + 2), radix: 16);
    final attr = attrForCode(code) ?? _colourMixCodes[code];
    if (attr != null) result.add(attr);
  }
  return result;
}

class PatchScreen extends StatefulWidget {
  final int initialTab;
  const PatchScreen({super.key, this.initialTab = 0});

  @override
  State<PatchScreen> createState() => _PatchScreenState();
}

class _PatchScreenState extends State<PatchScreen> {
  late int _tab;
  final Set<int> _selectedSlots = {};

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
  }

  void _toggleSlot(int i) {
    setState(() {
      if (_selectedSlots.contains(i)) {
        _selectedSlots.remove(i);
      } else {
        _selectedSlots.add(i);
      }
    });
  }

  void _addSlot(int i) => setState(() => _selectedSlots.add(i));
  void _removeSlot(int i) => setState(() => _selectedSlots.remove(i));
  void _clearSelection() => setState(() => _selectedSlots.clear());

  @override
  Widget build(BuildContext context) {
    final model = context.watch<ShowModel>();
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          _TopBar(tab: _tab, onTabChanged: (t) => setState(() => _tab = t)),
          Expanded(
            child: _tab == 0
                ? _PatchTab(
                    model: model,
                    selectedSlots: _selectedSlots,
                    onToggleSlot: _toggleSlot,
                    onSlideSlot: _addSlot,
                    onRemoveSlot: _removeSlot,
                    onDeselect: _clearSelection,
                  )
                : OptionsScreen(model: model),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------
class _TopBar extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTabChanged;
  const _TopBar({required this.tab, required this.onTabChanged});

  @override
  Widget build(BuildContext context) => AppTopBar(
        connected: context.watch<ShowModel>().liveConnected,
        left: [
          _Tab('PATCH', tab == 0, () => onTabChanged(0)),
          _Tab('OPTIONS', tab == 1, () => onTabChanged(1)),
        ],
        right: [_BackBtn(onTap: () => Navigator.of(context).pop())],
      );
}

class _BackBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _BackBtn({required this.onTap});

  @override
  Widget build(BuildContext context) => AppButton('', icon: Icons.chevron_left, onTap: onTap);
}

// PATCH / OPTIONS: the open one is lit; tapping it goes back to PLAYBACK.
class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Tab(this.label, this.active, this.onTap);

  @override
  Widget build(BuildContext context) => AppButton(label,
      lit: active, onTap: active ? () => Navigator.of(context).pushReplacementNamed('/playback') : onTap);
}

// ---------------------------------------------------------------------------
// PATCH tab
// ---------------------------------------------------------------------------
class _PatchTab extends StatefulWidget {
  final ShowModel model;
  final Set<int> selectedSlots;
  final ValueChanged<int> onToggleSlot;
  final ValueChanged<int> onSlideSlot;
  final ValueChanged<int> onRemoveSlot;
  final VoidCallback onDeselect;
  const _PatchTab({
    required this.model,
    required this.selectedSlots,
    required this.onToggleSlot,
    required this.onSlideSlot,
    required this.onRemoveSlot,
    required this.onDeselect,
  });

  @override
  State<_PatchTab> createState() => _PatchTabState();
}

// "SET START ADDRESS" like the reference app: DIP switches 1-10 (the address in
// binary), up/down per digit around a 3-digit display, Ok / Cancel.
// Pops with the new address (1-512) or null.
class _StartAddressDialog extends StatefulWidget {
  final int initial;
  const _StartAddressDialog({required this.initial});

  @override
  State<_StartAddressDialog> createState() => _StartAddressDialogState();
}

class _StartAddressDialogState extends State<_StartAddressDialog> {
  late int _addr = widget.initial.clamp(1, 512);

  static const _border = Colors.white38;
  static const _text = Colors.white70;

  void _set(int v) {
    if (v >= 1 && v <= 512) setState(() => _addr = v);
  }

  Widget _box({required Widget child, VoidCallback? onTap, double? height}) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border.all(color: _border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: child,
        ),
      );

  Widget _arrow(int step, bool up) => Expanded(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: _box(
            height: 36,
            onTap: () => _set(_addr + (up ? step : -step)),
            child: Icon(up ? Icons.arrow_drop_up : Icons.arrow_drop_down, color: Colors.white, size: 40),
          ),
        ),
      );

  Widget _dip(int bit) {
    final on = _addr & (1 << bit) != 0;
    Widget half(String s, bool lit) => Expanded(
          child: Container(
            alignment: Alignment.center,
            color: lit ? const Color(0xFFBBBBBB) : const Color(0xFF3A3A3A),
            child: Text(s,
                style: TextStyle(color: lit ? Colors.black87 : _text, fontSize: 11)),
          ),
        );
    return Expanded(
      child: GestureDetector(
        onTap: () => _set(_addr ^ (1 << bit)),
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          // The switch knob is up (lit "on") when the bit is set.
          child: Column(children: [half('on', on), half('${bit + 1}', !on)]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            border: Border.all(color: Colors.white24),
            borderRadius: BorderRadius.circular(6),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 40,
                  decoration: const BoxDecoration(
                    color: Color(0xFF555555),
                    borderRadius: BorderRadius.horizontal(left: Radius.circular(6)),
                  ),
                  child: const Center(
                    child: RotatedBox(
                      quarterTurns: 3,
                      child: Text('SET START ADDRESS',
                          style: TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 1)),
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(children: [for (var b = 0; b < 10; b++) _dip(b)]),
                        const SizedBox(height: 8),
                        Row(children: [_arrow(100, true), _arrow(10, true), _arrow(1, true)]),
                        Padding(
                          padding: const EdgeInsets.all(3),
                          child: _box(
                            height: 60,
                            child: Text(_addr.toString().padLeft(3, '0'),
                                style: const TextStyle(color: _text, fontSize: 22)),
                          ),
                        ),
                        Row(children: [_arrow(100, false), _arrow(10, false), _arrow(1, false)]),
                        const SizedBox(height: 8),
                        Row(children: [
                          const Spacer(),
                          SizedBox(
                            width: 110,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _box(
                                height: 36,
                                onTap: () => Navigator.pop(context, _addr),
                                child: const Text('Ok', style: TextStyle(color: _text, fontSize: 13)),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 110,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: _box(
                                height: 36,
                                onTap: () => Navigator.pop(context),
                                child: const Text('Cancel', style: TextStyle(color: _text, fontSize: 13)),
                              ),
                            ),
                          ),
                        ]),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PatchTabState extends State<_PatchTab> {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Row(
            children: [
              const Text('FIXTURES', style: appHeader),
              const Spacer(),
              if (widget.selectedSlots.isNotEmpty)
                GestureDetector(
                  onTap: widget.onDeselect,
                  child: const Text('DESELECT ALL',
                      style: TextStyle(color: Colors.white38, fontSize: 10)),
                ),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FixtureGrid(
              fixtures: widget.model.fixtures,
              selected: widget.selectedSlots,
              onToggle: widget.onToggleSlot,
              onSet: (slot, on) => on ? widget.onSlideSlot(slot) : widget.onRemoveSlot(slot),
              // 8 x 8 filling the space, like the reference app (taller tiles
              // on a tall phone)
              square: false,
            ),
          ),
        ),
        _PatchBottomBar(
          model: widget.model,
          selectedSlots: widget.selectedSlots,
          onDeselect: widget.onDeselect,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Patch bottom bar
// ---------------------------------------------------------------------------
class _PatchBottomBar extends StatelessWidget {
  final ShowModel model;
  final Set<int> selectedSlots;
  final VoidCallback onDeselect;
  const _PatchBottomBar({
    required this.model,
    required this.selectedSlots,
    required this.onDeselect,
  });

  FixturePatch? get _firstFx {
    for (final slot in selectedSlots) {
      try {
        return model.fixtures.firstWhere((f) => f.slot == slot);
      } catch (_) {}
    }
    return null;
  }

  List<FixturePatch> get _allFx => selectedSlots
      .map((slot) {
        try {
          return model.fixtures.firstWhere((f) => f.slot == slot);
        } catch (_) {
          return null;
        }
      })
      .whereType<FixturePatch>()
      .toList();

  bool get _hasAny => selectedSlots.isNotEmpty;

  /// The entries of the selected slots; an empty slot gets an entry without a
  /// personality (only name / address / flags), like the reference app allows.
  List<FixturePatch> _entries() {
    final out = <FixturePatch>[];
    var nextId = model.fixtures.fold<int>(0, (m, f) => f.id > m ? f.id : m);
    for (final slot in [...selectedSlots]..sort()) {
      FixturePatch? f;
      for (final x in model.fixtures) {
        if (x.slot == slot) f = x;
      }
      if (f == null) {
        f = FixturePatch(id: ++nextId, slot: slot, channelCount: 0);
        model.addFixture(f);
      }
      out.add(f);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final fx = _firstFx;
    // Laid out as two panels; left a
    // joined PERSONALITY / RENAME / ADDRESS column with CLEAR beside it,
    // right the four patch flags as one joined row at the bottom. No MARGIN
    // (the reference app has none). No fixed height, so nothing gets cut off.
    Widget btn(String label, VoidCallback? onTap, {bool active = false}) =>
        _BottomBtn(label, onTap: onTap, active: active);
    // Taller on a tall (phone) screen, like the reference app; as small as its
    // buttons at 1024 high.
    final extra = ((MediaQuery.of(context).size.height - 1024) * 0.25).clamp(0.0, 300.0);
    return Container(
      color: AppColors.background,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      constraints: BoxConstraints(minHeight: 140 + extra),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Panel(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ButtonGroup(axis: Axis.vertical, children: [
                    btn('PERSONALITY', _hasAny ? () => _showPersonalityLibrary(context) : null),
                    // Like the reference app: every button works for any selected
                    // slot, an empty one too.
                    btn('RENAME', _hasAny ? () => _showRenameDialog(context) : null),
                    btn('ADDRESS', _hasAny ? () => _showAddressDialog(context) : null),
                  ]),
                  const SizedBox(width: 12),
                  _ButtonGroup(axis: Axis.vertical, children: [
                    btn(
                        'CLEAR',
                        _hasAny
                            ? () {
                                for (final f in _allFx) {
                                  model.removeFixture(f.id);
                                }
                                onDeselect();
                              }
                            : null),
                  ]),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _Panel(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: _ButtonGroup(axis: Axis.horizontal, children: [
                    btn('INVERT\nPAN',
                        _hasAny ? () { for (final f in _entries()) { model.toggleFixtureInvertPan(f.id); } } : null,
                        active: fx?.invertPan ?? false),
                    btn('INVERT\nTILT',
                        _hasAny ? () { for (final f in _entries()) { model.toggleFixtureInvertTilt(f.id); } } : null,
                        active: fx?.invertTilt ?? false),
                    btn('SWAP\nPAN/TILT',
                        _hasAny ? () { for (final f in _entries()) { model.toggleFixtureSwapPanTilt(f.id); } } : null,
                        active: fx?.swapPanTilt ?? false),
                    btn('VIRTUAL\nDIMMER',
                        _hasAny ? () { for (final f in _entries()) { model.toggleFixtureVirtualDimmer(f.id); } } : null,
                        active: fx?.virtualDimmer ?? false),
                  ]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Personality library: returns {manufacturer, model, mode, channelCount, hex}
  // -------------------------------------------------------------------------
  void _showPersonalityLibrary(BuildContext context) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _PersonalityLibraryDialog(),
    );
    if (result == null) return;

    final channelCount = result['channelCount'] as int? ?? 1;
    int nextId = model.fixtures.isEmpty
        ? 0
        : model.fixtures.map((f) => f.id).reduce((a, b) => a > b ? a : b);

    // Sort selected slots for predictable auto-address ordering
    final sortedSlots = [...selectedSlots]..sort();

    // Addresses: replacing a patched fixture keeps its address; otherwise the
    // first free channels (core/patch.dart), each next fixture after the one
    // before, so new fixtures never land on patched ones.
    final used = [
      for (final f in model.fixtures)
        if (f.isPatched && !sortedSlots.contains(f.slot)) (start: f.address, count: f.channelCount < 1 ? 1 : f.channelCount)
    ];
    final replaced = model.fixtures.where((f) => f.isPatched && f.slot == sortedSlots.firstOrNull).firstOrNull;
    int nextAddr = replaced?.address ?? 1;

    for (final s in sortedSlots) {
      if (!(s == sortedSlots.first && replaced != null)) nextAddr = freeAddress(used, channelCount, from: nextAddr);
      used.add((start: nextAddr, count: channelCount));
      try {
        final existing = model.fixtures.firstWhere((f) => f.slot == s);
        model.removeFixture(existing.id);
      } catch (_) {}
      nextId++;
      final hex = result['hex'] as String? ?? '';
      model.addFixture(FixturePatch(
        id: nextId,
        slot: s,
        label: '', // no name yet: the tile shows the fixture number

        manufacturer: result['manufacturer'] as String? ?? '',
        model: result['model'] as String? ?? '',
        mode: result['mode'] as String? ?? '',
        address: nextAddr.clamp(1, 512),
        universe: 0,
        channelCount: channelCount,
        profile: hex,
        channels: _channelsFromHex(hex),
        fixtureClass: _classFromChannels(_channelsFromHex(hex)),
      ));
      nextAddr = (nextAddr + channelCount).clamp(1, 512);
    }
  }

  // -------------------------------------------------------------------------
  // Rename dialog
  // -------------------------------------------------------------------------
  void _showRenameDialog(BuildContext context) {
    final fx = _firstFx;
    showDialog(
      context: context,
      builder: (_) => NameDialog(
        title: 'RENAME FIXTURE',
        initial: fx?.label ?? '',
        onOk: (name) {
          for (final f in _entries()) {
            model.renameFixture(f.id, name);
          }
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Address dialog - auto-increments by channelCount per fixture
  // -------------------------------------------------------------------------
  Future<void> _showAddressDialog(BuildContext context) async {
    final fx = _firstFx;
    final addr = await showDialog<int>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => _StartAddressDialog(initial: fx?.address ?? 1),
    );
    if (addr == null) return;
    // Several fixtures selected: consecutive addresses from the start address
    // (an empty slot takes one address).
    final sorted = _entries();
    int next = addr;
    for (final f in sorted) {
      model.setFixtureAddress(f.id, next, f.universe);
      next = (next + (f.channelCount < 1 ? 1 : f.channelCount)).clamp(1, 512);
    }
  }
}

// ---------------------------------------------------------------------------
// Bottom button widget
// ---------------------------------------------------------------------------
// A rounded panel of the patch bottom bar.
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});
  @override
  // The reference app's bottom panels: the page grey with a faint dark edge.
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C2F),
          border: Border.all(color: const Color(0xFF232325)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );
}

// Buttons joined into one block.
class _ButtonGroup extends StatelessWidget {
  final Axis axis;
  final List<Widget> children;
  const _ButtonGroup({required this.axis, required this.children});
  @override
  Widget build(BuildContext context) => AppButtonGroup(axis: axis, children: children);
}

// A button of the PATCH panels: the app's one button.
class _BottomBtn extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool active;
  const _BottomBtn(this.label, {this.onTap, this.active = false});

  @override
  // No highlight for an option that is on (the reference app has none; the tile
  // shows the flags P T S D).
  Widget build(BuildContext context) => AppButton(label, onTap: onTap);
}

// ---------------------------------------------------------------------------
// Personality Library Dialog
// Returns Map<String, dynamic> with keys: manufacturer, model, mode,
//   channelCount (int), hex (String)
// ---------------------------------------------------------------------------
class _PersonalityLibraryDialog extends StatefulWidget {
  const _PersonalityLibraryDialog();

  @override
  State<_PersonalityLibraryDialog> createState() => _PersonalityLibraryDialogState();
}

class _PersonalityLibraryDialogState extends State<_PersonalityLibraryDialog> {
  bool _loading = true;
  List<xml.XmlElement> _manufacturers = [];
  String? _selectedMfg;
  String? _selectedModel;
  String? _selectedMode;
  String _selectedHex = '';
  List<xml.XmlElement> _models = [];
  List<String> _modes = [];
  Map<String, String> _modeHexMap = {}; // mode label -> hex

  @override
  void initState() {
    super.initState();
    _loadXml();
  }

  Future<void> _loadXml() async {
    final data = await loadPersonalityXml(); // the local library when there is one
    final doc = xml.XmlDocument.parse(data);
    setState(() {
      _manufacturers = doc.rootElement.findElements('manufacturer').toList();
      _loading = false;
    });
  }

  void _selectMfg(String label) {
    final mfg = _manufacturers.firstWhere((m) => m.getAttribute('label') == label);
    setState(() {
      _selectedMfg = label;
      _selectedModel = null;
      _selectedMode = null;
      _selectedHex = '';
      _models = mfg.findElements('model').toList();
      _modes = [];
      _modeHexMap = {};
    });
  }

  void _selectModel(xml.XmlElement modelEl) {
    final modeEls = modelEl.findElements('mode').toList();
    final Map<String, String> hexMap = {};

    if (modeEls.isEmpty) {
      // Single-mode fixture: hex is the text content of <model>
      final hex = modelEl.innerText.trim();
      hexMap['Default'] = hex;
    } else {
      for (final m in modeEls) {
        final lbl = m.getAttribute('label') ?? '';
        if (lbl.isNotEmpty) hexMap[lbl] = m.innerText.trim();
      }
    }

    final modes = hexMap.keys.toList();
    final firstMode = modes.isNotEmpty ? modes.first : 'Default';
    setState(() {
      _selectedModel = modelEl.getAttribute('label');
      _modes = modes;
      _modeHexMap = hexMap;
      _selectedMode = firstMode;
      _selectedHex = hexMap[firstMode] ?? '';
    });
  }

  int get _channelCount => _channelCountFromHex(_selectedHex);

  // Like the reference app: the grey PERSONALITY LIBRARY strip, a-z (jumps to
  // the first manufacturer with that letter), Manufacturer / Model / Mode
  // lists with a line under each row and the selected row grey, Ok / Cancel.
  static const double _row = 45;
  final ScrollController _mfgScroll = ScrollController();

  @override
  void dispose() {
    _mfgScroll.dispose();
    super.dispose();
  }

  void _jumpTo(String letter) {
    final i = _manufacturers.indexWhere((m) => (m.getAttribute('label') ?? '').toLowerCase().startsWith(letter));
    if (i < 0 || !_mfgScroll.hasClients) return;
    _mfgScroll.jumpTo((i * _row).clamp(0.0, _mfgScroll.position.maxScrollExtent));
  }

  Widget _list(List<String> items, String? selected, ValueChanged<int> onTap, {ScrollController? controller}) =>
      ListView.builder(
        controller: controller,
        padding: EdgeInsets.zero,
        itemExtent: _row,
        itemCount: items.length,
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => onTap(i),
          child: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: items[i] == selected ? const Color(0xFF8A8A8A) : Colors.transparent,
              border: const Border(bottom: BorderSide(color: Color(0xFF4A4A4A))),
            ),
            child: Text(items[i],
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFFE0E0E0), fontSize: 14)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final letters = List.generate(26, (i) => String.fromCharCode(97 + i));
    final height = (MediaQuery.of(context).size.height - 120).clamp(300.0, 760.0);
    const head = TextStyle(color: Color(0xFFC8C8C8), fontSize: 14);
    return DialogPanel(
      title: 'PERSONALITY LIBRARY',
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: 540,
        height: height,
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF8A8A8A)))
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                // a-z
                Container(
                  width: 48,
                  color: const Color(0xFF2A2A2A),
                  child: Column(children: [
                    for (final l in letters)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _jumpTo(l),
                          child: Center(child: Text(l, style: const TextStyle(color: Color(0xFFB4B4B4), fontSize: 13))),
                        ),
                      ),
                  ]),
                ),
                Expanded(
                  child: Column(children: [
                    const SizedBox(
                      height: 30,
                      child: Row(children: [
                        Expanded(flex: 5, child: Center(child: Text('Manufacturer', style: head))),
                        Expanded(flex: 5, child: Center(child: Text('Model', style: head))),
                        Expanded(flex: 3, child: Center(child: Text('Mode', style: head))),
                      ]),
                    ),
                    Expanded(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(
                          flex: 5,
                          child: _list([for (final m in _manufacturers) m.getAttribute('label') ?? ''], _selectedMfg,
                              (i) => _selectMfg(_manufacturers[i].getAttribute('label') ?? ''),
                              controller: _mfgScroll),
                        ),
                        Expanded(
                          flex: 5,
                          child: _list([for (final m in _models) m.getAttribute('label') ?? ''], _selectedModel,
                              (i) => _selectModel(_models[i])),
                        ),
                        Expanded(
                          flex: 3,
                          child: _list(_modes, _selectedMode, (i) => setState(() {
                                _selectedMode = _modes[i];
                                _selectedHex = _modeHexMap[_modes[i]] ?? '';
                              })),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 10, 10),
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        DialogButton('Ok',
                            onTap: _selectedModel == null
                                ? null
                                : () => Navigator.pop(context, {
                                      'manufacturer': _selectedMfg ?? '',
                                      'model': _selectedModel ?? '',
                                      'mode': _selectedMode ?? '',
                                      'hex': _selectedHex,
                                      'channelCount': _channelCount,
                                    })),
                        const SizedBox(width: 8),
                        DialogButton('Cancel', onTap: () => Navigator.pop(context)),
                      ]),
                    ),
                  ]),
                ),
              ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// OPTIONS tab
// ---------------------------------------------------------------------------
