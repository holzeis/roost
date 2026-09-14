import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.roomId, this.room});

  final String roomId;
  final ApiRoom? room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final usersById = ref.watch(usersByIdProvider);
    final roomAsync = room != null ? AsyncData<ApiRoom>(room!) : ref.watch(_roomProvider(roomId));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _ChatTitle(roomAsync: roomAsync, me: me, usersById: usersById),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/chat/$roomId/search'),
          ),
          IconButton(
            icon: const Icon(Icons.videocam_outlined),
            onPressed: () => context.push('/call/$roomId?group=${room?.isGroup ?? false}'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: me.hasValue
                ? _MessageList(roomId: roomId, meId: me.value!.id, usersById: usersById.valueOrNull ?? const {})
                : const Center(child: CircularProgressIndicator()),
          ),
          _MessageComposer(roomId: roomId),
        ],
      ),
    );
  }
}

final _roomProvider = FutureProvider.family<ApiRoom, String>(
  (ref, roomId) => ref.watch(apiClientProvider).getRoom(roomId),
);

class _ChatTitle extends StatelessWidget {
  const _ChatTitle({required this.roomAsync, required this.me, required this.usersById});

  final AsyncValue<ApiRoom> roomAsync;
  final AsyncValue<ApiUser> me;
  final AsyncValue<Map<String, ApiContact>> usersById;

  @override
  Widget build(BuildContext context) {
    final room = roomAsync.valueOrNull;
    if (room == null) return const SizedBox.shrink();

    String title = room.name ?? '';
    if (title.isEmpty) {
      final meId = me.valueOrNull?.id;
      final otherId = room.members.firstWhere((id) => id != meId, orElse: () => '');
      title = usersById.valueOrNull?[otherId]?.displayName ?? 'Direct message';
    }

    return Row(
      children: [
        InitialAvatar(initial: title.isNotEmpty ? title[0].toUpperCase() : '?', size: 26),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              if (room.isGroup)
                Text('${room.members.length} members', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({required this.roomId, required this.meId, required this.usersById});

  final String roomId;
  final String meId;
  final Map<String, ApiContact> usersById;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(messagesProvider(roomId));

    return messages.when(
      error: (error, _) => Center(child: Text('Could not load messages.\n$error')),
      loading: () => const Center(child: CircularProgressIndicator()),
      data: (messages) {
        if (messages.isEmpty) {
          return const Center(child: Text('No messages yet. Say hello!'));
        }
        final reversed = messages.reversed.toList();
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.all(12),
          itemCount: reversed.length,
          itemBuilder: (context, index) {
            final message = reversed[index];
            final senderName = message.senderId == meId
                ? 'Me'
                : (usersById[message.senderId]?.displayName ?? '?');
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _MessageRow(message: message, fromMe: message.senderId == meId, senderName: senderName),
            );
          },
        );
      },
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.message, required this.fromMe, required this.senderName});

  final ApiMessage message;
  final bool fromMe;
  final String senderName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final align = fromMe ? MainAxisAlignment.end : MainAxisAlignment.start;
    final timeLabel = TimeOfDay.fromDateTime(message.createdAt.toLocal()).format(context);

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: fromMe ? scheme.primary : scheme.surface,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(8),
          topRight: const Radius.circular(8),
          bottomLeft: Radius.circular(fromMe ? 8 : 2),
          bottomRight: Radius.circular(fromMe ? 2 : 8),
        ),
      ),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 13, color: fromMe ? scheme.onPrimary : scheme.onSurface),
          children: [
            TextSpan(text: message.kind == 'location' ? 'Shared their location' : (message.body ?? '')),
            TextSpan(
              text: '  $timeLabel',
              style: TextStyle(fontSize: 10, color: (fromMe ? scheme.onPrimary : scheme.onSurface).withOpacity(0.6)),
            ),
          ],
        ),
      ),
    );

    return Row(
      mainAxisAlignment: align,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: fromMe
          ? [bubble]
          : [
              InitialAvatar(initial: senderName.isNotEmpty ? senderName[0].toUpperCase() : '?', size: 20),
              const SizedBox(width: 6),
              bubble,
            ],
    );
  }
}

class _MessageComposer extends ConsumerStatefulWidget {
  const _MessageComposer({required this.roomId});
  final String roomId;

  @override
  ConsumerState<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends ConsumerState<_MessageComposer> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();
    try {
      await ref.read(messagesProvider(widget.roomId).notifier).send(text);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

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
          Expanded(
            child: TextField(
              controller: _controller,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: 'Message',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ),
          IconButton(
            icon: _sending
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(Icons.send, color: Theme.of(context).colorScheme.primary),
            onPressed: _send,
          ),
        ],
      ),
    );
  }
}
