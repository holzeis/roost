import 'package:flutter/material.dart';

/// Layout constants shared with callers that need to reserve enough on-screen
/// space *before* opening this overlay (chat_screen.dart scrolls the target
/// message into view first if it wouldn't otherwise fit) — kept in sync with
/// the actual widget sizes below rather than re-guessed at the call site.
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
/// [anchorKey] must already be attached to the bubble widget itself (not
/// the row containing its avatar) — its current [RenderBox] is read once,
/// at the moment this is called, to know where on screen to open the menu.
/// The bubble isn't duplicated into the overlay: a translucent scrim is
/// painted with a rounded-rect cutout matching the bubble's own bounds, so
/// the real bubble — already in the message list, one layer down — shows
/// through undimmed instead of needing a snapshot or a second copy of it.
void showMessageActionOverlay({
  required BuildContext context,
  required GlobalKey anchorKey,
  required bool alignEnd,
  required BorderRadius bubbleBorderRadius,
  required List<String> quickEmojis,
  required void Function(String emoji) onReact,
  required List<MessageActionItem> actions,
}) {
  final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return;
  final anchorRect = box.localToGlobal(Offset.zero) & box.size;

  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) => _MessageActionContent(
      anchorRect: anchorRect,
      alignEnd: alignEnd,
      bubbleBorderRadius: bubbleBorderRadius,
      quickEmojis: quickEmojis,
      onReact: onReact,
      actions: actions,
      onClose: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _MessageActionContent extends StatefulWidget {
  const _MessageActionContent({
    required this.anchorRect,
    required this.alignEnd,
    required this.bubbleBorderRadius,
    required this.quickEmojis,
    required this.onReact,
    required this.actions,
    required this.onClose,
  });

  final Rect anchorRect;
  final bool alignEnd;
  final BorderRadius bubbleBorderRadius;
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
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 140),
  )..forward();

  Future<void> _close([VoidCallback? then]) async {
    await _controller.reverse();
    then?.call();
    if (mounted) widget.onClose();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final anchorRect = widget.anchorRect;
    final screen = MediaQuery.of(context).size;

    final scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    final fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final crossAlign = widget.alignEnd ? Alignment.centerRight : Alignment.centerLeft;
    // Each piece scales in from the edge nearest the bubble it's anchored
    // to — the picker (above) from its own bottom, the menu (below) from
    // its own top — rather than sharing one origin now that they're no
    // longer adjacent siblings in one column.
    final pickerOrigin = Alignment(widget.alignEnd ? 1.0 : -1.0, 1.0);
    final menuOrigin = Alignment(widget.alignEnd ? 1.0 : -1.0, -1.0);

    // The picker is always above the bubble and the menu always below it —
    // chat_screen.dart scrolls the message into a position with room for
    // both before this ever opens, so there's no "does it fit above?"
    // fallback here, and no clamp pulling either one back toward the bubble
    // to stay on screen: a clamp here previously won out over an
    // insufficient scroll instead of just landing a bit further off-screen,
    // and the opaque menu card painting over part of the "undimmed" cutout
    // it had been pulled into read as a dirty seam across the bubble as
    // much as it read as literal overlap. Each is anchored by exactly one
    // edge (`bottom` for the picker, `top` for the menu) so it grows away
    // from that fixed line using its own real, measured height instead of a
    // guessed one.
    final menuTop = anchorRect.bottom + messageActionGap;
    final pickerBottom = screen.height - anchorRect.top + messageActionGap;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _close(),
            child: FadeTransition(
              opacity: fade,
              child: ClipPath(
                clipper: _CutoutClipper(anchorRect, widget.bubbleBorderRadius),
                child: Container(color: Colors.black.withValues(alpha: 0.32)),
              ),
            ),
          ),
        ),
        if (widget.quickEmojis.isNotEmpty)
          Positioned(
            bottom: pickerBottom,
            left: messageActionScreenMargin,
            right: messageActionScreenMargin,
            child: Align(
              alignment: crossAlign,
              child: ScaleTransition(
                scale: scale,
                alignment: pickerOrigin,
                child: FadeTransition(
                  opacity: fade,
                  child: _ReactionPicker(
                    emojis: widget.quickEmojis,
                    onPick: (emoji) => _close(() => widget.onReact(emoji)),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          top: menuTop,
          left: messageActionScreenMargin,
          right: messageActionScreenMargin,
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
    );
  }
}

class _CutoutClipper extends CustomClipper<Path> {
  _CutoutClipper(this.holeRect, this.holeRadius);

  final Rect holeRect;
  final BorderRadius holeRadius;

  @override
  Path getClip(Size size) {
    final screen = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    // Matches the bubble's own per-corner radius (its tail corner is much
    // sharper than the rest) rather than a uniform radius — a uniform hole
    // left a sliver of scrim showing at the tail corner, reading as a dirty
    // smudge right on the bubble it was supposed to be highlighting.
    final hole = Path()..addRRect(holeRadius.toRRect(holeRect));
    return Path.combine(PathOperation.difference, screen, hole);
  }

  @override
  bool shouldReclip(covariant _CutoutClipper oldClipper) =>
      oldClipper.holeRect != holeRect || oldClipper.holeRadius != holeRadius;
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
  const _ActionMenu({required this.items, required this.rowHeight, required this.onSelected});

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
                          color: item.isDestructive ? scheme.error : scheme.onSurface.withValues(alpha: 0.75),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          item.label,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: item.isDestructive ? scheme.error : scheme.onSurface,
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
