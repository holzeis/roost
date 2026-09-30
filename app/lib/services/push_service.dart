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
import 'native_call.dart';

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
    // Video — every call starts as one (FR4.1/FR4.2), matching the APNs
    // side's isVideo.
    type: 1,
    extra: {
      'roomId': data['roomId'] as String? ?? '',
      'messageId': data['messageId'] as String? ?? '',
      'callId': data['callId'] as String? ?? '',
      'callerId': data['callerId'] as String? ?? '',
    },
  );
}

/// Given the data on a tapped FR5.2 message notification, the chat to open
/// — null when incomplete. Pulled out of PushService as a plain function so
/// it's unit-testable without a real platform channel.
String? routeForMessageNotification(Map<String, dynamic>? data) {
  final roomId = data?['roomId'] as String?;
  if (roomId == null || roomId.isEmpty) return null;
  return '/chat/$roomId';
}

/// Decides whether a tapped message notification should open its chat.
/// iOS can report a single tap twice — through both getInitialMessage and
/// onMessageOpenedApp — which pushed the same chat on top of itself, so
/// "back" led to the same chat again. A notification is only ever handled
/// once, and a chat that's already the screen on top isn't pushed again.
class NotificationOpener {
  final _handled = <String>{};

  /// The route to push for a notification carrying [data], or null to do
  /// nothing. [currentLocation] is the path of the screen now on top.
  String? routeToPush(Map<String, dynamic> data, {required String currentLocation}) {
    final route = routeForMessageNotification(data);
    if (route == null) return null;
    final messageId = data['messageId'] as String?;
    if (messageId != null && !_handled.add(messageId)) return null;
    if (currentLocation == route) return null;
    return route;
  }
}

/// Whether an FCM message is FR5.1's call-wake (Android only — iOS's call
/// wake never goes through FCM, only PushKit) rather than an FR5.2 message
/// notification: call wake arrives data-only, with no `notification` block
/// — a message notification always has one, and the OS displays it
/// natively without any of this app's code needing to run at all.
bool isCallWakeMessage(RemoteMessage message) =>
    message.notification == null && message.data['roomId'] != null;

/// Whether [options] are real project credentials rather than the
/// committed `firebase_options.dart` placeholder. This has to be checked
/// *before* ever calling `Firebase.initializeApp` — the placeholder's
/// malformed apiKey/appId fail Firebase's native validation with an
/// uncaught NSException on iOS, which crashes the whole process rather
/// than surfacing as a catchable Dart error, so wrapping the call in
/// try/catch alone (as this file otherwise relies on for "push isn't set
/// up yet") isn't enough here.
bool isFirebaseConfigured(FirebaseOptions options) =>
    options.apiKey != 'REPLACE_ME' && options.appId != 'REPLACE_ME';

/// FCM background messages must be handled by a top-level/static function
/// (firebase_messaging's own requirement — it runs in a separate isolate
/// with no access to PushService's own state) — Android's half of FR5.1's
/// call-wake path when the app is backgrounded or fully closed.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (!isCallWakeMessage(message)) return;
  await FlutterCallkitIncoming.showCallkitIncoming(callKitParamsFromPushData(message.data));
}

/// Wires up FR5.1 (push-woken incoming calls) and FR5.2 (message
/// notifications): registers this device's push token(s) with the server
/// (server/internal/api's handleRegisterDevice) and routes both
/// flutter_callkit_incoming's accept/decline events and tapped message
/// notifications into the app.
///
/// Firebase Cloud Messaging runs on both platforms now (FR5.2 needs it on
/// iOS too, unlike FR5.1's call-wake path, which stays iOS-PushKit-only —
/// see [isCallWakeMessage]/AppDelegate.swift). A single physical iOS
/// device ends up with two registered tokens: one "voip" (PushKit, call
/// wake) and one "fcm" (Firebase, message notifications) — see
/// models.Device server-side.
class PushService {
  PushService(this._ref);

  final Ref _ref;
  StreamSubscription<CallEvent?>? _callKitSub;
  final _notificationOpener = NotificationOpener();

  Future<void> init() async {
    _callKitSub = FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
    // Also starts ending native calls whose call finished server-side.
    unawaited(_ref.read(nativeCallControllerProvider).resumeAcceptedCalls());

    // Best-effort: Firebase may not be configured yet (a placeholder
    // firebase_options.dart before a real project exists) or this may not
    // be a supported platform at all (e.g. running under `flutter test`)
    // — push is a fallback path, never something the rest of the app
    // depends on succeeding.
    try {
      await FlutterCallkitIncoming.requestNotificationPermission({
        'title': 'Notification permission',
        'rationaleMessagePermission':
            'Notification permission is required to show incoming calls and new messages.',
        'postNotificationMessageRequired':
            'Notification permission is required — please allow it from settings.',
      });

      // iOS call-wake (FR5.1) goes through PushKit/CallKit directly, not
      // Firebase — register it regardless of whether Firebase itself is
      // configured yet.
      if (Platform.isIOS) {
        final existingVoip = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
        if (existingVoip != null && existingVoip.isNotEmpty) {
          unawaited(_registerDevice('ios', existingVoip, 'voip'));
        }
      }

      final options = DefaultFirebaseOptions.currentPlatform;
      if (!isFirebaseConfigured(options)) return;

      await Firebase.initializeApp(options: options);
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      FirebaseMessaging.onMessage.listen((message) {
        if (!isCallWakeMessage(message)) return;
        unawaited(FlutterCallkitIncoming.showCallkitIncoming(callKitParamsFromPushData(message.data)));
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) => _openMessageNotification(message.data));
      final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
      if (initialMessage != null) _openMessageNotification(initialMessage.data);

      await FirebaseMessaging.instance.requestPermission();

      final platform = Platform.isIOS ? 'ios' : 'android';
      final fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) unawaited(_registerDevice(platform, fcmToken, 'fcm'));
      FirebaseMessaging.instance.onTokenRefresh.listen((token) => _registerDevice(platform, token, 'fcm'));
    } catch (_) {
      // Ignored — see doc comment above.
    }
  }

  void _openMessageNotification(Map<String, dynamic> data) {
    final route = _notificationOpener.routeToPush(
      data,
      currentLocation: appRouter.routerDelegate.currentConfiguration.uri.path,
    );
    if (route != null) appRouter.push(route);
  }

  void _onCallKitEvent(CallEvent? event) {
    switch (event) {
      case CallEventActionDidUpdateDevicePushTokenVoip():
        unawaited(_refreshIOSVoipToken());
      default:
        // Accept/decline/end — see NativeCallController. Only one listener
        // on onEvent: its EventChannel supports a single native listener.
        unawaited(_ref.read(nativeCallControllerProvider).handleEvent(event));
    }
  }

  Future<void> _refreshIOSVoipToken() async {
    final token = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
    if (token != null && token.isNotEmpty) await _registerDevice('ios', token, 'voip');
  }

  /// Best-effort: a failed registration just means this device won't get
  /// call-wake/message-notification push until the next retry (next app
  /// start, or the next onTokenRefresh/DID_UPDATE_DEVICE_PUSH_TOKEN_VOIP
  /// event) — push is a fallback path, not something the rest of the app
  /// depends on working.
  Future<void> _registerDevice(String platform, String pushToken, String tokenType) async {
    try {
      await _ref.read(meProvider.future);
      await _ref
          .read(apiClientProvider)
          .registerDevice(platform: platform, pushToken: pushToken, tokenType: tokenType);
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
