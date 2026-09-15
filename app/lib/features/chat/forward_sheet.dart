import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

/// Room-picker bottom sheet for forwarding a message (FR1.11). Returns
/// without doing anything if the user backs out.
Future<void> showForwardSheet(
    BuildContext context, WidgetRef ref, ApiMessage message) async {
  final rooms = ref.read(roomsProvider).valueOrNull ?? const <ApiRoom>[];
  final meId = ref.read(meProvider).valueOrNull?.id;
  final usersById = ref.read(usersByIdProvider).valueOrNull ?? const {};

  final targetRoomId = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Forward to…',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700))),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: rooms.length,
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  var title = room.name ?? '';
                  if (title.isEmpty) {
                    final otherId = room.members
                        .firstWhere((id) => id != meId, orElse: () => '');
                    title = usersById[otherId]?.displayName ?? 'Direct message';
                  }
                  return ListTile(
                    leading: InitialAvatar(
                        initial:
                            title.isNotEmpty ? title[0].toUpperCase() : '?',
                        seed: title,
                        size: 34),
                    title: Text(title),
                    onTap: () => Navigator.of(sheetContext).pop(room.id),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );

  if (targetRoomId == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(messagesProvider(message.roomId).notifier)
        .forwardMessage(message.id, targetRoomId);
    messenger.showSnackBar(const SnackBar(content: Text('Message forwarded')));
  } catch (error) {
    messenger
        .showSnackBar(SnackBar(content: Text('Could not forward: $error')));
  }
}
