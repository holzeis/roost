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
        padding: const EdgeInsets.only(top: 4, bottom: 88),
        itemCount: roomList.length,
        separatorBuilder: (_, __) => Padding(
          padding: const EdgeInsets.only(left: 84),
          child: Divider(height: 1, color: Theme.of(context).dividerColor),
        ),
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
    final scheme = theme.colorScheme;
    final name = roomDisplayName(room, meId, usersById);
    final timeLabel = formatActivityTime(room.lastMessageAt ?? room.createdAt);

    // No unread badge here: the server doesn't track per-user read state
    // yet (FR1.5/1.6 are deferred — see docs/data-model.md's "not yet
    // modeled" section), and a badge with no real data behind it would just
    // be a lie dressed up as UI polish.
    return InkWell(
      onTap: () => context.push('/chat/${room.id}', extra: room),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            InitialAvatar(
              initial: name.isNotEmpty ? name[0].toUpperCase() : '?',
              seed: name,
              size: 52,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _lastMessagePreview(room),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface.withOpacity(0.55)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeLabel,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface.withOpacity(0.45)),
            ),
          ],
        ),
      ),
    );
  }
}
