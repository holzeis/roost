import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../widgets/avatar.dart';

class ChatScreen extends StatelessWidget {
  const ChatScreen({super.key, required this.roomId, this.room});

  final String roomId;
  final RoomSummary? room;

  @override
  Widget build(BuildContext context) {
    final title = room?.name ?? roomId;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            InitialAvatar(initial: room?.initial ?? '?', size: 26),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                  if (room?.isGroup ?? false)
                    Text('4 members', style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/chat/$roomId/search'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => context.push('/call/$roomId'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final message in MockData.familyMessages) _MessageRow(message: message),
              ],
            ),
          ),
          const _MessageComposer(),
        ],
      ),
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final align = message.fromMe ? MainAxisAlignment.end : MainAxisAlignment.start;

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: message.fromMe ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(8),
          topRight: const Radius.circular(8),
          bottomLeft: Radius.circular(message.fromMe ? 8 : 2),
          bottomRight: Radius.circular(message.fromMe ? 2 : 8),
        ),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            fontSize: 13,
            color: message.fromMe ? scheme.onPrimary : scheme.onSurface,
          ),
          children: [
            TextSpan(text: message.kind == MessageKind.location ? 'Shared their location' : (message.body ?? '')),
            TextSpan(
              text: '  ${message.timeLabel}',
              style: TextStyle(fontSize: 10, color: (message.fromMe ? scheme.onPrimary : scheme.onSurface).withOpacity(0.6)),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: align,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: message.fromMe
            ? [bubble]
            : [
                InitialAvatar(initial: message.senderName.substring(0, 1), size: 20),
                const SizedBox(width: 6),
                bubble,
              ],
      ),
    );
  }
}

class _MessageComposer extends StatelessWidget {
  const _MessageComposer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () {}),
          const Expanded(
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Message',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.send, color: Theme.of(context).colorScheme.primary),
            onPressed: () {},
          ),
        ],
      ),
    );
  }
}
