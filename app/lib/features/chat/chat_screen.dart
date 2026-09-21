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
import '../../util/time_format.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';
import 'call_message.dart';
import 'forward_sheet.dart';
import 'link_preview_card.dart';
import 'media_caption_screen.dart';
import 'location_message.dart';
import 'media_message.dart';
import 'message_action_overlay.dart';
import 'reply_preview.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.roomId, this.room});

  final String roomId;
  final ApiRoom? room;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  // Lets a long-press find the composer's current on-screen position (which
  // moves with the keyboard) so the reaction picker/action menu never cover
  // it — a plain field here rather than minted inside build() so it stays
  // the same key across rebuilds instead of orphaning itself the moment
  // anything above this widget rebuilds it.
  final _composerKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final roomId = widget.roomId;
    final room = widget.room;
    final me = ref.watch(meProvider);
    final usersById = ref.watch(usersByIdProvider);
    final roomAsync = room != null
        ? AsyncData<ApiRoom>(room)
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
                    composerKey: _composerKey,
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          _MessageComposer(key: _composerKey, roomId: roomId),
        ],
      ),
    );
  }
}

/// FR4.1/FR4.2: begins a call and jumps straight to CallScreen — unlike an
/// accepting callee (see IncomingCallScreen), the caller never goes through
/// the incoming-call screen for their own call.
Future<void> _startCall(
    BuildContext context, WidgetRef ref, String roomId, bool isGroup) async {
  try {
    final message = await ref.read(apiClientProvider).startCall(roomId);
    if (context.mounted) {
      context.push('/call/$roomId?messageId=${message.id}&group=$isGroup');
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not start call: $error')));
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
    // Only a 1:1 room has one specific person's avatar to show — a group's
    // own title has no single user behind it, so this stays null there.
    String? avatarMediaId;
    if (title.isEmpty) {
      final meId = me.valueOrNull?.id;
      final otherId =
          room.members.firstWhere((id) => id != meId, orElse: () => '');
      final other = usersById.valueOrNull?[otherId];
      title = other?.displayName ?? 'Direct message';
      avatarMediaId = other?.avatarMediaId;
    }
    final typingLabel = _typingLabel(me.valueOrNull?.id);

    return Row(
      children: [
        InitialAvatar(
            initial: title.isNotEmpty ? title[0].toUpperCase() : '?',
            seed: title,
            avatarMediaId: avatarMediaId,
            size: 34),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(title,
                  // The AppBar's own titleTextStyle is a display serif
                  // (Zilla Slab, see app_theme.dart) meant for plain screen
                  // titles — the chat title sits right above message text
                  // set in the body font, so it borrows that family instead
                  // of the ambient AppBar one.
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      )),
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
    required this.composerKey,
  });

  final String roomId;
  final String meId;
  final Map<String, ApiContact> usersById;
  final bool isGroup;
  final GlobalKey composerKey;

  @override
  ConsumerState<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends ConsumerState<_MessageList> {
  final _itemScrollController = ItemScrollController();
  final _itemPositionsListener = ItemPositionsListener.create();
  Timer? _seenDebounce;

  // Rebuilt on every build() alongside the list itself — the single source
  // of truth for what item index N actually is, since date dividers mean
  // that's no longer just `reversed[N]`. Kept as a field (rather than
  // recomputed from the provider) so the scroll-position listeners below,
  // which fire independently of build(), always agree with what's actually
  // on screen.
  List<_ListEntry> _entries = const [];

  // Drives the scrollbar and sticky date pill's fade in/out — set from
  // actual scroll notifications (not item positions, which also fire on
  // plain layout) so they only appear while the user is really scrolling.
  Timer? _scrollActivityTimer;
  bool _scrollActive = false;

  void _onScrollActivity() {
    if (!_scrollActive && mounted) setState(() => _scrollActive = true);
    _scrollActivityTimer?.cancel();
    _scrollActivityTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _scrollActive = false);
    });
  }

  // Keyed by message id and reused across rebuilds, rather than minted fresh
  // inside _MessageRow on every build — a rebuild between a long-press and
  // the overlay actually opening (e.g. from a seen-status ack) would
  // otherwise swap in a new _MessageRow with a brand new key, silently
  // detaching the one the long-press closure had captured and leaving the
  // overlay anchored to whatever bubble happens to hold the stale key
  // afterward instead of the one actually pressed.
  final _bubbleKeys = <String, GlobalKey>{};

  GlobalKey _bubbleKeyFor(String messageId) =>
      _bubbleKeys.putIfAbsent(messageId, GlobalKey.new);

  // The message currently duplicated into an open action overlay (see
  // message_action_overlay.dart) — its real bubble hides for as long as
  // this is set, so the lifted copy reads as the one message having moved
  // rather than a second, dimmed ghost of it sitting right next to the
  // copy the whole time.
  String? _liftedMessageId;

  void _setLifted(String? messageId) {
    if (mounted) setState(() => _liftedMessageId = messageId);
  }

  @override
  void initState() {
    super.initState();
    _itemPositionsListener.itemPositions.addListener(_onPositionsChanged);
  }

  @override
  void dispose() {
    _itemPositionsListener.itemPositions.removeListener(_onPositionsChanged);
    _seenDebounce?.cancel();
    _scrollActivityTimer?.cancel();
    super.dispose();
  }

  /// Debounced FR1.6 seen-tracking: whenever the visible window of the
  /// (reversed, newest-first) list settles, ack any visible message from
  /// someone else as seen. Debounced rather than acked on every scroll
  /// frame since positions fire continuously while flinging the list.
  /// Reads indices against `_entries` (this build's own item list, dividers
  /// included) rather than a freshly re-derived message list, since it's
  /// only `_entries` that the visible `position.index` values actually
  /// index into.
  void _onPositionsChanged() {
    _seenDebounce?.cancel();
    _seenDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      final visibleIds = <String>[];
      for (final position in _itemPositionsListener.itemPositions.value) {
        if (position.index < 0 || position.index >= _entries.length) continue;
        final entry = _entries[position.index];
        if (entry is _MessageEntry) visibleIds.add(entry.message.id);
      }
      unawaited(ref
          .read(messagesProvider(widget.roomId).notifier)
          .ackSeen(visibleIds));
    });
  }

  /// Topmost currently-visible day, for the sticky overlay pill — "topmost"
  /// meaning the largest visible index, since this list is reverse:true and
  /// increasing index means further up/older. If that's a divider itself
  /// (i.e. it's just been scrolled to), the label already switches to the
  /// next, older day per the requested "until the actual date separator is
  /// found, then start with the next date" behavior.
  String? _stickyDateLabel(Iterable<ItemPosition> positions) {
    if (positions.isEmpty || _entries.isEmpty) return null;
    var topIndex =
        positions.map((p) => p.index).reduce((a, b) => a > b ? a : b);
    topIndex = topIndex.clamp(0, _entries.length - 1);
    var entry = _entries[topIndex];
    if (entry is _DateDividerEntry && topIndex + 1 < _entries.length) {
      entry = _entries[topIndex + 1];
    }
    final day = switch (entry) {
      _DateDividerEntry(:final day) => day,
      _MessageEntry(:final message) => _dayOnly(message.createdAt),
    };
    return formatDateDivider(day);
  }

  double _scrollFraction(Iterable<ItemPosition> positions) {
    if (positions.isEmpty || _entries.length <= 1) return 0;
    final topIndex = positions.map((p) => p.index).reduce((a, b) => a > b ? a : b);
    return (topIndex / (_entries.length - 1)).clamp(0.0, 1.0);
  }

  /// Scrolls back to a message by id, e.g. when a reply quote is tapped
  /// (FR1.10). A silent no-op if it isn't in the currently loaded window
  /// (e.g. it's further back than pagination has fetched) — there's no
  /// stable way to jump to something that isn't loaded yet.
  void _jumpToMessage(String messageId) {
    final index = _entries
        .indexWhere((e) => e is _MessageEntry && e.message.id == messageId);
    if (index == -1 || !_itemScrollController.isAttached) return;
    _itemScrollController.scrollTo(
        index: index,
        duration: const Duration(milliseconds: 300),
        alignment: 0.4);
  }

  void _jumpToBottom() {
    if (!_itemScrollController.isAttached) return;
    _itemScrollController.scrollTo(
        index: 0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.5)),
            ),
          );
        }
        // `messages` is oldest-first; the list itself renders newest-at-
        // bottom via reverse:true, so we walk it newest-first here too.
        final reversed = messages.reversed.toList();
        final currentIds = reversed.map((m) => m.id).toSet();
        _bubbleKeys.removeWhere((id, _) => !currentIds.contains(id));

        // Built once per rebuild rather than derived per-item in
        // itemBuilder, since the day-boundary check needs each message's
        // chronological neighbors and a day divider takes up its own item
        // slot — see _ListEntry's own doc comment for the index contract
        // the scroll-position listeners above depend on.
        final entries = <_ListEntry>[];
        for (var i = 0; i < reversed.length; i++) {
          final message = reversed[i];
          final older =
              i + 1 < reversed.length ? reversed[i + 1] : null;
          final newer = i > 0 ? reversed[i - 1] : null;
          final isFirstInGroup = older == null ||
              older.senderId != message.senderId ||
              !_isSameDay(older.createdAt, message.createdAt);
          final isLastInGroup = newer == null ||
              newer.senderId != message.senderId ||
              !_isSameDay(newer.createdAt, message.createdAt);
          entries.add(_MessageEntry(message,
              isFirstInGroup: isFirstInGroup, isLastInGroup: isLastInGroup));
          if (older == null || !_isSameDay(older.createdAt, message.createdAt)) {
            entries.add(_DateDividerEntry(_dayOnly(message.createdAt)));
          }
        }
        _entries = entries;

        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is ScrollStartNotification ||
                notification is ScrollUpdateNotification) {
              _onScrollActivity();
            }
            return false;
          },
          child: Stack(
            children: [
              ScrollablePositionedList.builder(
                reverse: true,
                itemScrollController: _itemScrollController,
                itemPositionsListener: _itemPositionsListener,
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  if (entry is _DateDividerEntry) {
                    return _DateDividerRow(day: entry.day);
                  }
                  final message = (entry as _MessageEntry).message;
                  final senderName = message.senderId == widget.meId
                      ? 'Me'
                      : (widget.usersById[message.senderId]?.displayName ?? '?');
                  return Padding(
                    padding:
                        EdgeInsets.only(bottom: entry.isLastInGroup ? 28 : 10),
                    child: _MessageRow(
                      key: ValueKey(message.id),
                      bubbleKey: _bubbleKeyFor(message.id),
                      roomId: widget.roomId,
                      isGroup: widget.isGroup,
                      message: message,
                      fromMe: message.senderId == widget.meId,
                      senderName: senderName,
                      isFirstInGroup: entry.isFirstInGroup,
                      isLastInGroup: entry.isLastInGroup,
                      showSenderLabel: widget.isGroup &&
                          message.senderId != widget.meId &&
                          entry.isFirstInGroup,
                      meId: widget.meId,
                      usersById: widget.usersById,
                      onJumpToReply: _jumpToMessage,
                      composerKey: widget.composerKey,
                      isLifted: _liftedMessageId == message.id,
                      onLiftedChange: _setLifted,
                    ),
                  );
                },
              ),
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _scrollActive ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Center(
                      child: ValueListenableBuilder<Iterable<ItemPosition>>(
                        valueListenable: _itemPositionsListener.itemPositions,
                        builder: (context, positions, _) {
                          final label = _stickyDateLabel(positions);
                          if (label == null) return const SizedBox.shrink();
                          return _DatePill(label: label);
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 2,
                top: 8,
                bottom: 8,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _scrollActive ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: ValueListenableBuilder<Iterable<ItemPosition>>(
                      valueListenable: _itemPositionsListener.itemPositions,
                      builder: (context, positions, _) =>
                          _HistoryScrollbar(fraction: _scrollFraction(positions)),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: ValueListenableBuilder<Iterable<ItemPosition>>(
                  valueListenable: _itemPositionsListener.itemPositions,
                  builder: (context, positions, _) {
                    final atBottom = positions.any((p) => p.index == 0);
                    if (atBottom || positions.isEmpty) return const SizedBox.shrink();
                    return _JumpToBottomButton(onPressed: _jumpToBottom);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One row in the rendered (reverse-chronological, dividers-included) list —
/// the shared index contract every scroll-position listener in
/// _MessageListState reads against, since `reversed[index]` alone stopped
/// being true once dividers took up their own slots.
sealed class _ListEntry {
  const _ListEntry();
}

class _MessageEntry extends _ListEntry {
  const _MessageEntry(this.message,
      {required this.isFirstInGroup, required this.isLastInGroup});
  final ApiMessage message;
  final bool isFirstInGroup;
  final bool isLastInGroup;
}

class _DateDividerEntry extends _ListEntry {
  const _DateDividerEntry(this.day);
  final DateTime day;
}

DateTime _dayOnly(DateTime dt) {
  final local = dt.toLocal();
  return DateTime(local.year, local.month, local.day);
}

bool _isSameDay(DateTime a, DateTime b) => _dayOnly(a) == _dayOnly(b);

/// The inline, non-sticky day divider rendered as an ordinary list item —
/// a visual line-break between one day's messages and the next. Extra top
/// margin vs. bottom, as asked, so it reads as closing the day above it
/// more than opening the one below.
class _DateDividerRow extends StatelessWidget {
  const _DateDividerRow({required this.day});
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 8),
      child: Center(
        child: Text(
          formatDateDivider(day),
          style: roostMono(context,
              fontSize: 11.5, color: scheme.onSurface.withValues(alpha: 0.55)),
        ),
      ),
    );
  }
}

/// The floating pill that tracks whichever day is currently scrolled to,
/// shown only while the list is actively being scrolled (see
/// _MessageListState._scrollActive).
class _DatePill extends StatelessWidget {
  const _DatePill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Text(label,
          style: roostMono(context,
              fontSize: 11.5, color: scheme.onSurface.withValues(alpha: 0.75))),
    );
  }
}

/// A minimal history indicator standing in for a native scrollbar —
/// scrollable_positioned_list doesn't provide one. `fraction` is an
/// approximation of how far back through history the visible window is (0 =
/// newest/bottom, 1 = oldest/top loaded), good enough for a visual cue
/// rather than pixel-accurate scroll physics.
class _HistoryScrollbar extends StatelessWidget {
  const _HistoryScrollbar({required this.fraction});
  final double fraction;

  static const _thumbHeight = 36.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxHeight;
        final top = (track - _thumbHeight).clamp(0.0, double.infinity) * fraction;
        return SizedBox(
          width: 4,
          height: track,
          child: Stack(
            children: [
              Positioned(
                top: top,
                child: Container(
                  width: 4,
                  height: _thumbHeight,
                  decoration: BoxDecoration(
                    color: scheme.onSurface.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Jumps back to the newest message — shown only once scrolled away from it.
class _JumpToBottomButton extends StatelessWidget {
  const _JumpToBottomButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 4,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(TablerIcons.arrowDown,
              size: 20, color: scheme.onSurface.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}

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
      child: Icon(icon,
          size: 13, color: onPrimary.withValues(alpha: seen ? 1 : 0.62)),
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
    required this.composerKey,
    required this.isLifted,
    required this.onLiftedChange,
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

  // Owned by _ChatScreenState — lets a long-press find the composer's
  // current on-screen position (moves with the keyboard) so the picker/menu
  // never cover it. See openActions() below.
  final GlobalKey composerKey;

  // Whether this message is currently duplicated into an open action
  // overlay — while true, the real bubble here hides so the lifted copy
  // reads as this one message having moved, not a second copy of it.
  final bool isLifted;
  final void Function(String? messageId) onLiftedChange;

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

    // A photo/video/location map renders edge-to-edge, with no
    // bubble-colored frame around it — but if there's a
    // forwarded/reply/sender-name header above it in the same bubble, its
    // top corners go square (flush against that header) rather than
    // rounded, since it's no longer adjacent to the bubble's own top edge.
    final isFrameless = isMedia || isLocation;
    final hasFramelessHeader = message.forwarded ||
        message.replyTo != null ||
        (isFrameless && showSenderLabel);
    final framelessRadius = hasFramelessHeader
        ? BorderRadius.only(
            bottomLeft: borderRadius.bottomLeft,
            bottomRight: borderRadius.bottomRight)
        : borderRadius;

    final bubbleContent = Container(
      constraints:
          BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.74),
      padding: isFrameless
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
              padding: EdgeInsets.fromLTRB(
                  isFrameless ? 8 : 0, isFrameless ? 6 : 0, isFrameless ? 8 : 0, 2),
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
              padding: EdgeInsets.symmetric(
                  horizontal: isFrameless ? 8 : 0, vertical: isFrameless ? 4 : 0),
              child: ReplyQuoteChip(
                snippet: message.replyTo!,
                senderName: _nameFor(message.replyTo!.senderId),
                tint: fromMe ? scheme.onPrimary : scheme.primary,
                onTap: () => onJumpToReply(message.replyTo!.id),
              ),
            ),
          // Group chats always show who posted a photo/video/location, the
          // same way a group text message already names its sender — never
          // for the viewer's own messages, which need no such label.
          if (isFrameless && showSenderLabel)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              child: Text(
                senderName,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: colorForAvatarSeed(senderName),
                ),
              ),
            ),
          if (isMedia)
            MediaBubbleContent(message: message, borderRadius: framelessRadius)
          else if (isLocation)
            LocationBubbleContent(
                message: message, roomId: roomId, borderRadius: framelessRadius)
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
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: colorForAvatarSeed(senderName),
                  ),
                ),
              ),
            Text.rich(
              TextSpan(
                style: TextStyle(
                    fontSize: 16.5,
                    height: 1.3,
                    color: fromMe ? scheme.onPrimary : scheme.onSurface),
                children: [
                  TextSpan(text: message.body ?? ''),
                  TextSpan(
                    text:
                        '${message.editedAt != null ? ' (edited)' : ''}  $timeLabel',
                    style: roostMono(
                      context,
                      fontSize: 11.5,
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
      width: 34,
      child: (!fromMe && isLastInGroup)
          ? Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InitialAvatar(
                initial:
                    senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                seed: senderName,
                size: 30,
                avatarMediaId: usersById[message.senderId]?.avatarMediaId,
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
    // size. Horizontally too: the badge is flush with the bubble's own edge,
    // not poking past it, for the same reason — anchored to the same side
    // the bubble itself is on (right for the viewer's own messages, left
    // for everyone else's) so multiple reaction chips grow inward from that
    // edge rather than toward the screen's center.
    //
    // Factored into a function rather than a single `bubbleWithReactions`
    // value: openActions() below duplicates the bubble's content into the
    // overlay so it can be lifted to a new position without touching the
    // real list underneath, and that duplicate can't reuse `bubbleKey` —
    // GlobalKeys can't appear twice in the tree at once — so it needs its
    // own, otherwise-identical instance built from unkeyed `bubbleContent`.
    const reactionBadgeProtrusion = 14.0;
    Widget withReactions(Widget bubbleWidget) {
      if (message.reactions.isEmpty) return bubbleWidget;
      return Stack(
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              bubbleWidget,
              const SizedBox(height: reactionBadgeProtrusion)
            ],
          ),
          Positioned(
            bottom: 0,
            right: fromMe ? 0 : null,
            left: fromMe ? null : 0,
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
    }

    final bubble = KeyedSubtree(key: bubbleKey, child: bubbleContent);
    final bubbleWithReactions = withReactions(bubble);

    final actions = _buildActions(context, ref);
    // Shown with a highlighted background in the picker rather than hidden
    // — tapping one still toggles it off via the same onReact below.
    final reactedEmojis = {
      for (final reaction in message.reactions)
        if (reaction.reactedByMe) reaction.emoji,
    };

    // Fully synchronous — no scroll to await — so there's no gap between
    // measuring and using these values for anything to go stale in.
    void openActions() {
      final bubbleBox =
          bubbleKey.currentContext?.findRenderObject() as RenderBox?;
      if (bubbleBox == null || !bubbleBox.attached) return;
      final bubbleRect = bubbleBox.localToGlobal(Offset.zero) & bubbleBox.size;

      // The composer's own current position already reflects the keyboard,
      // open or not — it's measured fresh right here rather than assumed,
      // so this holds either way without any extra keyboard-aware logic.
      final composerBox =
          composerKey.currentContext?.findRenderObject() as RenderBox?;
      final composerTop = (composerBox != null && composerBox.attached)
          ? composerBox.localToGlobal(Offset.zero).dy
          : MediaQuery.of(context).size.height;

      // The picker is always shown now (it always has at least the default
      // quick emoji plus the "+" custom-entry button), so this clearance no
      // longer depends on whether any given message has emoji left to pick.
      const pickerClearance = messageActionPickerHeight + messageActionGap;
      final menuClearance =
          actions.length * messageActionMenuRowHeight + messageActionGap;

      // The message is *displayed* somewhere between these two bounds —
      // never scrolled there, since scrolling moves every other message in
      // the list too. minTop leaves room for the picker above; maxBottom
      // leaves room for the menu below *and* keeps the composer clear.
      const minTop = messageActionScreenMargin + pickerClearance;
      final maxBottom = composerTop - messageActionGap - menuClearance;

      var displayTop = bubbleRect.top;
      if (displayTop + bubbleRect.height > maxBottom) {
        displayTop = maxBottom - bubbleRect.height;
      }
      if (displayTop < minTop) {
        displayTop = minTop;
      }

      onLiftedChange(message.id);
      showMessageActionOverlay(
        context: context,
        originalRect: bubbleRect,
        displayTop: displayTop,
        alignEnd: fromMe,
        bubbleContent: withReactions(bubbleContent),
        selectedEmojis: reactedEmojis,
        onReact: (emoji) => ref
            .read(messagesProvider(roomId).notifier)
            .toggleReaction(message.id, emoji),
        actions: actions,
        onDismissed: () => onLiftedChange(null),
      );
    }

    return Row(
      mainAxisAlignment: align,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (!fromMe) avatarSlot,
        GestureDetector(
          onLongPress: openActions,
          child: Opacity(opacity: isLifted ? 0 : 1, child: bubbleWithReactions),
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
      // FR1.15/FR2.5: any of the caller's own messages except a call record
      // (that's shared call history, not authored content) can be deleted,
      // always behind a confirmation sheet first.
      if (fromMe && !isCall)
        MessageActionItem(
          icon: TablerIcons.trash,
          label: 'Delete',
          isDestructive: true,
          onTap: () async {
            final confirmed =
                await confirmDelete(context, title: 'Delete this message?');
            if (!confirmed || !context.mounted) return;
            final messenger = ScaffoldMessenger.of(context);
            try {
              final notifier = ref.read(messagesProvider(roomId).notifier);
              if (isMedia) {
                await notifier.deleteMedia(message.mediaId!);
              } else {
                await notifier.deleteMessage(message.id);
              }
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
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: chatWallpaperColor(context), width: 1.5),
          boxShadow: ChatBubbleStyle.shadow(Theme.of(context).brightness),
        ),
        child: Text(
          '${reaction.emoji} ${reaction.count}',
          style: TextStyle(
            fontSize: 15,
            fontWeight:
                reaction.reactedByMe ? FontWeight.w700 : FontWeight.w400,
            color: reaction.reactedByMe
                ? ochreColor(context)
                : scheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

class _MessageComposer extends ConsumerStatefulWidget {
  const _MessageComposer({super.key, required this.roomId});
  final String roomId;

  @override
  ConsumerState<_MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends ConsumerState<_MessageComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _sending = false;

  // The "+"/keyboard-toggle attach tray (Photos/Camera/Location), shown in
  // the space the system keyboard would otherwise occupy rather than as a
  // modal sheet — see _toggleAttachTray.
  bool _showAttachTray = false;

  bool _typingSignaled = false;
  DateTime? _lastTypingPing;
  Timer? _typingAutoStop;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // Tapping directly into the field while the tray is open should swap
    // back to the keyboard, the same as tapping the keyboard-toggle icon
    // does — otherwise the tray would just sit there covering the keyboard
    // that focusing the field just brought up underneath it.
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _showAttachTray) {
        setState(() => _showAttachTray = false);
      }
    });
  }

  void _toggleAttachTray() {
    if (_showAttachTray) {
      setState(() => _showAttachTray = false);
      _focusNode.requestFocus();
    } else {
      _focusNode.unfocus();
      setState(() => _showAttachTray = true);
    }
  }

  void _onTextChanged() {
    _notifyTyping(_controller.text.trim().isNotEmpty);
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
    final shouldPing = _lastTypingPing == null ||
        now.difference(_lastTypingPing!) >= const Duration(seconds: 3);
    if (shouldPing) {
      _lastTypingPing = now;
      _typingSignaled = true;
      ref.read(messagesProvider(widget.roomId).notifier).notifyTyping(true);
    }
    _typingAutoStop?.cancel();
    _typingAutoStop =
        Timer(const Duration(seconds: 5), () => _notifyTyping(false));
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
    _focusNode.dispose();
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

  /// Every media-sending entry point (camera capture, a single gallery
  /// pick, and — via [_pickAndSendMultipleMedia] — a multi-select gallery
  /// pick) routes through [MediaCaptionScreen] first (FR2.6): the picker
  /// itself has no way to collect a caption, so this is a review step in
  /// between, same shape as WhatsApp/iMessage's own attach flow. Backing
  /// out of that screen (its "caption" comes back null) cancels the send
  /// entirely — nothing gets uploaded.
  Future<void> _pickAndSendMedia(
      {required bool video, ImageSource source = ImageSource.gallery}) async {
    final picker = ImagePicker();
    final file = video
        ? await picker.pickVideo(source: source)
        : await picker.pickImage(source: source);
    if (file == null) return;

    if (!mounted) return;
    final caption = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            MediaCaptionScreen(media: [PendingMedia(file: file, isVideo: video)]),
      ),
    );
    if (caption == null) return;

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
            caption: caption.isEmpty ? null : caption,
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

  /// The attach tray's "Photos" option: unlike the single-file
  /// _pickAndSendMedia, this lets the gallery picker return more than one
  /// file (images and videos mixed) and sends each in turn. A shared
  /// caption (if any) attaches only to the last file sent, matching
  /// WhatsApp's own multi-select behavior — the whole batch reads as one
  /// captioned share in the chat rather than the same text repeated under
  /// every photo.
  Future<void> _pickAndSendMultipleMedia() async {
    final picked = await ImagePicker().pickMultipleMedia();
    if (picked.isEmpty) return;

    final files = [
      for (final file in picked)
        (
          file: file,
          isVideo: (file.mimeType ?? lookupMimeType(file.path) ?? 'image/jpeg')
              .startsWith('video/'),
        ),
    ];

    if (!mounted) return;
    final caption = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => MediaCaptionScreen(media: [
          for (final f in files) PendingMedia(file: f.file, isVideo: f.isVideo),
        ]),
      ),
    );
    if (caption == null) return;

    setState(() => _sending = true);
    try {
      for (var i = 0; i < files.length; i++) {
        final (file: file, isVideo: isVideo) = files[i];
        final bytes = await file.readAsBytes();
        final contentType =
            file.mimeType ?? lookupMimeType(file.path) ?? 'image/jpeg';
        final isLast = i == files.length - 1;
        await ref.read(messagesProvider(widget.roomId).notifier).sendMedia(
              bytes: bytes,
              filename: file.name,
              contentType: contentType,
              kind: isVideo ? 'video' : 'image',
              caption: (isLast && caption.isNotEmpty) ? caption : null,
            );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not upload: $error')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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
                child: Text('Share your location for…',
                    style: TextStyle(fontWeight: FontWeight.w600)),
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
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not share your location: $error')));
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

    // A soft shadow lifts the composer off the wallpaper behind it — without
    // it the bar was just flat color flush against the message list, with
    // nothing marking it as its own input layer rather than part of the
    // scrollable conversation.
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      elevation: 8,
      shadowColor: Colors.black.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? 0.5 : 0.18),
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
                  // Toggles between "+" (open the attach tray below,
                  // dismissing the keyboard) and a keyboard glyph (close the
                  // tray, bring the keyboard back) — see _toggleAttachTray.
                  IconButton(
                    icon: Icon(
                        _showAttachTray ? TablerIcons.keyboard : TablerIcons.plus,
                        color: scheme.onSurface.withValues(alpha: 0.6)),
                    onPressed: _toggleAttachTray,
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 42),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          // A moderate fixed radius (not a full pill/stadium
                          // shape) so the field reads as a rounded box even
                          // as it grows to several lines tall.
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                              color: scheme.onSurface.withValues(alpha: 0.08)),
                        ),
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          minLines: 1,
                          maxLines: 5,
                          textCapitalization: TextCapitalization.sentences,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: const InputDecoration(
                            hintText: 'Message',
                            isDense: true,
                            border: InputBorder.none,
                            // The app-wide InputDecorationTheme defaults to
                            // filled:true with a *square* fallback fill
                            // shape once the border is InputBorder.none (it
                            // only borrows a radius from an OutlineInputBorder,
                            // which this field doesn't have) — that fill
                            // painted right over this field's own rounded
                            // DecoratedBox background, squaring off what
                            // should have been a pill. This field's fill is
                            // the surrounding DecoratedBox; the field itself
                            // paints none of its own.
                            filled: false,
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Always visible now, on the trailing side — kept even
                  // while composing text, rather than hidden the moment
                  // there's something typed. Jumps straight into the native
                  // camera for a photo — image_picker's camera source is
                  // always locked to one fixed media type per call (no way
                  // to ask for a combined photo/video capture session the
                  // way Apple's own Camera app offers, even though the
                  // underlying UIImagePickerController supports it — the
                  // plugin just never exposes that combination through its
                  // public API), so video and gallery live in the "+"
                  // attach tray instead rather than pretending this one tap
                  // can reach all three.
                  IconButton(
                    icon: Icon(TablerIcons.camera,
                        color: scheme.onSurface.withValues(alpha: 0.6)),
                    onPressed: () =>
                        _pickAndSendMedia(video: false, source: ImageSource.camera),
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
            // Occupies roughly the space the system keyboard would, rather
            // than a modal sheet over it — see _toggleAttachTray's own doc
            // comment for why this needs a real FocusNode instead of just
            // calling FocusScope.of(context).unfocus() ad hoc.
            if (_showAttachTray)
              _AttachTray(
                onPhotos: () {
                  setState(() => _showAttachTray = false);
                  _pickAndSendMultipleMedia();
                },
                onCamera: () {
                  setState(() => _showAttachTray = false);
                  _pickAndSendMedia(video: false, source: ImageSource.camera);
                },
                onVideo: () {
                  setState(() => _showAttachTray = false);
                  _pickAndSendMedia(video: true, source: ImageSource.camera);
                },
                onLocation: () {
                  setState(() => _showAttachTray = false);
                  _showLocationTtlSheet();
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// The composer's "+" attach tray: Photos / Camera / Video / Location, laid
/// out the way the system keyboard's own emoji/suggestions area would be —
/// filling the space the keyboard just vacated rather than a modal sheet on
/// top of it. A fixed height, roughly what a keyboard occupies, rather than
/// sizing to content: this is meant to read as "the keyboard, but for
/// attachments" swapping in and out at a stable size, not a panel that
/// jumps around. Camera and Video are separate options here (rather than
/// one combined "camera" entry point) because image_picker's camera source
/// is always locked to a single fixed media type per call — there's no way
/// to ask for the same combined photo/video capture session Apple's own
/// Camera app offers.
class _AttachTray extends StatelessWidget {
  const _AttachTray({
    required this.onPhotos,
    required this.onCamera,
    required this.onVideo,
    required this.onLocation,
  });

  final VoidCallback onPhotos;
  final VoidCallback onCamera;
  final VoidCallback onVideo;
  final VoidCallback onLocation;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 220,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: 0.04),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      ),
      // Expanded, not spaceEvenly sized to each option's own natural
      // width — four options' combined intrinsic width (icon circle +
      // label) overflowed a typical phone width by a couple dozen
      // pixels; splitting the row evenly instead scales to however many
      // options there are and can't overflow regardless of screen width.
      child: Row(
        children: [
          Expanded(
            child: _AttachOption(
              icon: TablerIcons.photo,
              label: 'Photos',
              color: const Color(0xFF3F7CE0),
              onTap: onPhotos,
            ),
          ),
          Expanded(
            child: _AttachOption(
              icon: TablerIcons.camera,
              label: 'Camera',
              color: scheme.onSurface.withValues(alpha: 0.75),
              onTap: onCamera,
            ),
          ),
          Expanded(
            child: _AttachOption(
              icon: TablerIcons.video,
              label: 'Video',
              color: const Color(0xFFE0673F),
              onTap: onVideo,
            ),
          ),
          Expanded(
            child: _AttachOption(
              icon: TablerIcons.mapPin,
              label: 'Location',
              color: const Color(0xFF2FA97A),
              onTap: onLocation,
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachOption extends StatelessWidget {
  const _AttachOption({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: color,
              child: Icon(icon, color: Colors.white, size: 26),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
