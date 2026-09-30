import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/features/chat/fast_scroll_detector.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

void main() {
  group('FastScrollDetector', () {
    bool drag(double pixelsPerFrame, {int frames = 8, bool withTimeStamps = true}) {
      final detector = FastScrollDetector()..start();
      var fast = false;
      for (var i = 1; i <= frames; i++) {
        fast = detector.update(DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: Offset(0, pixelsPerFrame),
          primaryDelta: pixelsPerFrame,
          sourceTimeStamp: withTimeStamps ? Duration(milliseconds: 16 * i) : null,
        ));
      }
      return fast;
    }

    testWidgets('a slow drag is not fast', (tester) async {
      expect(drag(8), isFalse); // ~500 px/s
    });

    testWidgets('a very fast drag is', (tester) async {
      expect(drag(60), isTrue); // ~3750 px/s
      expect(drag(-60), isTrue, reason: 'in either direction');
    });

    testWidgets('scrolling without a finger (no pointer timestamps) never counts', (tester) async {
      expect(drag(60, withTimeStamps: false), isFalse);
    });
  });

  group('the chat', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> openLongChat(WidgetTester tester) async {
      appRouter.go('/');
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeApiClient(FakeWsClient())
        ..contacts = const [ApiContact(id: 'mom', displayName: 'Mom', online: true)]
        ..rooms = [
          ApiRoom(id: 'room-1', isGroup: false, createdBy: 'mom', createdAt: DateTime(2026), members: const ['me', 'mom']),
        ];
      final start = DateTime.now().subtract(const Duration(hours: 2));
      api.messagesByRoom['room-1'] = [
        for (var i = 0; i < 80; i++)
          ApiMessage(
            id: 'm$i',
            roomId: 'room-1',
            senderId: i.isEven ? 'mom' : 'me',
            kind: 'text',
            body: 'Message number $i',
            createdAt: start.add(Duration(minutes: i)),
          ),
      ];
      await tester.pumpWidget(RoostRoot(overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
      ]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mom').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField).last);
      await tester.pumpAndSettle();
      expect(composerFocused(tester), isTrue);
    }

    testWidgets('a slow scroll keeps the keyboard up', (tester) async {
      await openLongChat(tester);

      await tester.timedDrag(find.textContaining('Message number').first, const Offset(0, 300),
          const Duration(milliseconds: 1200));
      await tester.pumpAndSettle();

      expect(composerFocused(tester), isTrue);
    });

    testWidgets('a very fast scroll hides the keyboard', (tester) async {
      await openLongChat(tester);

      await tester.fling(find.textContaining('Message number').first, const Offset(0, 400), 5000);
      await tester.pumpAndSettle();

      expect(composerFocused(tester), isFalse);
    });
  });
}

bool composerFocused(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText).last).focusNode.hasFocus;
