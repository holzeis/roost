import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';
import 'media_message.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.roomId, this.room});

  final String roomId;
  final ApiRoom? room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final usersById = ref.watch(usersByIdProvider);
    final roomAsync = room != null ? AsyncData<ApiRoom>(room!) : ref.watch(_roomProvider(roomId));
    final isGroup = roomAsync.valueOrNull?.isGroup ?? false;

    return Scaffold(
      backgroundColor: chatWallpaperColor(context),
      appBar: AppBar(
        titleSpacing: 4,
        leading: const TablerBackButton(),
        // Explicit hairline matching the composer's top border exactly (same
        // color, same 0.5 width) — without this the only separation here was
        // the AppBar/wallpaper background colors meeting, which reads as a
        // different, softer line than the composer's actual drawn border.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(0.5),
          child: Container(height: 0.5, color: Theme.of(context).dividerColor),
        ),
        title: _ChatTitle(roomAsync: roomAsync, me: me, usersById: usersById),
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.search),
            onPressed: () => context.push('/chat/$roomId/search'),
          ),
          IconButton(
            icon: const Icon(TablerIcons.video),
            onPressed: () => context.push('/call/$roomId?group=${room?.isGroup ?? false}'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: me.hasValue
                ? _MessageList(
                    roomId: roomId,
                    meId: me.value!.id,
                    usersById: usersById.valueOrNull ?? const {},
                    isGroup: isGroup,
                  )
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
        InitialAvatar(initial: title.isNotEmpty ? title[0].toUpperCase() : '?', seed: title, size: 34),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              if (room.isGroup)
                Text(
                  '${room.members.length} members',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5),
                      ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.roomId,
    required this.meId,
    required this.usersById,
    required this.isGroup,
  });

  final String roomId;
  final String meId;
  final Map<String, ApiContact> usersById;
  final bool isGroup;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final messages = ref.watch(messagesProvider(roomId));

    return messages.when(
      error: (error, _) => Center(child: Text('Could not load messages.\n$error')),
      loading: () => const Center(child: CircularProgressIndicator()),
      data: (messages) {
        if (messages.isEmpty) {
          return Center(
            child: Text(
              'No messages yet. Say hello!',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.5)),
            ),
          );
        }
        // `messages` is oldest-first; the list itself renders newest-at-
        // bottom via reverse:true, so we walk it newest-first here too.
        final reversed = messages.reversed.toList();
        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
          itemCount: reversed.length,
          itemBuilder: (context, index) {
            final message = reversed[index];
            // Chronologically-next/-previous, i.e. the neighbors on screen
            // above/below since this list is newest-first.
            final older = index + 1 < reversed.length ? reversed[index + 1] : null;
            final newer = index > 0 ? reversed[index - 1] : null;
            final isFirstInGroup = older == null || older.senderId != message.senderId;
            final isLastInGroup = newer == null || newer.senderId != message.senderId;

            final senderName =
                message.senderId == meId ? 'Me' : (usersById[message.senderId]?.displayName ?? '?');
            return Padding(
              padding: EdgeInsets.only(bottom: isLastInGroup ? 10 : 2),
              child: _MessageRow(
                roomId: roomId,
                message: message,
                fromMe: message.senderId == meId,
                senderName: senderName,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                showSenderLabel: isGroup && message.senderId != meId && isFirstInGroup,
              ),
            );
          },
        );
      },
    );
  }
}

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

class _MessageRow extends ConsumerWidget {
  const _MessageRow({
    required this.roomId,
    required this.message,
    required this.fromMe,
    required this.senderName,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.showSenderLabel,
  });

  final String roomId;
  final ApiMessage message;
  final bool fromMe;
  final String senderName;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool showSenderLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final align = fromMe ? MainAxisAlignment.end : MainAxisAlignment.start;
    final timeLabel = TimeOfDay.fromDateTime(message.createdAt.toLocal()).format(context);
    final isMedia = message.kind == 'image' || message.kind == 'video';

    // Only the last bubble of a consecutive run from one sender gets the
    // "tail" (pointed) corner; earlier bubbles in the same run are fully
    // rounded, reading as one continuous group — the same grouping cue
    // WhatsApp/Telegram use instead of repeating the tail on every bubble.
    final tail = isLastInGroup ? ChatBubbleStyle.tailRadius : ChatBubbleStyle.radius;
    final borderRadius = BorderRadius.only(
      topLeft: ChatBubbleStyle.radius,
      topRight: ChatBubbleStyle.radius,
      bottomLeft: fromMe ? ChatBubbleStyle.radius : tail,
      bottomRight: fromMe ? tail : ChatBubbleStyle.radius,
    );

    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
      padding: isMedia
          ? const EdgeInsets.all(3)
          : const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: fromMe ? scheme.primary : scheme.surface,
        borderRadius: borderRadius,
        boxShadow: ChatBubbleStyle.shadow(Theme.of(context).brightness),
      ),
      child: isMedia
          ? MediaBubbleContent(message: message)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showSenderLabel)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      senderName,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: colorForAvatarSeed(senderName),
                      ),
                    ),
                  ),
                Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 14.5, height: 1.28, color: fromMe ? scheme.onPrimary : scheme.onSurface),
                    children: [
                      TextSpan(text: message.kind == 'location' ? 'Shared their location' : (message.body ?? '')),
                      TextSpan(
                        text: '  $timeLabel',
                        style: TextStyle(
                          fontSize: 10.5,
                          color: (fromMe ? scheme.onPrimary : scheme.onSurface).withOpacity(0.62),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );

    final avatarSlot = SizedBox(
      width: 26,
      child: (!fromMe && isLastInGroup)
          ? Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InitialAvatar(
                initial: senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                seed: senderName,
                size: 22,
              ),
            )
          : null,
    );

    return Column(
      crossAxisAlignment: fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onLongPress: () => _showMessageActions(context, ref),
          child: Row(
            mainAxisAlignment: align,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: fromMe ? [bubble] : [avatarSlot, bubble],
          ),
        ),
        if (message.reactions.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(left: fromMe ? 0 : 32, top: 2, right: fromMe ? 4 : 0),
            child: Transform.translate(
              offset: const Offset(0, -7),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                decoration: BoxDecoration(
                  color: chatWallpaperColor(context),
                  borderRadius: BorderRadius.circular(999),
                  boxShadow: ChatBubbleStyle.shadow(Theme.of(context).brightness),
                ),
                child: Wrap(
                  spacing: 3,
                  children: [
                    for (final reaction in message.reactions)
                      _ReactionChip(
                        reaction: reaction,
                        onTap: () =>
                            ref.read(messagesProvider(roomId).notifier).toggleReaction(message.id, reaction.emoji),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showMessageActions(BuildContext context, WidgetRef ref) {
    final isMedia = message.kind == 'image' || message.kind == 'video';
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Wrap(
                spacing: 16,
                children: [
                  for (final emoji in _quickReactions)
                    InkWell(
                      onTap: () {
                        Navigator.of(sheetContext).pop();
                        ref.read(messagesProvider(roomId).notifier).toggleReaction(message.id, emoji);
                      },
                      borderRadius: BorderRadius.circular(24),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(emoji, style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                ],
              ),
            ),
            if (isMedia)
              ListTile(
                leading: const Icon(TablerIcons.download),
                title: const Text('Download'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    final ext = message.kind == 'video' ? 'mp4' : 'jpg';
                    final path = await downloadMediaToDisk(ref, message.mediaId!, '${message.id}.$ext');
                    messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
                  } catch (error) {
                    messenger.showSnackBar(SnackBar(content: Text('Could not download: $error')));
                  }
                },
              ),
            if (isMedia && fromMe)
              ListTile(
                leading: Icon(TablerIcons.trash, color: Theme.of(context).colorScheme.error),
                title: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final messenger = ScaffoldMessenger.of(context);
                  try {
                    await ref.read(messagesProvider(roomId).notifier).deleteMedia(message.mediaId!);
                  } catch (error) {
                    messenger.showSnackBar(SnackBar(content: Text('Could not delete: $error')));
                  }
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.reaction, required this.onTap});

  final ApiReaction reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: reaction.reactedByMe ? scheme.primary.withOpacity(0.15) : scheme.onSurface.withOpacity(0.06),
          borderRadius: BorderRadius.circular(999),
          border: reaction.reactedByMe ? Border.all(color: scheme.primary.withOpacity(0.4)) : null,
        ),
        child: Text('${reaction.emoji} ${reaction.count}', style: const TextStyle(fontSize: 12)),
      ),
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

  Future<void> _pickAndSendMedia({required bool video, ImageSource source = ImageSource.gallery}) async {
    final picker = ImagePicker();
    final file = video ? await picker.pickVideo(source: source) : await picker.pickImage(source: source);
    if (file == null) return;

    setState(() => _sending = true);
    try {
      final bytes = await file.readAsBytes();
      final contentType = file.mimeType ?? lookupMimeType(file.path) ?? (video ? 'video/mp4' : 'image/jpeg');
      await ref.read(messagesProvider(widget.roomId).notifier).sendMedia(
            bytes: bytes,
            filename: file.name,
            contentType: contentType,
            kind: video ? 'video' : 'image',
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not upload: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(TablerIcons.photo),
              title: const Text('Photo library'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndSendMedia(video: false);
              },
            ),
            ListTile(
              leading: const Icon(TablerIcons.video),
              title: const Text('Video library'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndSendMedia(video: true);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The dedicated camera shortcut (distinct from the attach menu's gallery
  /// pickers): jumps straight into the device's own camera UI to capture and
  /// share a new photo or video, per the user's request. image_picker's
  /// camera source opens photo-capture and video-capture as two separate
  /// flows (no combined native toggle like the attach menu doesn't need),
  /// so this offers both as one tap each rather than guessing which the
  /// user wants.
  void _showCameraMenu() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(TablerIcons.camera),
              title: const Text('Take photo'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndSendMedia(video: false, source: ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(TablerIcons.video),
              title: const Text('Record video'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndSendMedia(video: true, source: ImageSource.camera);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 8, 10, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: Icon(TablerIcons.circlePlus, color: scheme.onSurface.withOpacity(0.6)),
              onPressed: _showAttachMenu,
            ),
            IconButton(
              icon: Icon(TablerIcons.camera, color: scheme.onSurface.withOpacity(0.6)),
              tooltip: 'Camera',
              onPressed: _showCameraMenu,
            ),
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 42),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: scheme.onSurface.withOpacity(0.08)),
                  ),
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Message',
                      isDense: true,
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Material(
              color: scheme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _send,
                child: SizedBox(
                  width: 42,
                  height: 42,
                  child: Center(
                    child: _sending
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: scheme.onPrimary),
                          )
                        : Icon(TablerIcons.send, color: scheme.onPrimary, size: 19),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
