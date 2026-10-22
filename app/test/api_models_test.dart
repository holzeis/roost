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
  });
}
