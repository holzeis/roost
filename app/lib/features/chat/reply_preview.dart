import 'package:flutter/material.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';

/// A one-line label for a message when it's quoted rather than shown in
/// full — used by both the reply quote on a bubble and the composer's
/// draft bar.
String messagePreviewLabel(ApiMessage message) {
  switch (message.kind) {
    case 'image':
      return 'Photo';
    case 'video':
      return 'Video';
    case 'location':
      return 'Location';
    default:
      return message.body ?? '';
  }
}

/// The quoted-original strip shown inside a reply bubble (FR1.10). Tapping
/// it scrolls the list back to the original message.
class ReplyQuoteChip extends StatelessWidget {
  const ReplyQuoteChip({
    super.key,
    required this.snippet,
    required this.senderName,
    required this.onTap,
    required this.tint,
  });

  final ApiMessageSnippet snippet;
  final String senderName;
  final VoidCallback onTap;

  /// The text/accent color to use, chosen by the caller so it reads
  /// correctly against either bubble color (own vs. others').
  final Color tint;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: tint.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: tint, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(senderName,
                style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: tint)),
            Text(
              messagePreviewLabel(ApiMessage(
                id: snippet.id,
                roomId: '',
                senderId: snippet.senderId,
                kind: snippet.kind,
                body: snippet.body,
                createdAt: DateTime.now(),
              )),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: tint.withOpacity(0.85)),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bar shown above the composer while replying to or editing a message
/// (FR1.10/FR1.13), with a way to back out of it.
class ComposerDraftBar extends StatelessWidget {
  const ComposerDraftBar(
      {super.key,
      required this.draft,
      required this.senderName,
      required this.onDiscard});

  final ComposerDraft draft;
  final String senderName;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isEdit = draft is EditDraft;
    final label = isEdit ? 'Editing message' : 'Replying to $senderName';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border:
            Border(top: BorderSide(color: scheme.onSurface.withOpacity(0.08))),
      ),
      child: Row(
        children: [
          Container(
              width: 3,
              height: 30,
              color: scheme.primary,
              margin: const EdgeInsets.only(right: 8)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.primary)),
                Text(
                  messagePreviewLabel(draft.message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12.5, color: scheme.onSurface.withOpacity(0.7)),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close,
                size: 18, color: scheme.onSurface.withOpacity(0.6)),
            onPressed: onDiscard,
          ),
        ],
      ),
    );
  }
}
