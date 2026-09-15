import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import 'call_controls.dart';

/// The native CallKit/ConnectionService screen (FR4.4) for a fully-closed
/// app needs push to wake the app first (deferred — see
/// docs/architecture-overview.md's call flow and FR5); this in-app screen
/// is the fallback shown whenever the call invite arrives while this app
/// process is alive, foregrounded or backgrounded, over the WebSocket
/// (see incomingCallProvider / RoostApp in lib/main.dart, which is what
/// navigates here). Reuses the same accept/decline affordances (FR4.5).
class IncomingCallScreen extends ConsumerStatefulWidget {
  const IncomingCallScreen({super.key, required this.roomId, required this.messageId});

  final String roomId;
  final String messageId;

  @override
  ConsumerState<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends ConsumerState<IncomingCallScreen> {
  bool _cameraOn = true;
  bool _busy = false;
  bool _popped = false;

  void _popOnce() {
    if (_popped || !mounted) return;
    _popped = true;
    Navigator.of(context).maybePop();
  }

  Future<void> _accept(ApiMessage message, bool isGroup) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).acceptCall(message.call!.id);
      ref.read(incomingCallProvider.notifier).dismiss();
      if (!mounted) return;
      _popped = true; // this screen is being replaced, not popped
      context.pushReplacement(
        '/call/${widget.roomId}?messageId=${widget.messageId}&group=$isGroup&audioOnly=${!_cameraOn}',
      );
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not join: $error')));
      }
    }
  }

  Future<void> _decline(ApiMessage message) async {
    ref.read(incomingCallProvider.notifier).dismiss();
    _popOnce();
    try {
      await ref.read(apiClientProvider).declineCall(message.call!.id);
    } catch (_) {
      // Best-effort — declining is primarily a local "make it stop ringing
      // for me" action; the caller's own timeout is the fallback if this
      // notification doesn't land.
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesProvider(widget.roomId)).valueOrNull;
    final usersById = ref.watch(usersByIdProvider).valueOrNull ?? const {};
    final isGroup = ref.watch(roomProvider(widget.roomId)).valueOrNull?.isGroup ?? false;

    ApiMessage? message;
    if (messages != null) {
      for (final m in messages) {
        if (m.id == widget.messageId) {
          message = m;
          break;
        }
      }
    }

    // The call ended before the user acted on it — answered on another
    // device, declined by someone else, or nobody answered in time.
    if (message?.call != null && message!.call!.status != 'ringing') {
      SchedulerBinding.instance.addPostFrameCallback((_) => _popOnce());
    }

    final callerName = message != null ? (usersById[message.senderId]?.displayName ?? '?') : '…';

    return Scaffold(
      backgroundColor: CallColors.background,
      body: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 56),
              child: Column(
                children: [
                  Text(isGroup ? 'Incoming group call' : 'Incoming video call',
                      style: const TextStyle(color: CallColors.textSecondary, fontSize: 11)),
                  const SizedBox(height: 14),
                  Container(
                    width: 76,
                    height: 76,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: CallColors.controlButton, shape: BoxShape.circle),
                    child: Text(
                      callerName.isNotEmpty ? callerName[0] : '?',
                      style: const TextStyle(color: CallColors.textSecondary, fontSize: 26),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(callerName, style: const TextStyle(color: CallColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  const Text('Roost · calling…', style: TextStyle(color: CallColors.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Column(
                children: [
                  // FR4.3: choose audio-only before joining.
                  TextButton.icon(
                    onPressed: message == null ? null : () => setState(() => _cameraOn = !_cameraOn),
                    icon: Icon(_cameraOn ? TablerIcons.video : TablerIcons.videoOff, color: CallColors.textSecondary, size: 16),
                    label: Text(_cameraOn ? 'Camera on' : 'Audio only',
                        style: const TextStyle(color: CallColors.textSecondary, fontSize: 11)),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Column(
                        children: [
                          CallControlButton(
                            icon: TablerIcons.phoneX,
                            background: CallColors.danger,
                            iconColor: Colors.white,
                            onPressed: message == null ? () {} : () => _decline(message!),
                          ),
                          const SizedBox(height: 6),
                          const Text('Decline', style: TextStyle(color: CallColors.textSecondary, fontSize: 10)),
                        ],
                      ),
                      const SizedBox(width: 48),
                      Column(
                        children: [
                          CallControlButton(
                            icon: TablerIcons.phone,
                            background: CallColors.accept,
                            iconColor: Colors.white,
                            onPressed: message == null || _busy ? () {} : () => _accept(message!, isGroup),
                          ),
                          const SizedBox(height: 6),
                          const Text('Accept', style: TextStyle(color: CallColors.textSecondary, fontSize: 10)),
                        ],
                      ),
                    ],
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
