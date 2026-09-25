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

  group('routeForAcceptedCall', () {
    test('builds the IncomingCallScreen route from roomId/messageId', () {
      final route = routeForAcceptedCall({'roomId': 'room-1', 'messageId': 'msg-1'});
      expect(route, '/call/room-1/incoming?messageId=msg-1');
    });

    test('returns null when extra is null', () {
      expect(routeForAcceptedCall(null), isNull);
    });

    test('returns null when roomId is missing', () {
      expect(routeForAcceptedCall({'messageId': 'msg-1'}), isNull);
    });

    test('returns null when messageId is missing', () {
      expect(routeForAcceptedCall({'roomId': 'room-1'}), isNull);
    });

    test('returns null when either field is present but empty', () {
      expect(routeForAcceptedCall({'roomId': '', 'messageId': 'msg-1'}), isNull);
      expect(routeForAcceptedCall({'roomId': 'room-1', 'messageId': ''}), isNull);
    });
  });

  group('callIdToDecline', () {
    test('returns the callId when present', () {
      expect(callIdToDecline({'callId': 'call-1'}), 'call-1');
    });

    test('returns null when extra is null', () {
      expect(callIdToDecline(null), isNull);
    });

    test('returns null when callId is missing or empty', () {
      expect(callIdToDecline({}), isNull);
      expect(callIdToDecline({'callId': ''}), isNull);
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
