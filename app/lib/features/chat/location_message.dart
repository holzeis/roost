import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../features/location/location_markers.dart';
import '../../providers/chat_providers.dart';
import '../../theme/app_theme.dart';
import '../../util/time_format.dart';

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
      // Maps Platform "map load". A plain pin conveys the same thing
      // (there's a location here, tap for the full view) for free.
      return _ExpiredLocationPreview(roomId: widget.roomId, box: box, borderRadius: widget.borderRadius);
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

/// Static stand-in for [LocationBubbleContent] once a share has ended or
/// expired — see the doc comment where this is returned for why this avoids
/// a real Maps SDK view entirely rather than just showing the same map
/// without the "Live" chip.
class _ExpiredLocationPreview extends StatelessWidget {
  const _ExpiredLocationPreview({required this.roomId, required this.box, required this.borderRadius});

  final String roomId;
  final BoxConstraints box;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => context.push('/chat/$roomId/location'),
      child: ConstrainedBox(
        constraints: box,
        child: ClipRRect(
          borderRadius: borderRadius,
          child: Stack(
            children: [
              Container(
                color: scheme.primary.withValues(alpha: 0.12),
                alignment: Alignment.center,
                child: Icon(TablerIcons.mapPin, size: 36, color: scheme.primary),
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
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(TablerIcons.mapPin, color: Colors.white, size: 12),
                      SizedBox(width: 3),
                      Text('Location shared', style: TextStyle(color: Colors.white, fontSize: 10.5)),
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
