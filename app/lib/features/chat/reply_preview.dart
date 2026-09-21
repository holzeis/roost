import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';

/// A one-line label for a message when it's quoted rather than shown in
/// full — used by both the reply quote on a bubble and the composer's
/// draft bar. A photo/video's own caption (if it has one) takes priority
/// over the generic "Photo"/"Video" fallback, the same way a text message's
/// own body already does.
String messagePreviewLabel(ApiMessage message) {
  switch (message.kind) {
    case 'image':
      return (message.body?.isNotEmpty ?? false) ? message.body! : 'Photo';
    case 'video':
      return (message.body?.isNotEmpty ?? false) ? message.body! : 'Video';
    case 'location':
      return 'Location';
    default:
      return message.body ?? '';
  }
}

/// A small icon marking what kind of message is being quoted — shown ahead
/// of [messagePreviewLabel]'s text, the same way WhatsApp's own reply quote
/// and draft bar do.
IconData? _previewIcon(String kind) => switch (kind) {
      'image' => TablerIcons.camera,
      'video' => TablerIcons.video,
      'location' => TablerIcons.mapPin,
      _ => null,
    };

/// The small square preview shown alongside a quoted photo/video, cropped
/// to match rather than showing the image's own aspect ratio.
class _QuoteThumbnail extends ConsumerWidget {
  const _QuoteThumbnail({required this.mediaId, required this.tint});

  final String mediaId;
  final Color tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        ref.watch(apiClientProvider).mediaUrl(mediaId),
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return Container(
            width: 40,
            height: 40,
            color: tint.withValues(alpha: 0.1),
          );
        },
        errorBuilder: (context, error, stack) => Container(
          width: 40,
          height: 40,
          color: tint.withValues(alpha: 0.15),
          child: Icon(TablerIcons.photoOff, size: 18, color: tint),
        ),
      ),
    );
  }
}

/// The quoted-original strip shown inside a reply bubble (FR1.10). Tapping
/// it scrolls the list back to the original message. A photo/video's own
/// thumbnail sits at the trailing edge, matching WhatsApp's own reply quote.
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
    final icon = _previewIcon(snippet.kind);
    final label = messagePreviewLabel(ApiMessage(
      id: snippet.id,
      roomId: '',
      senderId: snippet.senderId,
      kind: snippet.kind,
      body: snippet.body,
      createdAt: DateTime.now(),
    ));
    final isMedia = snippet.kind == 'image' || snippet.kind == 'video';

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: tint, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(senderName,
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700, color: tint)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icon != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(icon, size: 14, color: tint.withValues(alpha: 0.85)),
                        ),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12.5, color: tint.withValues(alpha: 0.85)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isMedia && snippet.mediaId != null) ...[
              const SizedBox(width: 8),
              _QuoteThumbnail(mediaId: snippet.mediaId!, tint: tint),
            ],
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
    final message = draft.message;
    final icon = _previewIcon(message.kind);
    final isMedia = message.kind == 'image' || message.kind == 'video';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border:
            Border(top: BorderSide(color: scheme.onSurface.withValues(alpha: 0.08))),
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(icon,
                            size: 14, color: scheme.onSurface.withValues(alpha: 0.6)),
                      ),
                    Flexible(
                      child: Text(
                        messagePreviewLabel(message),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5, color: scheme.onSurface.withValues(alpha: 0.7)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (isMedia && message.mediaId != null) ...[
            const SizedBox(width: 8),
            _QuoteThumbnail(mediaId: message.mediaId!, tint: scheme.primary),
          ],
          IconButton(
            icon: Icon(Icons.close,
                size: 18, color: scheme.onSurface.withValues(alpha: 0.6)),
            onPressed: onDiscard,
          ),
        ],
      ),
    );
  }
}
