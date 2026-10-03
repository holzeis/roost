import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../../providers/chat_providers.dart';
import '../../providers/image_cache_provider.dart';
import '../../widgets/back_button.dart';

/// Where a profile picture opens full screen.
String avatarViewerRoute(String mediaId, String name) =>
    Uri(path: '/avatar/$mediaId', queryParameters: {'name': name}).toString();

/// A profile picture full screen, opened by tapping someone's avatar (or
/// your own on the profile screen): the full-quality original, pinch to
/// zoom. The small preview the avatar already showed stands in while the
/// original loads.
class AvatarViewerScreen extends ConsumerWidget {
  const AvatarViewerScreen({super.key, required this.mediaId, required this.name});

  final String mediaId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.watch(apiClientProvider);
    final cacheManager = ref.watch(imageCacheManagerProvider);
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        foregroundColor: Colors.white,
        leading: const TablerBackButton(),
        title: Text(name, style: const TextStyle(color: Colors.white)),
      ),
      body: PhotoView(
        key: const ValueKey('avatar-viewer-photo'),
        imageProvider: CachedNetworkImageProvider(api.mediaUrl(mediaId), cacheManager: cacheManager),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        minScale: PhotoViewComputedScale.contained,
        maxScale: PhotoViewComputedScale.covered * 3,
        loadingBuilder: (context, event) => Center(
          child: CachedNetworkImage(
            imageUrl: api.mediaPreviewUrl(mediaId),
            cacheManager: cacheManager,
            fit: BoxFit.contain,
            fadeInDuration: Duration.zero,
            placeholder: (context, url) => const SizedBox.shrink(),
            errorWidget: (context, url, error) => const SizedBox.shrink(),
          ),
        ),
        errorBuilder: (context, error, stackTrace) => const Center(
          child: Text('Could not load the photo', style: TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}
