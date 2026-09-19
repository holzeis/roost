import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

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
    required this.quickEmojis,
    required this.onReact,
    required this.actions,
    required this.onClose,
  });

  final Rect anchorRect;
  final bool alignEnd;
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
  static const _menuWidth = 190.0;
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
    final totalHeight = _pillHeight + _gap + menuHeight;
    // Mirrors the same "does it fit above?" check a web build would do with
    // getBoundingClientRect — flip below the bubble when there isn't room.
    final anchorAbove = anchorRect.top > totalHeight + 32;

    final pillTop =
        anchorAbove ? anchorRect.top - _gap - _pillHeight : anchorRect.bottom + _gap;
    final menuTop =
        anchorAbove ? pillTop - _gap - menuHeight : pillTop + _pillHeight + _gap;

    double left = widget.alignEnd ? anchorRect.right - _menuWidth : anchorRect.left;
    left = left.clamp(_screenMargin, screen.width - _menuWidth - _screenMargin);

    final popOrigin = Alignment(widget.alignEnd ? 1.0 : -1.0, anchorAbove ? 1.0 : -1.0);
    final scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack, reverseCurve: Curves.easeIn);
    final fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);

    // The dismiss-on-tap GestureDetector wraps only the scrim, as a Stack
    // sibling to the pill/menu below rather than their ancestor — nesting
    // it around all three would put every InkWell tap on the picker/menu
    // through this GestureDetector's hit-test subtree too.
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _close(),
            child: FadeTransition(
              opacity: fade,
              child: ClipPath(
                clipper: _CutoutClipper(anchorRect.inflate(4), ChatBubbleStyle.radius),
                child: Container(color: Colors.black.withValues(alpha: 0.32)),
              ),
            ),
          ),
        ),
        Positioned(
          left: left,
          top: pillTop,
          child: ScaleTransition(
            scale: scale,
            alignment: popOrigin,
            child: FadeTransition(
              opacity: fade,
              child: _ReactionPicker(
                emojis: widget.quickEmojis,
                onPick: (emoji) => _close(() => widget.onReact(emoji)),
              ),
            ),
          ),
        ),
        Positioned(
          left: left,
          top: menuTop,
          width: _menuWidth,
          child: ScaleTransition(
            scale: scale,
            alignment: popOrigin,
            child: FadeTransition(
              opacity: fade,
              child: _ActionMenu(
                items: widget.actions,
                rowHeight: _menuRowHeight,
                onSelected: (item) => _close(item.onTap),
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
  final Radius holeRadius;

  @override
  Path getClip(Size size) {
    final screen = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()..addRRect(RRect.fromRectAndRadius(holeRect, holeRadius));
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
    return Material(
      color: scheme.surface,
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final item in items)
            InkWell(
              onTap: () => onSelected(item),
              child: SizedBox(
                height: rowHeight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
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
    );
  }
}
