import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../util/time_format.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';
import 'location_markers.dart';

/// FR3.8: every currently-active location share in a room, together on one
/// map, live-updating as message.updated events land (see
/// chat_providers.dart's MessagesController — this screen just watches the
/// same messagesProvider everything else in the chat does). Reached by
/// tapping any location bubble in the chat (LocationBubbleContent).
class LiveLocationScreen extends ConsumerStatefulWidget {
  const LiveLocationScreen({super.key, required this.roomId});

  final String roomId;

  @override
  ConsumerState<LiveLocationScreen> createState() => _LiveLocationScreenState();
}

class _LiveLocationScreenState extends ConsumerState<LiveLocationScreen> {
  GoogleMapController? _mapController;
  Timer? _ticker;
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  void _fitToShares(List<ApiMessage> shares) {
    final controller = _mapController;
    if (controller == null || shares.isEmpty) return;
    if (shares.length == 1) {
      controller.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(shares.first.location!.lat, shares.first.location!.lng), 14),
      );
      return;
    }
    final lats = shares.map((m) => m.location!.lat);
    final lngs = shares.map((m) => m.location!.lng);
    final bounds = LatLngBounds(
      southwest: LatLng(lats.reduce((a, b) => a < b ? a : b), lngs.reduce((a, b) => a < b ? a : b)),
      northeast: LatLng(lats.reduce((a, b) => a > b ? a : b), lngs.reduce((a, b) => a > b ? a : b)),
    );
    controller.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(widget.roomId));
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    final me = ref.watch(meProvider).valueOrNull;
    final meId = me?.id;
    final ownShareMessageId = ref.watch(locationShareProvider(widget.roomId));

    final shares = (messagesAsync.valueOrNull ?? const <ApiMessage>[])
        .where((m) => m.kind == 'location' && (m.location?.isActive() ?? false))
        .toList();

    if (!_fitted && shares.isNotEmpty && _mapController != null) {
      _fitted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToShares(shares));
    }

    String nameFor(String userId) => userId == meId ? 'You' : (usersById[userId]?.displayName ?? '?');
    String? avatarMediaIdFor(String userId) =>
        userId == meId ? me?.avatarMediaId : usersById[userId]?.avatarMediaId;

    return Scaffold(
      appBar: AppBar(leading: const TablerBackButton(), title: const Text('Live locations')),
      body: shares.isEmpty
          ? const Center(child: Text('No active location shares in this chat.'))
          : Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: LatLng(shares.first.location!.lat, shares.first.location!.lng),
                    zoom: 13,
                  ),
                  onMapCreated: (controller) {
                    _mapController = controller;
                    if (!_fitted) {
                      _fitted = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) => _fitToShares(shares));
                    }
                  },
                  markers: {
                    for (final m in shares)
                      Marker(
                        markerId: MarkerId(m.id),
                        position: LatLng(m.location!.lat, m.location!.lng),
                        // Falls back to the stock pin for the brief moment
                        // before the avatar marker's own async render
                        // resolves — see avatarMarkerProvider.
                        icon: ref.watch(avatarMarkerProvider(m.senderId)).valueOrNull ??
                            BitmapDescriptor.defaultMarker,
                        infoWindow: InfoWindow(title: nameFor(m.senderId)),
                      ),
                  },
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: Container(
                      margin: const EdgeInsets.all(10),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final m in shares)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  InitialAvatar(
                                    initial: nameFor(m.senderId).isNotEmpty ? nameFor(m.senderId)[0].toUpperCase() : '?',
                                    seed: nameFor(m.senderId),
                                    size: 22,
                                    avatarMediaId: avatarMediaIdFor(m.senderId),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(nameFor(m.senderId), style: const TextStyle(fontSize: 13.5))),
                                  Text(
                                    formatRemaining(m.location!.expiresAt.difference(DateTime.now())),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (ownShareMessageId != null) ...[
                            const SizedBox(height: 4),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(TablerIcons.playerStop, size: 16),
                                label: const Text('Stop sharing'),
                                onPressed: () => ref.read(locationShareProvider(widget.roomId).notifier).end(),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
