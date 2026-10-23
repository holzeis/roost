import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';

void main() {
  group('ApiRoom.fromJson', () {
    final base = {
      'id': 'r1',
      'name': 'Family',
      'isGroup': true,
      'createdBy': 'me',
      'createdAt': '2026-10-22T10:00:00Z',
      'members': ['me', 'mom'],
    };

    test('reads a group picture', () {
      final room = ApiRoom.fromJson({...base, 'avatarMediaId': 'media-1'});
      expect(room.avatarMediaId, 'media-1');
    });

    test('a room without one has none — the server omits the field', () {
      expect(ApiRoom.fromJson(base).avatarMediaId, isNull);
    });

    test('reads this user\'s mute, timed or not; absent means not muted', () {
      expect(ApiRoom.fromJson(base).muted, isFalse);
      expect(ApiRoom.fromJson(base).mutedUntil, isNull);
      final always = ApiRoom.fromJson({...base, 'muted': true});
      expect(always.muted, isTrue);
      expect(always.mutedUntil, isNull);
      final timed = ApiRoom.fromJson({...base, 'muted': true, 'mutedUntil': '2026-10-23T20:00:00Z'});
      expect(timed.mutedUntil, DateTime.utc(2026, 10, 23, 20));
    });
  });

  group('ApiRoom.copyWith', () {
    final room = ApiRoom(
      id: 'r1',
      name: 'Family',
      isGroup: true,
      createdBy: 'me',
      createdAt: DateTime.utc(2026, 10, 22),
      members: const ['me'],
      avatarMediaId: 'pic',
      lastMessageBody: 'hi',
    );

    test('changes only what it is given', () {
      final renamed = room.copyWith(name: 'Fam Jam');
      expect(renamed.name, 'Fam Jam');
      expect(renamed.members, ['me']);
      expect(renamed.avatarMediaId, 'pic');
      expect(renamed.lastMessageBody, 'hi');
    });

    test('muting sets the end, unmuting clears it, other changes keep it', () {
      final until = DateTime.utc(2026, 10, 23, 20);
      final muted = room.copyWith(muted: true, mutedUntil: until);
      expect(muted.muted, isTrue);
      expect(muted.mutedUntil, until);
      expect(muted.copyWith(name: 'X').mutedUntil, until);
      final unmuted = muted.copyWith(muted: false);
      expect(unmuted.muted, isFalse);
      expect(unmuted.mutedUntil, isNull);
    });
  });
}
