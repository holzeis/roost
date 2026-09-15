import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/ws_client.dart';
import 'package:roost/providers/chat_providers.dart';

import 'fakes.dart';

/// FR1.7: who's typing, derived purely from `typing` WS events. Exercises
/// TypingController directly (no widget tree) — the chat title's rendering
/// of the resulting set is thin display logic verified manually per the
/// feature's plan, same split used for FR1.5/1.6's message_status_test.dart.
void main() {
  group('typing indicator', () {
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

    test('a typing:true event adds the sender to the room\'s typing set', () async {
      container.read(typingUsersProvider('room-1')); // start listening

      api.ws.emit(const WsEvent('typing', {'roomId': 'room-1', 'userId': 'them', 'typing': true}));
      await Future<void>.delayed(Duration.zero); // let the WS stream event propagate

      expect(container.read(typingUsersProvider('room-1')), {'them'});
    });

    test('a typing:false event removes the sender immediately', () async {
      container.read(typingUsersProvider('room-1'));

      api.ws.emit(const WsEvent('typing', {'roomId': 'room-1', 'userId': 'them', 'typing': true}));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(typingUsersProvider('room-1')), {'them'});

      api.ws.emit(const WsEvent('typing', {'roomId': 'room-1', 'userId': 'them', 'typing': false}));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(typingUsersProvider('room-1')), isEmpty);
    });

    test('events for a different room are ignored', () async {
      container.read(typingUsersProvider('room-1'));

      api.ws.emit(const WsEvent('typing', {'roomId': 'room-2', 'userId': 'them', 'typing': true}));
      await Future<void>.delayed(Duration.zero);

      expect(container.read(typingUsersProvider('room-1')), isEmpty);
    });

    test('a typer with no further ping is cleared after the local timeout', () {
      fakeAsync((async) {
        container.read(typingUsersProvider('room-1'));

        api.ws.emit(const WsEvent('typing', {'roomId': 'room-1', 'userId': 'them', 'typing': true}));
        async.flushMicrotasks();
        expect(container.read(typingUsersProvider('room-1')), {'them'});

        async.elapse(const Duration(seconds: 5));
        expect(container.read(typingUsersProvider('room-1')), {'them'}, reason: 'not yet timed out');

        async.elapse(const Duration(seconds: 2));
        expect(container.read(typingUsersProvider('room-1')), isEmpty, reason: 'timed out with no further ping');
      });
    });

    test('a repeated ping resets the timeout instead of letting it expire', () {
      fakeAsync((async) {
        container.read(typingUsersProvider('room-1'));

        api.ws.emit(const WsEvent('typing', {'roomId': 'room-1', 'userId': 'them', 'typing': true}));
        async.elapse(const Duration(seconds: 5));
        api.ws.emit(const WsEvent('typing', {'roomId': 'room-1', 'userId': 'them', 'typing': true}));
        async.elapse(const Duration(seconds: 5));

        // 10s of elapsed time total, but the second ping at t=5s should
        // have pushed the 6s timeout out to t=11s.
        expect(container.read(typingUsersProvider('room-1')), {'them'});
      });
    });
  });
}
