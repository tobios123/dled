import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../core/show_file.dart' show writeShow;
import '../models/show_model.dart';
import '../services/file_save.dart'
    if (dart.library.html) '../services/file_save_web.dart';
import '../services/show_exporter.dart';
import '../services/show_loader.dart';
import '../services/vn_service.dart'; // every platform (udp.dart: UDP or the bridge)
import '../widgets/dialogs.dart';
import '../widgets/app_button.dart';
import '../widgets/app_theme.dart';

// ---------------------------------------------------------------------------
// OPTIONS screen, laid out like the reference app (background_settings): the
// device list with its buttons on top, the show files below.
//
// Connecting: selecting an LPU in the device list connects to it (and the
// app remembers it); tapping empty space in the list deselects it, which
// disconnects and empties the app. At start the app connects by itself to
// the LPU selected last, or to the only LPU on the network (VnService).
// ---------------------------------------------------------------------------

const _bg = AppColors.background;
const _panel = AppColors.panel;
const _head = appHeader;
const _cell = TextStyle(color: Color(0xFFD8D8D8), fontSize: 14);
const _cellSelected = TextStyle(color: Color(0xFF1A1A1A), fontSize: 14);
const _rowSelected = Color(0xFF9A9A9A); // light grey bar, like the reference app

class OptionsScreen extends StatefulWidget {
  final ShowModel model;
  const OptionsScreen({super.key, required this.model});

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  int _selectedShow = -1;
  Timer? _rescanTimer;
  void Function(List<VnDevice>)? _prevOnDevicesChanged;
  void Function(VnDevice?)? _prevOnConnectionChanged;

  ShowModel get _m => widget.model;
  VnService get _vn => _m.vnService;

  @override
  void initState() {
    super.initState();
    // Chain onto the existing callbacks (set by main.dart) so that the
    // main.dart sync of VnDevice -> model.networkDevices and its
    // connected / offline switch still run.
    _prevOnDevicesChanged = _vn.onDevicesChanged;
    _vn.onDevicesChanged = (devices) {
      _prevOnDevicesChanged?.call(devices);
      if (mounted) setState(() {});
    };
    _prevOnConnectionChanged = _vn.onConnectionChanged;
    _vn.onConnectionChanged = (d) {
      _prevOnConnectionChanged?.call(d);
      if (mounted) setState(() {});
    };
    // Not connected: look for the LPU again (unless the user deselected it).
    if (!_vn.isConnected && !_vn.isConnecting) _vn.startAutoConnect();
    // Send discovery immediately when the options page opens, then every 2s.
    _vn.rescan();
    _rescanTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) _vn.rescan();
    });
    // Files may have been added to the folder; refresh after the first frame
    // (refreshing notifies listeners, which must not happen during a build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _m.loadShowFileList();
    });
  }

  @override
  void dispose() {
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _vn.onDevicesChanged = _prevOnDevicesChanged;
    _vn.onConnectionChanged = _prevOnConnectionChanged;
    super.dispose();
  }

  /// The LPU the app is connected (or connecting) to.
  String? get _activeIp => _vn.connected?.ip ?? _vn.connecting?.ip;

  NetworkDevice? get _activeDevice {
    final ip = _activeIp;
    for (final d in _m.networkDevices) {
      if (d.ipAddress == ip) return d;
    }
    return null;
  }

  void _selectDevice(NetworkDevice d) {
    if (d.ipAddress == _activeIp) return;
    final vd = _vn.devices.where((x) => x.ip == d.ipAddress).firstOrNull ??
        VnDevice(label: d.displayName, ip: d.ipAddress, port: 16945, version: d.firmware, lastSeen: DateTime.now());
    _vn.connect(vd); // the user's choice: remembered for the next start
    setState(() {});
  }

  void _deselectDevice() {
    if (_activeIp == null) return;
    _m.deselectLpu();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        children: [
          Expanded(flex: 5, child: _devicesSection()),
          const SizedBox(height: 14),
          Expanded(flex: 5, child: _showsSection()),
        ],
      ),
    );
  }

  // --- devices --------------------------------------------------------------

  static const _cols = [2.6, 1.8, 1.6, 1.8, 1.4, 1.0]; // DEVICES LABEL FIRMWARE HARDWARE ART-NET sACN

  Widget _columns(List<Widget> cells) => Row(children: [
        for (var i = 0; i < cells.length; i++)
          Expanded(flex: (_cols[i] * 10).round(), child: cells[i]),
      ]);

  Widget _devicesSection() {
    final devices = _m.networkDevices;
    final active = _activeDevice;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 8, 8),
            child: _columns(const [
              Text('DEVICES', style: _head),
              Text('LABEL', style: _head),
              Text('FIRMWARE', style: _head),
              Text('HARDWARE', style: _head),
              Text('ART-NET', style: _head),
              Text('sACN', style: _head),
            ]),
          ),
          Expanded(
            child: _Panel(
              // Tapping empty space deselects (disconnects) the LPU.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _deselectDevice,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    for (final d in devices)
                      _deviceRow(d, d.ipAddress == _activeIp, connected: _vn.connected?.ip == d.ipAddress),
                  ],
                ),
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      // Only as tall as its buttons (no black bar below them).
      Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 34),
          child: _BtnColumn(children: [
          _OptBtn('IP ADDRESS', onTap: active == null ? null : () => _ipDialog(active)),
          _OptBtn('RENAME', onTap: active == null ? null : () => _renameDevice(active)),
          _OptBtn('ART-NET', onTap: active == null ? null : () => _artNetDialog(active)),
          _OptBtn('sACN', onTap: active == null ? null : () => _sacnDialog(active)),
          ]),
        ),
      ),
    ]);
  }

  Widget _deviceRow(NetworkDevice d, bool selected, {required bool connected}) {
    final style = selected ? _cellSelected : _cell;
    final known = connected; // Art-Net / sACN / hardware are read once connected
    return GestureDetector(
      onTap: () => _selectDevice(d),
      child: Container(
        height: 44,
        color: selected ? _rowSelected : Colors.transparent,
        padding: const EdgeInsets.only(left: 10, right: 8),
        child: _columns([
          Row(children: [
            const _LpuIcon(),
            const SizedBox(width: 8),
            Flexible(child: Text(d.ipAddress, style: style, overflow: TextOverflow.ellipsis)),
          ]),
          Text(d.displayName == d.ipAddress ? '' : d.displayName, style: style, overflow: TextOverflow.ellipsis),
          Text(d.firmware, style: style),
          Text(known ? d.hardware : '', style: style),
          Text(!known ? '' : d.artNetEnabled ? d.artNetText : '-', style: style),
          Text(!known ? '' : d.sacnEnabled ? '${d.sacnUniverse}' : '-', style: style),
        ]),
      ),
    );
  }

  void _ipDialog(NetworkDevice d) => showDialog(
        context: context,
        builder: (_) => DialogIpDialog(
          dhcp: _m.deviceInfo['dhcp'] != 'false',
          ip: d.ipAddress,
          mask: _m.deviceInfo['subnet'] ?? '255.255.255.0',
          // Written like the reference app (FINDINGS 20.18); the LPU moves to the
          // new address and the app follows it.
          onOk: (dhcp, ip, mask) => _m.setDeviceNetwork(d.ipAddress, dhcp: dhcp, ip: ip, mask: mask),
        ),
      );

  void _renameDevice(NetworkDevice d) => showDialog(
        context: context,
        builder: (_) => NameDialog(
          title: 'DEVICE NAME',
          initial: d.displayName == d.ipAddress ? '' : d.displayName,
          onOk: (name) => setState(() => _m.renameDevice(d.ipAddress, name)),
        ),
      );

  void _artNetDialog(NetworkDevice d) => showDialog(
        context: context,
        builder: (_) => DialogArtNetDialog(
          enabled: d.artNetEnabled,
          raw: d.artNetRaw,
          onOk: (on, raw) => setState(() => _m.setDeviceArtNet(d.ipAddress, on, raw: raw)),
        ),
      );

  void _sacnDialog(NetworkDevice d) => showDialog(
        context: context,
        builder: (_) => DialogSacnDialog(
          enabled: d.sacnEnabled,
          universe: d.sacnUniverse,
          onOk: (on, uni) => setState(() => _m.setDeviceSacn(d.ipAddress, on, universe: uni)),
        ),
      );

  // --- show files -----------------------------------------------------------

  Widget _showsSection() {
    final shows = _m.showFiles;
    final selected = _selectedShow >= 0 && _selectedShow < shows.length ? shows[_selectedShow] : null;
    final folder = _m.showFolder;
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Text('SHOW FILES', style: _head),
          ),
          Expanded(
            child: _Panel(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: shows.length,
                itemBuilder: (_, i) {
                  final s = shows[i];
                  final sel = i == _selectedShow;
                  final style = sel ? _cellSelected : _cell;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedShow = i),
                    child: Container(
                      height: 44,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: sel ? _rowSelected : Colors.transparent,
                        border: const Border(bottom: BorderSide(color: Color(0xFF2A3440))),
                      ),
                      child: Row(children: [
                        Expanded(
                            flex: 5,
                            child: Text(s.name, style: style, overflow: TextOverflow.ellipsis)),
                        Expanded(flex: 3, child: Text(_date(s.savedAt), style: style)),
                        Expanded(flex: 2, child: Text(_size(s.sizeBytes), style: style)),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
        ]),
      ),
      const SizedBox(width: 8),
      Padding(
        padding: const EdgeInsets.only(top: 26),
        child: Column(children: [
          _BtnColumn(children: [
            _OptBtn('NEW', onTap: _newShow),
            _OptBtn('REMOVE', onTap: selected == null ? null : () => _removeShow(selected.name)),
            _OptBtn('RENAME', onTap: selected == null ? null : () => _renameShow(selected.name)),
            _OptBtn('SAVE', onTap: _saveShow),
            _OptBtn('SAVE AS', onTap: _saveShowAs),
            _OptBtn('OPEN', onTap: selected == null ? null : () => _openShow(selected.name)),
          ]),
          const SizedBox(height: 10),
          // Windows: the folder with the .show files. Phone / web: import /
          // export, since there is no folder to open.
          if (folder != null)
            _BtnColumn(children: [
              _OptBtn('FOLDER', icon: Icons.folder_outlined, onTap: folder.reveal),
            ])
          else
            _BtnColumn(children: [
              _OptBtn('IMPORT', icon: Icons.upload_file, onTap: _importShow),
              _OptBtn('EXPORT', icon: Icons.download, onTap: selected == null ? null : () => _exportShow(selected.name)),
            ]),
          const Spacer(),
          const Text('v1.20', style: TextStyle(color: Color(0xFF8A8A8A), fontSize: 14)),
        ]),
      ),
    ]);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _date(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';
  static String _size(int bytes) => bytes < 1024 ? '$bytes bytes' : '${(bytes / 1024).round()} kB';

  void _selectShowNamed(String name) {
    final i = _m.showFiles.indexWhere((s) => s.name == name);
    setState(() => _selectedShow = i);
  }

  /// NEW: an empty "show N" added to the list, no questions (reference app).
  Future<void> _newShow() async {
    final name = await _m.addEmptyShow();
    if (name != null && mounted) _selectShowNamed(name);
  }

  /// SAVE: into the selected show file (else the open show's name), asking
  /// before overwriting.
  Future<void> _saveShow() async {
    final shows = _m.showFiles;
    final target = _selectedShow >= 0 && _selectedShow < shows.length
        ? shows[_selectedShow].name
        : _m.showFileName;
    if (target == 'Untitled') return _saveShowAs();
    await _saveAs(target);
  }

  Future<void> _saveAs(String name) async {
    if (name.isEmpty) return;
    if (_m.showExists(name) && !await dialogConfirm(context, 'Overwrite file?')) return;
    await _m.saveShow(name); // false = 50 shows already
    if (mounted) _selectShowNamed(name);
  }

  void _saveShowAs() => showDialog(
        context: context,
        builder: (_) => NameDialog(
          title: 'SHOWFILE NAME',
          initial: _m.showFileName == 'Untitled' ? _m.nextShowName() : _m.showFileName,
          onOk: _saveAs,
        ),
      );

  Future<void> _removeShow(String name) async {
    if (!await dialogConfirm(context, 'Remove file?')) return;
    await _m.deleteShow(name);
    if (mounted) setState(() => _selectedShow = -1);
  }

  void _renameShow(String oldName) => showDialog(
        context: context,
        builder: (_) => NameDialog(
          title: 'SHOWFILE NAME',
          initial: oldName,
          onOk: (name) async {
            if (name.isEmpty || name == oldName) return;
            await _m.renameShow(oldName, name);
            if (mounted) _selectShowNamed(name);
          },
        ),
      );

  /// OPEN: load the show into the app; connected, also send it to the LPU
  /// (release all, backup, send, verify) with the LOADING window - Abort
  /// puts the LPU's previous show back.
  Future<void> _openShow(String name) async {
    // what the LPU holds now: sent back on Abort
    final before = _m.liveConnected ? await _m.showForLpu() : null;
    await _m.loadShow(name);
    if (!mounted || !_m.liveConnected) return;
    final progress = ValueNotifier(const DialogProgress(0, 'Opening show file...'));
    var abort = false;
    const steps = {
      'releasing all playbacks': 'Releasing all playbacks...',
      'uploading': 'Sending the show to the LPU...',
      'restoring the previous show': 'Aborted: restoring the previous show...',
      'verifying': 'Checking the show on the LPU...',
    };
    var text = progress.value.text;
    unawaited(showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => DialogLoadingDialog(
          progress: progress,
          onAbort: abort ? null : () => setD(() => abort = true),
        ),
      ),
    ));
    await _m.uploadShowToLpu(
      restore: before,
      progress: (step) => progress.value = DialogProgress(progress.value.fraction, text = steps[step] ?? text),
      fraction: (f) => progress.value = DialogProgress(f, text),
      cancelled: () => abort,
    );
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // the LOADING window
    progress.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _importShow() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.first.bytes;
    if (bytes == null) return;
    final parsed = ShowLoader.loadFromBytes(bytes);
    if (!mounted || parsed == null) return; // not a .show file
    // Importing only loads the file into the app; it does not touch the LPU
    // (sending a show to the LPU is OPEN).
    parsed.applyToModel(_m);
    final name = result.files.first.name.replaceAll(RegExp(r'\.show$', caseSensitive: false), '');
    _m.showFileName = name;
    await _m.saveShow(name);
    if (mounted) _selectShowNamed(name);
  }

  // Write the selected saved show as a .show file (same format as the reference app).
  Future<void> _exportShow(String name) async {
    try {
      final content = await _m.savedShowContent(name);
      if (content == null) return;
      final show = showFromModel(
        cuelists: content.cuelists,
        fixtures: content.fixtures,
        device: content.device,
        profiles: await loadPersonalityProfiles(),
      );
      await saveFileAs('$name.show', utf8.encode(writeShow(show)));
    } catch (_) {
      // no message (user's wish); nothing was written
    }
  }
}

// ---------------------------------------------------------------------------
// Parts of the OPTIONS page
// ---------------------------------------------------------------------------

/// The dark navy rounded panel the lists sit in.
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: _panel,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF0E141B)),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );
}

/// Buttons joined in a black rounded column, like the reference app.
class _BtnColumn extends StatelessWidget {
  final List<Widget> children;
  const _BtnColumn({required this.children});

  @override
  Widget build(BuildContext context) => AppButtonGroup(axis: Axis.vertical, children: children);
}

// A button of the side columns: the app's one button, taller (like the reference app).
class _OptBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  const _OptBtn(this.label, {this.onTap, this.icon});

  @override
  Widget build(BuildContext context) => AppButton(label, icon: icon, onTap: onTap, height: 44);
}

/// A small LPU drawn in code (no picture: scales cleanly).
class _LpuIcon extends StatelessWidget {
  const _LpuIcon();

  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(34, 18), painter: _LpuIconPainter());
}

class _LpuIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.drawRRect(
        body,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF29B6F6), Color(0xFF0D5C82)],
          ).createShader(Offset.zero & size));
    final dark = Paint()..color = const Color(0xFF082636);
    for (final x in [0.25, 0.5, 0.75]) {
      canvas.drawCircle(Offset(size.width * x, size.height * 0.55), size.height * 0.16, dark);
    }
  }

  @override
  bool shouldRepaint(_LpuIconPainter old) => false;
}
