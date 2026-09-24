import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../firebase_options.dart';
import '../providers/chat_providers.dart';
import '../router/app_router.dart';

/// Given the extra data on an accepted incoming-call CallKit event, the
/// app-router path to navigate to — the same in-app flow the WebSocket-
/// delivered call.created path already uses (IncomingCallScreen re-derives
/// caller name/status from roomId+messageId on its own, so nothing else
/// needs to travel through the push payload). Null when the data is
/// incomplete, which a real event never should be but a malformed/forged
/// one could. Pulled out of PushService as a plain function so it's
/// unit-testable without a real platform channel.
String? routeForAcceptedCall(Map<String, dynamic>? extra) {
  final roomId = extra?['roomId'] as String?;
  final messageId = extra?['messageId'] as String?;
  if (roomId == null || roomId.isEmpty || messageId == null || messageId.isEmpty) {
    return null;
  }
  return '/call/$roomId/incoming?messageId=$messageId';
}

/// Given the extra data on a declined incoming-call CallKit event, the call
/// id to decline via the API directly — a decline made right from the
/// native CallKit UI happens before the app's own providers are
/// necessarily running, so this can't go through the normal
/// IncomingCallScreen flow the way an accept does.
String? callIdToDecline(Map<String, dynamic>? extra) {
  final callId = extra?['callId'] as String?;
  if (callId == null || callId.isEmpty) return null;
  return callId;
}

/// Builds the flutter_callkit_incoming params for showing the native
/// incoming-call UI from an FR5.1 call-wake payload — shared by the
/// Android FCM foreground/background handlers, which both receive the same
/// data shape (see server/internal/push's FCMSender).
CallKitParams callKitParamsFromPushData(Map<String, dynamic> data) {
  final callerName = data['callerName'] as String?;
  return CallKitParams(
    id: data['messageId'] as String? ?? '',
    nameCaller: (callerName != null && callerName.isNotEmpty) ? callerName : 'Incoming call',
    appName: 'Roost',
    handle: 'Roost',
    type: 0,
    extra: {
      'roomId': data['roomId'] as String? ?? '',
      'messageId': data['messageId'] as String? ?? '',
      'callId': data['callId'] as String? ?? '',
      'callerId': data['callerId'] as String? ?? '',
    },
  );
}

/// FCM background messages must be handled by a top-level/static function
/// (firebase_messaging's own requirement — it runs in a separate isolate
/// with no access to PushService's own state) — Android's half of FR5.1's
/// call-wake path when the app is backgrounded or fully closed.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.data['roomId'] == null) return;
  await FlutterCallkitIncoming.showCallkitIncoming(callKitParamsFromPushData(message.data));
}

/// Wires up FR5.1 (push-woken incoming calls): registers this device's push
/// token with the server (server/internal/api's handleRegisterDevice), and
/// routes CallKit accept/decline events into the app. iOS's call-wake path
/// goes entirely through flutter_callkit_incoming's own PushKit
/// registration (see ios/Runner/AppDelegate.swift) — no Firebase on that
/// platform at all; only Android needs FCM.
class PushService {
  PushService(this._ref);

  final Ref _ref;
  StreamSubscription<CallEvent?>? _callKitSub;

  Future<void> init() async {
    _callKitSub = FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);

    if (Platform.isAndroid) {
      await _initAndroid();
    } else if (Platform.isIOS) {
      await _initIOS();
    }
  }

  Future<void> _initAndroid() async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    FirebaseMessaging.onMessage.listen((message) async {
      if (message.data['roomId'] == null) return;
      await FlutterCallkitIncoming.showCallkitIncoming(callKitParamsFromPushData(message.data));
    });

    await FlutterCallkitIncoming.requestNotificationPermission({
      'title': 'Notification permission',
      'rationaleMessagePermission': 'Notification permission is required to show incoming calls.',
      'postNotificationMessageRequired':
          'Notification permission is required — please allow it from settings.',
    });
    await FirebaseMessaging.instance.requestPermission();

    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) unawaited(_registerDevice('android', token));
    FirebaseMessaging.instance.onTokenRefresh.listen((token) => _registerDevice('android', token));
  }

  Future<void> _initIOS() async {
    final existing = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    if (existing != null && existing.isNotEmpty) {
      unawaited(_registerDevice('ios', existing));
    }
  }

  void _onCallKitEvent(CallEvent? event) {
    switch (event) {
      case CallEventActionDidUpdateDevicePushTokenVoip():
        unawaited(_refreshIOSToken());
      case CallEventActionCallAccept(:final callKitParams):
        final route = routeForAcceptedCall(callKitParams.extra);
        if (route != null) appRouter.push(route);
      case CallEventActionCallDecline(:final callKitParams):
        final callId = callIdToDecline(callKitParams.extra);
        if (callId != null) {
          unawaited(_ref.read(apiClientProvider).declineCall(callId).catchError((_) {}));
        }
      default:
        break;
    }
  }

  Future<void> _refreshIOSToken() async {
    final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    if (token != null && token.isNotEmpty) await _registerDevice('ios', token);
  }

  /// Best-effort: a failed registration just means this device won't get
  /// call-wake push until the next retry (next app start, or the next
  /// onTokenRefresh/DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP event) — push is a
  /// fallback path, not something the rest of the app depends on working.
  Future<void> _registerDevice(String platform, String pushToken) async {
    try {
      await _ref.read(meProvider.future);
      await _ref.read(apiClientProvider).registerDevice(platform: platform, pushToken: pushToken);
    } catch (_) {
      // Ignored — see doc comment above.
    }
  }

  void dispose() {
    unawaited(_callKitSub?.cancel());
  }
}

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(service.dispose);
  return service;
});
