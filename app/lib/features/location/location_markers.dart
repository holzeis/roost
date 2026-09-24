import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

/// Renders a person's avatar — their uploaded photo, or their initial on a
/// color from [colorForAvatarSeed] (the same identity styling [InitialAvatar]
/// uses everywhere else) — as a round map marker, in place of Google Maps'
/// generic red pin. Cached per user by Riverpod, since rasterizing one of
/// these is too expensive to redo on every location tick or rebuild.
final avatarMarkerProvider = FutureProvider.family<BitmapDescriptor, String>((ref, userId) async {
  final me = await ref.watch(meProvider.future);
  String displayName;
  String? avatarMediaId;
  if (userId == me.id) {
    displayName = 'You';
    avatarMediaId = me.avatarMediaId;
  } else {
    final users = await ref.watch(usersProvider.future);
    ApiContact? contact;
    for (final u in users) {
      if (u.id == userId) {
        contact = u;
        break;
      }
    }
    displayName = contact?.displayName ?? '?';
    avatarMediaId = contact?.avatarMediaId;
  }

  Uint8List? avatarBytes;
  if (avatarMediaId != null) {
    try {
      avatarBytes = Uint8List.fromList(await ref.read(apiClientProvider).downloadMedia(avatarMediaId));
    } catch (_) {
      // Falls back to the initial glyph below, same as InitialAvatar's own
      // errorBuilder does for a broken image URL.
    }
  }

  final png = await renderAvatarMarkerPng(
    initial: displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
    color: colorForAvatarSeed(displayName),
    avatarBytes: avatarBytes,
  );
  return BitmapDescriptor.bytes(png, width: 40, height: 40);
});

/// Draws a circular avatar marker (a photo cropped to a circle, or an
/// initial on a solid color, both framed by a white ring so they read
/// clearly against any map terrain) and encodes it as PNG bytes for
/// [BitmapDescriptor.bytes]. Rendered at [physicalSize] regardless of the
/// marker's on-map display size, so it stays crisp at higher pixel ratios.
@visibleForTesting
Future<Uint8List> renderAvatarMarkerPng({
  required String initial,
  required Color color,
  Uint8List? avatarBytes,
  double physicalSize = 120,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final radius = physicalSize / 2;
  final center = Offset(radius, radius);

  canvas.drawCircle(center, radius, Paint()..color = Colors.white);
  const borderWidth = 6.0;
  final innerRadius = radius - borderWidth;

  if (avatarBytes != null) {
    final codec = await ui.instantiateImageCodec(avatarBytes);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final path = Path()..addOval(Rect.fromCircle(center: center, radius: innerRadius));
    canvas.save();
    canvas.clipPath(path);
    final cropSize = image.width < image.height ? image.width.toDouble() : image.height.toDouble();
    final src = Rect.fromCenter(
      center: Offset(image.width / 2, image.height / 2),
      width: cropSize,
      height: cropSize,
    );
    final dst = Rect.fromCircle(center: center, radius: innerRadius);
    canvas.drawImageRect(image, src, dst, Paint());
    canvas.restore();
  } else {
    canvas.drawCircle(center, innerRadius, Paint()..color = color);
    final painter = TextPainter(
      text: TextSpan(
        text: initial,
        style: TextStyle(color: Colors.white, fontSize: innerRadius, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(physicalSize.round(), physicalSize.round());
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  return byteData!.buffer.asUint8List();
}
