import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../providers/chat_providers.dart';
import '../../theme/app_theme.dart';
import 'media_message.dart';

/// A photo or video the user just sent, shown in the chat straight away
/// while it uploads ("Sending…"), from the bytes on the phone. The server's
/// confirmed message replaces it. If the upload fails it stays, marked
/// "Not sent", with Retry and a button to discard it.
class PendingUploadRow extends ConsumerStatefulWidget {
  const PendingUploadRow({super.key, required this.upload, required this.roomId});

  final PendingUpload upload;
  final String roomId;

  @override
  ConsumerState<PendingUploadRow> createState() => _PendingUploadRowState();
}

class _PendingUploadRowState extends ConsumerState<PendingUploadRow> {
  /// width / height of the photo, once read from its header; square until
  /// then, and for a video.
  double _aspectRatio = 1;

  @override
  void initState() {
    super.initState();
    if (!widget.upload.isVideo) _readAspectRatio();
  }

  Future<void> _readAspectRatio() async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(Uint8List.fromList(widget.upload.item.bytes));
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ratio = descriptor.width / descriptor.height;
      descriptor.dispose();
      buffer.dispose();
      if (mounted && ratio.isFinite && ratio > 0) setState(() => _aspectRatio = ratio);
    } catch (_) {
      // Stays square.
    }
  }

  Future<void> _retry() async {
    try {
      await ref.read(messagesProvider(widget.roomId).notifier).retryUpload(widget.upload.id);
    } catch (_) {
      // Shown as not sent again.
    }
  }

  @override
  Widget build(BuildContext context) {
    final upload = widget.upload;
    final onBubble = onSentBubbleColor(context);
    final width = mediaDisplayWidth(context, _aspectRatio);
    final caption = upload.item.caption;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        key: ValueKey('pending-upload-${upload.id}'),
        width: width,
        decoration: BoxDecoration(
          color: sentBubbleColor(context),
          borderRadius: const BorderRadius.all(ChatBubbleStyle.radius),
          boxShadow: ChatBubbleStyle.shadow(Theme.of(context).brightness),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: _aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (upload.isVideo)
                    ColoredBox(
                      color: Colors.black87,
                      child: Icon(TablerIcons.video, color: Colors.white.withValues(alpha: 0.8), size: 40),
                    )
                  else
                    Image.memory(
                      Uint8List.fromList(upload.item.bytes),
                      fit: BoxFit.cover,
                      // Decoded at the size it's shown, not the camera's.
                      cacheWidth: (width * dpr).round(),
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                    ),
                  if (!upload.failed)
                    const Center(
                      child: SizedBox.square(
                        dimension: 36,
                        child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            if (caption != null && caption.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: Text(caption, style: TextStyle(fontSize: 15, height: 1.3, color: onBubble)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
              child: upload.failed ? _failedFooter(context) : _sendingFooter(onBubble),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sendingFooter(Color onBubble) => Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(TablerIcons.clock, size: 13, color: onBubble.withValues(alpha: 0.6)),
          const SizedBox(width: 4),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text('Sending…', style: TextStyle(fontSize: 12, color: onBubble.withValues(alpha: 0.6))),
          ),
        ],
      );

  Widget _failedFooter(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return Row(
      children: [
        Icon(TablerIcons.alertCircle, size: 15, color: error),
        const SizedBox(width: 4),
        Expanded(child: Text('Not sent', style: TextStyle(fontSize: 12.5, color: error))),
        TextButton(
          key: const ValueKey('pending-upload-retry'),
          onPressed: _retry,
          child: const Text('Retry'),
        ),
        IconButton(
          key: const ValueKey('pending-upload-discard'),
          tooltip: 'Discard',
          visualDensity: VisualDensity.compact,
          icon: const Icon(TablerIcons.x, size: 18),
          onPressed: () => ref.read(pendingUploadsProvider(widget.roomId).notifier).remove(widget.upload.id),
        ),
      ],
    );
  }
}
