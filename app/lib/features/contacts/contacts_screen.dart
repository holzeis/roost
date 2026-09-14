import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/mock_data.dart';
import '../../data/models.dart';
import '../../widgets/avatar.dart';

class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
          for (final contact in MockData.contacts) _ContactTile(contact: contact),
        ],
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact});

  final Contact contact;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: InitialAvatar(
        initial: contact.initial,
        presenceOnline: contact.presence == PresenceStatus.online,
      ),
      title: Text(contact.displayName),
      subtitle: Text(contact.presence == PresenceStatus.online ? 'Online' : (contact.lastSeenLabel ?? '')),
      onTap: () => context.push('/chat/user-${contact.id}'),
    );
  }
}
