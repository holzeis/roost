import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:share_handler/share_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/demo/demo_mode.dart';
import 'package:roost/features/chat/chat_screen.dart';
import 'package:roost/features/chat/media_caption_screen.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';
import 'package:roost/services/share_intake.dart';
import 'package:roost/services/share_suggestions.dart';

import 'fakes.dart';

/// Stands in for share_handler's platform side: what was shared into the
/// app, and which chats the app reported for share-sheet suggestions.
class FakeShareHandler extends ShareHandlerPlatform {
  SharedMedia? initial;
  int resets = 0;
  final stream = StreamController<SharedMedia>.broadcast();
  final List<({String id, String name})> recorded = [];

  @override
  Future<SharedMedia?> getInitialSharedMedia() async => initial;

  @override
  Future<void> resetInitialSharedMedia() async {
    resets++;
    initial = null;
  }

  @override
  Stream<SharedMedia> get sharedMediaStream => stream.stream;

  @override
  Future<void> recordSentMessage({
    required String conversationIdentifier,
    required String conversationName,
    String? conversationImageFilePath,
    String? serviceName,
  }) async =>
      recorded.add((id: conversationIdentifier, name: conversationName));
}

FakeApiClient seeded() {
  final api = FakeApiClient(FakeWsClient())
    ..contacts = const [
      ApiContact(id: 'mom', displayName: 'Mom', online: true),
      ApiContact(id: 'dad', displayName: 'Dad', online: false),
    ]
    ..rooms = [
      ApiRoom(
          id: 'room-mom',
          isGroup: false,
          createdBy: 'mom',
          createdAt: DateTime(2026, 9, 1),
          members: const ['me', 'mom'],
          lastMessageAt: DateTime(2026, 9, 30)),
      ApiRoom(
          id: 'room-dad',
          isGroup: false,
          createdBy: 'dad',
          createdAt: DateTime(2026, 9, 1),
          members: const ['me', 'dad'],
          lastMessageAt: DateTime(2026, 9, 20)),
    ];
  return api;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pendingShareFrom', () {
    test('keeps photos and videos, drops anything else', () {
      final share = pendingShareFrom(SharedMedia(attachments: [
        SharedAttachment(path: '/tmp/a.jpg', type: SharedAttachmentType.image),
        SharedAttachment(path: '/tmp/b.mov', type: SharedAttachmentType.video),
        SharedAttachment(path: '/tmp/c.pdf', type: SharedAttachmentType.file),
        null,
      ]))!;
      expect(share.media.map((m) => (m.file.path, m.isVideo)), [('/tmp/a.jpg', false), ('/tmp/b.mov', true)]);
      expect(share.media.first.file.mimeType, 'image/jpeg');
      expect(share.roomId, isNull);
    });

    test('carries the chat picked in the system share sheet', () {
      final share = pendingShareFrom(SharedMedia(
        conversationIdentifier: 'room-mom',
        attachments: [SharedAttachment(path: '/tmp/a.jpg', type: SharedAttachmentType.image)],
      ))!;
      expect(share.roomId, 'room-mom');
    });

    test('nothing sendable is no share at all', () {
      expect(pendingShareFrom(SharedMedia(content: 'just text')), isNull);
      expect(
          pendingShareFrom(SharedMedia(
              attachments: [SharedAttachment(path: '/tmp/c.pdf', type: SharedAttachmentType.file)])),
          isNull);
    });
  });

  group('ranking', () {
    final rooms = seeded().rooms;

    test('most sent-to chats come first', () {
      expect(rankRoomsForSharing(rooms, {'room-dad': 5, 'room-mom': 1}).map((r) => r.id), ['room-dad', 'room-mom']);
    });

    test('ties fall back to the most recently active', () {
      expect(rankRoomsForSharing(rooms, const {}).map((r) => r.id), ['room-mom', 'room-dad']);
    });

    test('usage counts are kept per chat on this device', () async {
      final usage = ChatUsage(SharedPreferences.getInstance);
      await usage.recordSend('room-dad');
      await usage.recordSend('room-dad');
      await usage.recordSend('room-mom');
      expect(await usage.counts(), {'room-dad': 2, 'room-mom': 1});
    });
  });

  group('share-sheet suggestions', () {
    ProviderContainer container(FakeApiClient api, FakeShareHandler handler, {bool demo = false}) {
      final c = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        shareHandlerProvider.overrideWithValue(handler),
        if (demo) demoModeProvider.overrideWithValue(DemoMode(enabled: true, setEnabled: (_) async {})),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test('sending to a chat reports it to the OS by name and counts it', () async {
      final api = seeded();
      final handler = FakeShareHandler();
      final c = container(api, handler);

      await c.read(messagesProvider('room-mom').notifier).send('hi');
      await settle();

      expect(handler.recorded, [(id: 'room-mom', name: 'Mom')]);
      expect(await c.read(chatUsageProvider).counts(), {'room-mom': 1});
    });

    test('forwarding counts toward the chat it was forwarded to', () async {
      final api = seeded();
      api.messagesByRoom['room-mom'] = [
        ApiMessage(id: 'm1', roomId: 'room-mom', senderId: 'mom', kind: 'text', body: 'x', createdAt: DateTime.now()),
      ];
      final handler = FakeShareHandler();
      final c = container(api, handler);

      await c.read(messagesProvider('room-mom').notifier).forwardMessage('m1', 'room-dad');
      await settle();

      expect(handler.recorded.single.id, 'room-dad');
    });

    test('demo chats are never reported to the OS', () async {
      final api = seeded();
      final handler = FakeShareHandler();
      final c = container(api, handler, demo: true);

      await c.read(shareSuggestionsProvider).recordSent('room-mom');

      expect(handler.recorded, isEmpty);
      expect(await c.read(chatUsageProvider).counts(), {'room-mom': 1});
    });
  });

  group('ShareIntake', () {
    test('opens what launched the app once, and anything shared while it runs', () async {
      final handler = FakeShareHandler()
        ..initial = SharedMedia(attachments: [SharedAttachment(path: '/tmp/a.jpg', type: SharedAttachmentType.image)]);
      final opened = <PendingShare>[];
      final c = ProviderContainer(overrides: [
        shareHandlerProvider.overrideWithValue(handler),
        shareNavigatorProvider.overrideWithValue(opened.add),
      ]);
      addTearDown(c.dispose);

      await c.read(shareIntakeProvider).start();
      expect(opened, hasLength(1));
      expect(handler.resets, 1, reason: 'consumed, so it is not replayed');

      handler.stream.add(SharedMedia(
        conversationIdentifier: 'room-dad',
        attachments: [SharedAttachment(path: '/tmp/b.mov', type: SharedAttachmentType.video)],
      ));
      handler.stream.add(SharedMedia(content: 'text is ignored'));
      await Future<void>.delayed(Duration.zero);

      expect(opened, hasLength(2));
      expect(opened.last.roomId, 'room-dad');
      expect(opened.last.media.single.isVideo, isTrue);
    });
  });

  group('the Share to… flow', () {
    PendingMedia photo(String name) => PendingMedia(
          file: XFile.fromData(base64Decode(_png), name: '$name.png', mimeType: 'image/png'),
          isVideo: false,
        );

    /// The app running, with a share just handed over by ShareIntake (whose
    /// own hand-off is covered above).
    Future<FakeApiClient> openShare(WidgetTester tester, PendingShare share, {Map<String, int> usage = const {}}) async {
      SharedPreferences.setMockInitialValues({if (usage.isNotEmpty) ChatUsage.prefKey: jsonEncode(usage)});
      appRouter.go('/');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = seeded();
      await tester.pumpWidget(RoostRoot(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
        shareHandlerProvider.overrideWithValue(FakeShareHandler()),
      ]));
      await tester.pumpAndSettle();
      appRouter.push('/share', extra: share);
      await tester.pumpAndSettle();
      return api;
    }

    testWidgets('sharing to Roost lets you pick a chat, most-used first, then review and send', (tester) async {
      final api = await openShare(tester, PendingShare(media: [photo('one'), photo('two')]), usage: {'room-dad': 3});

      expect(find.text('Share 2 items to…'), findsOneWidget);
      final dad = tester.getTopLeft(find.text('Dad'));
      final mom = tester.getTopLeft(find.text('Mom'));
      expect(dad.dy, lessThan(mom.dy), reason: 'Dad is the most-used chat, even though Mom is more recent');

      await tester.tap(find.text('Dad'));
      await tester.pumpAndSettle();
      expect(find.byType(MediaCaptionScreen), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'From the trip');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      final sent = api.messagesByRoom['room-dad']!.where((m) => m.kind == 'image').toList();
      expect(sent, hasLength(2));
      expect(sent.map((m) => m.body), [null, 'From the trip'], reason: 'the caption goes on the last one');
      expect(find.byType(ChatScreen), findsOneWidget);
      expect(appRouter.state.uri.path, '/chat/room-dad');
    });

    testWidgets('sharing to a Roost chat suggested in the share sheet goes straight to its review', (tester) async {
      final api = await openShare(tester, PendingShare(media: [photo('three')], roomId: 'room-mom'));

      expect(find.byType(MediaCaptionScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(api.messagesByRoom['room-mom']!.where((m) => m.kind == 'image'), hasLength(1));
      expect(appRouter.state.uri.path, '/chat/room-mom');
    });

    testWidgets('backing out of the review sends nothing and leaves you on the picker', (tester) async {
      final api = await openShare(tester, PendingShare(media: [photo('four')], roomId: 'room-mom'));

      await tester.tap(find.byIcon(Icons.close)); // the review screen's close button
      await tester.pumpAndSettle();

      expect(find.text('Share to…'), findsOneWidget);
      expect(api.messagesByRoom['room-mom'] ?? const [], isEmpty);
    });
  });
}

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
