// The one look of the app's pages: a grey page, navy
// panels / lists / tiles, one plain font (the theme's DejaVu Sans). Dialogs
// have their own look (dialogs.dart).

import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF2B2B2F); // every page
  static const panel = Color(0xFF151D26); // lists, tiles, panels
  static const panelLine = Color(0xFF3A3F48);
  static const header = Color(0xFF9A9A9A); // DEVICES, FIXTURES, CUES ...
  static const text = Color(0xFFD8D8D8);
}

/// A section title above a panel (DEVICES, SHOW FILES, FIXTURES, CUES).
const appHeader = TextStyle(color: AppColors.header, fontSize: 15);

/// A navy panel with a thin line (lists).
class AppPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AppPanel({super.key, required this.child, this.padding = const EdgeInsets.all(8)});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: AppColors.panel,
          border: Border.all(color: AppColors.panelLine),
          borderRadius: BorderRadius.circular(4),
        ),
        child: child,
      );
}
