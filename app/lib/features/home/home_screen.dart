import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../util/time_format.dart';
import '../../widgets/avatar.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rooms = ref.watch(roomsProvider);
    final me = ref.watch(meProvider);
    final usersById = ref.watch(usersByIdProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Roost'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {},
            tooltip: 'Search',
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => context.push('/profile'),
            tooltip: 'Profile',
          ),
        ],
      ),
      body: _buildBody(context, ref, rooms, me, usersById),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts'),
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<List<ApiRoom>> rooms,
    AsyncValue<ApiUser> me,
    AsyncValue<Map<String, ApiContact>> usersById,
  ) {
    if (rooms.hasError) return _ErrorState(error: rooms.error!);
    if (me.hasError) return _ErrorState(error: me.error!);
    if (!rooms.hasValue || !me.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }

    final roomList = rooms.value!;
    if (roomList.isEmpty) return const _EmptyRooms();

    return RefreshIndicator(
      onRefresh: () => ref.read(roomsProvider.notifier).refresh(),
      child: ListView.separated(
        itemCount: roomList.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) => _RoomTile(
          room: roomList[index],
          meId: me.value!.id,
          usersById: usersById.valueOrNull ?? const {},
        ),
      ),
    );
  }
}

class _EmptyRooms extends StatelessWidget {
  const _EmptyRooms();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'No conversations yet. Tap the compose button to message someone on your tailnet.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text('Could not reach the chat server.\n$error', textAlign: TextAlign.center),
      ),
    );
  }
}

String roomDisplayName(ApiRoom room, String meId, Map<String, ApiContact> usersById) {
  if (room.name != null && room.name!.isNotEmpty) return room.name!;
  final otherId = room.members.firstWhere((id) => id != meId, orElse: () => '');
  return usersById[otherId]?.displayName ?? 'Direct message';
}

String _lastMessagePreview(ApiRoom room) {
  switch (room.lastMessageKind) {
    case 'location':
      return 'Shared their location';
    case 'image':
      return 'Photo';
    case 'video':
      return 'Video';
    case 'call':
      return 'Call';
    default:
      return room.lastMessageBody ?? 'No messages yet';
  }
}

class _RoomTile extends StatelessWidget {
  const _RoomTile({required this.room, required this.meId, required this.usersById});

  final ApiRoom room;
  final String meId;
  final Map<String, ApiContact> usersById;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = roomDisplayName(room, meId, usersById);
    return ListTile(
      leading: InitialAvatar(initial: name.isNotEmpty ? name[0].toUpperCase() : '?'),
      title: Text(name, style: theme.textTheme.titleSmall),
      subtitle: Text(
        _lastMessagePreview(room),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        formatActivityTime(room.lastMessageAt ?? room.createdAt),
        style: theme.textTheme.labelSmall,
      ),
      onTap: () => context.push('/chat/${room.id}', extra: room),
    );
  }
}
