import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/services/push_service.dart';

void main() {
  group('isFirebaseConfigured', () {
    test('a placeholder apiKey is not configured', () {
      const options = FirebaseOptions(
        apiKey: 'REPLACE_ME',
        appId: '1:123:ios:abc',
        messagingSenderId: '123',
        projectId: 'roost',
      );
      expect(isFirebaseConfigured(options), isFalse);
    });

    test('a placeholder appId is not configured', () {
      const options = FirebaseOptions(
        apiKey: 'AIzaReal',
        appId: 'REPLACE_ME',
        messagingSenderId: '123',
        projectId: 'roost',
      );
      expect(isFirebaseConfigured(options), isFalse);
    });

    test('real-looking credentials are configured', () {
      const options = FirebaseOptions(
        apiKey: 'AIzaReal',
        appId: '1:123:ios:abc',
        messagingSenderId: '123',
        projectId: 'roost',
      );
      expect(isFirebaseConfigured(options), isTrue);
    });
  });

  group('callKitParamsFromPushData', () {
    test('carries the caller name and every id through to extra', () {
      final params = callKitParamsFromPushData({
        'roomId': 'room-1',
        'messageId': 'msg-1',
        'callId': 'call-1',
        'callerId': 'user-1',
        'callerName': 'Mom',
      });

      expect(params.id, 'msg-1');
      expect(params.nameCaller, 'Mom');
      expect(params.type, 1, reason: 'calls are video calls');
      expect(params.extra, {
        'roomId': 'room-1',
        'messageId': 'msg-1',
        'callId': 'call-1',
        'callerId': 'user-1',
      });
    });

    test('falls back to a generic caller name when none is given', () {
      final params = callKitParamsFromPushData({'roomId': 'room-1', 'messageId': 'msg-1'});
      expect(params.nameCaller, 'Incoming call');
    });
  });

  group('NotificationOpener', () {
    test('opens the chat for a tapped notification', () {
      final opener = NotificationOpener();
      expect(opener.routeToPush({'roomId': 'room-1', 'messageId': 'm1'}, currentLocation: '/'), '/chat/room-1');
    });

    test('ignores the same tap reported a second time (iOS reports it twice)', () {
      final opener = NotificationOpener();
      final data = {'roomId': 'room-1', 'messageId': 'm1'};
      expect(opener.routeToPush(data, currentLocation: '/'), '/chat/room-1');
      expect(opener.routeToPush(data, currentLocation: '/chat/room-1'), isNull);
      expect(opener.routeToPush(data, currentLocation: '/'), isNull);
    });

    test("doesn't push a chat that's already on top", () {
      final opener = NotificationOpener();
      expect(opener.routeToPush({'roomId': 'room-1', 'messageId': 'm2'}, currentLocation: '/chat/room-1'), isNull);
    });

    test('a later notification still opens its chat', () {
      final opener = NotificationOpener();
      expect(opener.routeToPush({'roomId': 'room-1', 'messageId': 'm1'}, currentLocation: '/'), '/chat/room-1');
      expect(opener.routeToPush({'roomId': 'room-2', 'messageId': 'm3'}, currentLocation: '/chat/room-1'), '/chat/room-2');
    });

    test('ignores a notification without a room', () {
      expect(NotificationOpener().routeToPush({'messageId': 'm1'}, currentLocation: '/'), isNull);
    });
  });

  group('routeForMessageNotification', () {
    test('builds the chat route from roomId', () {
      expect(routeForMessageNotification({'roomId': 'room-1'}), '/chat/room-1');
    });

    test('returns null when data is null', () {
      expect(routeForMessageNotification(null), isNull);
    });

    test('returns null when roomId is missing or empty', () {
      expect(routeForMessageNotification({}), isNull);
      expect(routeForMessageNotification({'roomId': ''}), isNull);
    });
  });

  group('isCallWakeMessage', () {
    test('a data-only message with roomId is a call wake', () {
      const message = RemoteMessage(data: {'roomId': 'room-1', 'messageId': 'msg-1'});
      expect(isCallWakeMessage(message), isTrue);
    });

    test('a message carrying a notification block is not a call wake', () {
      // FR5.2's message notifications always have one — the OS displays
      // them natively, so this app's code must never treat them as a
      // call-wake data message.
      const message = RemoteMessage(
        data: {'roomId': 'room-1', 'messageId': 'msg-1'},
        notification: RemoteNotification(title: 'Mom', body: 'Sent a message in Roost'),
      );
      expect(isCallWakeMessage(message), isFalse);
    });

    test('a data-only message with no roomId is not a call wake', () {
      const message = RemoteMessage(data: {'somethingElse': 'value'});
      expect(isCallWakeMessage(message), isFalse);
    });
  });
}
