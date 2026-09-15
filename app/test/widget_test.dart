import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/main.dart';
import 'package:roost/providers/chat_providers.dart';
import 'package:roost/router/app_router.dart';

import 'fakes.dart';

const _me = ApiUser(id: 'me', displayName: 'Dev User');

FakeApiClient _seededApiClient() {
  final api = FakeApiClient(FakeWsClient())
    ..me = _me
    ..contacts = const [
      ApiContact(id: 'user-mom', displayName: 'Mom', online: true),
      ApiContact(id: 'user-dad', displayName: 'Dad', online: false),
    ]
    ..rooms = [
      ApiRoom(
        id: 'room-family',
        name: 'Family',
        isGroup: true,
        createdBy: 'me',
        createdAt: DateTime.now(),
        members: const ['me', 'user-mom', 'user-dad'],
        lastMessageBody: 'On my way, leaving now',
        lastMessageKind: 'text',
        lastMessageAt: DateTime.now(),
      ),
      ApiRoom(
        id: 'room-weekend',
        name: 'Weekend trip',
        isGroup: true,
        createdBy: 'me',
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
        members: const ['me', 'user-mom'],
        lastMessageBody: 'Booked the cabin',
        lastMessageKind: 'text',
        lastMessageAt: DateTime.now().subtract(const Duration(days: 1)),
      ),
    ];
  api.messagesByRoom['room-family'] = [
    ApiMessage(
      id: 'm1',
      roomId: 'room-family',
      senderId: 'user-mom',
      kind: 'text',
      body: "Dinner's at 7, see you all soon",
      createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
    ),
    ApiMessage(
      id: 'm2',
      roomId: 'room-family',
      senderId: 'me',
      kind: 'text',
      body: 'On my way, leaving now',
      createdAt: DateTime.now(),
    ),
    ApiMessage(
      id: 'm3',
      roomId: 'room-family',
      senderId: 'me',
      kind: 'image',
      mediaId: 'media-1',
      createdAt: DateTime.now(),
    ),
  ];
  api.mediaBytesById['media-1'] = const [1, 2, 3];
  return api;
}

Future<void> _pumpApp(WidgetTester tester, FakeApiClient api) async {
  appRouter.go('/'); // appRouter is a module-level singleton; reset between tests.
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
      ],
      child: const RoostApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Home screen lists rooms from the server', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    expect(find.text('Roost'), findsOneWidget);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Weekend trip'), findsOneWidget);
    expect(find.text('On my way, leaving now'), findsOneWidget);
  });

  testWidgets('Tapping a room opens its chat screen with real history', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Dinner's at 7"), findsOneWidget);
    expect(find.text('Message'), findsOneWidget); // the composer's hint text
  });

  testWidgets('Camera shortcut hides while typing and long-press offers video/gallery alternatives', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.camera), findsOneWidget);

    // Long-press surfaces the alternatives without invoking the (unmockable
    // in a widget test) native camera/gallery pickers.
    await tester.longPress(find.byIcon(TablerIcons.camera));
    await tester.pumpAndSettle();

    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Record video'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);

    await tester.tapAt(const Offset(200, 100)); // dismiss the sheet
    await tester.pumpAndSettle();

    // Typing hides the camera shortcut entirely (nothing to shortcut to
    // mid-message), matching WhatsApp/Telegram.
    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.pump();

    expect(find.byIcon(TablerIcons.camera), findsNothing);
  });

  testWidgets('There is no send button; hitting the keyboard\'s send action sends the message', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.send), findsNothing);

    await tester.enterText(find.byType(TextField).last, 'hello from a test');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(api.messagesByRoom['room-family']!.any((m) => m.body == 'hello from a test'), isTrue);
  });

  testWidgets('Long-pressing a message and picking an emoji adds a reaction', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining("Dinner's at 7"));
    await tester.pumpAndSettle();

    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();

    expect(find.text('👍 1'), findsOneWidget);

    // Tapping the now-present chip toggles it back off.
    await tester.tap(find.text('👍 1'));
    await tester.pumpAndSettle();

    expect(find.text('👍 1'), findsNothing);
  });

  testWidgets('Replying to a message shows a draft bar and tags the sent reply', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining("Dinner's at 7"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Replying to'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'sure, on it');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    final sent = api.messagesByRoom['room-family']!.firstWhere((m) => m.body == 'sure, on it');
    expect(sent.replyToMessageId, 'm1');
    // The draft bar clears once the reply is sent.
    expect(find.textContaining('Replying to'), findsNothing);
    // The sent reply renders a quote of the original above its own text.
    expect(find.textContaining("Dinner's at 7"), findsNWidgets(2));
  });

  testWidgets('Editing a recent message updates its body in place', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'oops typo');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining('oops typo'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    expect(find.text('Editing message'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller!.text, 'oops typo');

    await tester.enterText(find.byType(TextField).last, 'fixed now');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(api.messagesByRoom['room-family']!.any((m) => m.body == 'fixed now'), isTrue);
    expect(find.textContaining('oops typo'), findsNothing);
    expect(find.text('Editing message'), findsNothing);
  });

  testWidgets('Image messages render inline and can be deleted', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // fake:// isn't a real network scheme, so Image.network fails to load
    // and falls through to the error builder — confirming the message was
    // routed to the media renderer at all (as opposed to the plain text one).
    expect(find.byIcon(TablerIcons.photoOff), findsOneWidget);

    await tester.longPress(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();

    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.photoOff), findsNothing);
    expect(api.mediaBytesById.containsKey('media-1'), isFalse);
  });

  testWidgets('Contacts screen lists other users with presence', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.byIcon(TablerIcons.edit));
    await tester.pumpAndSettle();

    expect(find.text('Mom'), findsOneWidget);
    expect(find.text('Dad'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('Profile screen exposes a theme picker with all three modes', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.byIcon(TablerIcons.user));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(find.text('Dev User'), findsOneWidget);

    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();

    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsWidgets);
  });
}
