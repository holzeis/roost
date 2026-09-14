import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(usersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
              child: Icon(Icons.group_outlined, color: Theme.of(context).colorScheme.primary),
            ),
            title: Text(
              'New group',
              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w500),
            ),
            onTap: () => context.push('/contacts/new-group'),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('On the tailnet', style: TextStyle(fontSize: 11)),
            ),
          ),
          users.when(
            data: (contacts) => contacts.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Nobody else has connected yet.'),
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
    return ListTile(
      leading: InitialAvatar(
        initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
        presenceOnline: contact.online,
      ),
      title: Text(contact.displayName),
      subtitle: Text(contact.online ? 'Online' : 'Offline'),
      onTap: () async {
        final messenger = ScaffoldMessenger.of(context);
        final router = GoRouter.of(context);
        try {
          // Reuses an existing 1:1 room if one already exists server-side
          // would be nicer, but for now this always starts a fresh one —
          // good enough until room de-duplication is added.
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
