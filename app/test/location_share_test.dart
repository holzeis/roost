import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/features/chat/location_message.dart';
import 'package:roost/features/location/location_service.dart';
import 'package:roost/providers/chat_providers.dart';

import 'fakes.dart';

/// FR3.1-FR3.5: starting/updating/ending a live location share. Exercises
/// LocationShareController directly against a FakeLocationService (no real
/// GPS or platform permission dialogs) — the map/UI rendering built on top
/// isn't testable under `flutter test` (no platform view in the headless
/// harness) and is verified manually per the feature's plan.
void main() {
  group('ApiLocationShare', () {
    test('fromJson round-trips lat/lng/expiresAt and an optional endedAt', () {
      final expiresAt = DateTime.now().add(const Duration(minutes: 15));
      final withoutEndedAt = ApiLocationShare.fromJson({
        'lat': 52.5,
        'lng': 13.4,
        'expiresAt': expiresAt.toIso8601String(),
      });
      expect(withoutEndedAt.lat, 52.5);
      expect(withoutEndedAt.lng, 13.4);
      expect(withoutEndedAt.expiresAt, expiresAt);
      expect(withoutEndedAt.endedAt, isNull);

      final endedAt = DateTime.now();
      final withEndedAt = ApiLocationShare.fromJson({
        'lat': 52.5,
        'lng': 13.4,
        'expiresAt': expiresAt.toIso8601String(),
        'endedAt': endedAt.toIso8601String(),
      });
      expect(withEndedAt.endedAt, endedAt);
    });

    test('isActive mirrors the server\'s LocationShare.Active(now)', () {
      final now = DateTime(2026, 1, 1, 12);
      final active = ApiLocationShare(lat: 0, lng: 0, expiresAt: DateTime(2026, 1, 1, 13));
      expect(active.isActive(now), isTrue);

      final expired = ApiLocationShare(lat: 0, lng: 0, expiresAt: DateTime(2026, 1, 1, 11));
      expect(expired.isActive(now), isFalse);

      final endedBeforeExpiry = ApiLocationShare(
        lat: 0,
        lng: 0,
        expiresAt: DateTime(2026, 1, 1, 13),
        endedAt: DateTime(2026, 1, 1, 11, 30),
      );
      expect(endedBeforeExpiry.isActive(now), isFalse);

      final endsExactlyNow =
          ApiLocationShare(lat: 0, lng: 0, expiresAt: DateTime(2026, 1, 1, 13), endedAt: DateTime(2026, 1, 1, 12));
      expect(endsExactlyNow.isActive(now), isFalse);
    });
  });

  group('location sharing', () {
    late FakeApiClient api;
    late FakeLocationService location;
    late ProviderContainer container;

    setUp(() {
      api = FakeApiClient(FakeWsClient());
      location = FakeLocationService()..initialPosition = FakeLocationService.testPosition(52.5, 13.4);
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        locationServiceProvider.overrideWithValue(location),
      ]);
      addTearDown(container.dispose);
      addTearDown(location.dispose);
    });

    test('start requests permission, posts the initial fix, and starts watching', () async {
      await container.read(locationShareProvider('room-1').notifier).start(const Duration(minutes: 15));

      expect(location.requestPermissionCalls, 1);
      expect(location.watching, isTrue);
      final created = api.messagesByRoom['room-1']!.single;
      expect(created.kind, 'location');
      expect(created.location!.lat, 52.5);
      expect(created.location!.lng, 13.4);
      expect(container.read(locationShareProvider('room-1')), created.id);
    });

    test('each emitted position posts an update for the active share', () async {
      await container.read(locationShareProvider('room-1').notifier).start(const Duration(minutes: 15));
      final messageId = container.read(locationShareProvider('room-1'))!;

      location.emit(52.51, 13.42);
      await Future<void>.delayed(Duration.zero);

      final updated = api.messagesByRoom['room-1']!.firstWhere((m) => m.id == messageId);
      expect(updated.location!.lat, 52.51);
      expect(updated.location!.lng, 13.42);
    });

    test('start is a no-op when a share in this room is already active', () async {
      final notifier = container.read(locationShareProvider('room-1').notifier);
      await notifier.start(const Duration(minutes: 15));
      final firstCallCount = location.requestPermissionCalls;

      await notifier.start(const Duration(hours: 1));

      expect(location.requestPermissionCalls, firstCallCount);
      expect(api.messagesByRoom['room-1']!.length, 1);
    });

    test('a denied permission leaves no share started', () async {
      location.permissionDenied = true;

      await expectLater(
        container.read(locationShareProvider('room-1').notifier).start(const Duration(minutes: 15)),
        throwsA(isA<LocationPermissionDeniedException>()),
      );

      expect(container.read(locationShareProvider('room-1')), isNull);
      expect(api.messagesByRoom['room-1'], isNull);
    });

    test('end stops the position stream and marks the share ended', () async {
      final notifier = container.read(locationShareProvider('room-1').notifier);
      await notifier.start(const Duration(minutes: 15));
      final messageId = container.read(locationShareProvider('room-1'))!;

      await notifier.end();

      expect(container.read(locationShareProvider('room-1')), isNull);
      final ended = api.messagesByRoom['room-1']!.firstWhere((m) => m.id == messageId);
      expect(ended.location!.endedAt, isNotNull);

      // A position emitted after end() must not resurrect the share.
      location.emit(99, 99);
      await Future<void>.delayed(Duration.zero);
      final stillEnded = api.messagesByRoom['room-1']!.firstWhere((m) => m.id == messageId);
      expect(stillEnded.location!.lat, isNot(99));
    });

    test('the TTL timer ends the share on its own once it elapses (FR3.4)', () async {
      // A real (short) TTL and real wall-clock wait rather than fakeAsync —
      // the interaction between fakeAsync's fake Timer/microtask zone and
      // this controller's specific await chain proved unreliable to drive
      // deterministically, and 100ms of real time is cheap here.
      final notifier = container.read(locationShareProvider('room-1').notifier);
      await notifier.start(const Duration(milliseconds: 30));
      expect(container.read(locationShareProvider('room-1')), isNotNull);

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(container.read(locationShareProvider('room-1')), isNull);
      final ended = api.messagesByRoom['room-1']!.single;
      expect(ended.location!.endedAt, isNotNull);
    });
  });

  group('locationSnapshotProvider', () {
    test('fetches a snapshot at most once per message, even read repeatedly', () async {
      final api = FakeApiClient(FakeWsClient());
      final message = ApiMessage(
        id: 'expired-1',
        roomId: 'room-1',
        senderId: 'someone',
        kind: 'location',
        location: ApiLocationShare(
            lat: 52.5, lng: 13.4, expiresAt: DateTime.now().subtract(const Duration(minutes: 5))),
        createdAt: DateTime.now(),
      );
      api.messagesByRoom['room-1'] = [message];
      final container = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
      addTearDown(container.dispose);

      // Riverpod's own FutureProvider.family caching is what's actually
      // under test here — reading the same argument twice must reuse the
      // first call's in-flight/completed future rather than triggering the
      // underlying fetch again. This is the client-side half of the same
      // "never re-fetch (and re-bill) an existing snapshot" guarantee
      // handleLocationSnapshot enforces server-side.
      await container.read(locationSnapshotProvider('expired-1').future);
      await container.read(locationSnapshotProvider('expired-1').future);

      expect(api.fetchLocationSnapshotCallCount, 1);
    });
  });

  group('keeping tracking in step with the share', () {
    late FakeApiClient api;
    late FakeLocationService location;
    late ProviderContainer container;

    setUp(() {
      api = FakeApiClient(FakeWsClient());
      location = FakeLocationService()..initialPosition = FakeLocationService.testPosition(52.5, 13.4);
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        locationServiceProvider.overrideWithValue(location),
      ]);
      addTearDown(container.dispose);
      addTearDown(location.dispose);
    });

    Future<String> startSharing() async {
      await container.read(locationShareProvider('room-1').notifier).start(const Duration(minutes: 15));
      return container.read(locationShareProvider('room-1'))!;
    }

    Future<void> settle() async {
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('deleting the share stops tracking it', () async {
      final id = await startSharing();

      await api.deleteMessage(id); // broadcasts message.deleted
      await settle();

      expect(container.read(locationShareProvider('room-1')), isNull);
      location.emit(52.6, 13.5);
      await settle();
      expect(api.messagesByRoom['room-1']!.any((m) => m.id == id), isFalse, reason: 'nothing recreated');
    });

    test('the share ending server-side (e.g. replaced by a newer one) stops tracking it', () async {
      final id = await startSharing();

      await api.endLocationShare(id); // broadcasts message.updated with endedAt
      await settle();

      expect(container.read(locationShareProvider('room-1')), isNull);
    });

    test('an update the server refuses (share gone) stops tracking; a network error does not', () async {
      final id = await startSharing();

      // Gone without this device hearing about it (e.g. deleted while offline).
      api.messagesByRoom['room-1']!.removeWhere((m) => m.id == id);
      location.emit(52.6, 13.5);
      await settle();
      expect(container.read(locationShareProvider('room-1')), isNull);
    });

    test('a failed update for a network reason keeps tracking', () async {
      final flaky = _FlakyLocationApiClient();
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(flaky),
        wsClientProvider.overrideWithValue(flaky.ws),
        locationServiceProvider.overrideWithValue(location),
      ]);
      addTearDown(c.dispose);
      await c.read(locationShareProvider('room-1').notifier).start(const Duration(minutes: 15));

      location.emit(52.6, 13.5);
      await settle();

      expect(c.read(locationShareProvider('room-1')), isNotNull);
    });

    ApiMessage liveShare({DateTime? expiresAt, DateTime? endedAt}) => ApiMessage(
          id: 'loc-live',
          roomId: 'room-1',
          senderId: api.me.id,
          kind: 'location',
          createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
          location: ApiLocationShare(
            lat: 1,
            lng: 2,
            expiresAt: expiresAt ?? DateTime.now().add(const Duration(minutes: 10)),
            endedAt: endedAt,
          ),
        );

    test('resume picks an existing live share back up and posts its updates, without prompting', () async {
      final share = liveShare();
      api.messagesByRoom['room-1'] = [share];

      await container.read(locationShareProvider('room-1').notifier).resume(share);

      expect(container.read(locationShareProvider('room-1')), share.id);
      expect(location.requestPermissionCalls, 0);
      location.emit(52.6, 13.5);
      await settle();
      expect(api.messagesByRoom['room-1']!.single.location!.lat, 52.6);
    });

    test('resume without location access ends the share instead of leaving it frozen', () async {
      final share = liveShare();
      api.messagesByRoom['room-1'] = [share];
      location.permissionDenied = true;

      await container.read(locationShareProvider('room-1').notifier).resume(share);

      expect(container.read(locationShareProvider('room-1')), isNull);
      expect(api.messagesByRoom['room-1']!.single.location!.endedAt, isNotNull);
    });

    test('resume ignores a share that already ended or expired', () async {
      final notifier = container.read(locationShareProvider('room-1').notifier);
      await notifier.resume(liveShare(endedAt: DateTime.now()));
      await notifier.resume(liveShare(expiresAt: DateTime.now().subtract(const Duration(seconds: 1))));
      expect(container.read(locationShareProvider('room-1')), isNull);
    });

    test('on start and on every reconnect, the app resumes its own live shares', () async {
      api.messagesByRoom['room-1'] = [liveShare()];

      container.read(locationShareResumerProvider);
      await settle();
      expect(container.read(locationShareProvider('room-1')), 'loc-live');

      // A reconnect finds it already tracked: nothing changes.
      api.ws.emit(const WsEvent(WsClient.connectedEvent, {}));
      await settle();
      expect(container.read(locationShareProvider('room-1')), 'loc-live');
    });
  });
}

class _FlakyLocationApiClient extends FakeApiClient {
  _FlakyLocationApiClient() : super(FakeWsClient());

  @override
  Future<ApiMessage> updateLocation(String messageId, {required double lat, required double lng}) async =>
      throw Exception('network unreachable');
}
