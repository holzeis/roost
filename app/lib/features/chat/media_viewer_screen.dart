import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:go_router/go_router.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import 'forward_sheet.dart';
import 'media_message.dart';
import 'message_action_overlay.dart' show ReactionPicker, quickReactions;

/// The image/video subset of a room's messages, in the same order they were
/// given — the gallery this viewer pages through.
List<ApiMessage> mediaMessagesIn(List<ApiMessage> messages) =>
    messages.where((m) => m.kind == 'image' || m.kind == 'video').toList();

/// Where to start the gallery: the message that was tapped, or the first
/// page if it isn't in `media` (e.g. deleted between the tap and opening).
int initialMediaIndex(List<ApiMessage> media, String initialMessageId) {
  final index = media.indexWhere((m) => m.id == initialMessageId);
  return index == -1 ? 0 : index;
}

/// Full-screen photo/video viewer (the "Image view in chat" batch), opened
/// from a tap on a media bubble. Replaces the old bare video route
/// entirely — images and videos share one viewer here, with a swipeable
/// gallery of every other media message in the room, quick react/reply
/// straight from the photo, and save/share/forward underneath.
class MediaViewerScreen extends ConsumerStatefulWidget {
  const MediaViewerScreen(
      {super.key, required this.roomId, required this.initialMessageId});

  final String roomId;
  final String initialMessageId;

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  late final PageController _pageController;
  int _index = 0;
  bool _overlaysVisible = true;
  bool _busy = false;

  List<ApiMessage> _mediaMessages(WidgetRef ref) => mediaMessagesIn(
      ref.watch(messagesProvider(widget.roomId)).valueOrNull ?? const []);

  @override
  void initState() {
    super.initState();
    final media = mediaMessagesIn(
        ref.read(messagesProvider(widget.roomId)).valueOrNull ?? const []);
    _index = initialMediaIndex(media, widget.initialMessageId);
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _toggleOverlays() => setState(() => _overlaysVisible = !_overlaysVisible);

  void _goTo(int index) {
    _pageController.animateToPage(index,
        duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  /// Tapping a quick-react emoji here always leaves the viewer's own
  /// reaction as a single emoji — picking a different one than whatever the
  /// viewer already has swaps it, rather than stacking a second reaction
  /// alongside it (the data model allows multiple, and the regular chat
  /// bubble's own per-emoji chips still work that way, but "tap it again to
  /// change the reaction" only makes sense as a single-reaction control).
  /// Picking the same emoji already reacted with just toggles it off, same
  /// as tapping a reaction chip anywhere else in the app.
  Future<void> _react(ApiMessage message, String emoji) async {
    final controller = ref.read(messagesProvider(widget.roomId).notifier);
    for (final existing in message.reactions) {
      if (existing.reactedByMe && existing.emoji != emoji) {
        await controller.toggleReaction(message.id, existing.emoji);
      }
    }
    await controller.toggleReaction(message.id, emoji);
  }

  void _reply(ApiMessage message) {
    ref.read(composerDraftProvider(widget.roomId).notifier).state =
        ReplyDraft(message);
    context.pop();
  }

  Future<String> _downloadToTemp(ApiMessage message) {
    final ext = message.kind == 'video' ? 'mp4' : 'jpg';
    return downloadMediaToDisk(ref, message.mediaId!, '${message.id}.$ext');
  }

  Future<void> _save(ApiMessage message) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final path = await _downloadToTemp(message);
      if (message.kind == 'video') {
        await Gal.putVideo(path);
      } else {
        await Gal.putImageBytes(await File(path).readAsBytes());
      }
      messenger.showSnackBar(const SnackBar(content: Text('Saved to your photo library')));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(ApiMessage message) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final size = MediaQuery.of(context).size;
    try {
      final path = await _downloadToTemp(message);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(path)],
        sharePositionOrigin: Rect.fromLTWH(0, 0, size.width, size.height / 2),
      ));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not share: $error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = _mediaMessages(ref);
    if (media.isEmpty) {
      // The message this viewer was opened for was deleted out from under
      // it (a live message.deleted event) — nothing left to show.
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Text('Media not available', style: TextStyle(color: Colors.white))),
      );
    }
    final index = _index.clamp(0, media.length - 1);
    final current = media[index];
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    final meId = ref.watch(meProvider).valueOrNull?.id;
    final senderName = current.senderId == meId
        ? 'You'
        : (usersById[current.senderId]?.displayName ?? '?');
    final timeLabel =
        TimeOfDay.fromDateTime(current.createdAt.toLocal()).format(context);
    final apiClient = ref.watch(apiClientProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PhotoViewGallery.builder(
            pageController: _pageController,
            itemCount: media.length,
            onPageChanged: (i) => setState(() => _index = i),
            backgroundDecoration: const BoxDecoration(color: Colors.black),
            builder: (context, i) {
              final message = media[i];
              if (message.kind == 'video') {
                return PhotoViewGalleryPageOptions.customChild(
                  child: _InlineVideoPage(
                    url: apiClient.mediaUrl(message.mediaId!),
                    isCurrent: i == index,
                  ),
                  onTapUp: (_, __, ___) => _toggleOverlays(),
                  minScale: PhotoViewComputedScale.contained,
                  initialScale: PhotoViewComputedScale.contained,
                );
              }
              return PhotoViewGalleryPageOptions(
                imageProvider: NetworkImage(apiClient.mediaUrl(message.mediaId!)),
                onTapUp: (_, __, ___) => _toggleOverlays(),
                minScale: PhotoViewComputedScale.contained,
                initialScale: PhotoViewComputedScale.contained,
                errorBuilder: (context, error, stack) => const Center(
                  child: Icon(TablerIcons.photoOff, color: Colors.white54, size: 48),
                ),
              );
            },
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_overlaysVisible,
              child: AnimatedOpacity(
                opacity: _overlaysVisible ? 1 : 0,
                duration: const Duration(milliseconds: 180),
                child: Column(
                  children: [
                    _ViewerHeader(senderName: senderName, timeLabel: timeLabel),
                    const Spacer(),
                    _ReactReplyRow(
                      reactions: current.reactions,
                      onReact: (emoji) => _react(current, emoji),
                      onReply: () => _reply(current),
                    ),
                    const SizedBox(height: 12),
                    if (media.length > 1)
                      _Filmstrip(
                        media: media,
                        currentIndex: index,
                        mediaUrl: apiClient.mediaUrl,
                        onSelect: _goTo,
                      ),
                    const SizedBox(height: 8),
                    _ActionRow(
                      busy: _busy,
                      onSave: () => _save(current),
                      onShare: () => _share(current),
                      onForward: () => showForwardSheet(context, ref, current),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({required this.senderName, required this.timeLabel});
  final String senderName;
  final String timeLabel;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                icon: const Icon(TablerIcons.chevronLeft, color: Colors.white),
                onPressed: () => context.pop(),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(senderName,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15)),
                Text(timeLabel,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-left react / bottom-right reply row, overlaid directly on the
/// photo per the WhatsApp-style reference. Reply hands off to the regular
/// composer draft and returns to the chat screen — the same reply flow as
/// everywhere else, just entered from here.
///
/// The react side shows the current state of `reactions`: the viewer's own
/// reaction (if any) replaces the add button outright — tapping it reopens
/// the picker to change it — and everyone else's reactions sit beside it as
/// plain chips, tapping one adding that same emoji as the viewer's own.
class _ReactReplyRow extends StatelessWidget {
  const _ReactReplyRow({
    required this.reactions,
    required this.onReact,
    required this.onReply,
  });
  final List<ApiReaction> reactions;
  final void Function(String emoji) onReact;
  final VoidCallback onReply;

  @override
  Widget build(BuildContext context) {
    ApiReaction? myReaction;
    final othersReactions = <ApiReaction>[];
    for (final reaction in reactions) {
      if (reaction.reactedByMe) {
        myReaction ??= reaction;
      } else {
        othersReactions.add(reaction);
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ReactButton(onReact: onReact, myReaction: myReaction),
                  for (final reaction in othersReactions) ...[
                    const SizedBox(width: 6),
                    _ViewerReactionChip(
                      reaction: reaction,
                      onTap: () => onReact(reaction.emoji),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Material(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: onReply,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(TablerIcons.arrowBackUp, color: Colors.white, size: 18),
                    SizedBox(width: 6),
                    Text('Reply', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A read-only-looking chip for someone else's reaction — tapping it still
/// acts (adds that emoji as the viewer's own, via the same onReact as
/// everything else here), it just isn't drawn as a button the way the
/// add/change control is.
class _ViewerReactionChip extends StatelessWidget {
  const _ViewerReactionChip({required this.reaction, required this.onTap});
  final ApiReaction reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text('${reaction.emoji} ${reaction.count}',
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ),
      ),
    );
  }
}

/// The add-reaction control, bottom-left — an emoji icon with no reaction
/// yet, or the viewer's own current reaction once they've picked one (tap
/// either state to open the picker; picking a different emoji changes it,
/// picking the same one removes it — see _MediaViewerScreenState._react).
class _ReactButton extends StatefulWidget {
  const _ReactButton({required this.onReact, this.myReaction});
  final void Function(String emoji) onReact;
  final ApiReaction? myReaction;

  @override
  State<_ReactButton> createState() => _ReactButtonState();
}

class _ReactButtonState extends State<_ReactButton> {
  OverlayEntry? _entry;

  void _openPicker(BuildContext context) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    void close() {
      entry.remove();
      _entry = null;
    }

    entry = OverlayEntry(
      // The scrim and the picker are separate Stack children, not one
      // wrapping the other — nesting the picker's InkWell inside the
      // scrim's own GestureDetector puts both in the same tap gesture
      // arena, and the scrim can win the tap that was meant for an emoji.
      // message_action_overlay.dart's action overlay uses this same
      // sibling shape for the same reason.
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: close,
            ),
          ),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 72),
              child: ReactionPicker(
                emojis: quickReactions,
                onPick: (emoji) {
                  close();
                  widget.onReact(emoji);
                },
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(entry);
    _entry = entry;
  }

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final myReaction = widget.myReaction;
    if (myReaction != null) {
      return Material(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openPicker(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('${myReaction.emoji} ${myReaction.count}',
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      );
    }
    return Material(
      color: Colors.white.withValues(alpha: 0.15),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => _openPicker(context),
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(TablerIcons.moodSmile, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

class _Filmstrip extends StatelessWidget {
  const _Filmstrip({
    required this.media,
    required this.currentIndex,
    required this.mediaUrl,
    required this.onSelect,
  });

  final List<ApiMessage> media;
  final int currentIndex;
  final String Function(String mediaId) mediaUrl;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: media.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final message = media[i];
          final selected = i == currentIndex;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              width: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: selected ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  message.kind == 'video'
                      ? Container(color: Colors.white24)
                      : Image.network(mediaUrl(message.mediaId!), fit: BoxFit.cover),
                  if (message.kind == 'video')
                    const Center(
                      child: Icon(TablerIcons.playerPlayFilled, color: Colors.white, size: 18),
                    ),
                  if (!selected) Container(color: Colors.black.withValues(alpha: 0.35)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow(
      {required this.busy, required this.onSave, required this.onShare, required this.onForward});

  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _ActionButton(icon: TablerIcons.download, label: 'Save', onTap: busy ? null : onSave),
            _ActionButton(icon: TablerIcons.share, label: 'Share', onTap: busy ? null : onShare),
            _ActionButton(icon: TablerIcons.arrowForwardUp, label: 'Forward', onTap: busy ? null : onForward),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: onTap == null ? 0.4 : 1)),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(color: Colors.white.withValues(alpha: onTap == null ? 0.4 : 1), fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// A video page inside the gallery — plays while its page is current, pauses
/// otherwise, so swiping away from a playing video doesn't leave it running
/// off-screen with sound.
class _InlineVideoPage extends StatefulWidget {
  const _InlineVideoPage({required this.url, required this.isCurrent});
  final String url;
  final bool isCurrent;

  @override
  State<_InlineVideoPage> createState() => _InlineVideoPageState();
}

class _InlineVideoPageState extends State<_InlineVideoPage> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..setLooping(true)
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _ready = true);
        if (widget.isCurrent) _controller.play();
      });
  }

  @override
  void didUpdateWidget(covariant _InlineVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    if (widget.isCurrent && !_controller.value.isPlaying) {
      _controller.play();
    } else if (!widget.isCurrent && _controller.value.isPlaying) {
      _controller.pause();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return Center(
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: VideoPlayer(_controller),
      ),
    );
  }
}
