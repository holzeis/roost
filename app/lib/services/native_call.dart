import 'dart:async';

import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ws_client.dart';
import '../providers/chat_providers.dart';
import '../router/app_router.dart';

/// Thin seam over flutter_callkit_incoming's static API, so
/// [NativeCallController] can be exercised under `flutter test` with a fake
/// in place of the real platform channel.
class NativeCallKit {
  const NativeCallKit();

  Future<List<CallKitParams>> activeCalls() => FlutterCallkitIncoming.activeCalls();

  Future<void> endCall(String id) => FlutterCallkitIncoming.endCall(id);
}

final nativeCallKitProvider = Provider<NativeCallKit>((ref) => const NativeCallKit());

/// Where [NativeCallController] sends the app once a native accept has
/// joined the call — overridable so tests can observe it without a real
/// router.
final callNavigatorProvider = Provider<void Function(String route)>((ref) => (route) => appRouter.push(route));

/// The ids a native CallKit call carries (see AppDelegate.swift's
/// `data.extra` and push_service.dart's callKitParamsFromPushData). The
/// native call's own id is the call message's id.
class NativeCallInfo {
  const NativeCallInfo({required this.roomId, required this.messageId, required this.callId});

  final String roomId;
  final String messageId;
  final String callId;

  /// Null when any id is missing/empty, which a real event never should be
  /// but a malformed/forged one could.
  static NativeCallInfo? fromExtra(Map<String, dynamic>? extra) {
    final roomId = extra?['roomId'] as String?;
    final messageId = extra?['messageId'] as String?;
    final callId = extra?['callId'] as String?;
    if (roomId == null || roomId.isEmpty) return null;
    if (messageId == null || messageId.isEmpty) return null;
    if (callId == null || callId.isEmpty) return null;
    return NativeCallInfo(roomId: roomId, messageId: messageId, callId: callId);
  }
}

/// The CallScreen route for joining [messageId]'s call directly — a native
/// accept has already answered it, so IncomingCallScreen is skipped.
String callRoute(String roomId, String messageId, {required bool isGroup}) =>
    '/call/$roomId?messageId=$messageId&group=$isGroup';

/// Compares native call ids case-insensitively: CallKit round-trips them as
/// UUIDs, which iOS may hand back uppercased.
bool sameCallId(String a, String b) => a.toLowerCase() == b.toLowerCase();

/// The call message id [event] reports as finished (status no longer
/// "ringing" — the server keeps a live call "ringing" until it's finalized
/// as completed/missed/declined), or null for any other event.
String? finishedCallMessageId(WsEvent? event) {
  if (event == null || event.type != 'message.updated') return null;
  final call = event.payload['call'] as Map<String, dynamic>?;
  if (call == null || call['status'] == 'ringing') return null;
  return event.payload['id'] as String?;
}

/// Links the native CallKit call (FR4.4 — shown by a push-woken app, see
/// AppDelegate.swift) to the app's own call flow:
///
/// - native accept → accepts the call server-side and opens CallScreen
///   directly, instead of making the user answer a second time in-app;
/// - native decline → declines server-side;
/// - native end (e.g. the lock-screen hang-up button) → [endedFromNative],
///   which CallScreen listens to and hangs up on;
/// - the app hanging up, or answering/declining in-app, or the call ending
///   server-side → [endCall], so the native call never lingers.
class NativeCallController {
  NativeCallController(this._ref);

  final Ref _ref;
  final _joined = <String>{};
  final _endingLocally = <String>{};
  final _ended = StreamController<String>.broadcast();

  NativeCallKit get _callKit => _ref.read(nativeCallKitProvider);

  /// Call message ids whose native call the user ended from the native UI.
  Stream<String> get endedFromNative => _ended.stream;

  Future<void> handleEvent(CallEvent? event) async {
    switch (event) {
      case CallEventActionCallAccept(:final callKitParams):
        final info = NativeCallInfo.fromExtra(callKitParams.extra);
        if (info != null) await _join(info);
      case CallEventActionCallDecline(:final callKitParams):
        final info = NativeCallInfo.fromExtra(callKitParams.extra);
        final id = info?.messageId ?? callKitParams.id;
        // Ending a still-ringing native call ourselves (see endCall) is
        // reported back as a decline — not the user's, so don't act on it.
        if (_endingLocally.remove(id.toLowerCase())) return;
        if (info == null) return;
        try {
          await _ref.read(apiClientProvider).declineCall(info.callId);
        } catch (_) {
          // Best-effort — the caller's own ring timeout is the fallback.
        }
      case CallEventActionCallEnded(:final callKitParams):
        final id = NativeCallInfo.fromExtra(callKitParams.extra)?.messageId ?? callKitParams.id;
        // Also reported for our own endCall — only a user-initiated end
        // should hang up the in-app call.
        if (!_endingLocally.contains(id.toLowerCase())) _ended.add(id);
      default:
        break;
    }
  }

  /// Joins any native call the user already accepted before this Dart code
  /// was listening — a cold start from a killed app can deliver the accept
  /// before [handleEvent] is wired up, and the event isn't replayed.
  Future<void> resumeAcceptedCalls() async {
    final List<CallKitParams> calls;
    try {
      calls = await _callKit.activeCalls();
    } catch (_) {
      return; // No CallKit here (e.g. `flutter test`).
    }
    for (final call in calls) {
      if (!call.isAccepted) continue;
      final info = NativeCallInfo.fromExtra(call.extra);
      if (info != null) await _join(info);
    }
  }

  Future<void> _join(NativeCallInfo info) async {
    if (!_joined.add(info.messageId.toLowerCase())) return;
    try {
      await _ref.read(meProvider.future);
      await _ref.read(apiClientProvider).acceptCall(info.callId);
    } catch (_) {
      // The call ended before the accept landed (or the server is
      // unreachable) — there's nothing to join, so drop the native call.
      await endCall(info.messageId);
      return;
    }
    final incoming = _ref.read(incomingCallProvider);
    if (incoming != null && sameCallId(incoming.messageId, info.messageId)) {
      _ref.read(incomingCallProvider.notifier).dismiss();
    }
    var isGroup = false;
    try {
      isGroup = (await _ref.read(roomProvider(info.roomId).future)).isGroup;
    } catch (_) {
      // Only affects CallScreen's layout choice; 1:1 is the common case.
    }
    _ref.read(callNavigatorProvider)(callRoute(info.roomId, info.messageId, isGroup: isGroup));
  }

  /// Ends [messageId]'s native call, if there is one. A no-op otherwise —
  /// flutter_callkit_incoming ends whichever call PushKit last reported
  /// regardless of the id passed, so this must never be called blindly.
  Future<void> endCall(String messageId) async {
    try {
      final active = await _callKit.activeCalls();
      if (!active.any((c) => sameCallId(c.id, messageId))) return;
      _endingLocally.add(messageId.toLowerCase());
      await _callKit.endCall(messageId);
    } catch (_) {
      // No CallKit here (e.g. `flutter test`) — nothing to end.
    }
  }

  void dispose() => unawaited(_ended.close());
}

final nativeCallControllerProvider = Provider<NativeCallController>((ref) {
  final controller = NativeCallController(ref);
  // The call finished server-side (caller gave up, answered on another
  // device, declined, or everyone hung up) — stop the native ring/call.
  ref.listen(wsEventsProvider, (previous, next) {
    final messageId = finishedCallMessageId(next.valueOrNull);
    if (messageId != null) unawaited(controller.endCall(messageId));
  });
  ref.onDispose(controller.dispose);
  return controller;
});
