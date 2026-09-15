import 'package:flutter/material.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

/// AppBar back button using the Tabler icon set (matching
/// docs/mockups/roost-mockups-utility-dense.html's `ti-chevron-left`)
/// instead of Flutter's default Material back arrow, so every screen's
/// chrome agrees on one icon style.
class TablerBackButton extends StatelessWidget {
  const TablerBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(TablerIcons.chevronLeft),
      onPressed: () => Navigator.of(context).maybePop(),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
    );
  }
}
