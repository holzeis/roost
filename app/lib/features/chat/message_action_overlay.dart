import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// Layout constants shared with callers that need to reserve enough on-screen
/// space when deciding where to display a message (chat_screen.dart's
/// openActions computes that before this ever opens) — kept in sync with the
/// actual widget sizes below rather than re-guessed at the call site.
const messageActionGap = 8.0;
const messageActionPickerHeight = 46.0;
const messageActionMenuRowHeight = 40.0;
const messageActionScreenMargin = 12.0;

/// One row in the action menu (Reply, Forward, Copy, ...). Kept as plain
/// data so the caller decides which actions apply to a given message —
/// this widget only knows how to lay a list of them out.
class MessageActionItem {
  const MessageActionItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool isDestructive;
}

/// Replaces a full-width bottom sheet with a reaction row and action menu
/// anchored directly to the message that was pressed — the same shape
/// iMessage/WhatsApp/Telegram all converged on, instead of a sheet that
/// could belong to any message in the conversation.
///
/// Built on [Overlay]/[OverlayEntry] rather than a pushed [Route]:
/// go_router owns this app's Navigator, and imperatively pushing a raw
/// route onto a router-managed Navigator can leave the router's own
/// picture of "what's active" out of sync with the Navigator's actual
/// stack once popped — the chat screen kept rendering fine afterward but
/// silently stopped receiving taps. `Overlay.insert` sits above routing
/// entirely and never touches it.
///
/// The message itself is *duplicated* here rather than scrolled into place:
/// [bubbleContent] is the same widget the real message list renders (minus
/// its `GlobalKey`, which can't appear twice in the tree at once), shown at
/// [displayTop] while the real one sits dimmed, untouched, at its actual
/// scroll position underneath — scrolling the list to make room instead
/// would have moved every other message too, and fighting a `reverse: true`
/// list's scroll semantics to do it precisely was its own rabbit hole.
/// [originalRect] (the bubble's real, current on-screen bounds) is where
/// the duplicate animates from/back to, so opening and closing this reads as
/// the one message lifting into place and settling back, not a popup
/// appearing over it. [displayTop] is already computed by the caller to
/// leave room for the picker above and the menu below without covering the
/// composer — this widget just renders at the position it's given.
void showMessageActionOverlay({
  required BuildContext context,
  required Rect originalRect,
  required double displayTop,
  required bool alignEnd,
  required Widget bubbleContent,
  required List<String> quickEmojis,
  required void Function(String emoji) onReact,
  required List<MessageActionItem> actions,
  required VoidCallback onDismissed,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _MessageActionContent(
      originalRect: originalRect,
      displayTop: displayTop,
      alignEnd: alignEnd,
      bubbleContent: bubbleContent,
      quickEmojis: quickEmojis,
      onReact: onReact,
      actions: actions,
      onClose: () {
        entry.remove();
        onDismissed();
      },
    ),
  );
  overlay.insert(entry);
}

class _MessageActionContent extends StatefulWidget {
  const _MessageActionContent({
    required this.originalRect,
    required this.displayTop,
    required this.alignEnd,
    required this.bubbleContent,
    required this.quickEmojis,
    required this.onReact,
    required this.actions,
    required this.onClose,
  });

  final Rect originalRect;
  final double displayTop;
  final bool alignEnd;
  final Widget bubbleContent;
  final List<String> quickEmojis;
  final void Function(String emoji) onReact;
  final List<MessageActionItem> actions;
  final VoidCallback onClose;

  @override
  State<_MessageActionContent> createState() => _MessageActionContentState();
}

class _MessageActionContentState extends State<_MessageActionContent>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 180),
  )..forward();

  Future<void> _close([VoidCallback? then]) async {
    await _controller.reverse();
    then?.call();
    // Removes the overlay entry *and* tells the caller to un-hide the real
    // bubble (see chat_screen.dart's isLifted) — done together so the real
    // one only reappears once this duplicate is already gone, not before.
    if (mounted) widget.onClose();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final originalRect = widget.originalRect;
    final screen = MediaQuery.of(context).size;

    final fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final scale = CurvedAnimation(
        parent: _controller,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeIn);
    final lift =
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    final bubbleScale = Tween<double>(begin: 1.0, end: 1.035)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    final crossAlign =
        widget.alignEnd ? Alignment.centerRight : Alignment.centerLeft;
    final pickerOrigin = Alignment(widget.alignEnd ? 1.0 : -1.0, 1.0);
    final menuOrigin = Alignment(widget.alignEnd ? 1.0 : -1.0, -1.0);

    final menuTop = widget.displayTop + originalRect.height + messageActionGap;
    final pickerBottom = screen.height - widget.displayTop + messageActionGap;
    // The picker/menu anchor to the bubble's own edge — not a fixed screen
    // margin on both sides — so a short bubble (e.g. one with an avatar
    // before it) doesn't leave them hanging out past where the bubble
    // itself actually starts or ends. The margin still applies on the
    // *other* side, purely as an overflow guard.
    final horizontalLeft =
        widget.alignEnd ? messageActionScreenMargin : originalRect.left;
    final horizontalRight = widget.alignEnd
        ? screen.width - originalRect.right
        : messageActionScreenMargin;

    return AnimatedBuilder(
      animation: lift,
      builder: (context, child) {
        // Slides between the bubble's real position and its displayed one —
        // a no-op lerp (and so no visible motion) when they're already the
        // same, which is the common case of a message that already had
        // enough room.
        final top =
            lerpDouble(originalRect.top, widget.displayTop, lift.value)!;
        // The root overlay sits alongside the current route's own Scaffold,
        // not underneath it, so nothing here inherits a Material ancestor
        // from the chat screen — the duplicated bubble's reaction chips
        // (InkWells) need one of their own to paint/build at all.
        // `transparency` provides that without painting anything itself.
        return Material(
          type: MaterialType.transparency,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _close(),
                  child: FadeTransition(
                    opacity: fade,
                    child:
                        Container(color: Colors.black.withValues(alpha: 0.32)),
                  ),
                ),
              ),
              // The real bubble stays exactly where it is in the list
              // underneath, but hidden for as long as this is open (see
              // chat_screen.dart's isLifted) — without that, it would still
              // show through here, dimmed by the scrim, right next to this
              // undimmed duplicate, reading as two copies of one message
              // rather than the one message having moved.
              Positioned(
                left: originalRect.left,
                top: top,
                width: originalRect.width,
                child: GestureDetector(
                  onTap: () => _close(),
                  child: ScaleTransition(
                    scale: bubbleScale,
                    // Anchored to the bubble's own outer edge (the one
                    // flush with its sender's side), not its center — a
                    // centered scale would grow past that edge too, subtly
                    // breaking the left/right alignment the popup above and
                    // menu below are otherwise careful to preserve. This
                    // keeps that edge fixed and only grows toward the
                    // middle of the chat.
                    alignment: crossAlign,
                    child: IgnorePointer(child: widget.bubbleContent),
                  ),
                ),
              ),
              if (widget.quickEmojis.isNotEmpty)
                Positioned(
                  bottom: pickerBottom,
                  left: horizontalLeft,
                  right: horizontalRight,
                  child: Align(
                    alignment: crossAlign,
                    child: ScaleTransition(
                      scale: scale,
                      alignment: pickerOrigin,
                      child: FadeTransition(
                        opacity: fade,
                        child: _ReactionPicker(
                          emojis: widget.quickEmojis,
                          onPick: (emoji) =>
                              _close(() => widget.onReact(emoji)),
                        ),
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: menuTop,
                left: horizontalLeft,
                right: horizontalRight,
                child: Align(
                  alignment: crossAlign,
                  child: ScaleTransition(
                    scale: scale,
                    alignment: menuOrigin,
                    child: FadeTransition(
                      opacity: fade,
                      child: _ActionMenu(
                        items: widget.actions,
                        rowHeight: messageActionMenuRowHeight,
                        onSelected: (item) => _close(item.onTap),
                      ),
                    ),
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

class _ReactionPicker extends StatelessWidget {
  const _ReactionPicker({required this.emojis, required this.onPick});

  final List<String> emojis;
  final void Function(String emoji) onPick;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in emojis)
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => onPick(emoji),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Text(emoji, style: const TextStyle(fontSize: 22)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionMenu extends StatelessWidget {
  const _ActionMenu(
      {required this.items, required this.rowHeight, required this.onSelected});

  final List<MessageActionItem> items;
  final double rowHeight;
  final void Function(MessageActionItem item) onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // IntrinsicWidth first sizes this to its content's true natural width
    // (the widest label row) rather than the wide, loose box the enclosing
    // Positioned offers — `stretch` alone would fill *that* box, since
    // stretch matches children to the incoming constraint, not to each
    // other's natural size. With a genuinely content-sized box established,
    // `stretch` then makes every row match the widest one, so the menu
    // reads as one clean card instead of ragged or full-screen-wide rows.
    return IntrinsicWidth(
      child: Material(
        color: scheme.surface,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              InkWell(
                onTap: () => onSelected(item),
                child: SizedBox(
                  height: rowHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.icon,
                          size: 17,
                          color: item.isDestructive
                              ? scheme.error
                              : scheme.onSurface.withValues(alpha: 0.75),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: item.isDestructive
                                ? scheme.error
                                : scheme.onSurface,
                          ),
                        ),
                      ],
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
