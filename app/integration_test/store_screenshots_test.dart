import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/demo/demo_mode.dart';
import 'package:roost/features/chat/location_message.dart';
import 'package:roost/features/chat/media_message.dart';
import 'package:roost/main.dart';
import 'package:roost/router/app_router.dart';

/// Walks the in-app demo through the screens shown on the App Store, and
/// holds each one still while tool/store_screenshots.sh captures the
/// simulator's screen (with its status bar, which an in-app screenshot
/// wouldn't have). Run it through that script, not on its own.
Future<void> _shot(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  // ignore: avoid_print
  print('STORE_SHOT:$name');
  await Future<void>.delayed(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App Store screenshots', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(demoModePrefKey);
    // No DEBUG ribbon: a simulator can only run debug builds.
    WidgetsApp.debugAllowBannerOverride = false;

    await tester.pumpWidget(const RoostRoot(demoAvailable: true));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20));
    await tester.tap(find.text('Explore the demo'));
    await _shot(tester, '1-chats');

    await tester.tap(find.text('Family'));
    await _shot(tester, '2-family-chat');

    // Scroll back a little, then tap a photo that's fully on screen.
    final chat = find.byType(Scrollable).first;
    await tester.drag(chat, const Offset(0, 500));
    await tester.pumpAndSettle();
    final visible = tester.getRect(chat);
    final photos = find.byType(MediaBubbleContent);
    final photo = [for (var i = 0; i < photos.evaluate().length; i++) tester.getRect(photos.at(i))].firstWhere(
        (r) => r.top >= visible.top && r.bottom <= visible.bottom);
    await tester.tapAt(photo.center);
    await _shot(tester, '3-photo');
    appRouter.pop();
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -1000));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LocationBubbleContent).last);
    // The map tiles load over the network.
    await Future<void>.delayed(const Duration(seconds: 5));
    await _shot(tester, '4-live-location');
    appRouter.pop();
    await tester.pumpAndSettle();

    appRouter.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Weekend trip'));
    await _shot(tester, '5-group-chat');

    await prefs.remove(demoModePrefKey);
  });
}
