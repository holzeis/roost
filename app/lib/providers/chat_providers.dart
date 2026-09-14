import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/api_models.dart';
import '../data/ws_client.dart';

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

/// One WebSocket connection for the app's lifetime (docs/architecture-overview.md:
/// "signaling and media are separate paths" — this carries chat signaling).
final wsClientProvider = Provider<WsClient>((ref) {
  final client = WsClient()..connect();
  ref.onDispose(client.dispose);
  return client;
});

final wsEventsProvider = StreamProvider<WsEvent>((ref) => ref.watch(wsClientProvider).events);

final meProvider = FutureProvider<ApiUser>((ref) => ref.watch(apiClientProvider).getMe());

final usersProvider = FutureProvider<List<ApiContact>>((ref) => ref.watch(apiClientProvider).listUsers());

/// O(1) id -> contact lookups, e.g. for resolving a 1:1 room's display name
/// or a message sender's name, without re-scanning the list each time.
final usersByIdProvider = Provider<AsyncValue<Map<String, ApiContact>>>((ref) {
  return ref.watch(usersProvider).whenData((users) => {for (final u in users) u.id: u});
});

final roomsProvider = AsyncNotifierProvider<RoomsController, List<ApiRoom>>(RoomsController.new);

class RoomsController extends AsyncNotifier<List<ApiRoom>> {
  @override
  FutureOr<List<ApiRoom>> build() async {
    final sub = ref.listen(wsEventsProvider, (previous, next) {
      // Any inbound message can change room ordering/preview, regardless of
      // which room it's for, so just refresh the list.
      if (next.valueOrNull != null) unawaited(refresh());
    });
    ref.onDispose(sub.close);
    return ref.read(apiClientProvider).listRooms();
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(() => ref.read(apiClientProvider).listRooms());
  }

  Future<ApiRoom> createRoom({String? name, required bool isGroup, required List<String> memberIds}) async {
    final room = await ref.read(apiClientProvider).createRoom(name: name, isGroup: isGroup, memberIds: memberIds);
    await refresh();
    return room;
  }
}

final messagesProvider = AsyncNotifierProvider.family<MessagesController, List<ApiMessage>, String>(
  MessagesController.new,
);

class MessagesController extends FamilyAsyncNotifier<List<ApiMessage>, String> {
  late final String roomId = arg;

  @override
  FutureOr<List<ApiMessage>> build(String arg) async {
    final sub = ref.listen(wsEventsProvider, (previous, next) {
      final event = next.valueOrNull;
      if (event == null) return;
      final message = ref.read(wsClientProvider).messageFrom(event);
      if (message == null || message.roomId != arg) return;
      final current = state.valueOrNull ?? const <ApiMessage>[];
      if (current.any((m) => m.id == message.id)) return;
      state = AsyncData([...current, message]);
    });
    ref.onDispose(sub.close);

    // Server returns newest-first; the chat screen renders oldest-first.
    final history = await ref.read(apiClientProvider).listMessages(arg);
    return history.reversed.toList();
  }

  Future<void> send(String body) async {
    // No local append here: the server broadcasts the new message back over
    // the WebSocket to every room member including the sender, so the
    // listener above is the single source of truth for state updates.
    await ref.read(apiClientProvider).sendTextMessage(roomId, body);
  }
}
