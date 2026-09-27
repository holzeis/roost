import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../features/location/location_markers.dart';
import '../../providers/chat_providers.dart';
import '../../providers/image_cache_provider.dart';
import '../../theme/app_theme.dart';
import '../../util/time_format.dart';
import '../../widgets/avatar.dart';

/// The inline content of a location-share message bubble (FR3.7): a small
/// non-interactive map, with a "Live · Xm left" chip while active (FR3.6) or
/// a plain "Location shared" label once it's ended/expired. Tapping it opens
/// the room's full live-location map (FR3.8). While this share is active,
/// the preview also plots every other currently-active share in the room
/// alongside it (each as that person's own avatar, not a generic pin) —
/// matching the full map's own aggregation rather than showing only this
/// one message's position and making a second, simultaneous share
/// invisible until the bubble is tapped.
/// Renders edge-to-edge like a photo/video bubble (no bubble-colored frame
/// around the map) — see chat_screen.dart's own computation of
/// `borderRadius`, square on whichever edge has a forwarded/reply/sender-name
/// header above it instead of rounded.
class LocationBubbleContent extends ConsumerStatefulWidget {
  const LocationBubbleContent({
    super.key,
    required this.message,
    required this.roomId,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  final ApiMessage message;
  final String roomId;
  final BorderRadius borderRadius;

  @override
  ConsumerState<LocationBubbleContent> createState() => _LocationBubbleContentState();
}

class _LocationBubbleContentState extends ConsumerState<LocationBubbleContent> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-renders the "Xm left" label periodically while active — the
    // position itself updates via the normal message.updated WS flow
    // (chat_providers.dart), not this timer. Skipped entirely once already
    // expired (and cancels itself the moment it notices expiry) — an ended
    // share can never become active again, so there's nothing left for a
    // 30-second tick to ever change.
    if (widget.message.location?.isActive() ?? false) {
      _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!mounted) return;
        setState(() {});
        if (!(widget.message.location?.isActive() ?? false)) _ticker?.cancel();
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// A zoom level coarse enough to fit [span] degrees of lat/lng — plenty
  /// for a small preview thumbnail (the real bounds-fit happens on the full
  /// live map, reached by tapping this bubble) without pulling in a full
  /// Mercator-projection zoom calculation for it.
  static double _zoomForSpan(double span) {
    if (span < 0.005) return 14;
    if (span < 0.02) return 12;
    if (span < 0.05) return 11;
    if (span < 0.1) return 10;
    if (span < 0.3) return 9;
    if (span < 0.6) return 8;
    return 6;
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.message.location;
    if (share == null) return const SizedBox.shrink();

    // Media gets its own (wider) cap than a text bubble — see
    // ChatBubbleStyle.mediaMaxWidth — keeping the map preview's original
    // width:height ratio (220:160) rather than going square like a photo.
    final maxWidth = ChatBubbleStyle.mediaMaxWidth(context);
    final box = BoxConstraints(maxWidth: maxWidth, maxHeight: maxWidth * 160 / 220);

    if (!share.isActive()) {
      // An ended/expired share's position is frozen — a live Maps SDK view
      // here would just reload the exact same static picture every time
      // this bubble's widget gets rebuilt (e.g. scrolling back through
      // history), and each of those reloads is a real, separately billed
      // Maps Platform "map load". A static snapshot, fetched once
      // server-side and cached like any other media (see
      // handleLocationSnapshot), shows the same picture for free after
      // that first fetch.
      return _ExpiredLocationPreview(
        messageId: widget.message.id,
        senderId: widget.message.senderId,
        share: share,
        roomId: widget.roomId,
        box: box,
        borderRadius: widget.borderRadius,
      );
    }

    // Every other currently-active share in the room joins this preview —
    // matching the full map's own aggregation rather than showing only this
    // one message's position.
    final roomShares = ref
            .watch(messagesProvider(widget.roomId))
            .valueOrNull
            ?.where((m) => m.kind == 'location' && (m.location?.isActive() ?? false))
            .toList() ??
        const <ApiMessage>[];
    final sharesToShow =
        roomShares.any((m) => m.id == widget.message.id) ? roomShares : [widget.message];

    final positions = [for (final m in sharesToShow) LatLng(m.location!.lat, m.location!.lng)];
    final centerLat = positions.map((p) => p.latitude).reduce((a, b) => a + b) / positions.length;
    final centerLng = positions.map((p) => p.longitude).reduce((a, b) => a + b) / positions.length;
    final latSpan =
        positions.map((p) => p.latitude).reduce((a, b) => a > b ? a : b) -
            positions.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    final lngSpan =
        positions.map((p) => p.longitude).reduce((a, b) => a > b ? a : b) -
            positions.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    final zoom = positions.length > 1 ? _zoomForSpan(latSpan > lngSpan ? latSpan : lngSpan) : 14.0;

    final label = sharesToShow.length > 1
        ? '${sharesToShow.length} sharing live'
        : 'Live · ${formatRemaining(share.expiresAt.difference(DateTime.now()))}';

    return GestureDetector(
      onTap: () => context.push('/chat/${widget.roomId}/location'),
      child: ConstrainedBox(
        constraints: box,
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: Stack(
            children: [
              AbsorbPointer(
                // Non-interactive — this is a preview, not the real map
                // (FR3.8's aggregated view is a tap away).
                child: GoogleMap(
                  initialCameraPosition:
                      CameraPosition(target: LatLng(centerLat, centerLng), zoom: zoom),
                  markers: {
                    for (final m in sharesToShow)
                      Marker(
                        markerId: MarkerId(m.id),
                        position: LatLng(m.location!.lat, m.location!.lng),
                        // Falls back to the stock pin for the brief moment
                        // before the avatar marker's own async render
                        // resolves — see avatarMarkerProvider.
                        icon: ref.watch(avatarMarkerProvider(m.senderId)).valueOrNull ??
                            BitmapDescriptor.defaultMarker,
                      ),
                  },
                  liteModeEnabled: true,
                  zoomControlsEnabled: false,
                  myLocationButtonEnabled: false,
                ),
              ),
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(TablerIcons.point, color: Colors.white, size: 12),
                      const SizedBox(width: 3),
                      Text(label, style: const TextStyle(color: Colors.white, fontSize: 10.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lazily asks the server to generate an ended share's static map snapshot
/// the first time any client views it (see handleLocationSnapshot) — never
/// eagerly, and never repeated once one exists. Riverpod caches this per
/// messageId, so a widget rebuild (e.g. scrolling this bubble in and out of
/// view) never re-requests it. This provider's own resolved value is
/// unused by [_ExpiredLocationPreview] — the server's message.updated
/// broadcast (sent to every room member, including whoever triggered this)
/// is what actually updates messagesProvider's state with the new
/// snapshotMediaId; a fetch failure (e.g. no
/// GOOGLE_MAPS_STATIC_API_KEY configured server-side, see
/// docs/ios-dev-setup.md) is swallowed here and just leaves the bubble
/// showing its plain icon fallback.
final locationSnapshotProvider = FutureProvider.family<void, String>((ref, messageId) async {
  try {
    await ref.read(apiClientProvider).fetchLocationSnapshot(messageId);
  } catch (_) {
    // Best-effort, see doc comment above.
  }
});

/// Static stand-in for [LocationBubbleContent] once a share has ended or
/// expired — see the doc comment where this is returned for why this avoids
/// a real Maps SDK view entirely rather than just showing the same map
/// without the "Live" chip. Once a snapshot exists, shows a static map
/// image of the last known position with the sender's own avatar centered
/// on it in place of a generic pin (matching WhatsApp's "Live location
/// ended" card) — falls back to a plain icon if no snapshot has been
/// fetched yet (or ever could be, e.g. local dev with no Maps API key set).
class _ExpiredLocationPreview extends ConsumerWidget {
  const _ExpiredLocationPreview({
    required this.messageId,
    required this.senderId,
    required this.share,
    required this.roomId,
    required this.box,
    required this.borderRadius,
  });

  final String messageId;
  final String senderId;
  final ApiLocationShare share;
  final String roomId;
  final BoxConstraints box;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final snapshotMediaId = share.snapshotMediaId;
    if (snapshotMediaId == null) {
      // Only watched while there's no snapshot yet — once one exists this
      // provider's job is done, and watching it forever would just be a
      // pointless Riverpod subscription for the rest of this bubble's life.
      ref.watch(locationSnapshotProvider(messageId));
    }

    Widget fallbackIcon() => Container(
          color: scheme.primary.withValues(alpha: 0.12),
          alignment: Alignment.center,
          child: Icon(TablerIcons.mapPin, size: 36, color: scheme.primary),
        );

    return GestureDetector(
      onTap: () => context.push('/chat/$roomId/location'),
      child: ConstrainedBox(
        constraints: box,
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (snapshotMediaId != null)
                CachedNetworkImage(
                  key: ValueKey('location-snapshot-$messageId'),
                  imageUrl: ref.watch(apiClientProvider).mediaPreviewUrl(snapshotMediaId),
                  cacheManager: ref.watch(imageCacheManagerProvider),
                  fit: BoxFit.cover,
                  // No crossfade — see widgets/avatar.dart's identical
                  // reasoning.
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: Duration.zero,
                  placeholder: (context, url) => fallbackIcon(),
                  errorWidget: (context, url, error) => fallbackIcon(),
                )
              else
                fallbackIcon(),
              // A static map image is always centered exactly on the point
              // it was requested for, so pinning this dead-center lines it
              // up with the share's own position with no separate
              // marker-placement math needed.
              if (snapshotMediaId != null) Center(child: _MapMarkerAvatar(userId: senderId)),
              Positioned(
                left: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(TablerIcons.mapPin, color: Colors.white, size: 12),
                      SizedBox(width: 3),
                      Text('Live location ended', style: TextStyle(color: Colors.white, fontSize: 10.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The sender's own avatar (their uploaded photo, or their initial on a
/// color, framed by a white ring with a soft shadow) shown centered over an
/// ended share's static map snapshot, in place of a generic pin — the live
/// (still-active) map above uses [avatarMarkerProvider]'s rasterized
/// equivalent instead, since that one has to become a native Google Maps
/// SDK [BitmapDescriptor]; this is a plain Flutter widget, since it's drawn
/// directly into this bubble's own widget tree.
class _MapMarkerAvatar extends ConsumerWidget {
  const _MapMarkerAvatar({required this.userId});

  final String userId;
  static const double size = 40;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).valueOrNull;
    String displayName;
    String? avatarMediaId;
    if (me != null && userId == me.id) {
      displayName = me.displayName;
      avatarMediaId = me.avatarMediaId;
    } else {
      final contact = ref.watch(usersByIdProvider).valueOrNull?[userId];
      displayName = contact?.displayName ?? '?';
      avatarMediaId = contact?.avatarMediaId;
    }
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final seedColor = colorForAvatarSeed(displayName);

    Widget glyph() => Container(
          color: seedColor,
          alignment: Alignment.center,
          child: Text(initial,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: size * 0.4)),
        );

    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(3),
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: ClipOval(
        child: avatarMediaId != null
            ? CachedNetworkImage(
                imageUrl: ref.watch(apiClientProvider).mediaPreviewUrl(avatarMediaId),
                cacheManager: ref.watch(imageCacheManagerProvider),
                fit: BoxFit.cover,
                // No crossfade — see widgets/avatar.dart's identical
                // reasoning.
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholder: (context, url) => ColoredBox(color: seedColor),
                errorWidget: (context, url, error) => glyph(),
              )
            : glyph(),
      ),
    );
  }
}
