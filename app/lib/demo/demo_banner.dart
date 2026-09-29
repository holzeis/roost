import 'package:flutter/material.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../theme/app_theme.dart';

/// The label shown above every screen in demo mode.
const demoBannerText = 'Demo · sample data on this phone only';

/// A slim strip above the whole app while in demo mode, so it's always
/// clear the chats on screen aren't real. Takes over the top safe-area
/// inset itself, so the screens below lay out as if the strip were the
/// status bar.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final background = brightness == Brightness.dark ? RoostColors.darkAccent : RoostColors.lightAccent;
    final foreground = brightness == Brightness.dark ? RoostColors.darkOnAccent : RoostColors.lightOnAccent;
    return Column(
      children: [
        Material(
          color: background,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(TablerIcons.flask, size: 14, color: foreground),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      demoBannerText,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: foreground, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(context: context, removeTop: true, child: child),
        ),
      ],
    );
  }
}
