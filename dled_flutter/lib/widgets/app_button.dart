// The one button of the app (not in dialogs, which keep DialogButton): the
// PLAYBACK top bar's look, like the reference app - dark gradient face, light grey
// bold label. Lit (a mode waiting, an active tab or option): a lighter face
// and a white label. Pressed: lighter too. Disabled (no onTap): a dim label.
// One size everywhere: [appButtonWidth] x [appButtonHeight], unless the place
// sets another (the OPTIONS side columns are taller).

import 'package:flutter/material.dart';

import 'dled_logo.dart';

const double appButtonHeight = 34;
const double appButtonWidth = 80;

class AppButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool lit;
  final double? width;
  final double height;

  /// An outline colour instead of the normal one (EDIT: red FX buttons when
  /// the loaded cue has that FX, like the reference app).
  final Color? outline;
  const AppButton(this.label,
      {super.key,
      this.icon,
      this.onTap,
      this.onLongPress,
      this.lit = false,
      this.width = appButtonWidth,
      this.height = appButtonHeight,
      this.outline});

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _pressed = false;

  void _press(bool down) {
    if (_pressed != down) setState(() => _pressed = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final lit = enabled && widget.lit;
    final colour = !enabled
        ? const Color(0xFF454547) // clearly off
        : lit
            ? Colors.white
            : const Color(0xFFB4B4B4);
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown: enabled ? (_) => _press(true) : null,
      onTapUp: enabled ? (_) => _press(false) : null,
      onTapCancel: enabled ? () => _press(false) : null,
      child: Container(
        width: widget.width,
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: lit
                ? const [Color(0xFF52575F), Color(0xFF34383F)]
                : _pressed
                    ? const [Color(0xFF444444), Color(0xFF2E2E2E)]
                    : const [Color(0xFF2C2C2C), Color(0xFF1C1C1C)],
          ),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: widget.outline ?? (lit ? const Color(0xFF7A8696) : const Color(0xFF3A3A3A)),
              width: widget.outline != null ? 1.5 : 1),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.icon != null) Icon(widget.icon, color: colour, size: 18),
            if (widget.icon != null && widget.label.isNotEmpty) const SizedBox(width: 4),
            if (widget.label.isNotEmpty)
              Text(widget.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colour, fontSize: 12, fontWeight: FontWeight.bold, height: 1.1)),
          ]),
        ),
      ),
    );
  }
}

/// Buttons joined in one black-rimmed block with thin gaps, like the reference app.
class AppButtonGroup extends StatelessWidget {
  final Axis axis;
  final List<Widget> children;
  const AppButtonGroup({super.key, this.axis = Axis.horizontal, required this.children});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(6)),
        child: Flex(
          direction: axis,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: 1, height: 1),
              children[i],
            ],
          ],
        ),
      );
}

/// The top bar of every page: [left] buttons, the connection LED (green =
/// connected to an LPU, red = not), the logo, and [right] buttons. Always the
/// same size; a window too narrow for it shrinks the whole bar evenly.
class AppTopBar extends StatelessWidget {
  final List<Widget> left;
  final List<Widget> right;
  final bool connected;
  const AppTopBar({super.key, required this.left, this.right = const [], required this.connected});

  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    final led = connected ? const Color(0xFF44FF44) : const Color(0xFFFF3B3B);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) => FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: box.maxWidth < 760 ? 760 : box.maxWidth,
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                if (left.isNotEmpty) AppButtonGroup(children: left),
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: led,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: led.withValues(alpha: 0.67), blurRadius: 6)],
                  ),
                ),
                // DLED's logo, like the light page
                const DledLogo(),
                const Spacer(),
                if (right.isNotEmpty) AppButtonGroup(children: right),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
