import 'package:flutter/material.dart';

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

  static const _pillHeight = 46.0;
  static const _menuRowHeight = 40.0;
  static const _gap = 8.0;
  static const _screenMargin = 12.0;

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
    final menuHeight = widget.actions.length * _menuRowHeight + 8;
    // A rough estimate, only ever used to decide *which side* of the bubble
    // there's room on — mirrors the "does it fit above?" check a web build
    // would do with getBoundingClientRect. The actual on-screen position
    // below is never computed from this estimate, so a mismatch between it
    // and the real rendered height can't visibly shift anything.
    final estimatedHeight = _pillHeight + _gap + menuHeight;
    final anchorAbove = anchorRect.top > estimatedHeight + 32;

    final scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    final fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    final popOrigin = Alignment(widget.alignEnd ? 1.0 : -1.0, anchorAbove ? 1.0 : -1.0);

    final picker = _ReactionPicker(
      emojis: widget.quickEmojis,
      onPick: (emoji) => _close(() => widget.onReact(emoji)),
    );
    final menu = _ActionMenu(
      items: widget.actions,
      rowHeight: _menuRowHeight,
      onSelected: (item) => _close(item.onTap),
    );

    // One column, not two independently-positioned widgets: the menu and
    // picker share a single cross-axis alignment so their edges always line
    // up with each other, whatever their own intrinsic widths turn out to
    // be — sizing one from the other's fixed width was what let the wider
    // picker sail past the menu's edge (and off the screen) before.
    // Above the bubble the menu reads first (top to bottom: menu, picker,
    // bubble); below it the order flips so the picker still sits closest
    // to the bubble either way.
    final group = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: anchorAbove
          ? [menu, const SizedBox(height: _gap), picker]
          : [picker, const SizedBox(height: _gap), menu],
    );

    // Anchored by `bottom` (above the bubble) or `top` (below it) only —
    // never both — so the Positioned sizes to the column's real, measured
    // height instead of the `estimatedHeight` guess above. Anchoring from
    // an estimated height meant any drift between the guess and the real
    // layout showed up as the whole group appearing to start low and get
    // shoved upward; anchoring from one true edge and letting the other
    // float removes the guess from the position entirely.
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
        Positioned(
          top: anchorAbove ? null : anchorRect.bottom + _gap,
          bottom: anchorAbove ? screen.height - anchorRect.top + _gap : null,
          left: _screenMargin,
          right: _screenMargin,
          child: Align(
            alignment: widget.alignEnd ? Alignment.centerRight : Alignment.centerLeft,
            child: ScaleTransition(
              scale: scale,
              alignment: popOrigin,
              child: FadeTransition(opacity: fade, child: group),
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
