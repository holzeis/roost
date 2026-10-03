import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photo_view/photo_view.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/features/profile/avatar_viewer_screen.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/providers/image_cache_provider.dart';
import 'package:roost/router/app_router.dart';
import 'package:roost/widgets/avatar.dart';

import '../test/fakes.dart';

/// Tapping someone's profile picture shows it full screen, on a real
/// device or simulator — the picture decoded and drawn, then back to where
/// it was tapped. Run with:
///
///   flutter test integration_test/avatar_viewer_test.dart -d <device-id>
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a profile picture opens full screen and closes again', (tester) async {
    final api = FakeApiClient(FakeWsClient())
      ..contacts = const [ApiContact(id: 'mom', displayName: 'Mom', online: true, avatarMediaId: 'avatar-mom')]
      ..rooms = [
        ApiRoom(id: 'room-1', isGroup: false, createdBy: 'me', createdAt: DateTime.now(), members: const ['me', 'mom']),
      ];
    appRouter.go('/');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        imageCacheManagerProvider.overrideWithValue(FakeCacheManager()),
      ],
      child: const RoostApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate((w) => w is InitialAvatar && w.avatarMediaId == 'avatar-mom').first);
    await tester.pumpAndSettle();

    expect(find.byType(AvatarViewerScreen), findsOneWidget);
    final drawn = find.descendant(of: find.byType(PhotoView), matching: find.byType(RawImage));
    await tester.pumpAndSettle();
    expect(tester.widget<RawImage>(drawn.first).image, isNotNull, reason: 'the picture is decoded and drawn');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(AvatarViewerScreen), findsNothing);
    expect(find.text('Mom'), findsWidgets);
  });
}
