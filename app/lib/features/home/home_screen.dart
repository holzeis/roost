import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../demo/demo_mode.dart';
import '../chat/reply_preview.dart' show deletedMessageLabel;
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
            icon: const Icon(TablerIcons.search),
            onPressed: () {},
            tooltip: 'Search',
          ),
          IconButton(
            icon: const Icon(TablerIcons.user),
            onPressed: () => context.push('/profile'),
            tooltip: 'Profile',
          ),
        ],
      ),
      body: _buildBody(context, ref, rooms, me, usersById),
      floatingActionButton: FloatingActionButton(
        onPressed: () => context.push('/contacts'),
        child: const Icon(TablerIcons.edit),
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
    final meId = me.value!.id;

    // Anyone who's opened the app at least once (usersById's own source,
    // usersProvider) belongs in this list too, not just the separate
    // Contacts screen — even before a first message is ever sent. Only
    // filtered by 1:1 room, not group membership: a shared group doesn't
    // mean there's already a direct conversation with that person.
    final contactedIds = {
      for (final r in roomList)
        if (!r.isGroup) r.members.firstWhere((id) => id != meId, orElse: () => ''),
    };
    final roomlessContacts = (usersById.valueOrNull ?? const {})
        .values
        .where((c) => !contactedIds.contains(c.id))
        .toList();

    if (roomList.isEmpty && roomlessContacts.isEmpty) {
      return const _EmptyRooms();
    }

    final divider = Padding(
      padding: const EdgeInsets.only(left: 84, right: 16),
      child: Divider(height: 1, thickness: 0.5, color: Theme.of(context).dividerColor),
    );

    final children = <Widget>[];
    for (var i = 0; i < roomList.length; i++) {
      if (i > 0) children.add(divider);
      children.add(_RoomTile(room: roomList[i], meId: meId, usersById: usersById.valueOrNull ?? const {}));
    }
    if (roomlessContacts.isNotEmpty) {
      if (roomList.isNotEmpty) children.add(divider);
      children.add(const _SectionHeader('START A CONVERSATION'));
      for (var i = 0; i < roomlessContacts.length; i++) {
        if (i > 0) children.add(divider);
        children.add(_ContactTile(contact: roomlessContacts[i]));
      }
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(roomsProvider.notifier).refresh(),
      child: ListView(padding: const EdgeInsets.only(top: 4, bottom: 88), children: children),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

/// A contact with no existing 1:1 room yet — same row shape as _RoomTile,
/// so the merged list reads as one continuous thing rather than two
/// visually distinct list types, but with online/offline in place of a
/// last-message preview (there isn't one) and no timestamp (nothing's
/// happened yet). Tapping it does exactly what ContactsScreen's own contact
/// tile does: the server reuses/creates the 1:1 room (FR1.1), same
/// idempotent createRoom call, just reached from this list too now.
class _ContactTile extends ConsumerWidget {
  const _ContactTile({required this.contact});

  final ApiContact contact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final router = GoRouter.of(context);
        try {
          final room = await ref
              .read(roomsProvider.notifier)
              .createRoom(isGroup: false, memberIds: [contact.id]);
          router.push('/chat/${room.id}');
        } catch (error) {
          messenger.showSnackBar(SnackBar(content: Text('Could not start chat: $error')));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            InitialAvatar(
              initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
              seed: contact.displayName,
              size: 52,
              presenceOnline: contact.online,
              avatarMediaId: contact.avatarMediaId,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    contact.online ? 'Online' : 'Offline',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: contact.online ? scheme.primary : scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
          'Nobody else has opened Roost yet. Once someone else on your tailnet does, they\'ll show up here.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _ErrorState extends ConsumerWidget {
  const _ErrorState({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // App Store review: the reviewer can't reach a family's private server,
    // so builds that offer the demo (see lib/demo/demo_mode.dart) point
    // them to it right here.
    final offerDemo = ref.watch(demoAvailableProvider) && !ref.watch(demoModeProvider).enabled;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not reach the chat server.',
                textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            // The technical cause, for troubleshooting — kept small so it
            // doesn't dominate the screen.
            Text('$error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55))),
            if (offerDemo) ...[
              const SizedBox(height: 24),
              const Text(
                'Not connected to a family server? Try Roost with sample chats — everything stays on this phone.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(TablerIcons.flask),
                label: const Text('Explore the demo'),
                onPressed: () => ref.read(demoModeProvider).setEnabled(true),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String roomDisplayName(ApiRoom room, String meId, Map<String, ApiContact> usersById) {
  if (room.name != null && room.name!.isNotEmpty) return room.name!;
  final otherId = room.members.firstWhere((id) => id != meId, orElse: () => '');
  return usersById[otherId]?.displayName ?? 'Direct message';
}

/// The one person behind a 1:1 room's own avatar — null for a named group,
/// which has no single user's picture to show instead of its own name's
/// initial.
String? roomAvatarMediaId(ApiRoom room, String meId, Map<String, ApiContact> usersById) {
  if (room.name != null && room.name!.isNotEmpty) return null;
  final otherId = room.members.firstWhere((id) => id != meId, orElse: () => '');
  return usersById[otherId]?.avatarMediaId;
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
    case 'deleted':
      return deletedMessageLabel;
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
              avatarMediaId: roomAvatarMediaId(room, meId, usersById),
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
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurface.withValues(alpha: 0.55)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              timeLabel,
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface.withValues(alpha: 0.45)),
            ),
          ],
        ),
      ),
    );
  }
}
