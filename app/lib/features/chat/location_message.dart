import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../util/time_format.dart';

/// The inline content of a location-share message bubble (FR3.7): a small
/// non-interactive map centered on that share's own position, with a "Live ·
/// Xm left" chip while active (FR3.6) or a plain "Location shared" label
/// once it's ended/expired. Tapping it opens the room's full live-location
/// map (FR3.8), which is where multiple simultaneous shares actually come
/// together — this bubble only ever shows its own message's position.
/// Renders edge-to-edge like a photo/video bubble (no bubble-colored frame
/// around the map) — see chat_screen.dart's own computation of
/// `borderRadius`, square on whichever edge has a forwarded/reply/sender-name
/// header above it instead of rounded.
class LocationBubbleContent extends StatefulWidget {
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
  State<LocationBubbleContent> createState() => _LocationBubbleContentState();
}

class _LocationBubbleContentState extends State<LocationBubbleContent> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Re-renders the "Xm left" label periodically while active — the
    // position itself updates via the normal message.updated WS flow
    // (chat_providers.dart), not this timer.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final share = widget.message.location;
    const box = BoxConstraints(maxWidth: 220, maxHeight: 160);
    if (share == null) return const SizedBox.shrink();

    final active = share.isActive();
    final position = LatLng(share.lat, share.lng);

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
                  initialCameraPosition: CameraPosition(target: position, zoom: 14),
                  markers: {Marker(markerId: const MarkerId('self'), position: position)},
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
                      Icon(active ? TablerIcons.point : TablerIcons.mapPin, color: Colors.white, size: 12),
                      const SizedBox(width: 3),
                      Text(
                        active ? 'Live · ${formatRemaining(share.expiresAt.difference(DateTime.now()))}' : 'Location shared',
                        style: const TextStyle(color: Colors.white, fontSize: 10.5),
                      ),
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
