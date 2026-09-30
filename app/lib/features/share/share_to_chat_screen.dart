import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../router/app_router.dart';
import '../../services/share_intake.dart';
import '../../services/share_suggestions.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';
import '../chat/media_caption_screen.dart';
import '../chat/media_send.dart';
import '../home/home_screen.dart' show roomAvatarMediaId, roomDisplayName;

/// Where photos/videos shared into Roost from another app land: pick the
/// chat to send them to (most-used first), review them with an optional
/// caption on the usual MediaCaptionScreen, then they're sent and the chat
/// opens. When the user already picked a Roost chat in the system share
/// sheet ([PendingShare.roomId]), the review opens for it straight away;
/// backing out of that review leaves them here to pick a different chat.
class ShareToChatScreen extends ConsumerStatefulWidget {
  const ShareToChatScreen({super.key, required this.share});

  final PendingShare share;

  @override
  ConsumerState<ShareToChatScreen> createState() => _ShareToChatScreenState();
}

class _ShareToChatScreenState extends ConsumerState<ShareToChatScreen> {
  late final Future<Map<String, int>> _usage = ref.read(chatUsageProvider).counts();

  @override
  void initState() {
    super.initState();
    final roomId = widget.share.roomId;
    if (roomId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _review(roomId);
      });
    }
  }

  Future<void> _review(String roomId) async {
    final caption = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => MediaCaptionScreen(media: widget.share.media)),
    );
    if (caption == null || !mounted) return;

    // This screen is replaced by the chat, so capture what the upload needs
    // first: it carries on after this widget is gone.
    final container = ProviderScope.containerOf(context);
    final messenger = ScaffoldMessenger.of(context);
    appRouter.pushReplacement('/chat/$roomId');
    try {
      await sendPendingMedia(container.read(messagesProvider(roomId).notifier), widget.share.media, caption);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not share: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final rooms = ref.watch(roomsProvider);
    final me = ref.watch(meProvider).valueOrNull;
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const <String, ApiContact>{};
    final count = widget.share.media.length;
    return Scaffold(
      appBar: AppBar(
        leading: const TablerBackButton(),
        title: Text(count == 1 ? 'Share to…' : 'Share $count items to…'),
      ),
      body: rooms.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load your chats.\n$error', textAlign: TextAlign.center),
          ),
        ),
        data: (list) => FutureBuilder<Map<String, int>>(
          future: _usage,
          builder: (context, usage) {
            if (me == null || !usage.hasData) return const Center(child: CircularProgressIndicator());
            final ranked = rankRoomsForSharing(list, usage.data!);
            if (ranked.isEmpty) return const Center(child: Text('No chats yet.'));
            return ListView.builder(
              itemCount: ranked.length,
              itemBuilder: (context, index) {
                final room = ranked[index];
                final name = roomDisplayName(room, me.id, usersById);
                return ListTile(
                  leading: InitialAvatar(
                    initial: name.isNotEmpty ? name[0].toUpperCase() : '?',
                    seed: name,
                    size: 40,
                    avatarMediaId: roomAvatarMediaId(room, me.id, usersById),
                  ),
                  title: Text(name),
                  onTap: () => _review(room.id),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
