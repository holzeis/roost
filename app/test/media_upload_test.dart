import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/data/api_client.dart';
import 'package:roost/data/api_models.dart';
import 'package:roost/features/chat/pending_upload_row.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/main.dart';
import 'package:roost/router/app_router.dart';
import 'package:roost/services/image_shrinker.dart';

import 'fakes.dart';

/// Uploads that can be held open, or made to fail, to look at a photo
/// while it's being sent.
class _SlowUploadApi extends FakeApiClient {
  _SlowUploadApi() : super(FakeWsClient()) {
    rooms = [
      ApiRoom(id: 'room-1', isGroup: false, createdBy: 'me', createdAt: DateTime(2026), members: const ['me', 'mom']),
    ];
    contacts = const [ApiContact(id: 'mom', displayName: 'Mom', online: true)];
    messagesByRoom['room-1'] = [
      ApiMessage(id: 'm0', roomId: 'room-1', senderId: 'mom', kind: 'text', body: 'Send me a photo', createdAt: DateTime.now()),
    ];
  }

  Completer<void>? gate;
  int failures = 0;
  final uploaded = <({String filename, String contentType, int size, String kind, String? caption})>[];

  @override
  Future<ApiMessage> uploadMedia(String roomId,
      {required List<int> bytes,
      required String filename,
      required String contentType,
      required String kind,
      String? replyToMessageId,
      String? caption}) async {
    if (gate != null) await gate!.future;
    if (failures > 0) {
      failures--;
      throw ApiException(503, 'server unavailable');
    }
    uploaded.add((filename: filename, contentType: contentType, size: bytes.length, kind: kind, caption: caption));
    return super.uploadMedia(roomId,
        bytes: bytes,
        filename: filename,
        contentType: contentType,
        kind: kind,
        replyToMessageId: replyToMessageId,
        caption: caption);
  }
}

/// Records what it was asked to shrink, and halves it.
class _FakeShrinker implements ImageShrinker {
  final shrunk = <String>[];

  @override
  Future<ShrunkImage> shrink(Uint8List bytes,
      {required String contentType, required String filename, int maxLongSide = ImageShrinker.maxLongSide}) async {
    shrunk.add(filename);
    return (bytes: bytes.sublist(0, bytes.length ~/ 2), contentType: 'image/jpeg', filename: 'shrunk.jpg');
  }
}

MediaToSend _photo(String name, {String? caption, int size = 1000}) => (
      bytes: List.filled(size, 7),
      filename: name,
      contentType: 'image/heic',
      kind: 'image',
      caption: caption,
      replyToMessageId: null,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('ImageShrinker', () {
    test('caps the long side by scaling the short side, whichever way round', () {
      expect(ImageShrinker.shortSideFor((width: 4032, height: 3024), 2048), 1536);
      expect(ImageShrinker.shortSideFor((width: 3024, height: 4032), 2048), 1536);
      expect(ImageShrinker.shortSideFor((width: 3000, height: 3000), 2048), 2048);
      expect(ImageShrinker.shortSideFor(null, 2048), 1536, reason: 'unknown size: assume 4:3');
    });

    test('a shrunk photo is a JPEG', () {
      expect(ImageShrinker.jpegName('IMG_0001.HEIC'), 'IMG_0001.jpg');
      expect(ImageShrinker.jpegName('photo'), 'photo.jpg');
    });

    test('leaves videos, GIFs and small photos as they are', () async {
      const shrinker = ImageShrinker();
      final bytes = Uint8List.fromList(List.filled(100, 1));
      for (final type in ['video/mp4', 'image/gif']) {
        final out = await shrinker.shrink(bytes, contentType: type, filename: 'f');
        expect(out.bytes, same(bytes));
      }
      final png = await FakeCacheManager().getSingleFile('x');
      final small = await png.readAsBytes();
      final out = await shrinker.shrink(small, contentType: 'image/png', filename: 'small.png');
      expect((out.bytes, out.filename), (small, 'small.png'));
    });

    test('sends the original when shrinking fails', () async {
      // No platform image codec under `flutter test`.
      final bytes = Uint8List.fromList(List.filled(2 * 1024 * 1024, 1));
      final out = await const ImageShrinker().shrink(bytes, contentType: 'image/heic', filename: 'big.heic');
      expect((out.bytes, out.contentType, out.filename), (bytes, 'image/heic', 'big.heic'));
    });
  });

  group('sending photos', () {
    late _SlowUploadApi api;
    late _FakeShrinker shrinker;
    late ProviderContainer container;

    setUp(() {
      api = _SlowUploadApi();
      shrinker = _FakeShrinker();
      container = ProviderContainer(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        imageShrinkerProvider.overrideWithValue(shrinker),
      ]);
      addTearDown(container.dispose);
    });

    List<PendingUpload> pending() => container.read(pendingUploadsProvider('room-1'));

    test('a photo shows as sending right away, and goes once the server has it', () async {
      await container.read(messagesProvider('room-1').future);
      api.gate = Completer<void>();

      final sending = container.read(messagesProvider('room-1').notifier).sendMedia(
          bytes: List.filled(1000, 7), filename: 'IMG_1.HEIC', contentType: 'image/heic', kind: 'image');
      expect(pending().map((u) => u.item.filename), ['IMG_1.HEIC']);
      expect(pending().single.failed, isFalse);

      api.gate!.complete();
      await sending;
      expect(pending(), isEmpty);
      expect(api.uploaded.single, (filename: 'shrunk.jpg', contentType: 'image/jpeg', size: 500, kind: 'image', caption: null),
          reason: 'the photo went up shrunk');
    });

    test('a batch shows all at once and uploads in order; only photos are shrunk', () async {
      await container.read(messagesProvider('room-1').future);
      api.gate = Completer<void>();
      final video = (
        bytes: List.filled(10, 1),
        filename: 'clip.mov',
        contentType: 'video/quicktime',
        kind: 'video',
        caption: 'Look!',
        replyToMessageId: null,
      );

      final sending = container.read(messagesProvider('room-1').notifier).sendMediaBatch([_photo('a.heic'), video]);
      expect(pending().map((u) => u.item.filename), ['a.heic', 'clip.mov']);

      api.gate!.complete();
      await sending;
      expect(api.uploaded.map((u) => u.filename), ['shrunk.jpg', 'clip.mov']);
      expect(shrinker.shrunk, ['a.heic']);
      expect(api.uploaded.last.caption, 'Look!');
      expect(pending(), isEmpty);
    });

    test('a failed photo stays as not sent, the rest still go, and it can be retried', () async {
      await container.read(messagesProvider('room-1').future);
      api.failures = 1;
      final controller = container.read(messagesProvider('room-1').notifier);

      await expectLater(controller.sendMediaBatch([_photo('a.heic'), _photo('b.heic')]), throwsA(isA<ApiException>()));
      expect(pending().single.item.filename, 'a.heic');
      expect(pending().single.failed, isTrue);
      expect(api.uploaded, hasLength(1), reason: 'b still went');

      await controller.retryUpload(pending().single.id);
      expect(pending(), isEmpty);
      expect(api.uploaded, hasLength(2));
    });
  });

  testWidgets('the chat shows the photo while it sends, then the sent one; a failed one can be retried or discarded',
      (tester) async {
    appRouter.go('/');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _SlowUploadApi();
    final png = (await tester.runAsync(() => FakeCacheManager().getSingleFile('x').then((f) => f.readAsBytes())))!;
    await tester.pumpWidget(RoostRoot(overrides: [
      apiClientProvider.overrideWithValue(api),
      wsClientProvider.overrideWithValue(api.ws),
      imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
      imageShrinkerProvider.overrideWithValue(_FakeShrinker()),
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mom').first);
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.textContaining('Send me a photo')));
    final controller = container.read(messagesProvider('room-1').notifier);

    // Sending: shown at once, from the phone's own bytes.
    api.gate = Completer<void>();
    final sending = controller.sendMedia(
        bytes: png, filename: 'IMG_1.png', contentType: 'image/png', kind: 'image', caption: 'For you');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(PendingUploadRow), findsOneWidget);
    expect(find.text('Sending…'), findsOneWidget);
    expect(find.text('For you'), findsOneWidget);

    api.gate!.complete();
    await sending;
    await tester.pumpAndSettle();
    expect(find.byType(PendingUploadRow), findsNothing);
    expect(find.text('For you'), findsOneWidget, reason: 'now the sent message');

    // Failing: not sent, then retried.
    api.gate = null;
    api.failures = 1;
    await controller
        .sendMedia(bytes: png, filename: 'IMG_2.png', contentType: 'image/png', kind: 'image', caption: 'Again')
        .catchError((Object _) {});
    await tester.pumpAndSettle();
    expect(find.text('Not sent'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pending-upload-retry')));
    await tester.pumpAndSettle();
    expect(find.byType(PendingUploadRow), findsNothing);
    expect(find.text('Again'), findsOneWidget);

    // Failing and discarded.
    api.failures = 1;
    await controller
        .sendMedia(bytes: png, filename: 'IMG_3.png', contentType: 'image/png', kind: 'image', caption: 'Never mind')
        .catchError((Object _) {});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pending-upload-discard')));
    await tester.pumpAndSettle();
    expect(find.byType(PendingUploadRow), findsNothing);
    expect(find.text('Never mind'), findsNothing);
  });
}
