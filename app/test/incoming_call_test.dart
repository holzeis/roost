import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/features/call/call_screen.dart';
import 'package:roost/providers/chat_providers.dart';

import 'fakes.dart';

/// FR4.1-FR4.5: detecting an incoming call regardless of which screen is
/// open. Exercises IncomingCallController directly against FakeWsClient —
/// the actual navigation (RoostApp's ref.listen in lib/main.dart) and the
/// real LiveKit connection in CallScreen aren't testable under
/// `flutter test` and are verified manually per the feature's plan.
void main() {
  group('ApiCall', () {
    test('fromJson round-trips id/status/startedAt/endedAt', () {
      final startedAt = DateTime.now().subtract(const Duration(minutes: 2));
      final endedAt = DateTime.now();
      final call = ApiCall.fromJson({
        'id': 'call-1',
        'status': 'completed',
        'startedAt': startedAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
      });
      expect(call.id, 'call-1');
      expect(call.status, 'completed');
      expect(call.startedAt, startedAt);
      expect(call.endedAt, endedAt);
      expect(call.duration, endedAt.difference(startedAt));
    });

    test('duration is null while the call has no endedAt', () {
      final call = ApiCall.fromJson({
        'id': 'call-1',
        'status': 'ringing',
        'startedAt': DateTime.now().toIso8601String(),
      });
      expect(call.endedAt, isNull);
      expect(call.duration, isNull);
    });
  });

  group('resolveCallToJoin', () {
    final ringingCall = ApiCall.fromJson(
      {'id': 'call-1', 'status': 'ringing', 'startedAt': DateTime.now().toIso8601String()},
    );
    final callMessage = ApiMessage(
      id: 'msg-1',
      roomId: 'room-1',
      senderId: 'me',
      kind: 'call',
      call: ringingCall,
      createdAt: DateTime.now(),
    );

    test('prefers initialMessage when it carries a call', () {
      // The caller's only source — see CallScreen's own doc comment on why
      // messagesProvider's cache never has this message for them at all.
      final resolved = resolveCallToJoin('msg-1', callMessage, const []);
      expect(resolved, ringingCall);
    });

    test('falls back to finding messageId in messages when initialMessage is absent', () {
      final resolved = resolveCallToJoin('msg-1', null, [callMessage]);
      expect(resolved, ringingCall);
    });

    test('returns null when neither source has the message', () {
      final resolved = resolveCallToJoin('msg-missing', null, [callMessage]);
      expect(resolved, isNull);
    });
  });

  group('incoming call detection', () {
    late FakeApiClient api;
    late ProviderContainer container;

    setUp(() {
      api = FakeApiClient(FakeWsClient());
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
      ]);
      addTearDown(container.dispose);
    });

    Map<String, dynamic> callCreatedPayload({required String senderId, String status = 'ringing'}) => {
          'id': 'msg-1',
          'roomId': 'room-1',
          'senderId': senderId,
          'kind': 'call',
          'createdAt': DateTime.now().toIso8601String(),
          'call': {'id': 'call-1', 'status': status, 'startedAt': DateTime.now().toIso8601String()},
        };

    test('a call started by someone else surfaces as incoming', () async {
      container.read(incomingCallProvider); // start listening

      api.ws.emit(WsEvent('message.created', callCreatedPayload(senderId: 'them')));
      await Future<void>.delayed(Duration.zero);

      final incoming = container.read(incomingCallProvider);
      expect(incoming?.roomId, 'room-1');
      expect(incoming?.messageId, 'msg-1');
    });

    test('a call started by me is ignored', () async {
      container.read(incomingCallProvider);

      api.ws.emit(WsEvent('message.created', callCreatedPayload(senderId: api.me.id)));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(incomingCallProvider), isNull);
    });

    test('a non-call message.created is ignored', () async {
      container.read(incomingCallProvider);

      api.ws.emit(WsEvent('message.created', {
        'id': 'msg-2',
        'roomId': 'room-1',
        'senderId': 'them',
        'kind': 'text',
        'body': 'hi',
        'createdAt': DateTime.now().toIso8601String(),
      }));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(incomingCallProvider), isNull);
    });

    test('the call ending elsewhere (status leaves ringing) clears it', () async {
      container.read(incomingCallProvider);
      api.ws.emit(WsEvent('message.created', callCreatedPayload(senderId: 'them')));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(incomingCallProvider), isNotNull);

      api.ws.emit(WsEvent('message.updated', callCreatedPayload(senderId: 'them', status: 'missed')));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(incomingCallProvider), isNull);
    });

    test('a message.updated for a different message is ignored', () async {
      container.read(incomingCallProvider);
      api.ws.emit(WsEvent('message.created', callCreatedPayload(senderId: 'them')));
      await Future<void>.delayed(Duration.zero);

      final unrelated = callCreatedPayload(senderId: 'them', status: 'declined')..['id'] = 'msg-other';
      api.ws.emit(WsEvent('message.updated', unrelated));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(incomingCallProvider), isNotNull);
    });

    test('dismiss() clears the incoming call immediately', () async {
      container.read(incomingCallProvider);
      api.ws.emit(WsEvent('message.created', callCreatedPayload(senderId: 'them')));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(incomingCallProvider), isNotNull);

      container.read(incomingCallProvider.notifier).dismiss();

      expect(container.read(incomingCallProvider), isNull);
    });
  });
}
