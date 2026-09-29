import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/demo/demo_backend.dart';
import 'package:roost/demo/demo_cache_manager.dart';
import 'package:roost/demo/demo_seed.dart';

/// The in-app demo backend (App Store review): seeded data, and the same
/// server behavior and WebSocket events the real chat server produces.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DemoBackend backend;
  late List<WsEvent> events;
  late StreamSubscription<WsEvent> sub;

  DemoBackend create({Duration statusDelay = const Duration(milliseconds: 5)}) {
    final b = DemoBackend(statusDelay: statusDelay, replyDelay: const Duration(milliseconds: 5));
    events = [];
    sub = b.ws.events.listen(events.add);
    return b;
  }

  setUp(() => backend = create());
  tearDown(() async {
    await sub.cancel();
    backend.dispose();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

  group('seed', () {
    test('signs in a demo user with a family of contacts, one of them online', () async {
      expect(await backend.api.getMe(), isA<ApiUser>().having((u) => u.id, 'id', demoMeId));
      final contacts = await backend.api.listUsers();
      expect(contacts.map((c) => c.displayName), containsAll(['Mom', 'Dad', 'Grandma', 'Sam']));
      expect(contacts.where((c) => c.online).map((c) => c.displayName), ['Grandma']);
    });

    test('has three rooms, most recently active first, with their latest message previewed', () async {
      final rooms = await backend.api.listRooms();
      expect(rooms.map((r) => r.id), unorderedEquals([demoFamilyRoomId, demoMomRoomId, demoTripRoomId]));
      for (var i = 1; i < rooms.length; i++) {
        expect(rooms[i - 1].lastMessageAt!.isAfter(rooms[i].lastMessageAt!), isTrue);
      }
      final family = rooms.firstWhere((r) => r.id == demoFamilyRoomId);
      expect(family.lastMessageBody, 'On my way to pick up Grandma, see you soon');
    });

    test('covers photos, reactions, replies, a forward, an edit, calls and a live location', () async {
      final all = [
        for (final roomId in [demoFamilyRoomId, demoMomRoomId, demoTripRoomId])
          ...await backend.api.listMessages(roomId),
      ];
      final now = DateTime.now();
      expect(all.every((m) => m.createdAt.isBefore(now)), isTrue);
      expect(all.where((m) => m.kind == 'image' && m.mediaId != null), hasLength(3));
      expect(all.any((m) => m.reactions.any((r) => r.reactedByMe)), isTrue);
      expect(all.any((m) => m.replyTo != null), isTrue);
      expect(all.any((m) => m.forwarded), isTrue);
      expect(all.any((m) => m.editedAt != null), isTrue);
      expect(all.where((m) => m.kind == 'call').map((m) => m.call!.status), unorderedEquals(['missed', 'completed']));
      final live = all.singleWhere((m) => m.kind == 'location');
      expect(live.location!.expiresAt.isAfter(now), isTrue);
      expect(all.where((m) => m.senderId == demoMeId).every((m) => m.status == 'seen'), isTrue);
    });

    test('lists history newest first and pages with before/limit', () async {
      final page = await backend.api.listMessages(demoFamilyRoomId, limit: 3);
      expect(page, hasLength(3));
      expect(page[0].createdAt.isAfter(page[1].createdAt), isTrue);
      final older = await backend.api.listMessages(demoFamilyRoomId, before: page.last.createdAt, limit: 50);
      expect(older.every((m) => m.createdAt.isBefore(page.last.createdAt)), isTrue);
    });
  });

  group('sending', () {
    test('broadcasts the message, ticks it delivered then seen, and gets a typed reply', () async {
      final sent = await backend.api.sendTextMessage(demoMomRoomId, 'Hi Mom!');
      await settle();

      expect(events.first.type, 'message.created');
      expect(events.first.payload['id'], sent.id);
      final statuses = [
        for (final e in events)
          if (e.type == 'message.status' && e.payload['messageId'] == sent.id) e.payload['status'],
      ];
      expect(statuses, ['delivered', 'seen']);

      final typing = [for (final e in events) if (e.type == 'typing') e.payload['typing']];
      expect(typing, [true, false]);
      final reply = events.lastWhere((e) => e.type == 'message.created');
      expect(reply.payload['senderId'], 'demo-mom');
      expect(reply.payload['roomId'], demoMomRoomId);
    });

    test('a reply quotes the message it answers', () async {
      final original = (await backend.api.listMessages(demoMomRoomId)).last;
      final sent = await backend.api.sendTextMessage(demoMomRoomId, 'About that…', replyToMessageId: original.id);
      expect(sent.replyTo?.id, original.id);
    });

    test('uploads and downloads media, and serves it to the image cache', () async {
      final sent = await backend.api.uploadMedia(demoFamilyRoomId,
          bytes: [1, 2, 3], filename: 'x.jpg', contentType: 'image/jpeg', kind: 'image', caption: 'hi');
      expect(await backend.api.downloadMedia(sent.mediaId!), [1, 2, 3]);
      final file = await DemoCacheManager(backend).getSingleFile(backend.api.mediaPreviewUrl(sent.mediaId!));
      expect(await file.readAsBytes(), [1, 2, 3]);
    });

    test('serves the bundled seed photos', () async {
      final photo = (await backend.api.listMessages(demoFamilyRoomId)).firstWhere((m) => m.kind == 'image');
      final bytes = await backend.api.downloadMedia(photo.mediaId!);
      expect(bytes.take(2), [0xFF, 0xD8]); // a JPEG
      expect(backend.api.mediaUrl(photo.mediaId!), startsWith('demo://media/'));
    });

    test('plays a recorded video from a local file', () async {
      final sent = await backend.api.uploadMedia(demoFamilyRoomId,
          bytes: [9, 9], filename: 'clip.mp4', contentType: 'video/mp4', kind: 'video');
      final url = backend.api.mediaUrl(sent.mediaId!);
      expect(Uri.parse(url).scheme, 'file');
      expect(await backend.api.downloadMedia(sent.mediaId!), [9, 9]);
    });

    test('the cache manager rejects anything that is not demo media', () {
      expect(DemoCacheManager(backend).getSingleFile('https://example.com/x.jpg'), throwsA(anything));
    });
  });

  group('acting on messages', () {
    test('reactions are toggled once per user and reflected in history', () async {
      final target = (await backend.api.listMessages(demoMomRoomId)).first;
      await backend.api.addReaction(target.id, '🎉');
      await backend.api.addReaction(target.id, '🎉'); // no second event
      expect(events.where((e) => e.type == 'reaction.added'), hasLength(1));
      final reacted = (await backend.api.listMessages(demoMomRoomId)).first;
      expect(reacted.reactions.singleWhere((r) => r.emoji == '🎉').reactedByMe, isTrue);

      await backend.api.removeReaction(target.id, '🎉');
      expect(events.last.type, 'reaction.removed');
      expect((await backend.api.listMessages(demoMomRoomId)).first.reactions.any((r) => r.emoji == '🎉'), isFalse);
    });

    test('editing updates the body and marks it edited', () async {
      final sent = await backend.api.sendTextMessage(demoTripRoomId, 'typo');
      final edited = await backend.api.editMessage(sent.id, 'fixed');
      expect(edited.body, 'fixed');
      expect(edited.editedAt, isNotNull);
      expect(events.any((e) => e.type == 'message.updated' && e.payload['body'] == 'fixed'), isTrue);
    });

    test('forwarding copies the message, and its photo, into another room', () async {
      final photo = (await backend.api.listMessages(demoFamilyRoomId)).firstWhere((m) => m.kind == 'image');
      final forwarded = await backend.api.forwardMessage(photo.id, demoMomRoomId);
      expect(forwarded.forwarded, isTrue);
      expect(forwarded.roomId, demoMomRoomId);
      expect(forwarded.mediaId, isNot(photo.mediaId));
      expect(await backend.api.downloadMedia(forwarded.mediaId!), await backend.api.downloadMedia(photo.mediaId!));
    });

    test('deleting a seen message leaves a placeholder; an unseen one disappears (FR1.15)', () async {
      final seen = (await backend.api.listMessages(demoMomRoomId)).firstWhere((m) => m.senderId == demoMeId && m.kind == 'text');
      await backend.api.deleteMessage(seen.id);
      final placeholder = (await backend.api.listMessages(demoMomRoomId)).singleWhere((m) => m.id == seen.id);
      expect(placeholder.isDeleted, isTrue);
      expect(placeholder.body, isNull);
      expect(placeholder.reactions, isEmpty);

      backend.dispose();
      await sub.cancel();
      backend = create(statusDelay: const Duration(hours: 1)); // never gets seen
      final unseen = await backend.api.sendTextMessage(demoMomRoomId, 'oops');
      await backend.api.deleteMessage(unseen.id);
      expect(events.last.type, 'message.deleted');
      expect((await backend.api.listMessages(demoMomRoomId)).any((m) => m.id == unseen.id), isFalse);
    });

    test('a deleted message can no longer be edited, reacted to or found by search', () async {
      final seen = (await backend.api.listMessages(demoMomRoomId)).firstWhere((m) => m.senderId == demoMeId && m.kind == 'text');
      await backend.api.deleteMessage(seen.id);
      expect(backend.api.editMessage(seen.id, 'x'), throwsA(isA<Exception>()));
      expect(backend.api.addReaction(seen.id, '👍'), throwsA(isA<Exception>()));
      expect(await backend.api.searchMessages(demoMomRoomId, 'Thursday'), isEmpty);
    });

    test('a new 1:1 chat with someone who already has one reuses it', () async {
      final room = await backend.api.createRoom(isGroup: false, memberIds: const ['demo-mom']);
      expect(room.id, demoMomRoomId);
      final dad = await backend.api.createRoom(isGroup: false, memberIds: const ['demo-dad']);
      expect(dad.members, containsAll([demoMeId, 'demo-dad']));
    });

    test('location shares can be started, moved and ended', () async {
      final share = await backend.api.shareLocation(demoFamilyRoomId, lat: 1, lng: 2, ttl: const Duration(hours: 1));
      final moved = await backend.api.updateLocation(share.id, lat: 3, lng: 4);
      expect(moved.location!.lat, 3);
      final ended = await backend.api.endLocationShare(share.id);
      expect(ended.location!.endedAt, isNotNull);
    });

    test('calls are unavailable, and nothing is registered for push', () async {
      expect(backend.api.startCall(demoMomRoomId), throwsA(isA<DemoUnavailableException>()));
      expect(backend.api.mintLiveKitToken(demoMomRoomId), throwsA(isA<DemoUnavailableException>()));
      await backend.api.registerDevice(platform: 'ios', pushToken: 't');
      expect(await backend.api.fetchLinkPreview('https://example.com'), isNull);
    });
  });
}
