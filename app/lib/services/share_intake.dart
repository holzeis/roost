import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:mime/mime.dart';
import 'package:share_handler/share_handler.dart';

import '../features/chat/media_caption_screen.dart';
import '../router/app_router.dart';
import 'share_suggestions.dart';

/// Photos/videos shared into Roost from another app, waiting to be sent.
/// [roomId] is set when the user picked a Roost chat directly in the system
/// share sheet (a suggestion from ShareSuggestions), null when they picked
/// Roost itself and still need to choose a chat.
class PendingShare {
  const PendingShare({required this.media, this.roomId});

  final List<PendingMedia> media;
  final String? roomId;
}

/// The photos and videos in [shared], or null when it holds none (Roost only
/// accepts those; the share extension and intent filters are limited to
/// them, but other content could still arrive, e.g. via AirDrop).
PendingShare? pendingShareFrom(SharedMedia shared) {
  final media = <PendingMedia>[
    for (final attachment in shared.attachments ?? const <SharedAttachment?>[])
      if (attachment != null &&
          (attachment.type == SharedAttachmentType.image || attachment.type == SharedAttachmentType.video))
        PendingMedia(
          file: XFile(attachment.path, mimeType: lookupMimeType(attachment.path)),
          isVideo: attachment.type == SharedAttachmentType.video,
        ),
  ];
  if (media.isEmpty) return null;
  final roomId = shared.conversationIdentifier;
  return PendingShare(media: media, roomId: (roomId == null || roomId.isEmpty) ? null : roomId);
}

/// Where a share is taken once it arrives — the "Share to…" screen.
/// Overridable so tests can observe it without a real router.
final shareNavigatorProvider = Provider<void Function(PendingShare share)>(
  (ref) => (share) => appRouter.push('/share', extra: share),
);

/// Receives photos/videos shared into Roost from other apps (the iOS share
/// extension in ios/ShareExtension/, Android's share intent filters): the
/// one that launched the app, and any arriving while it runs.
class ShareIntake {
  ShareIntake(this._ref);

  final Ref _ref;
  StreamSubscription<SharedMedia>? _sub;

  Future<void> start() async {
    final handler = _ref.read(shareHandlerProvider);
    try {
      _sub = handler.sharedMediaStream.listen(_handle);
      final initial = await handler.getInitialSharedMedia();
      if (initial != null) {
        // Consumed: a later restart of the app scope mustn't replay it.
        await handler.resetInitialSharedMedia();
        _handle(initial);
      }
    } catch (_) {
      // No share plugin here (e.g. `flutter test`): nothing can arrive.
    }
  }

  void _handle(SharedMedia shared) {
    final share = pendingShareFrom(shared);
    if (share != null) _ref.read(shareNavigatorProvider)(share);
  }

  void dispose() => unawaited(_sub?.cancel());
}

final shareIntakeProvider = Provider<ShareIntake>((ref) {
  final intake = ShareIntake(ref);
  ref.onDispose(intake.dispose);
  return intake;
});
