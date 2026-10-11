import 'package:mime/mime.dart';

import '../../providers/chat_providers.dart';
import 'media_caption_screen.dart';

/// Uploads [media] to [messages]' room in order, as reviewed on
/// MediaCaptionScreen; each shows in the chat as sending straight away (see
/// MessagesController.sendMediaBatch). A caption (if any) attaches only to
/// the last file, matching WhatsApp's multi-select behavior: the batch
/// reads as one captioned share rather than the same text under every
/// photo. Shared by the chat's own photo picker and sharing into Roost from
/// another app.
Future<void> sendPendingMedia(MessagesController messages, List<PendingMedia> media, String caption) async {
  final items = <MediaToSend>[];
  for (var i = 0; i < media.length; i++) {
    final item = media[i];
    final isLast = i == media.length - 1;
    items.add((
      bytes: await item.file.readAsBytes(),
      filename: item.file.name,
      contentType: item.file.mimeType ??
          lookupMimeType(item.file.path) ??
          (item.isVideo ? 'video/mp4' : 'image/jpeg'),
      kind: item.isVideo ? 'video' : 'image',
      caption: (isLast && caption.isNotEmpty) ? caption : null,
      replyToMessageId: null,
    ));
  }
  await messages.sendMediaBatch(items);
}
