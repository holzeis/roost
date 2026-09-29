import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'demo_mode.dart';

/// Shown instead of a call in demo mode.
const demoCallNotice =
    "Video calls need your family's private network and a second device, so they aren't available in the demo.";

/// In demo mode, explains why calling isn't available and returns true — the
/// caller then skips the call. Returns false (showing nothing) otherwise.
Future<bool> showDemoCallNoticeIfDemo(BuildContext context, WidgetRef ref) async {
  if (!ref.read(demoModeProvider).enabled) return false;
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(TablerIcons.video, size: 32),
            const SizedBox(height: 12),
            const Text(demoCallNotice, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      ),
    ),
  );
  return true;
}
