import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';

/// The inline content of a call message bubble (FR4.8): an icon + label
/// reflecting the call's outcome (missed/declined/completed, with a
/// duration once it's over) or "Ringing…" while still active. Tapping a
/// finished call starts a new one (FR4.1/FR4.2); tapping a still-ringing
/// one joins it, the same way accepting from the incoming-call screen does.
class CallBubbleContent extends ConsumerWidget {
  const CallBubbleContent({super.key, required this.message, required this.roomId, required this.isGroup, required this.textColor});

  final ApiMessage message;
  final String roomId;
  final bool isGroup;
  final Color textColor;

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    final call = message.call;
    try {
      if (call != null && call.status == 'ringing') {
        await ref.read(apiClientProvider).acceptCall(call.id);
        ref.read(incomingCallProvider.notifier).dismiss();
        if (context.mounted) {
          context.push('/call/$roomId?messageId=${message.id}&group=$isGroup');
        }
      } else {
        final started = await ref.read(apiClientProvider).startCall(roomId);
        if (context.mounted) {
          context.push('/call/$roomId?messageId=${started.id}&group=$isGroup');
        }
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join call: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final call = message.call;
    final status = call?.status ?? 'ringing';
    final IconData icon;
    final String label;
    switch (status) {
      case 'missed':
        icon = TablerIcons.phoneX;
        label = 'Missed call';
      case 'declined':
        icon = TablerIcons.phoneX;
        label = 'Declined';
      case 'completed':
        icon = TablerIcons.phoneCall;
        label = _durationLabel(call);
      default:
        icon = TablerIcons.phone;
        label = 'Ringing…';
    }

    return InkWell(
      onTap: () => _join(context, ref),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: textColor),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 13.5, color: textColor)),
        ],
      ),
    );
  }

  String _durationLabel(ApiCall? call) {
    final d = call?.duration;
    if (d == null) return 'Call ended';
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
