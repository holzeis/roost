import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';

/// The inline content of an image/video message bubble (FR2.3: viewed
/// inline). Text messages don't go through this — see chat_screen.dart.
/// Tapping either kind opens the full-screen viewer (media_viewer_screen.dart)
/// rather than a kind-specific route, so photos and videos share one
/// gallery/react/reply/share experience.
class MediaBubbleContent extends ConsumerWidget {
  const MediaBubbleContent({super.key, required this.message});

  final ApiMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(apiClientProvider).mediaUrl(message.mediaId!);
    const box = BoxConstraints(maxWidth: 220, maxHeight: 220);
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
              borderRadius: BorderRadius.circular(6),
              child: _VideoThumbnail(url: url),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: openViewer,
      child: ConstrainedBox(
        constraints: box,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(
            url,
            fit: BoxFit.cover,
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return const SizedBox(
                width: 120,
                height: 120,
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            },
            errorBuilder: (context, error, stack) => const SizedBox(
              width: 120,
              height: 120,
              child: Center(child: Icon(TablerIcons.photoOff)),
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
