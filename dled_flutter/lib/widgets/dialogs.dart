// The app's dialogs: a title strip on the left with the title turned upright - grey, or yellow
// for a question ("ARE YOU SURE?") and while loading - on a dark panel with
// light rounded outlines. Shared by all screens.

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

const dialogStripGrey = Color(0xFF8A8A8A);
const dialogStripYellow = Color(0xFFA6A60D);
const _panel = Color(0xFF202020);
const dialogLine = Color(0xFF8C8C8C);
const dialogText = TextStyle(color: Color(0xFFE0E0E0), fontSize: 14);
const _label = TextStyle(color: Color(0xFFD0D0D0), fontSize: 14);

class DialogPanel extends StatelessWidget {
  final String title;
  final Color strip;
  final Widget child;
  final EdgeInsetsGeometry padding;
  const DialogPanel(
      {super.key,
      required this.title,
      required this.child,
      this.strip = dialogStripGrey,
      this.padding = const EdgeInsets.fromLTRB(20, 18, 16, 14)});

  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Container(
          decoration: BoxDecoration(
            color: _panel,
            border: Border.all(color: const Color(0xFF505050)),
            borderRadius: BorderRadius.circular(8),
          ),
          clipBehavior: Clip.antiAlias,
          child: IntrinsicHeight(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 44,
                  color: strip,
                  alignment: Alignment.center,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Text(title,
                        style: const TextStyle(color: Color(0xFF2A2A2A), fontSize: 16, letterSpacing: 1)),
                  ),
                ),
                Padding(padding: padding, child: child),
              ],
            ),
          ),
        ),
      );
}

class DialogButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final double width;
  final double height;
  final Color line;
  final Widget? icon;
  const DialogButton(this.label,
      {super.key, required this.onTap, this.width = 96, this.height = 40, this.line = dialogLine, this.icon});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _panel,
            border: Border.all(color: onTap == null ? const Color(0xFF444444) : line),
            borderRadius: BorderRadius.circular(6),
          ),
          child: icon ??
              Text(label, style: onTap == null ? dialogText.copyWith(color: const Color(0xFF666666)) : dialogText),
        ),
      );
}

class DialogCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const DialogCheckbox({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => onChanged(!value),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            border: Border.all(color: dialogLine),
            borderRadius: BorderRadius.circular(6),
          ),
          child: value ? const Icon(Icons.check, color: Color(0xFFE0E0E0), size: 24) : null,
        ),
      );
}

class DialogSegments extends StatelessWidget {
  final List<String> options;
  final int selected;
  final ValueChanged<int> onChanged;
  final double segmentWidth;
  const DialogSegments(
      {super.key, required this.options, required this.selected, required this.onChanged, this.segmentWidth = 86});

  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        decoration: BoxDecoration(
          border: Border.all(color: dialogLine),
          borderRadius: BorderRadius.circular(6),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < options.length; i++)
              GestureDetector(
                onTap: () => onChanged(i),
                child: Container(
                  width: segmentWidth,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == selected ? dialogStripGrey : Colors.transparent,
                    border: i == 0 ? null : const Border(left: BorderSide(color: dialogLine)),
                  ),
                  child: Text(options[i], style: dialogText),
                ),
              ),
          ],
        ),
      );
}

/// A label right-aligned in front of its control, like the reference app.
Widget dialogRow(String label, Widget control, {double labelWidth = 104}) => Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: labelWidth, child: Text(label, textAlign: TextAlign.right, softWrap: false, style: _label)),
      const SizedBox(width: 12),
      control,
    ]);

/// A text field (rounded outline).
class DialogField extends StatelessWidget {
  final TextEditingController controller;
  final double width;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final TextInputType? keyboard;
  final bool enabled;
  const DialogField(
      {super.key,
      required this.controller,
      this.width = 200,
      this.autofocus = false,
      this.onSubmitted,
      this.keyboard,
      this.enabled = true});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1C1C),
          border: Border.all(color: dialogLine),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.centerLeft,
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          enabled: enabled,
          keyboardType: keyboard,
          style: dialogText,
          cursorColor: const Color(0xFFE0E0E0),
          decoration:
              const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
          onSubmitted: onSubmitted,
        ),
      );
}

// ---------------------------------------------------------------------------
// Name: RENAME PLAYBACK, DEVICE NAME, SHOWFILE NAME - the name preselected,
// X clears it, Ok saves (also Enter), Cancel closes.
// ---------------------------------------------------------------------------

class NameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final ValueChanged<String> onOk;

  /// What X puts in the field: the default (a cue's number, "0s").
  final String clearTo;
  const NameDialog(
      {super.key, required this.title, required this.initial, required this.onOk, this.clearTo = ''});

  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final TextEditingController _ctrl = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _ok() {
    Navigator.pop(context);
    widget.onOk(_ctrl.text.trim());
  }

  @override
  Widget build(BuildContext context) => DialogPanel(
        title: widget.title,
        child: SizedBox(
          width: 290,
          height: 210,
          child: Column(
            children: [
              const Spacer(),
              Row(children: [
                Expanded(child: DialogField(controller: _ctrl, autofocus: true, onSubmitted: (_) => _ok())),
                const SizedBox(width: 8),
                DialogButton('X', width: 36, height: 36, onTap: () => _ctrl.text = widget.clearTo),
              ]),
              const Spacer(),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                DialogButton('Ok', onTap: _ok),
                const SizedBox(width: 8),
                DialogButton('Cancel', onTap: () => Navigator.pop(context)),
              ]),
            ],
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// ARE YOU SURE? - e.g. "Overwrite file?", "Remove file?". Pops true on Ok.
// ---------------------------------------------------------------------------

Future<bool> dialogConfirm(BuildContext context, String question) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogPanel(
        title: 'ARE YOU SURE?',
        strip: dialogStripYellow,
        child: SizedBox(
          width: 300,
          height: 170,
          child: Column(children: [
            const Spacer(),
            Text(question, style: const TextStyle(color: Color(0xFFC8C8C8), fontSize: 14)),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              DialogButton('Ok', line: dialogStripYellow, onTap: () => Navigator.pop(ctx, true)),
              const SizedBox(width: 8),
              DialogButton('Cancel', line: dialogStripYellow, onTap: () => Navigator.pop(ctx, false)),
            ]),
          ]),
        ),
      ),
    ) ==
    true;

// ---------------------------------------------------------------------------
// LOADING... - a progress bar, what is being done, and Abort.
// ---------------------------------------------------------------------------

class DialogProgress {
  final double fraction; // 0..1
  final String text;
  const DialogProgress(this.fraction, this.text);
}

class DialogLoadingDialog extends StatelessWidget {
  final ValueListenable<DialogProgress> progress;
  final VoidCallback? onAbort;
  const DialogLoadingDialog({super.key, required this.progress, this.onAbort});

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false, // closed by the caller when the work is done
        child: DialogPanel(
          title: 'LOADING...',
          strip: dialogStripYellow,
          child: SizedBox(
            width: 300,
            height: 170,
            child: ValueListenableBuilder<DialogProgress>(
              valueListenable: progress,
              builder: (_, p, __) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Text('PROGRESS', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFFC8C8C8), fontSize: 13)),
                const SizedBox(height: 6),
                Container(
                  height: 36,
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    border: Border.all(color: dialogLine),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: p.fraction.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                            color: const Color(0xFF898989), borderRadius: BorderRadius.circular(3)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(p.text, style: const TextStyle(color: Color(0xFFC8C8C8), fontSize: 13)),
                const Spacer(),
                Align(alignment: Alignment.centerRight, child: DialogButton('Abort', onTap: onAbort)),
              ]),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Up / down arrow buttons (ART-NET, sACN).
// ---------------------------------------------------------------------------

class _ArrowButton extends StatelessWidget {
  final bool up;
  final double width;
  final VoidCallback onTap;
  const _ArrowButton({required this.up, required this.width, required this.onTap});

  @override
  Widget build(BuildContext context) => DialogButton('',
      width: width,
      height: 40,
      onTap: onTap,
      // a white triangle drawn in code
      icon: CustomPaint(size: const Size(36, 18), painter: _TrianglePainter(up)));
}

class _TrianglePainter extends CustomPainter {
  final bool up;
  const _TrianglePainter(this.up);

  @override
  void paint(Canvas canvas, Size size) {
    final path = up
        ? (Path()
          ..moveTo(size.width / 2, 0)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height))
        : (Path()
          ..moveTo(0, 0)
          ..lineTo(size.width, 0)
          ..lineTo(size.width / 2, size.height));
    canvas.drawPath(path..close(), Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.up != up;
}

/// ART-NET: Enabled, and the "sub.uni" (subnet.universe, each 0-15) with an up
/// / down pair for each. [raw] = subnet x 16 + universe, as the LPU stores it.
class DialogArtNetDialog extends StatefulWidget {
  final bool enabled;
  final int raw;
  final void Function(bool enabled, int raw) onOk;
  const DialogArtNetDialog({super.key, required this.enabled, required this.raw, required this.onOk});

  @override
  State<DialogArtNetDialog> createState() => _DialogArtNetDialogState();
}

class _DialogArtNetDialogState extends State<DialogArtNetDialog> {
  late bool _on = widget.enabled;
  late int _sub = (widget.raw ~/ 16) % 16, _uni = widget.raw % 16;

  @override
  Widget build(BuildContext context) {
    const w = 96.0;
    Widget arrows(bool up) => Row(mainAxisSize: MainAxisSize.min, children: [
          _ArrowButton(up: up, width: w, onTap: () => setState(() => _sub = (_sub + (up ? 1 : 15)) % 16)),
          const SizedBox(width: 8),
          _ArrowButton(up: up, width: w, onTap: () => setState(() => _uni = (_uni + (up ? 1 : 15)) % 16)),
        ]);
    return DialogPanel(
      title: 'ART-NET',
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        dialogRow('Enabled', DialogCheckbox(value: _on, onChanged: (v) => setState(() => _on = v)), labelWidth: 64),
        const SizedBox(height: 8),
        Padding(padding: const EdgeInsets.only(left: 76), child: arrows(true)),
        const SizedBox(height: 8),
        dialogRow(
            'sub.uni',
            Container(
              width: w * 2 + 8,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(border: Border.all(color: dialogLine), borderRadius: BorderRadius.circular(6)),
              child: Text('$_sub.$_uni', style: dialogText.copyWith(fontSize: 18)),
            ),
            labelWidth: 64),
        const SizedBox(height: 8),
        Padding(padding: const EdgeInsets.only(left: 76), child: arrows(false)),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 76),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            DialogButton('Ok', width: w, onTap: () {
              Navigator.pop(context);
              widget.onOk(_on, _sub * 16 + _uni);
            }),
            const SizedBox(width: 8),
            DialogButton('Cancel', width: w, onTap: () => Navigator.pop(context)),
          ]),
        ),
      ]),
    );
  }
}

/// sACN: Enabled, and the universe (1-63999) with one up / down pair.
class DialogSacnDialog extends StatefulWidget {
  final bool enabled;
  final int universe;
  final void Function(bool enabled, int universe) onOk;
  const DialogSacnDialog({super.key, required this.enabled, required this.universe, required this.onOk});

  @override
  State<DialogSacnDialog> createState() => _DialogSacnDialogState();
}

class _DialogSacnDialogState extends State<DialogSacnDialog> {
  late bool _on = widget.enabled;
  late int _uni = widget.universe.clamp(1, 63999);

  @override
  Widget build(BuildContext context) {
    const w = 200.0;
    return DialogPanel(
      title: 'SACN',
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        dialogRow('Enabled', DialogCheckbox(value: _on, onChanged: (v) => setState(() => _on = v)), labelWidth: 64),
        const SizedBox(height: 8),
        Padding(
            padding: const EdgeInsets.only(left: 76),
            child: _ArrowButton(up: true, width: w, onTap: () => setState(() => _uni = _uni >= 63999 ? 1 : _uni + 1))),
        const SizedBox(height: 8),
        dialogRow(
            'sub.uni',
            Container(
              width: w,
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(border: Border.all(color: dialogLine), borderRadius: BorderRadius.circular(6)),
              child: Text('$_uni', style: dialogText.copyWith(fontSize: 18)),
            ),
            labelWidth: 64),
        const SizedBox(height: 8),
        Padding(
            padding: const EdgeInsets.only(left: 76),
            child: _ArrowButton(up: false, width: w, onTap: () => setState(() => _uni = _uni <= 1 ? 63999 : _uni - 1))),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 76),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            DialogButton('Ok', onTap: () {
              Navigator.pop(context);
              widget.onOk(_on, _uni);
            }),
            const SizedBox(width: 8),
            DialogButton('Cancel', onTap: () => Navigator.pop(context)),
          ]),
        ),
      ]),
    );
  }
}

/// SET IP ADDRESS: DHCP / Static, IP address and subnet mask. Shows the LPU's
/// values; [onOk] is null while the way to write them is not captured from
/// the reference app yet (then Ok only closes).
class DialogIpDialog extends StatefulWidget {
  final bool dhcp;
  final String ip;
  final String mask;
  final void Function(bool dhcp, String ip, String mask)? onOk;
  const DialogIpDialog({super.key, required this.dhcp, required this.ip, required this.mask, this.onOk});

  @override
  State<DialogIpDialog> createState() => _DialogIpDialogState();
}

class _DialogIpDialogState extends State<DialogIpDialog> {
  late bool _dhcp = widget.dhcp;
  late final _ip = TextEditingController(text: widget.ip);
  late final _mask = TextEditingController(text: widget.mask);

  @override
  void dispose() {
    _ip.dispose();
    _mask.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DialogPanel(
        title: 'SET IP ADDRESS',
        child: SizedBox(
          width: 310,
          height: 220,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            DialogSegments(
                options: const ['DHCP', 'Static'],
                selected: _dhcp ? 0 : 1,
                segmentWidth: 84,
                onChanged: (i) => setState(() => _dhcp = i == 0)),
            const SizedBox(height: 12),
            dialogRow('IP Address', DialogField(controller: _ip, width: 180, enabled: !_dhcp), labelWidth: 100),
            const SizedBox(height: 10),
            dialogRow('Subnet mask', DialogField(controller: _mask, width: 180, enabled: !_dhcp), labelWidth: 100),
            const Spacer(),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              DialogButton('Ok', onTap: () {
                Navigator.pop(context);
                widget.onOk?.call(_dhcp, _ip.text.trim(), _mask.text.trim());
              }),
              const SizedBox(width: 8),
              DialogButton('Cancel', onTap: () => Navigator.pop(context)),
            ]),
          ]),
        ),
      );
}

// ---------------------------------------------------------------------------
// FX dialog fader (Size / Speed / Phase), like the reference app: a rounded box
// with its name, a column of grey segments with a white window at the value,
// and the value below. Drag or tap to set it.
// ---------------------------------------------------------------------------

class WindowFader extends StatelessWidget {
  final String label;
  final double value, min, max;
  final ValueChanged<double> onChanged;
  const WindowFader(
      {super.key, required this.label, required this.value, this.min = 0, required this.max, required this.onChanged});

  static const _top = 20.0, _bottom = 26.0;

  void _set(Offset local, double height) {
    final f = 1 - (local.dy - _top - 4) / (height - _top - _bottom - 8);
    onChanged((min + f.clamp(0.0, 1.0) * (max - min)).roundToDouble());
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) => GestureDetector(
          onPanDown: (d) => _set(d.localPosition, box.maxHeight),
          onPanUpdate: (d) => _set(d.localPosition, box.maxHeight),
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: dialogLine),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(children: [
              SizedBox(
                height: _top,
                child: Center(child: Text(label, style: const TextStyle(color: Color(0xFFC8C8C8), fontSize: 10))),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
                  child: CustomPaint(size: Size.infinite, painter: _WindowPainter((value - min) / (max - min), value != 0, fromMiddle: min < 0)),
                ),
              ),
              SizedBox(
                height: _bottom,
                child: Center(
                  child: Text('${value.round()}', style: const TextStyle(color: Color(0xFFC8C8C8), fontSize: 10)),
                ),
              ),
            ]),
          ),
        ),
      );
}

class _WindowPainter extends CustomPainter {
  final double fraction;
  final bool filled; // the reference app fills nothing at 0 (Speed 0 is mid-way)
  final bool fromMiddle; // Speed (-100..100): filled from 0 in the middle
  const _WindowPainter(this.fraction, this.filled, {this.fromMiddle = false});

  @override
  void paint(Canvas canvas, Size size) {
    const seg = 4.0, gap = 2.0, inset = 6.0;
    final n = ((size.height + gap) / (seg + gap)).floor();
    // the window: about 5 segments tall, centred on the value; when not 0
    // the segments from the bottom (Speed: from the middle) up to and
    // including the window are white, the rest grey (like the reference app)
    const h = 5 * (seg + gap) + 4;
    final cy = h / 2 + (1 - fraction.clamp(0.0, 1.0)) * (size.height - h);
    final grey = Paint()..color = const Color(0xFF5A5A5A);
    final white = Paint()..color = const Color(0xFFE8E8E8);
    for (var i = 0; i < n; i++) {
      final y = size.height - (i + 1) * seg - i * gap;
      final mid = y + seg / 2;
      final lit = !filled
          ? false
          : !fromMiddle
              ? mid > cy - h / 2
              : cy < size.height / 2
                  ? mid > cy - h / 2 && mid < size.height / 2 // up from the middle
                  : mid < cy + h / 2 && mid > size.height / 2; // down from the middle
      canvas.drawRect(Rect.fromLTWH(inset, y, size.width - 2 * inset, seg), lit ? white : grey);
    }
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(size.width / 2, cy), width: size.width, height: h),
            const Radius.circular(6)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white);
  }

  @override
  bool shouldRepaint(_WindowPainter old) =>
      old.fraction != fraction || old.filled != filled || old.fromMiddle != fromMiddle;
}
