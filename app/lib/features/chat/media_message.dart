import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../theme/app_theme.dart';

/// The inline content of an image/video message bubble (FR2.3: viewed
/// inline). Text messages don't go through this — see chat_screen.dart.
/// Tapping either kind opens the full-screen viewer (media_viewer_screen.dart)
/// rather than a kind-specific route, so photos and videos share one
/// gallery/react/reply/share experience. Renders edge-to-edge — no padding
/// or bubble-colored frame around the photo/video itself — with corners
/// matching whichever of the bubble's own corners it's actually adjacent
/// to, per chat_screen.dart's own computation of `borderRadius` (square on
/// any edge that has a forwarded/reply/sender-name header above it instead).
class MediaBubbleContent extends ConsumerWidget {
  const MediaBubbleContent({
    super.key,
    required this.message,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  final ApiMessage message;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    // Media gets its own (wider) cap than a text bubble — see
    // ChatBubbleStyle.mediaMaxWidth — so photos/videos fill more of the row
    // instead of looking cramped next to a long message.
    final maxWidth = ChatBubbleStyle.mediaMaxWidth(context);
    final box = BoxConstraints(maxWidth: maxWidth, maxHeight: maxWidth);
    void openViewer() =>
        context.push('/chat/${message.roomId}/media/${message.id}');

    if (message.kind == 'video') {
      return GestureDetector(
        onTap: openViewer,
        child: ConstrainedBox(
          constraints: box,
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: borderRadius,
              child: _VideoThumbnail(url: api.mediaUrl(message.mediaId!)),
            ),
          ),
        ),
      );
    }

    // FR2.*: the server captures a photo's real pixel dimensions at upload
    // (message.media) — reserving the exact aspect ratio the image will
    // render at *before* it has even started downloading is what actually
    // fixes the bubble resizing/jumping once it loads, not just a loading
    // spinner. Falls back to square for a message uploaded before this
    // existed, or an image format the server couldn't decode (WebP/HEIC).
    final media = message.media;
    final aspectRatio = media != null ? media.width / media.height : 1.0;

    return GestureDetector(
      onTap: openViewer,
      child: ConstrainedBox(
        constraints: box,
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: ClipRRect(
            borderRadius: borderRadius,
            // The smaller, lower-quality preview — same dimensions, far
            // less data to fetch — since this is only ever a thumbnail-size
            // rendering; the full-screen viewer (media_viewer_screen.dart)
            // fetches the real, untouched original via mediaUrl instead.
            child: Image.network(
              api.mediaPreviewUrl(message.mediaId!),
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                // No fixed size here — it already fills whatever box the
                // AspectRatio above reserved, so there's nothing left to
                // jump between "loading" and "loaded".
                return const Center(child: CircularProgressIndicator(strokeWidth: 2));
              },
              errorBuilder: (context, error, stack) =>
                  const Center(child: Icon(TablerIcons.photoOff)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A real first-frame thumbnail for a video bubble, rather than a plain
/// black box — initializes a controller just far enough to have a decoded
/// frame, never plays it. Falls back to a black box while loading/on error,
/// same as before this existed.
class _VideoThumbnail extends StatefulWidget {
  const _VideoThumbnail({required this.url});
  final String url;

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() => _ready = true);
      }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black87,
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          if (_ready)
            FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _controller.value.size.width,
                  height: _controller.value.size.height,
                  child: VideoPlayer(_controller),
                )),
          const Icon(TablerIcons.playerPlayFilled,
              color: Colors.white, size: 40),
        ],
      ),
    );
  }
}

/// Downloads a media object's bytes to a real file in the app's documents
/// directory and reports where. Used both for FR2.3's "downloaded" and, by
/// media_viewer_screen.dart, as the file handed to the native share sheet
/// or the device's photo gallery.
Future<String> downloadMediaToDisk(
    WidgetRef ref, String mediaId, String suggestedName) async {
  final bytes = await ref.read(apiClientProvider).downloadMedia(mediaId);
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$suggestedName');
  await file.writeAsBytes(bytes);
  return file.path;
}
