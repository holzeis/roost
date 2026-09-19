import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';
import 'call_message.dart';
import 'forward_sheet.dart';
import 'link_preview_card.dart';
import 'location_message.dart';
import 'media_message.dart';
import 'message_action_overlay.dart';
import 'reply_preview.dart';

class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.roomId, this.room});

  final String roomId;
  final ApiRoom? room;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final usersById = ref.watch(usersByIdProvider);
    final roomAsync = room != null
        ? AsyncData<ApiRoom>(room!)
        : ref.watch(roomProvider(roomId));
    final isGroup = roomAsync.valueOrNull?.isGroup ?? false;
    final typingUsers = ref.watch(typingUsersProvider(roomId));

    return Scaffold(
      backgroundColor: chatWallpaperColor(context),
      appBar: AppBar(
        titleSpacing: 4,
        leading: const TablerBackButton(),
        title: _ChatTitle(
            roomAsync: roomAsync,
            me: me,
            usersById: usersById,
            typingUsers: typingUsers),
        actions: [
          IconButton(
            icon: const Icon(TablerIcons.search),
            onPressed: () => context.push('/chat/$roomId/search'),
          ),
          IconButton(
            icon: const Icon(TablerIcons.video),
            onPressed: () => _startCall(context, ref, roomId, isGroup),
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

/// FR4.1/FR4.2: begins a call and jumps straight to CallScreen — unlike an
/// accepting callee (see IncomingCallScreen), the caller never goes through
/// the incoming-call screen for their own call.
Future<void> _startCall(BuildContext context, WidgetRef ref, String roomId, bool isGroup) async {
  try {
    final message = await ref.read(apiClientProvider).startCall(roomId);
    if (context.mounted) {
      context.push('/call/$roomId?messageId=${message.id}&group=$isGroup');
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start call: $error')));
    }
  }
}

class _ChatTitle extends StatelessWidget {
  const _ChatTitle(
      {required this.roomAsync,
      required this.me,
      required this.usersById,
      required this.typingUsers});

  final AsyncValue<ApiRoom> roomAsync;
  final AsyncValue<ApiUser> me;
  final AsyncValue<Map<String, ApiContact>> usersById;
  final Set<String> typingUsers;

  /// FR1.7: "X is typing…" / "X and Y are typing…" / "Several people are
  /// typing…", built from whichever room members (other than the caller)
  /// are currently signaling typing. Empty when nobody is.
  String _typingLabel(String? meId) {
    final names = [
      for (final id in typingUsers)
        if (id != meId) usersById.valueOrNull?[id]?.displayName ?? 'Someone',
    ];
    if (names.isEmpty) return '';
    if (names.length == 1) return '${names[0]} is typing…';
    if (names.length == 2) return '${names[0]} and ${names[1]} are typing…';
    return 'Several people are typing…';
  }

  @override
  Widget build(BuildContext context) {
    final room = roomAsync.valueOrNull;
    if (room == null) return const SizedBox.shrink();

    String title = room.name ?? '';
    if (title.isEmpty) {
      final meId = me.valueOrNull?.id;
      final otherId =
          room.members.firstWhere((id) => id != meId, orElse: () => '');
      title = usersById.valueOrNull?[otherId]?.displayName ?? 'Direct message';
    }
    final typingLabel = _typingLabel(me.valueOrNull?.id);

    return Row(
      children: [
        InitialAvatar(
            initial: title.isNotEmpty ? title[0].toUpperCase() : '?',
            seed: title,
            size: 34),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              if (typingLabel.isNotEmpty)
                Text(
                  typingLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontStyle: FontStyle.italic,
                      ),
                )
              else if (room.isGroup)
                Text(
                  '${room.members.length} MEMBERS',
                  style: roostMono(context, fontSize: 10.5),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MessageList extends ConsumerStatefulWidget {
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
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  final _scrollOffsetController = ScrollOffsetController();
  final _viewportKey = GlobalKey();
  Timer? _seenDebounce;

  // Keyed by message id and reused across rebuilds, rather than minted fresh
  // inside _MessageRow on every build — openActions() there now awaits a
  // scroll before opening the overlay, and a rebuild during that await (e.g.
  // from a seen-status ack) would otherwise swap in a new _MessageRow with a
  // brand new key, silently detaching the one the long-press closure had
  // captured and leaving the overlay anchored to whatever bubble happens to
  // hold the stale key afterward instead of the one actually pressed.
  final _bubbleKeys = <String, GlobalKey>{};

  GlobalKey _bubbleKeyFor(String messageId) =>
      _bubbleKeys.putIfAbsent(messageId, GlobalKey.new);

  @override
  void initState() {
    super.initState();
    _itemPositionsListener.itemPositions.addListener(_onPositionsChanged);
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(_onPositionsChanged);
    _seenDebounce?.cancel();
    super.dispose();
  }

  /// Debounced FR1.6 seen-tracking: whenever the visible window of the
  /// (reversed, newest-first) list settles, ack any visible message from
  /// someone else as seen. Debounced rather than acked on every scroll
  /// frame since positions fire continuously while flinging the list.
  void _onPositionsChanged() {
    _seenDebounce?.cancel();
    _seenDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final reversed =
          (ref.read(messagesProvider(widget.roomId)).valueOrNull ?? const <ApiMessage>[])
              .reversed
              .toList();
      final visibleIds = [
        for (final position in _itemPositionsListener.itemPositions.value)
          if (position.index >= 0 && position.index < reversed.length)
            reversed[position.index].id,
      ];
      unawaited(ref.read(messagesProvider(widget.roomId).notifier).ackSeen(visibleIds));
    });
  }

  /// Scrolls back to a message by id, e.g. when a reply quote is tapped
  /// (FR1.10). A silent no-op if it isn't in the currently loaded window
  /// (e.g. it's further back than pagination has fetched) — there's no
  /// stable way to jump to something that isn't loaded yet.
  void _jumpToMessage(String messageId, List<ApiMessage> reversed) {
    final index = reversed.indexWhere((m) => m.id == messageId);
    if (index == -1 || !_itemScrollController.isAttached) return;
    _itemScrollController.scrollTo(
        index: index,
        duration: const Duration(milliseconds: 300),
        alignment: 0.4);
  }

  /// Scrolls by exactly [delta] pixels (positive scrolls further into the
  /// list, moving on-screen content up) — used to make room for the reaction
  /// picker/action menu when a message is too close to either edge of the
  /// list to fit them, per _MessageRow's own fit check.
  ///
  /// Deliberately not `ItemScrollController.scrollTo`'s index+alignment API:
  /// on this `reverse: true` list, `alignment` turned out not to map onto a
  /// predictable pixel offset — a request computed to shift a bubble by
  /// ~79px (using the "0 = top of view, 1 = bottom" semantics the docs
  /// describe for a *non*-reversed list) instead moved it by 381px, nearly
  /// 5x more than asked for, landing the popup over a different message
  /// entirely. `ScrollOffsetController.animateScroll` instead scrolls the
  /// underlying `ScrollController` by a literal relative pixel amount, with
  /// no index/alignment translation to get wrong.
  Future<void> _scrollByOffset(double delta) async {
    await _scrollOffsetController.animateScroll(
      offset: delta,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
    final settled = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) => settled.complete());
    await settled.future;
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesProvider(widget.roomId));

    return messages.when(
      error: (error, _) =>
          Center(child: Text('Could not load messages.\n$error')),
      loading: () => const Center(child: CircularProgressIndicator()),
      data: (messages) {
        if (messages.isEmpty) {
          return Center(
            child: Text(
              'No messages yet. Say hello!',
              style: TextStyle(
                  color:
                      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
            ),
          );
        }
        // `messages` is oldest-first; the list itself renders newest-at-
        // bottom via reverse:true, so we walk it newest-first here too.
        final reversed = messages.reversed.toList();
        final currentIds = reversed.map((m) => m.id).toSet();
        _bubbleKeys.removeWhere((id, _) => !currentIds.contains(id));
        return ScrollablePositionedList.builder(
          key: _viewportKey,
          reverse: true,
          itemScrollController: _itemScrollController,
          itemPositionsListener: _itemPositionsListener,
          scrollOffsetController: _scrollOffsetController,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
          itemCount: reversed.length,
          itemBuilder: (context, index) {
            final message = reversed[index];
            // Chronologically-next/-previous, i.e. the neighbors on screen
            // above/below since this list is newest-first.
            final older =
                index + 1 < reversed.length ? reversed[index + 1] : null;
            final newer = index > 0 ? reversed[index - 1] : null;
            final isFirstInGroup =
                older == null || older.senderId != message.senderId;
            final isLastInGroup =
                newer == null || newer.senderId != message.senderId;

            final senderName = message.senderId == widget.meId
                ? 'Me'
                : (widget.usersById[message.senderId]?.displayName ?? '?');
            return Padding(
              padding: EdgeInsets.only(bottom: isLastInGroup ? 10 : 2),
              child: _MessageRow(
                key: ValueKey(message.id),
                bubbleKey: _bubbleKeyFor(message.id),
                roomId: widget.roomId,
                isGroup: widget.isGroup,
                message: message,
                fromMe: message.senderId == widget.meId,
                senderName: senderName,
                isFirstInGroup: isFirstInGroup,
                isLastInGroup: isLastInGroup,
                showSenderLabel: widget.isGroup &&
                    message.senderId != widget.meId &&
                    isFirstInGroup,
                meId: widget.meId,
                usersById: widget.usersById,
                onJumpToReply: (id) => _jumpToMessage(id, reversed),
                viewportKey: _viewportKey,
                scrollByOffset: _scrollByOffset,
              ),
            );
          },
        );
      },
    );
  }
}

const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

/// Sent/delivered/seen tick (FR1.5, FR1.6), rendered next to the timestamp
/// on the sender's own message bubbles only. Delivered and seen both use
/// the double-check glyph (TablerIcons.checks) — seen is distinguished by
/// full opacity rather than a separate color, so it still reads clearly on
/// the primary-colored fromMe bubble in both themes.
WidgetSpan _statusIconSpan(String status, Color onPrimary) {
  final seen = status == 'seen';
  final icon = status == 'sent' ? TablerIcons.check : TablerIcons.checks;
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: Padding(
      padding: const EdgeInsets.only(left: 3),
      child: Icon(icon, size: 12, color: onPrimary.withValues(alpha: seen ? 1 : 0.62)),
    ),
  );
}

class _MessageRow extends ConsumerWidget {
  const _MessageRow({
    super.key,
    required this.bubbleKey,
    required this.roomId,
    required this.isGroup,
    required this.message,
    required this.fromMe,
    required this.senderName,
    required this.isFirstInGroup,
    required this.isLastInGroup,
    required this.showSenderLabel,
    required this.meId,
    required this.usersById,
    required this.onJumpToReply,
    required this.viewportKey,
    required this.scrollByOffset,
  });

  // Owned by _MessageListState and reused across rebuilds for this message
  // id — see its own doc comment for why this can't just be minted fresh
  // here on every build.
  final GlobalKey bubbleKey;

  final String roomId;
  final bool isGroup;
  final ApiMessage message;
  final bool fromMe;
  final String senderName;
  final bool isFirstInGroup;
  final bool isLastInGroup;
  final bool showSenderLabel;
  final String meId;
  final Map<String, ApiContact> usersById;
  final void Function(String messageId) onJumpToReply;

  // Lets a long-press measure this row's position against the list's own
  // viewport and scroll it into a spot with room for both the reaction
  // picker above and the action menu below before opening them — see
  // openActions() below.
  final GlobalKey viewportKey;
  final Future<void> Function(double delta) scrollByOffset;

  String _nameFor(String userId) =>
      userId == meId ? 'You' : (usersById[userId]?.displayName ?? '?');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final align = fromMe ? MainAxisAlignment.end : MainAxisAlignment.start;
    final timeLabel =
        TimeOfDay.fromDateTime(message.createdAt.toLocal()).format(context);
    final isMedia = message.kind == 'image' || message.kind == 'video';
    final isLocation = message.kind == 'location';
    final isCall = message.kind == 'call';

    // Only the last bubble of a consecutive run from one sender gets the
    // "tail" (pointed) corner; earlier bubbles in the same run are fully
    // rounded, reading as one continuous group — the same grouping cue
    // WhatsApp/Telegram use instead of repeating the tail on every bubble.
    final tail =
        isLastInGroup ? ChatBubbleStyle.tailRadius : ChatBubbleStyle.radius;
    final borderRadius = BorderRadius.only(
      topLeft: ChatBubbleStyle.radius,
      topRight: ChatBubbleStyle.radius,
      bottomLeft: fromMe ? ChatBubbleStyle.radius : tail,
      bottomRight: fromMe ? tail : ChatBubbleStyle.radius,
    );

    final bubble = Container(
      key: bubbleKey,
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
      padding: isMedia || isLocation
          ? const EdgeInsets.all(3)
          : const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: fromMe ? scheme.primary : scheme.surface,
        borderRadius: borderRadius,
        boxShadow: ChatBubbleStyle.shadow(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (message.forwarded)
            Padding(
              padding: EdgeInsets.only(bottom: 2, left: isMedia || isLocation ? 5 : 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(TablerIcons.arrowForwardUp,
                      size: 12,
                      color: (fromMe ? scheme.onPrimary : scheme.onSurface)
                          .withValues(alpha: 0.55)),
                  const SizedBox(width: 3),
                  Text(
                    'Forwarded',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: (fromMe ? scheme.onPrimary : scheme.onSurface)
                          .withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          if (message.replyTo != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: isMedia || isLocation ? 5 : 0),
              child: ReplyQuoteChip(
                snippet: message.replyTo!,
                senderName: _nameFor(message.replyTo!.senderId),
                tint: fromMe ? scheme.onPrimary : scheme.primary,
                onTap: () => onJumpToReply(message.replyTo!.id),
              ),
            ),
          if (isMedia)
            MediaBubbleContent(message: message)
          else if (isLocation)
            LocationBubbleContent(message: message, roomId: roomId)
          else if (isCall)
            CallBubbleContent(
              message: message,
              roomId: roomId,
              isGroup: isGroup,
              textColor: fromMe ? scheme.onPrimary : scheme.onSurface,
            )
          else ...[
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
                style: TextStyle(
                    fontSize: 14.5,
                    height: 1.28,
                    color: fromMe ? scheme.onPrimary : scheme.onSurface),
                children: [
                  TextSpan(text: message.body ?? ''),
                  TextSpan(
                    text:
                        '${message.editedAt != null ? ' (edited)' : ''}  $timeLabel',
                    style: roostMono(
                      context,
                      fontSize: 10.5,
                      color: (fromMe ? scheme.onPrimary : scheme.onSurface)
                          .withValues(alpha: 0.62),
                    ),
                  ),
                  if (fromMe) _statusIconSpan(message.status, scheme.onPrimary),
                ],
              ),
            ),
            if (message.kind == 'text' &&
                message.body != null &&
                firstUrlIn(message.body!) != null)
              LinkPreviewCard(
                  url: firstUrlIn(message.body!)!, onBackground: fromMe),
          ],
        ],
      ),
    );

    final avatarSlot = SizedBox(
      width: 26,
      child: (!fromMe && isLastInGroup)
          ? Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InitialAvatar(
                initial:
                    senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                seed: senderName,
                size: 22,
              ),
            )
          : null,
    );

    // A RenderBox's default hitTest() rejects any position outside its own
    // [0, size] box *before* it ever delegates to a child — so a
    // Transform/Positioned overlap that overflows past this widget's own
    // reported size is invisible to hit-testing regardless of what the
    // overflowing child itself does, no matter which ancestor eventually
    // contains it (learned the hard way: a -14 Transform.translate on a
    // separate sibling below the bubble looked right but silently ate every
    // tap on the reaction it was supposed to show). The fix is for this
    // Stack to genuinely report a size that already includes bubble +
    // overlap — reserved here via a real (non-positioned) SizedBox spacer —
    // rather than relying on Positioned overflow past a smaller reported
    // size. Horizontally too: the badge is flush with the bubble's own edge
    // (right: 0 / left: 0), not poking past it, for the same reason.
    const reactionBadgeProtrusion = 14.0;
    final bubbleWithReactions = message.reactions.isEmpty
        ? bubble
        : Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [bubble, const SizedBox(height: reactionBadgeProtrusion)],
              ),
              Positioned(
                bottom: 0,
                right: fromMe ? null : 0,
                left: fromMe ? 0 : null,
                child: Wrap(
                  spacing: 3,
                  children: [
                    for (final reaction in message.reactions)
                      _ReactionChip(
                        reaction: reaction,
                        onTap: () => ref
                            .read(messagesProvider(roomId).notifier)
                            .toggleReaction(message.id, reaction.emoji),
                      ),
                  ],
                ),
              ),
            ],
          );

    final actions = _buildActions(context, ref);
    // FR: don't offer an emoji the caller has already reacted with — there's
    // nothing useful to pick there (tapping it again would just toggle it
    // off, which the landed reaction chip itself already does).
    final reactedEmojis = {
      for (final reaction in message.reactions)
        if (reaction.reactedByMe) reaction.emoji,
    };
    final availableEmojis = [
      for (final emoji in _quickReactions)
        if (!reactedEmojis.contains(emoji)) emoji,
    ];

    Future<void> openActions() async {
      final bubbleBox = bubbleKey.currentContext?.findRenderObject() as RenderBox?;
      final viewportBox = viewportKey.currentContext?.findRenderObject() as RenderBox?;
      // Scroll this message into a spot with room for both the picker above
      // and the menu below *before* opening either — moving the popup to
      // fit around a cramped position, rather than moving the message,
      // is what let the layout end up ambiguous about which side either
      // piece was really anchored to.
      if (bubbleBox != null && bubbleBox.attached && viewportBox != null && viewportBox.attached) {
        final bubbleRect = bubbleBox.localToGlobal(Offset.zero) & bubbleBox.size;
        final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
        final viewportHeight = viewportBox.size.height;

        final neededAbove =
            availableEmojis.isEmpty ? 0.0 : messageActionPickerHeight + messageActionGap * 2;
        final neededBelow =
            actions.length * messageActionMenuRowHeight + 8 + messageActionGap * 2;

        final spaceAbove = bubbleRect.top - viewportTop;
        final spaceBelow = viewportTop + viewportHeight - bubbleRect.bottom;

        // Only scroll when something doesn't actually fit, and only by the
        // exact deficit — never re-centering a message that already fits. A
        // positive delta scrolls further into the list, which always moves
        // on-screen content up regardless of `reverse`; negative moves it
        // down.
        double? delta;
        if (neededAbove > 0 && spaceAbove < neededAbove) {
          delta = -(neededAbove - spaceAbove);
        } else if (spaceBelow < neededBelow) {
          delta = neededBelow - spaceBelow;
        }

        if (delta != null) {
          await scrollByOffset(delta);
        }
      }

      if (!context.mounted) return;
      showMessageActionOverlay(
        context: context,
        anchorKey: bubbleKey,
        alignEnd: fromMe,
        bubbleBorderRadius: borderRadius,
        quickEmojis: availableEmojis,
        onReact: (emoji) => ref
            .read(messagesProvider(roomId).notifier)
            .toggleReaction(message.id, emoji),
        actions: actions,
      );
    }

    return Row(
      mainAxisAlignment: align,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!fromMe) avatarSlot,
        GestureDetector(
          onLongPress: openActions,
          child: bubbleWithReactions,
        ),
      ],
    );
  }

  /// FR1.13: a message can be edited only if it's the caller's own text
  /// message, sent within the last minute — mirrors the server's own check
  /// (see server/internal/api's editWindow) so the option simply doesn't
  /// appear rather than appearing and then failing.
  bool get _canEdit =>
      fromMe &&
      message.kind == 'text' &&
      DateTime.now().difference(message.createdAt) < const Duration(minutes: 1);

  /// Same set of actions the old bottom sheet offered, and the same
  /// conditionals deciding which apply to this message — just handed to
  /// [showMessageActionOverlay] instead of a ListTile column, so dismissal
  /// is the overlay's job, not each item's.
  List<MessageActionItem> _buildActions(BuildContext context, WidgetRef ref) {
    final isMedia = message.kind == 'image' || message.kind == 'video';
    final isText = message.kind == 'text';
    final isLocation = message.kind == 'location';
    final isCall = message.kind == 'call';

    return [
      MessageActionItem(
        icon: TablerIcons.arrowBackUp,
        label: 'Reply',
        onTap: () => ref.read(composerDraftProvider(roomId).notifier).state =
            ReplyDraft(message),
      ),
      if (!isLocation && !isCall)
        MessageActionItem(
          icon: TablerIcons.arrowForwardUp,
          label: 'Forward',
          onTap: () => showForwardSheet(context, ref, message),
        ),
      if (isText)
        MessageActionItem(
          icon: TablerIcons.copy,
          label: 'Copy',
          onTap: () {
            Clipboard.setData(ClipboardData(text: message.body ?? ''));
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Copied')));
          },
        ),
      if (_canEdit)
        MessageActionItem(
          icon: TablerIcons.pencil,
          label: 'Edit',
          onTap: () => ref.read(composerDraftProvider(roomId).notifier).state =
              EditDraft(message),
        ),
      if (isMedia)
        MessageActionItem(
          icon: TablerIcons.download,
          label: 'Download',
          onTap: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              final ext = message.kind == 'video' ? 'mp4' : 'jpg';
              final path = await downloadMediaToDisk(
                  ref, message.mediaId!, '${message.id}.$ext');
              messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
            } catch (error) {
              messenger.showSnackBar(
                  SnackBar(content: Text('Could not download: $error')));
            }
          },
        ),
      if (isMedia && fromMe)
        MessageActionItem(
          icon: TablerIcons.trash,
          label: 'Delete',
          isDestructive: true,
          onTap: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await ref
                  .read(messagesProvider(roomId).notifier)
                  .deleteMedia(message.mediaId!);
            } catch (error) {
              messenger.showSnackBar(
                  SnackBar(content: Text('Could not delete: $error')));
            }
          },
        ),
    ];
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.reaction, required this.onTap});

  final ApiReaction reaction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // A ring the color of the wallpaper behind the bubble, not a plain
    // border — reads as a distinct badge sitting on the seam between the
    // bubble and the chat background, the way the reaction sits half on
    // each. Sitting directly on the bubble corner (see the Stack in
    // _MessageRow) rather than in a caption row underneath it.
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: chatWallpaperColor(context), width: 1.5),
          boxShadow: ChatBubbleStyle.shadow(Theme.of(context).brightness),
        ),
        child: Text(
          '${reaction.emoji} ${reaction.count}',
          style: TextStyle(
            fontSize: 11,
            fontWeight: reaction.reactedByMe ? FontWeight.w700 : FontWeight.w400,
            color: reaction.reactedByMe ? ochreColor(context) : scheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
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
  bool _hasText = false;

  bool _typingSignaled = false;
  DateTime? _lastTypingPing;
  Timer? _typingAutoStop;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
    _notifyTyping(hasText);
  }

  /// FR1.7: throttles typing.start pings to at most one per 3 seconds while
  /// there's text in the composer, and resets a 5-second local "auto-stop"
  /// so a typing indicator doesn't stick around forever if the user just
  /// stops typing without sending or clearing the field. Sending a stop is
  /// immediate — no reason to throttle the one that matters most.
  void _notifyTyping(bool isTyping) {
    if (!isTyping) {
      _typingAutoStop?.cancel();
      _lastTypingPing = null;
      if (_typingSignaled) {
        _typingSignaled = false;
        ref.read(messagesProvider(widget.roomId).notifier).notifyTyping(false);
      }
      return;
    }

    final now = DateTime.now();
    final shouldPing = _lastTypingPing == null || now.difference(_lastTypingPing!) >= const Duration(seconds: 3);
    if (shouldPing) {
      _lastTypingPing = now;
      _typingSignaled = true;
      ref.read(messagesProvider(widget.roomId).notifier).notifyTyping(true);
    }
    _typingAutoStop?.cancel();
    _typingAutoStop = Timer(const Duration(seconds: 5), () => _notifyTyping(false));
  }

  @override
  void dispose() {
    // No explicit stop signal here — `ref` isn't safe to read from dispose()
    // (Riverpod throws if the element is already tearing down), and it
    // isn't needed: the receiving side's own timeout in TypingController
    // (chat_providers.dart) clears a stale indicator a few seconds after
    // the last ping regardless of whether an explicit stop ever arrives.
    _typingAutoStop?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    final draftNotifier =
        ref.read(composerDraftProvider(widget.roomId).notifier);
    final draft = draftNotifier.state;

    setState(() => _sending = true);
    _controller.clear();
    draftNotifier.state = null;
    try {
      if (draft is EditDraft) {
        await ref
            .read(messagesProvider(widget.roomId).notifier)
            .editMessage(draft.message.id, text);
      } else {
        await ref.read(messagesProvider(widget.roomId).notifier).send(text,
            replyToMessageId: draft is ReplyDraft ? draft.message.id : null);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendMedia(
      {required bool video, ImageSource source = ImageSource.gallery}) async {
    final picker = ImagePicker();
    final file = video
        ? await picker.pickVideo(source: source)
        : await picker.pickImage(source: source);
    if (file == null) return;

    setState(() => _sending = true);
    try {
      final bytes = await file.readAsBytes();
      final contentType = file.mimeType ??
          lookupMimeType(file.path) ??
          (video ? 'video/mp4' : 'image/jpeg');
      await ref.read(messagesProvider(widget.roomId).notifier).sendMedia(
            bytes: bytes,
            filename: file.name,
            contentType: contentType,
            kind: video ? 'video' : 'image',
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not upload: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// One merged camera shortcut, replacing the separate "+" attach menu and
  /// camera button. A plain tap jumps straight into the device's own camera
  /// for a photo — "directly open the camera" as asked — since that's the
  /// single most common action and there's no way to inject a "video" or
  /// "gallery" control into the native camera capture screen itself (iOS's
  /// camera picker UI isn't customizable from Flutter). Long-pressing
  /// surfaces the alternatives (record video, or pick from the gallery
  /// instead) without slowing down the common one-tap case.
  Future<void> _onCameraTap() =>
      _pickAndSendMedia(video: false, source: ImageSource.camera);

  void _showAttachOptions() {
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
            ListTile(
              leading: const Icon(TablerIcons.photo),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pickAndSendMedia(video: false, source: ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(TablerIcons.mapPin),
              title: const Text('Share location'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showLocationTtlSheet();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// FR3.2: the sender picks a preset TTL before sharing starts. Presets
  /// match docs/architecture-overview.md's own example (15 min / 1 hr /
  /// "until I arrive" — the last implemented as a long bound since
  /// expiresAt needs a concrete value either way; FR3.5's manual "Stop
  /// sharing" is the expected way that preset actually ends).
  void _showLocationTtlSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Share your location for…', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            ListTile(
              title: const Text('15 minutes'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _startSharingLocation(const Duration(minutes: 15));
              },
            ),
            ListTile(
              title: const Text('1 hour'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _startSharingLocation(const Duration(hours: 1));
              },
            ),
            ListTile(
              title: const Text('Until I arrive'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _startSharingLocation(const Duration(hours: 8));
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _startSharingLocation(Duration ttl) async {
    try {
      await ref.read(locationShareProvider(widget.roomId).notifier).start(ttl);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not share your location: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final draft = ref.watch(composerDraftProvider(widget.roomId));

    // Entering edit mode prefills the field with the message being edited;
    // leaving it (send, or the bar's own discard button) doesn't touch the
    // field, except discard explicitly clears it back out — see _discardDraft.
    ref.listen<ComposerDraft?>(composerDraftProvider(widget.roomId),
        (previous, next) {
      if (next is EditDraft && previous is! EditDraft) {
        _controller.text = next.message.body ?? '';
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      }
    });

    final meId = ref.watch(meProvider).valueOrNull?.id;
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    String nameFor(String userId) => userId == meId
        ? 'yourself'
        : (usersById[userId]?.displayName ?? 'them');

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            if (draft != null)
              ComposerDraftBar(
                draft: draft,
                senderName: nameFor(draft.message.senderId),
                onDiscard: () {
                  final wasEditing = draft is EditDraft;
                  ref
                      .read(composerDraftProvider(widget.roomId).notifier)
                      .state = null;
                  if (wasEditing) _controller.clear();
                },
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 10, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Hidden while composing text, matching WhatsApp/Telegram —
                  // there's nothing to shortcut to the camera for once you're
                  // already mid-message.
                  if (!_hasText)
                    GestureDetector(
                      onLongPress: _showAttachOptions,
                      // No `tooltip:` here — IconButton wraps itself in a Tooltip
                      // when one is set, and Tooltip's own long-press-to-show
                      // recognizer competes with ours in the same gesture arena,
                      // making onLongPress fire unreliably.
                      child: IconButton(
                        icon: Icon(TablerIcons.camera,
                            color: scheme.onSurface.withValues(alpha: 0.6)),
                        onPressed: _onCameraTap,
                      ),
                    ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 42),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                              color: scheme.onSurface.withValues(alpha: 0.08)),
                        ),
                        child: TextField(
                          controller: _controller,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_sending)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
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
