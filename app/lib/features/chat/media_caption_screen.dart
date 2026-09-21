import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';
import 'package:video_player/video_player.dart';

/// One file queued for sending, paired with whether it's a video (decided
/// by the caller from its content type) — this screen only needs that much
/// to pick the right preview and hand the same flag back with the caption.
class PendingMedia {
  const PendingMedia({required this.file, required this.isVideo});
  final XFile file;
  final bool isVideo;
}

/// Shown after picking one or more photos/videos, before uploading (FR2.6):
/// a preview of what's about to be sent with a place to type an optional
/// caption, the same "review, then send" step WhatsApp/iMessage's own
/// attach flow uses. Pops with the typed caption (possibly empty) if the
/// viewer taps send, or null if they back out instead — the caller decides
/// what "cancelled" means (nothing gets uploaded either way).
class MediaCaptionScreen extends StatefulWidget {
  const MediaCaptionScreen({super.key, required this.media});
  final List<PendingMedia> media;

  @override
  State<MediaCaptionScreen> createState() => _MediaCaptionScreenState();
}

class _MediaCaptionScreenState extends State<MediaCaptionScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final single = widget.media.length == 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: single
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: _MediaThumb(media: widget.media.first, size: null),
                        ),
                      )
                    : ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.all(16),
                        itemCount: widget.media.length,
                        separatorBuilder: (context, index) => const SizedBox(width: 8),
                        itemBuilder: (context, index) => ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 110,
                            child: _MediaThumb(media: widget.media[index], size: 110),
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: false,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Add a caption',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.12),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: scheme.primary,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white),
                      onPressed: () =>
                          Navigator.of(context).pop(_controller.text.trim()),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MediaThumb extends StatelessWidget {
  const _MediaThumb({required this.media, required this.size});
  final PendingMedia media;
  // Fixed width/height for the multi-item strip; null lets the single-item
  // preview size itself to the image's own aspect ratio instead of being
  // forced square.
  final double? size;

  @override
  Widget build(BuildContext context) {
    if (media.isVideo) {
      return SizedBox(
        width: size,
        height: size,
        child: _LocalVideoThumb(path: media.file.path),
      );
    }
    return Image.file(
      File(media.file.path),
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }
}

/// A real first-frame thumbnail for a locally-picked video, rather than a
/// plain black box — same idiom as media_message.dart's own _VideoThumbnail
/// (which does the same for an already-uploaded video's network URL), just
/// pointed at a local file since nothing's been uploaded yet at this point.
class _LocalVideoThumb extends StatefulWidget {
  const _LocalVideoThumb({required this.path});
  final String path;

  @override
  State<_LocalVideoThumb> createState() => _LocalVideoThumbState();
}

class _LocalVideoThumbState extends State<_LocalVideoThumb> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.file(File(widget.path))
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
              ),
            ),
          const Icon(TablerIcons.playerPlay, color: Colors.white, size: 28),
        ],
      ),
    );
  }
}
