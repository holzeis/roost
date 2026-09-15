import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';
import 'package:video_player/video_player.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';

/// The inline content of an image/video message bubble (FR2.3: viewed
/// inline). Text messages don't go through this — see chat_screen.dart.
class MediaBubbleContent extends ConsumerWidget {
  const MediaBubbleContent({super.key, required this.message});

  final ApiMessage message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(apiClientProvider).mediaUrl(message.mediaId!);
    const box = BoxConstraints(maxWidth: 220, maxHeight: 220);

    if (message.kind == 'video') {
      return GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => VideoPlayerScreen(url: url)),
        ),
        child: ConstrainedBox(
          constraints: box,
          child: AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: const ColoredBox(
                color: Colors.black87,
                child: Center(
                  child: Icon(TablerIcons.playerPlayFilled, color: Colors.white, size: 40),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return ConstrainedBox(
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
    );
  }
}

/// Saves a media object's bytes into the app's documents directory and
/// reports where. There's no native "save to Photos" integration here —
/// that needs platform permissions this bootstrap doesn't wire up yet — but
/// this does give FR2.3's "downloaded" a real, verifiable effect.
Future<String> downloadMediaToDisk(WidgetRef ref, String mediaId, String suggestedName) async {
  final bytes = await ref.read(apiClientProvider).downloadMedia(mediaId);
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/$suggestedName');
  await file.writeAsBytes(bytes);
  return file.path;
}

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key, required this.url});
  final String url;

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _controller;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() => _ready = true);
        _controller.play();
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: Center(
        child: _ready
            ? AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: VideoPlayer(_controller),
              )
            : const CircularProgressIndicator(),
      ),
      floatingActionButton: _ready
          ? FloatingActionButton(
              onPressed: () => setState(() {
                _controller.value.isPlaying ? _controller.pause() : _controller.play();
              }),
              child: Icon(_controller.value.isPlaying ? Icons.pause : TablerIcons.playerPlay),
            )
          : null,
    );
  }
}
