import '../data/api_models.dart';
import 'demo_backend.dart';

/// The demo's signed-in user.
const demoMeId = 'demo-alex';

/// The demo's rooms, exposed so tests can find them.
const demoFamilyRoomId = 'demo-room-family';
const demoMomRoomId = 'demo-room-mom';
const demoTripRoomId = 'demo-room-trip';

/// Fills [b] with a small, believable family: a group chat, a 1:1 with Mom
/// and a trip-planning group, spread over the last few days relative to
/// [now] so the demo always looks current. Covers what a reviewer should
/// see: replies, a forward, reactions, an edit, photos, read ticks, call
/// history and a live location share.
void seedDemo(DemoBackend b, DateTime now) {
  b.me = const ApiUser(id: demoMeId, displayName: 'Alex (Demo)');
  const mom = 'demo-mom', dad = 'demo-dad', grandma = 'demo-grandma', sam = 'demo-sam';
  for (final (id, name, online) in [
    (mom, 'Mom', false),
    (dad, 'Dad', false),
    (grandma, 'Grandma', true),
    (sam, 'Sam', false),
  ]) {
    b.addContact(ApiContact(id: id, displayName: name, online: online));
  }

  // Days ago at a wall-clock time, or minutes before now for today's
  // messages — both always in the past.
  DateTime at(int daysAgo, int hour, int minute) =>
      DateTime(now.year, now.month, now.day - daysAgo, hour, minute);
  DateTime ago(int minutes) => now.subtract(Duration(minutes: minutes));

  final start = at(4, 9, 0);
  b.addRoom(ApiRoom(
      id: demoFamilyRoomId,
      name: 'Family',
      isGroup: true,
      createdBy: mom,
      createdAt: start,
      members: const [demoMeId, mom, dad, grandma, sam]));
  b.addRoom(ApiRoom(
      id: demoMomRoomId, isGroup: false, createdBy: mom, createdAt: start, members: const [demoMeId, mom]));
  b.addRoom(ApiRoom(
      id: demoTripRoomId,
      name: 'Weekend trip',
      isGroup: true,
      createdBy: sam,
      createdAt: start,
      members: const [demoMeId, dad, sam]));

  var n = 0;
  ApiMessage add(
    String roomId,
    String senderId,
    DateTime createdAt, {
    String kind = 'text',
    String? body,
    String? mediaId,
    ApiMediaInfo? media,
    String? replyTo,
    bool forwarded = false,
    DateTime? editedAt,
    ApiCall? call,
    ApiLocationShare? location,
  }) {
    final message = ApiMessage(
      id: 'demo-seed-${++n}',
      roomId: roomId,
      senderId: senderId,
      kind: kind,
      body: body,
      mediaId: mediaId,
      media: media,
      createdAt: createdAt,
      editedAt: editedAt,
      replyToMessageId: replyTo,
      replyTo: b.snippetFor(replyTo),
      forwarded: forwarded,
      // The demo user's own messages have all been read by now.
      status: senderId == demoMeId ? 'seen' : 'delivered',
      call: call,
      location: location,
    );
    b.addMessage(message);
    return message;
  }

  const photo = ApiMediaInfo(width: 1200, height: 900);
  String asset(String name) {
    final id = 'demo-media-$name';
    b.assetMedia[id] = 'assets/demo/$name.jpg';
    return id;
  }

  // Weekend trip
  final cabin = add(demoTripRoomId, sam, at(3, 19, 12), body: 'Cabin is booked for the 14th! 🏡');
  add(demoTripRoomId, dad, at(3, 19, 30), body: 'Weather forecast: sunny all weekend ☀️', forwarded: true);
  final games = add(demoTripRoomId, demoMeId, at(3, 19, 41), body: "Perfect, I'll bring the board games 🎲");
  b.react(games.id, sam, '🙌');
  add(demoTripRoomId, sam, at(2, 8, 5),
      kind: 'image', body: "The trail we'll hike", mediaId: asset('autumn_walk'), media: photo);
  add(demoTripRoomId, dad, at(2, 8, 20), body: 'Looks great. Leaving Friday at 8?', replyTo: cabin.id);
  add(demoTripRoomId, demoMeId, at(2, 8, 26), body: '8 works for me 👍');

  // Family
  final lunch = add(demoFamilyRoomId, grandma, at(2, 18, 5),
      body: "Good morning everyone! ☀️ Who's coming for lunch on Sunday?");
  final salad = add(demoFamilyRoomId, mom, at(2, 18, 7), body: "We'll be there! I'll bring the salad 🥗");
  b.react(salad.id, grandma, '❤️');
  b.react(salad.id, demoMeId, '❤️');
  add(demoFamilyRoomId, demoMeId, at(2, 18, 10), body: 'Count me in too');
  add(demoFamilyRoomId, sam, at(2, 18, 12), body: 'Can we have the chocolate cake again? 🍰', replyTo: lunch.id);
  final sweetheart = add(demoFamilyRoomId, grandma, at(2, 18, 15), body: 'Of course, sweetheart');
  b.react(sweetheart.id, sam, '😍');
  final sunset = add(demoFamilyRoomId, dad, at(1, 12, 30),
      kind: 'image', body: 'Sunset at the lake yesterday', mediaId: asset('lake_sunset'), media: photo);
  b.react(sunset.id, mom, '😮');
  b.react(sunset.id, demoMeId, '👍');
  add(demoFamilyRoomId, mom, at(1, 12, 32), body: 'Beautiful! 😍');
  add(demoFamilyRoomId, demoMeId, at(1, 12, 40), body: "Wish I'd been there!", editedAt: at(1, 12, 40));
  final cake = add(demoFamilyRoomId, sam, ago(180),
      kind: 'image', body: 'Practice run for Sunday 🎂', mediaId: asset('birthday_cake'), media: photo);
  b.react(cake.id, dad, '😂');
  b.react(cake.id, grandma, '❤️');
  add(demoFamilyRoomId, grandma, ago(170), body: 'That looks delicious!');
  add(demoFamilyRoomId, mom, ago(120),
      kind: 'call',
      call: ApiCall(id: 'demo-call-1', status: 'missed', startedAt: ago(120), endedAt: ago(119)));
  add(demoFamilyRoomId, dad, ago(60),
      kind: 'location',
      location: ApiLocationShare(lat: 48.2082, lng: 16.3738, expiresAt: now.add(const Duration(hours: 8))));
  add(demoFamilyRoomId, dad, ago(40), body: 'On my way to pick up Grandma, see you soon');

  // 1:1 with Mom
  add(demoMomRoomId, mom, at(1, 9, 0), body: 'Did you call the plumber?');
  final plumber = add(demoMomRoomId, demoMeId, at(1, 9, 20), body: "Yes, he's coming Thursday morning");
  b.react(plumber.id, mom, '👍');
  add(demoMomRoomId, mom, at(1, 9, 21), body: 'Great, thank you! 😘');
  add(demoMomRoomId, demoMeId, ago(300),
      kind: 'call',
      call: ApiCall(id: 'demo-call-2', status: 'completed', startedAt: ago(300), endedAt: ago(288)));
  add(demoMomRoomId, mom, ago(285), body: 'Lovely to talk to you');
  add(demoMomRoomId, mom, ago(30), body: "Don't forget your jacket, it's getting cold 🧥");
}
