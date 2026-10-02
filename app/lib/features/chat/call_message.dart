import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../demo/demo_call_notice.dart';
import '../../providers/chat_providers.dart';

/// Rooms with a call being started right now — starting one waits on the
/// server before the call screen opens, and a second tap in that window
/// used to start a second call with a second call screen stacked on the
/// first, so leaving took two "backs".
final _startingCalls = <String>{};

/// Runs [start] unless a call in [roomId] is already being started.
Future<void> startingCallIn(String roomId, Future<void> Function() start) async {
  if (!_startingCalls.add(roomId)) return;
  try {
    await start();
  } finally {
    _startingCalls.remove(roomId);
  }
}

/// "23 sec", "4 min", "1 hr 5 min" — a finished call's talk time, as on
/// the call bubble.
String formatCallDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds < 0 ? 0 : d.inSeconds} sec';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final minutes = d.inMinutes % 60;
  return minutes == 0 ? '${d.inHours} hr' : '${d.inHours} hr $minutes min';
}

/// What a call bubble says, which depends on the side: the caller sees "No
/// answer" where the person called sees "Missed video call — Tap to call
/// back" (in red). [outgoing] is true for the caller.
class CallSummary {
  const CallSummary({required this.title, required this.subtitle, required this.missed, required this.confirmLabel});

  final String title;
  final String subtitle;

  /// A call the viewer missed: shown in red.
  final bool missed;

  /// The question the tap-to-call sheet asks.
  final String confirmLabel;
}

CallSummary summarizeCall(ApiCall? call, {required bool outgoing}) {
  const title = 'Video call';
  switch (call?.status ?? 'ringing') {
    case 'completed':
      final talk = call?.duration;
      return CallSummary(
        title: title,
        subtitle: talk == null ? 'Ended' : formatCallDuration(talk),
        missed: false,
        confirmLabel: 'Start a new call?',
      );
    case 'missed':
      return outgoing
          ? const CallSummary(title: title, subtitle: 'No answer', missed: false, confirmLabel: 'Call again?')
          : const CallSummary(
              title: 'Missed video call', subtitle: 'Tap to call back', missed: true, confirmLabel: 'Call back?');
    case 'declined':
      return CallSummary(
        title: title,
        subtitle: 'Declined',
        missed: false,
        confirmLabel: outgoing ? 'Call again?' : 'Call back?',
      );
    default:
      // Still live: ringing, or answered and going on.
      return CallSummary(
        title: title,
        subtitle: call?.answeredAt != null ? 'In progress' : 'Ringing…',
        missed: false,
        confirmLabel: 'Join this call?',
      );
  }
}

/// The inline content of a call message bubble (FR4.8), laid out like
/// WhatsApp's: a camera icon in a circle with an arrow for the direction
/// (↗ you called, ↙ they called), the call's title, its outcome (talk time,
/// "No answer", "Tap to call back", …) and the time in the corner. Tapping
/// it asks for confirmation first via a bottom sheet rather than joining or
/// starting a call immediately, since that's a heavier action than any other
/// tap in the chat and shouldn't be one accidental tap away.
class CallBubbleContent extends ConsumerWidget {
  const CallBubbleContent({
    super.key,
    required this.message,
    required this.roomId,
    required this.isGroup,
    required this.textColor,
    required this.outgoing,
    this.meta,
  });

  final ApiMessage message;
  final String roomId;
  final bool isGroup;
  final Color textColor;

  /// Whether the viewer started this call.
  final bool outgoing;

  /// The bubble's time, shown in its bottom-right corner.
  final Widget? meta;

  void _confirm(BuildContext context, WidgetRef ref, String label) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(TablerIcons.phone, size: 18),
                      label: const Text('Call'),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        _join(context, ref);
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _join(BuildContext context, WidgetRef ref) async {
    if (await showDemoCallNoticeIfDemo(context, ref)) return;
    if (!context.mounted) return;
    final call = message.call;
    try {
      if (call != null && call.status == 'ringing') {
        await ref.read(apiClientProvider).acceptCall(call.id);
        ref.read(incomingCallProvider.notifier).dismiss();
        if (context.mounted) {
          context.push('/call/$roomId?messageId=${message.id}&group=$isGroup', extra: message);
        }
      } else {
        await startingCallIn(roomId, () async {
          final started = await ref.read(apiClientProvider).startCall(roomId);
          if (context.mounted) {
            context.push('/call/$roomId?messageId=${started.id}&group=$isGroup', extra: started);
          }
        });
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join call: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = summarizeCall(message.call, outgoing: outgoing);
    final iconColor = summary.missed ? Theme.of(context).colorScheme.error : textColor;
    return InkWell(
      onTap: () => _confirm(context, ref, summary.confirmLabel),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.08 : 0.55),
              ),
              child: CallDirectionIcon(outgoing: outgoing, color: iconColor, size: 26),
            ),
            const SizedBox(width: 12),
            // Flexible: on a narrow phone the text wraps inside the bubble
            // rather than running past its edge.
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(summary.title,
                      style: TextStyle(fontSize: 16.5, height: 1.25, fontWeight: FontWeight.w700, color: textColor)),
                  const SizedBox(height: 2),
                  Text(summary.subtitle,
                      style: TextStyle(fontSize: 15, height: 1.25, color: textColor.withValues(alpha: 0.62))),
                ],
              ),
            ),
            if (meta != null) ...[
              const SizedBox(width: 14),
              Transform.translate(offset: const Offset(0, 4), child: meta),
            ],
          ],
        ),
      ),
    );
  }
}

/// A video camera with an arrow on its body: ↗ for a call you made, ↙ for
/// one you received — the call bubble's icon.
class CallDirectionIcon extends StatelessWidget {
  const CallDirectionIcon({super.key, required this.outgoing, required this.color, this.size = 24});

  final bool outgoing;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size(size, size),
        painter: _CallDirectionPainter(outgoing: outgoing, color: color),
      );
}

class _CallDirectionPainter extends CustomPainter {
  const _CallDirectionPainter({required this.outgoing, required this.color});

  final bool outgoing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final fill = Paint()..color = color;

    // Camera body and lens, with the arrow cut out of the body (drawn in
    // one layer, so the cut-out shows whatever is behind the icon).
    canvas.saveLayer(Offset.zero & size, Paint());
    final body = Rect.fromLTWH(0, h * 0.2, w * 0.68, h * 0.6);
    canvas.drawRRect(RRect.fromRectAndRadius(body, Radius.circular(w * 0.1)), fill);
    final lens = Path()
      ..moveTo(w * 0.72, h * 0.42)
      ..lineTo(w, h * 0.24)
      ..lineTo(w, h * 0.76)
      ..lineTo(w * 0.72, h * 0.58)
      ..close();
    canvas.drawPath(lens, fill);

    final arrow = Paint()
      ..color = Colors.white
      ..blendMode = BlendMode.dstOut
      ..strokeWidth = w * 0.075
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final low = Offset(body.left + body.width * 0.3, body.top + body.height * 0.72);
    final high = Offset(body.left + body.width * 0.7, body.top + body.height * 0.28);
    final tip = outgoing ? high : low;
    final tail = outgoing ? low : high;
    final head = body.width * 0.26;
    canvas.drawLine(tail, tip, arrow);
    final dir = outgoing ? 1.0 : -1.0;
    canvas.drawLine(tip, tip + Offset(-head * dir, 0), arrow);
    canvas.drawLine(tip, tip + Offset(0, head * dir), arrow);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CallDirectionPainter old) => old.outgoing != outgoing || old.color != color;
}
