import 'models.dart';

/// Placeholder data so every screen is navigable and visually complete
/// before the API client is wired up. Replace with real ApiClient calls as
/// each screen is connected — see lib/data/api_client.dart.
class MockData {
  MockData._();

  static const rooms = [
    RoomSummary(
      id: 'room-family',
      name: 'Family',
      initial: 'F',
      lastMessagePreview: 'On my way, leaving now',
      lastActivityLabel: '6:12 PM',
      unreadCount: 2,
      isGroup: true,
    ),
    RoomSummary(
      id: 'room-mom',
      name: 'Mom',
      initial: 'M',
      lastMessagePreview: "Dinner's at 7, see you all soon",
      lastActivityLabel: '6:04 PM',
    ),
    RoomSummary(
      id: 'room-weekend',
      name: 'Weekend trip',
      initial: 'W',
      lastMessagePreview: 'Sam: booked the cabin',
      lastActivityLabel: 'Yesterday',
      isGroup: true,
    ),
    RoomSummary(
      id: 'room-sam',
      name: 'Sam',
      initial: 'S',
      lastMessagePreview: 'Shared their location',
      lastActivityLabel: 'Mon',
    ),
  ];

  static const contacts = [
    Contact(id: 'user-mom', displayName: 'Mom', initial: 'M', presence: PresenceStatus.online),
    Contact(
      id: 'user-dad',
      displayName: 'Dad',
      initial: 'D',
      presence: PresenceStatus.lastSeen,
      lastSeenLabel: 'Last seen 2h ago',
    ),
    Contact(id: 'user-sam', displayName: 'Sam', initial: 'S', presence: PresenceStatus.online),
    Contact(id: 'user-grandpa', displayName: 'Grandpa', initial: 'G', presence: PresenceStatus.lastSeen, lastSeenLabel: 'Last seen yesterday'),
  ];

  static const familyMessages = [
    ChatMessage(id: 'm1', senderName: 'Mom', kind: MessageKind.text, timeLabel: '5:58 PM', body: "What time's dinner?"),
    ChatMessage(id: 'm2', senderName: 'Dad', kind: MessageKind.text, timeLabel: '6:01 PM', body: '7pm, I already texted Sam'),
    ChatMessage(id: 'm3', senderName: 'Sam', kind: MessageKind.location, timeLabel: '6:10 PM', body: 'Shared their location'),
    ChatMessage(id: 'm4', senderName: 'Me', kind: MessageKind.text, timeLabel: '6:12 PM', body: 'On my way, leaving now', fromMe: true),
  ];
}
