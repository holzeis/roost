import 'package:flutter_test/flutter_test.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/features/chat/media_viewer_screen.dart';

ApiMessage _message(String id, String kind) => ApiMessage(
      id: id,
      roomId: 'room-1',
      senderId: 'user-1',
      kind: kind,
      mediaId: kind == 'text' ? null : 'media-$id',
      createdAt: DateTime.now(),
    );

void main() {
  group('mediaMessagesIn', () {
    test('keeps only image/video messages, in their given order', () {
      final messages = [
        _message('1', 'text'),
        _message('2', 'image'),
        _message('3', 'location'),
        _message('4', 'video'),
        _message('5', 'call'),
      ];
      final media = mediaMessagesIn(messages);
      expect(media.map((m) => m.id), ['2', '4']);
    });

    test('returns an empty list when there is no media', () {
      expect(mediaMessagesIn([_message('1', 'text')]), isEmpty);
    });
  });

  group('initialMediaIndex', () {
    test('finds the tapped message among the media-only list', () {
      final media = [_message('2', 'image'), _message('4', 'video')];
      expect(initialMediaIndex(media, '4'), 1);
    });

    test('falls back to the first page if the message is missing', () {
      final media = [_message('2', 'image')];
      expect(initialMediaIndex(media, 'gone'), 0);
    });
  });
}
