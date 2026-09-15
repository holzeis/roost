import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:tabler_icons_plus/tabler_icons_plus.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';
import '../../widgets/back_button.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(leading: const TablerBackButton(), title: const Text('Contacts')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            leading: CircleAvatar(
              radius: 22,
              backgroundColor: scheme.primary.withOpacity(0.12),
              child: Icon(TablerIcons.users, color: scheme.primary),
            ),
            title: Text(
              'New group',
              style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600, fontSize: 15),
            ),
            onTap: () => context.push('/contacts/new-group'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
            child: Text(
              'ON THE TAILNET',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: scheme.onSurface.withOpacity(0.45),
              ),
            ),
          ),
          users.when(
            data: (contacts) => contacts.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Nobody else has connected yet.',
                      style: TextStyle(color: scheme.onSurface.withOpacity(0.55)),
                    ),
                  )
                : Column(children: [for (final c in contacts) _ContactTile(contact: c)]),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Could not load contacts.\n$error'),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContactTile extends ConsumerWidget {
  const _ContactTile({required this.contact});

  final ApiContact contact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: InitialAvatar(
        initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
        seed: contact.displayName,
        size: 48,
        presenceOnline: contact.online,
      ),
      title: Text(contact.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(
        contact.online ? 'Online' : 'Offline',
        style: TextStyle(
          color: contact.online ? scheme.primary : scheme.onSurface.withOpacity(0.45),
          fontSize: 13,
        ),
      ),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final router = GoRouter.of(context);
        try {
          // The server reuses an existing 1:1 room between the same two
          // users instead of creating a duplicate every time (FR1.1).
          final room = await ref
              .read(roomsProvider.notifier)
              .createRoom(isGroup: false, memberIds: [contact.id]);
          router.push('/chat/${room.id}');
        } catch (error) {
          messenger.showSnackBar(SnackBar(content: Text('Could not start chat: $error')));
        }
      },
    );
  }
}
