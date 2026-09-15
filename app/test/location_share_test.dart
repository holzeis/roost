import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
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
}
