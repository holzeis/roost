import 'package:flutter_test/flutter_test.dart';

import 'package:roost/services/push_service.dart';

void main() {
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
}
