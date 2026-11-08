// The app is laid out for a 768 wide screen (the reference app's Windows window).
// On a narrower screen (a phone) it is scaled down to the screen's width, the
// same as the reference app does: the layout stays, the pages get the
// screen's full height (taller tiles and panels on a tall phone). Wider
// screens are used as they are.

import 'package:flutter/material.dart';

import 'app_theme.dart';

class DesignScale extends StatelessWidget {
  static const double designWidth = 768;
  final Widget child;
  const DesignScale({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    if (w >= designWidth || w <= 0) return child;
    final scale = w / designWidth;
    final size = Size(designWidth, mq.size.height / scale);
    return ColoredBox(
      color: AppColors.background, // behind the status bar
      child: FittedBox(
        fit: BoxFit.fitWidth,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: size,
          child: MediaQuery(
            data: mq.copyWith(
              size: size,
              padding: mq.padding / scale,
              viewPadding: mq.viewPadding / scale,
              viewInsets: mq.viewInsets / scale,
            ),
            // Keep clear of the status bar / gesture bar, like the reference app.
            child: SafeArea(child: child),
          ),
        ),
      ),
    );
  }
}
