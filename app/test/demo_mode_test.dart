import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'package:roost/data/api_client.dart';
import 'package:roost/data/api_models.dart';
import 'package:roost/demo/demo_banner.dart';
import 'package:roost/demo/demo_call_notice.dart';
import 'package:roost/demo/demo_mode.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

/// Stands in for a family server the phone can't reach — what an App Store
/// reviewer, who isn't on the family's tailnet, sees on first launch.
class _UnreachableApiClient extends FakeApiClient {
  _UnreachableApiClient() : super(FakeWsClient());

  @override
  Future<ApiUser> getMe() async => throw ApiException(503, 'unreachable');

  @override
  Future<List<ApiRoom>> listRooms() async => throw ApiException(503, 'unreachable');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpRoot(WidgetTester tester, {required bool demoAvailable, bool initialDemo = false}) async {
    appRouter.go('/');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final offline = _UnreachableApiClient();
    await tester.pumpWidget(RoostRoot(
      demoAvailable: demoAvailable,
      initialDemo: initialDemo,
      overrides: [
        apiClientProvider.overrideWithValue(offline),
        wsClientProvider.overrideWithValue(offline.ws),
        imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
      ],
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('without the build setting, the unreachable-server screen offers no demo', (tester) async {
    await pumpRoot(tester, demoAvailable: false);

    expect(find.textContaining('Could not reach the chat server'), findsOneWidget);
    expect(find.text('Explore the demo'), findsNothing);
  });

  testWidgets('"Explore the demo" signs in the demo user with sample chats, and is remembered', (tester) async {
    await pumpRoot(tester, demoAvailable: true);
    expect(find.text(demoBannerText), findsNothing);

    await tester.tap(find.text('Explore the demo'));
    await tester.pumpAndSettle();

    expect(find.text(demoBannerText), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Weekend trip'), findsOneWidget);
    expect(find.text('On my way to pick up Grandma, see you soon'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(demoModePrefKey), isTrue);
    // What a relaunch reads before its first frame (main.dart).
    expect(await loadDemoMode(available: true), isTrue);
    expect(await loadDemoMode(available: false), isFalse, reason: 'a build without the demo never starts in it');

    await tester.tap(find.text('Weekend trip'));
    await tester.pumpAndSettle();
    expect(find.textContaining("I'll bring the board games"), findsOneWidget);
  });

  testWidgets('the Family chat renders its photos, call history and live location', (tester) async {
    await pumpRoot(tester, demoAvailable: true, initialDemo: true);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.textContaining('On my way to pick up Grandma'), findsOneWidget);
    expect(find.textContaining('Practice run for Sunday'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calling in the demo explains why it is unavailable instead of calling', (tester) async {
    await pumpRoot(tester, demoAvailable: true, initialDemo: true);

    await tester.tap(find.text('Weekend trip'));
    await tester.pumpAndSettle();
    // The chat header's call button.
    await tester.tap(find.widgetWithIcon(IconButton, TablerIcons.video).first);
    await tester.pumpAndSettle();

    expect(find.text(demoCallNotice), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text(demoCallNotice), findsNothing);
    expect(find.textContaining("I'll bring the board games"), findsOneWidget, reason: 'still in the chat');
  });

  testWidgets('"Exit demo" returns to the family server and forgets the demo', (tester) async {
    await pumpRoot(tester, demoAvailable: true, initialDemo: true);
    expect(find.text(demoBannerText), findsOneWidget);

    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('Alex (Demo)'), findsWidgets);
    await tester.tap(find.text('Exit demo'));
    await tester.pumpAndSettle();

    expect(find.text(demoBannerText), findsNothing);
    expect(find.textContaining('Could not reach the chat server'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getBool(demoModePrefKey), isFalse);
    expect(await loadDemoMode(available: true), isFalse);
  });
}
