import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';

/// The inline content of a call message bubble (FR4.8): an icon + label
/// reflecting the call's outcome (missed/declined/completed, with a
/// duration once it's over) or "Ringing…" while still active. Tapping any
/// call message — finished, missed, or still ringing — asks for
/// confirmation first via a bottom sheet rather than joining or starting a
/// call immediately, since that's a heavier action than any other tap in
/// the chat and shouldn't be one accidental tap away.
class CallBubbleContent extends ConsumerWidget {
  const CallBubbleContent({super.key, required this.message, required this.roomId, required this.isGroup, required this.textColor});

  final ApiMessage message;
  final String roomId;
  final bool isGroup;
  final Color textColor;

  void _confirm(BuildContext context, WidgetRef ref, String label) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(TablerIcons.phone, size: 18),
                      label: const Text('Call'),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _join(context, ref);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

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
    final String confirmLabel;
    switch (status) {
      case 'missed':
        icon = TablerIcons.phoneX;
        label = 'Missed call';
        confirmLabel = 'Call back?';
      case 'declined':
        icon = TablerIcons.phoneX;
        label = 'Declined';
        confirmLabel = 'Call back?';
      case 'completed':
        icon = TablerIcons.phoneCall;
        label = _durationLabel(call);
        confirmLabel = 'Start a new call?';
      default:
        icon = TablerIcons.phone;
        label = 'Ringing…';
        confirmLabel = 'Join this call?';
    }

    return InkWell(
      onTap: () => _confirm(context, ref, confirmLabel),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: textColor),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 16.5, height: 1.3, color: textColor)),
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
