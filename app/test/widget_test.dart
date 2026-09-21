import 'dart:typed_data';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import 'package:roost/data/api_models.dart';
import 'package:roost/data/ws_client.dart';
import 'package:roost/features/chat/location_message.dart';
import 'package:roost/features/chat/message_action_overlay.dart';
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

Future<void> _pumpApp(WidgetTester tester, FakeApiClient api, {List<Override> extraOverrides = const []}) async {
  appRouter.go('/'); // appRouter is a module-level singleton; reset between tests.
  // The default test surface is 800x600 — wider than tall, unlike any real
  // phone — which starves message_action_overlay.dart's fit-check of the
  // vertical room a real device always has. A realistic portrait size here
  // means that fit-check exercises its normal path (scroll-if-needed)
  // instead of its degenerate one (nothing left to scroll).
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        wsClientProvider.overrideWithValue(api.ws),
        ...extraOverrides,
      ],
      child: const RoostApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Without this, a bare SharedPreferences.getInstance() (used by
  // quickReactionsProvider and, transitively, the emoji_picker_flutter
  // package's own recent-emoji tracking) hangs forever under flutter_test
  // rather than resolving to empty prefs — no timeout, no error, it just
  // never completes, silently stalling anything that awaits it.
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

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

  testWidgets("The composer's message field renders as a rounded box, not a square", (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // Regression test: the app-wide InputDecorationTheme defaults every
    // TextField to filled:true with a *square* fallback fill shape once
    // there's no OutlineInputBorder to borrow a radius from — that fill
    // paints right over this field's own rounded DecoratedBox background,
    // squaring off what should read as rounded, unless this field opts out
    // of the theme's fill with an explicit filled:false of its own.
    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.decoration?.filled, isFalse);

    final decoratedBox = tester.widget<DecoratedBox>(
      find.ancestor(of: find.byType(TextField).last, matching: find.byType(DecoratedBox)).first,
    );
    final decoration = decoratedBox.decoration as BoxDecoration;
    expect((decoration.borderRadius as BorderRadius?)?.topLeft.x, greaterThanOrEqualTo(12));
  });

  testWidgets('The chat title uses the message body font, not the AppBar\'s display serif', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // Regression test: the app-wide AppBarTheme.titleTextStyle is a
    // deliberately different display face (Zilla Slab) for plain screen
    // titles, but the chat title sits directly above message text set in
    // the body font (Hanken Grotesk) — it must match that, not the
    // ambient AppBar style, or the two clash right next to each other.
    final context = tester.element(find.text('Family').last);
    final title = tester.widget<Text>(find.text('Family').last);
    final bodyFamily = Theme.of(context).textTheme.bodyLarge?.fontFamily;
    final appBarFamily = Theme.of(context).appBarTheme.titleTextStyle?.fontFamily;
    expect(bodyFamily, isNotNull);
    expect(appBarFamily, isNotNull);
    expect(appBarFamily, isNot(equals(bodyFamily)));
    expect(title.style?.fontFamily, equals(bodyFamily));
  });

  testWidgets('Camera shortcut stays visible while typing and jumps straight to the camera on tap', (tester) async {
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FakeImagePickerPlatform(Uint8List.fromList([1, 2, 3]));
    addTearDown(() => ImagePickerPlatform.instance = originalPlatform);

    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.camera), findsOneWidget);

    // A plain tap goes straight to the camera — no chooser in between —
    // and sends whatever comes back as an image message.
    await tester.tap(find.byIcon(TablerIcons.camera));
    await tester.pumpAndSettle();

    expect(
      api.messagesByRoom['room-family']!.any((m) => m.kind == 'image' && m.senderId == 'me'),
      isTrue,
    );

    // Stays visible while composing text, rather than hiding once there's
    // something typed.
    await tester.enterText(find.byType(TextField).last, 'hi');
    await tester.pump();

    expect(find.byIcon(TablerIcons.camera), findsOneWidget);
  });

  testWidgets('The "+" attach tray shows Photos/Camera/Video/Location and swaps with the keyboard', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.plus), findsOneWidget);
    expect(find.byIcon(TablerIcons.keyboard), findsNothing);

    await tester.tap(find.byIcon(TablerIcons.plus));
    await tester.pumpAndSettle();

    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    // The leading icon swapped to a keyboard glyph while the tray is open.
    expect(find.byIcon(TablerIcons.plus), findsNothing);
    expect(find.byIcon(TablerIcons.keyboard), findsOneWidget);

    // Tapping Location closes the tray and opens the usual location sheet.
    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();
    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.text('Photos'), findsNothing);

    await tester.tapAt(const Offset(200, 100)); // dismiss the sheet
    await tester.pumpAndSettle();
    expect(find.byIcon(TablerIcons.plus), findsOneWidget);

    // Reopen the tray, then swap back to the keyboard directly.
    await tester.tap(find.byIcon(TablerIcons.plus));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsOneWidget);

    await tester.tap(find.byIcon(TablerIcons.keyboard));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsNothing);
    expect(find.byIcon(TablerIcons.plus), findsOneWidget);
  });

  testWidgets('The attach tray\'s Photos option sends whatever the gallery picker returns', (tester) async {
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FakeImagePickerPlatform(Uint8List.fromList([1, 2, 3]), name: 'trip.jpg');
    addTearDown(() => ImagePickerPlatform.instance = originalPlatform);

    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(TablerIcons.plus));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Photos'));
    await tester.pumpAndSettle();

    expect(
      api.messagesByRoom['room-family']!.any((m) => m.kind == 'image' && m.senderId == 'me'),
      isTrue,
    );
  });

  testWidgets('The attach tray\'s Video option records a video and sends it', (tester) async {
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FakeImagePickerPlatform(
      Uint8List.fromList([1, 2, 3]),
      name: 'clip.mp4',
      mimeType: 'video/mp4',
    );
    addTearDown(() => ImagePickerPlatform.instance = originalPlatform);

    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(TablerIcons.plus));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Video'));
    await tester.pumpAndSettle();

    expect(
      api.messagesByRoom['room-family']!.any((m) => m.kind == 'video' && m.senderId == 'me'),
      isTrue,
    );
  });

  testWidgets('Tapping directly into the message field closes the attach tray', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(TablerIcons.plus));
    await tester.pumpAndSettle();
    expect(find.text('Photos'), findsOneWidget);

    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();

    expect(find.text('Photos'), findsNothing);
    expect(find.byIcon(TablerIcons.plus), findsOneWidget);
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

  testWidgets('Typing pings the room and stops once the message is sent (FR1.7)', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, 'writing something');
    await tester.pump();

    expect(api.ws.typingSent, contains(('room-family', true)));
    expect(api.ws.typingSent.last, ('room-family', true));

    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(api.ws.typingSent.last, ('room-family', false));
  });

  testWidgets('The chat title shows a typing indicator that clears when typing stops (FR1.7)', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    api.ws.emit(const WsEvent('typing', {'roomId': 'room-family', 'userId': 'user-mom', 'typing': true}));
    await tester.pumpAndSettle();

    expect(find.textContaining('Mom is typing'), findsOneWidget);

    api.ws.emit(const WsEvent('typing', {'roomId': 'room-family', 'userId': 'user-mom', 'typing': false}));
    await tester.pumpAndSettle();

    expect(find.textContaining('is typing'), findsNothing);
    // Falls back to the member-count subtitle once nobody is typing.
    expect(find.text('3 MEMBERS'), findsOneWidget);
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

  testWidgets('A reacted-with emoji stays visible (highlighted) in the picker, not hidden', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining("Dinner's at 7"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();

    // Reopen the picker on the same message — 👍 used to be filtered out
    // entirely once reacted; it should still be offered (highlighted, not
    // testable visually here, but present) so tapping it again can change it.
    await tester.longPress(find.textContaining("Dinner's at 7"));
    await tester.pumpAndSettle();

    expect(find.text('👍'), findsOneWidget);
  });

  testWidgets('The "+" in the reaction picker opens an emoji-only picker, not the system keyboard', (tester) async {
    await _pumpApp(tester, _seededApiClient());

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining("Dinner's at 7"));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget); // the action menu is up

    // Scoped to the picker: the composer's own "+" attach-tray button uses
    // the same icon and is still on screen underneath.
    await tester.tap(find.descendant(
        of: find.byType(ReactionPicker), matching: find.byIcon(TablerIcons.plus)));
    await tester.pumpAndSettle();

    // A real emoji grid opened directly — not an extra text field (the
    // composer's own message field is the only TextField anywhere here)
    // that would only reach emoji via the system keyboard's own
    // globe/emoji switch. Category tabs (Recent, Smileys, ...) confirm
    // it's the full categorized picker, not a bare grid.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(EmojiPicker), findsOneWidget);
    expect(find.byType(Tab), findsWidgets);

    // The action overlay (scrim, lifted bubble, Reply/Forward/Copy menu)
    // is gone rather than stacked underneath the emoji picker's own sheet.
    expect(find.text('Reply'), findsNothing);
    expect(find.text('Forward'), findsNothing);
    expect(find.text('Copy'), findsNothing);
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

  testWidgets('Replying to a photo shows a thumbnail in the draft bar and the sent reply', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    final imagesBeforeReply = find.byType(Image).evaluate().length;

    await tester.longPress(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Replying to'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget); // label — this message has no caption
    // The draft bar's own thumbnail is a new Image widget (fake:// isn't a
    // real network scheme, so it falls through to the same error-icon
    // fallback as everywhere else, but the widget itself confirms a
    // thumbnail was attempted, which is what mediaId being threaded through
    // the draft actually enables here).
    expect(find.byType(Image).evaluate().length, greaterThan(imagesBeforeReply));

    await tester.enterText(find.byType(TextField).last, 'nice shot');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    final sent = api.messagesByRoom['room-family']!.firstWhere((m) => m.body == 'nice shot');
    expect(sent.replyToMessageId, 'm3');
    // The sent reply's own quote chip also carries a thumbnail attempt.
    expect(find.byType(Image).evaluate().length, greaterThan(imagesBeforeReply));
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

  testWidgets('Deleting a text message asks for confirmation and can be cancelled', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining('On my way, leaving now'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // FR1.15: a confirmation sheet, not an immediate delete.
    expect(find.text('Delete this message?'), findsOneWidget);
    expect(find.textContaining('On my way, leaving now'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Cancelling leaves the message untouched.
    expect(find.textContaining('On my way, leaving now'), findsOneWidget);
    expect(api.messagesByRoom['room-family']!.any((m) => m.id == 'm2'), isTrue);

    await tester.longPress(find.textContaining('On my way, leaving now'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('On my way, leaving now'), findsNothing);
    expect(api.messagesByRoom['room-family']!.any((m) => m.id == 'm2'), isFalse);
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

    // Deleting is destructive, so it's confirmed via a bottom sheet first
    // rather than acting immediately (FR1.15/FR2.5).
    expect(find.text('Delete this message?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.photoOff), findsNothing);
    expect(api.mediaBytesById.containsKey('media-1'), isFalse);
  });

  testWidgets('A group chat names who shared a photo, but never for the viewer\'s own', (tester) async {
    final api = _seededApiClient();
    api.messagesByRoom['room-family']!.add(
      ApiMessage(
        id: 'm4',
        roomId: 'room-family',
        senderId: 'user-mom',
        kind: 'image',
        mediaId: 'media-2',
        createdAt: DateTime.now(),
      ),
    );
    api.mediaBytesById['media-2'] = const [1, 2, 3];
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // Two "Mom" labels: the existing text message (m1) and the new image
    // (m4) — both from her. m3, sent by the viewer themself, gets none.
    expect(find.text('Mom'), findsNWidgets(2));
    expect(find.text('Dev User'), findsNothing);
    expect(find.text('Me'), findsNothing);
  });

  testWidgets('Tapping an image opens the full-screen viewer, where react and reply both work',
      (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // A plain tap (not long-press) opens the viewer.
    await tester.tap(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();

    // Now on the media viewer, not the chat screen — its back button and
    // react button are the ones the chat screen doesn't have.
    expect(find.byIcon(TablerIcons.moodSmile), findsOneWidget);

    await tester.tap(find.byIcon(TablerIcons.moodSmile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();

    // Reactions land in messagesProvider's own state via the reaction.added
    // WS round-trip (see chat_providers.dart's _applyReactionEvent), not in
    // the fake client's backing store — back on the chat screen is where
    // that state actually renders, same as the long-press reaction test.
    await tester.tap(find.byIcon(TablerIcons.chevronLeft));
    await tester.pumpAndSettle();
    expect(find.text('👍 1'), findsOneWidget);

    await tester.tap(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();

    // Reply hands off to the regular composer draft and returns to the chat
    // (the app bar title is chat-screen-only — the viewer has none).
    expect(find.text('Family'), findsOneWidget);
    expect(find.textContaining('Replying to'), findsOneWidget);
  });

  testWidgets('The viewer shows an existing reaction and lets the viewer change it', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();

    // React with 👍 first.
    await tester.tap(find.byIcon(TablerIcons.moodSmile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();

    // The add button is now the reaction itself, showing what was picked —
    // not the plain smile icon anymore.
    expect(find.byIcon(TablerIcons.moodSmile), findsNothing);
    expect(find.text('👍 1'), findsOneWidget);

    // Tapping it again reopens the picker; picking a different emoji swaps
    // the reaction rather than adding a second one alongside it.
    await tester.tap(find.text('👍 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('❤️'));
    await tester.pumpAndSettle();

    expect(find.text('👍 1'), findsNothing);
    expect(find.text('❤️ 1'), findsOneWidget);
  });

  testWidgets('The viewer shows someone else\'s reaction beside the add button', (tester) async {
    final api = _seededApiClient();
    final messages = api.messagesByRoom['room-family']!;
    final imageIndex = messages.indexWhere((m) => m.id == 'm3');
    messages[imageIndex] = messages[imageIndex].copyWith(
      reactions: const [ApiReaction(emoji: '😮', count: 1, reactedByMe: false)],
    );
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();

    // Mom's reaction sits next to the still-available add button — it isn't
    // the viewer's own reaction, so it doesn't replace it.
    expect(find.byIcon(TablerIcons.moodSmile), findsOneWidget);
    expect(find.text('😮 1'), findsOneWidget);

    // Tapping someone else's reaction adds that same emoji as the viewer's
    // own — it merges into the same emoji's count rather than sitting
    // beside it as a second entry.
    await tester.tap(find.text('😮 1'));
    await tester.pumpAndSettle();

    expect(find.text('😮 2'), findsOneWidget);
    expect(find.byIcon(TablerIcons.moodSmile), findsNothing);
  });

  testWidgets('The viewer offers to delete a photo the viewer sent themself, and returns to chat', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(TablerIcons.photoOff));
    await tester.pumpAndSettle();

    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Same confirm-before-deleting sheet as the chat screen's own action
    // menu (FR1.15/FR2.5).
    expect(find.text('Delete this photo/video?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // Nothing else to view (m3 was the only image) — back on the chat.
    expect(find.text('Family'), findsOneWidget);
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

  testWidgets('An own message shows a status tick that updates on a message.status event (FR1.5, FR1.6)', (tester) async {
    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // m2 ('On my way, leaving now') is the only text message from 'me' in
    // the seeded history; m3 is an image and doesn't render a status tick.
    expect(find.byIcon(TablerIcons.check), findsOneWidget);
    expect(find.byIcon(TablerIcons.checks), findsNothing);

    api.ws.emit(const WsEvent('message.status', {'messageId': 'm2', 'roomId': 'room-family', 'status': 'delivered'}));
    await tester.pumpAndSettle();

    expect(find.byIcon(TablerIcons.check), findsNothing);
    expect(find.byIcon(TablerIcons.checks), findsOneWidget);

    api.ws.emit(const WsEvent('message.status', {'messageId': 'm2', 'roomId': 'room-family', 'status': 'seen'}));
    await tester.pumpAndSettle();

    // Still the double-check glyph — "seen" is distinguished by opacity,
    // not a different icon (see chat_screen.dart's _statusIconSpan).
    expect(find.byIcon(TablerIcons.checks), findsOneWidget);
  });

  testWidgets('Sharing a location posts a live share and the bubble shows it as active (FR3.1, FR3.2, FR3.6, FR3.7)',
      (tester) async {
    final api = _seededApiClient();
    final location = FakeLocationService()..initialPosition = FakeLocationService.testPosition(52.5, 13.4);
    await _pumpApp(tester, api, extraOverrides: [locationServiceProvider.overrideWithValue(location)]);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(TablerIcons.plus));
    await tester.pumpAndSettle();
    expect(find.text('Location'), findsOneWidget);
    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();

    expect(find.text('15 minutes'), findsOneWidget);
    expect(find.text('1 hour'), findsOneWidget);
    expect(find.text('Until I arrive'), findsOneWidget);
    await tester.tap(find.text('15 minutes'));
    await tester.pumpAndSettle();

    final shared = api.messagesByRoom['room-family']!.firstWhere((m) => m.kind == 'location');
    expect(shared.location!.lat, 52.5);
    expect(shared.location!.lng, 13.4);
    expect(location.requestPermissionCalls, 1);
    expect(find.textContaining('Live ·'), findsOneWidget);

    // No bubble-colored frame around the map, same as a photo/video bubble.
    final bubbleContainer = tester.widget<Container>(find
        .ancestor(of: find.byType(LocationBubbleContent), matching: find.byType(Container))
        .first);
    expect(bubbleContainer.padding, EdgeInsets.zero);
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

  testWidgets('Picking a new profile photo uploads it and sets the avatar', (tester) async {
    final originalPlatform = ImagePickerPlatform.instance;
    ImagePickerPlatform.instance = FakeImagePickerPlatform(Uint8List.fromList([1, 2, 3]));
    addTearDown(() => ImagePickerPlatform.instance = originalPlatform);

    final api = _seededApiClient();
    await _pumpApp(tester, api);

    await tester.tap(find.byIcon(TablerIcons.user));
    await tester.pumpAndSettle();
    expect(find.text('Profile'), findsWidgets);
    expect(api.me.avatarMediaId, isNull);

    await tester.tap(find.byIcon(TablerIcons.camera));
    await tester.pumpAndSettle();

    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);

    await tester.tap(find.text('Choose from gallery'));
    await tester.pumpAndSettle();

    expect(api.me.avatarMediaId, isNotNull);
    // Renders the freshly uploaded photo instead of the initial fallback —
    // fake:// isn't a real network scheme, so it falls through to the same
    // error builder the initial letter would otherwise show, but the
    // Image.network widget itself only appears once avatarMediaId is set.
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('Tapping a missed call message asks for confirmation instead of joining immediately', (tester) async {
    final api = _seededApiClient();
    api.messagesByRoom['room-family']!.add(
      ApiMessage(
        id: 'callmsg-1',
        roomId: 'room-family',
        senderId: 'user-mom',
        kind: 'call',
        createdAt: DateTime.now(),
        call: ApiCall(id: 'call-1', status: 'missed', startedAt: DateTime.now()),
      ),
    );
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    expect(find.text('Missed call'), findsOneWidget);
    await tester.tap(find.text('Missed call'));
    await tester.pumpAndSettle();

    // The sheet, not a call screen — tapping a call message must not join
    // or start a call on its own.
    expect(find.text('Call back?'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Call'), findsOneWidget);
    expect(find.text('Missed call'), findsOneWidget); // still on the chat screen

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Call back?'), findsNothing);
    expect(find.text('Family'), findsOneWidget); // chat screen, undisturbed
  });

  testWidgets('A date divider separates messages sent on different days', (tester) async {
    final api = _seededApiClient();
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    api.messagesByRoom['room-family']!.insert(
      0,
      ApiMessage(
        id: 'm0',
        roomId: 'room-family',
        senderId: 'user-mom',
        kind: 'text',
        body: 'good morning from yesterday',
        createdAt: DateTime(yesterday.year, yesterday.month, yesterday.day, 9),
      ),
    );
    await _pumpApp(tester, api);

    await tester.tap(find.text('Family'));
    await tester.pumpAndSettle();

    // findsWidgets rather than findsOneWidget: the sticky date-pill overlay
    // (see chat_screen.dart's _DatePill) renders its own copy of whichever
    // label is current, invisible via opacity rather than absent from the
    // tree, so it's a legitimate second match alongside the inline divider.
    expect(find.text('Yesterday'), findsWidgets);
    expect(find.text('Today'), findsWidgets);
  });
}
