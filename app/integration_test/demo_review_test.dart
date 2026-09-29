import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:roost/demo/demo_banner.dart';
import 'package:roost/demo/demo_call_notice.dart';
import 'package:roost/demo/demo_mode.dart';
import 'package:roost/main.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

/// The App Store reviewer's path through the demo, on a real device or
/// simulator. Run with no reachable chat server:
///
///   flutter test integration_test/demo_review_test.dart \
///     --dart-define=DEMO_AVAILABLE=true --dart-define=API_BASE_URL=http://127.0.0.1:9
///
/// Set PAUSE_SECONDS (e.g. --dart-define=PAUSE_SECONDS=3) to linger on each
/// step, e.g. to take simulator screenshots.
const _pause = int.fromEnvironment('PAUSE_SECONDS');

/// --dart-define=KEEP_DEMO=true skips the final "Exit demo", leaving the app
/// in demo mode — to check a relaunch lands straight back in it.
const _keepDemo = bool.fromEnvironment('KEEP_DEMO');

Future<void> _linger() async {
  if (_pause > 0) await Future<void>.delayed(const Duration(seconds: _pause));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a reviewer can explore the demo end to end', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(demoModePrefKey);

    await tester.pumpWidget(const RoostRoot(demoAvailable: true));
    // The real (unreachable) server takes a moment to fail.
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 20));
    expect(find.text('Explore the demo'), findsOneWidget);
    await _linger();

    await tester.tap(find.text('Explore the demo'));
    await tester.pumpAndSettle();
    expect(find.text(demoBannerText), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(prefs.getBool(demoModePrefKey), isTrue);
    await _linger();

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    expect(find.textContaining('On my way to pick up Grandma'), findsOneWidget);
    await _linger();

    await tester.enterText(find.byType(TextField).last, 'Hello from the review!');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(find.textContaining('Hello from the review!'), findsOneWidget);
    // A family member answers a couple of seconds later.
    await Future<void>.delayed(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sounds good!'), findsOneWidget);
    await _linger();

    await tester.tap(find.widgetWithIcon(IconButton, TablerIcons.video).first);
    await tester.pumpAndSettle();
    expect(find.text(demoCallNotice), findsOneWidget);
    await _linger();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    if (!_keepDemo) {
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exit demo'));
      await tester.pumpAndSettle();
      expect(find.text(demoBannerText), findsNothing);
      expect(prefs.getBool(demoModePrefKey), isFalse);
    }
  });
}
