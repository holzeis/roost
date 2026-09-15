import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'call_controls.dart';

/// The native CallKit/ConnectionService screen (FR4.4) is provided by the
/// OS, triggered by the push wake-up described in
/// docs/architecture-overview.md's call flow; this in-app screen is the
/// fallback shown when the call invite arrives while the app is already in
/// the foreground over the WebSocket, and reuses the same accept/decline
/// affordances (FR4.5).
class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({super.key, required this.roomId, required this.callerName});

  final String roomId;
  final String callerName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CallColors.background,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 56),
              child: Column(
                children: [
                  const Text('Incoming video call', style: TextStyle(color: CallColors.textSecondary, fontSize: 11)),
                  const SizedBox(height: 14),
                  Container(
                    width: 76,
                    height: 76,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: CallColors.controlButton, shape: BoxShape.circle),
                    child: Text(
                      callerName.isNotEmpty ? callerName[0] : '?',
                      style: const TextStyle(color: CallColors.textSecondary, fontSize: 26),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(callerName, style: const TextStyle(color: CallColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  const Text('Roost · calling…', style: TextStyle(color: CallColors.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Column(
                    children: [
                      CallControlButton(
                        icon: TablerIcons.phoneX,
                        background: CallColors.danger,
                        iconColor: Colors.white,
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(height: 6),
                      const Text('Decline', style: TextStyle(color: CallColors.textSecondary, fontSize: 10)),
                    ],
                  ),
                  const SizedBox(width: 48),
                  Column(
                    children: [
                      CallControlButton(
                        icon: TablerIcons.phone,
                        background: CallColors.accept,
                        iconColor: Colors.white,
                        onPressed: () => context.pushReplacement('/call/$roomId'),
                      ),
                      const SizedBox(height: 6),
                      const Text('Accept', style: TextStyle(color: CallColors.textSecondary, fontSize: 10)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
