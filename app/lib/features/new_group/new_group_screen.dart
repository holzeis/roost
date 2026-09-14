import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api_models.dart';
import '../../providers/chat_providers.dart';
import '../../widgets/avatar.dart';

class NewGroupScreen extends ConsumerStatefulWidget {
  const NewGroupScreen({super.key});

  @override
  ConsumerState<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends ConsumerState<NewGroupScreen> {
  final _nameController = TextEditingController();
  final _selected = <String>{};
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create(List<ApiContact> contacts) async {
    setState(() => _creating = true);
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final room = await ref.read(roomsProvider.notifier).createRoom(
            name: _nameController.text.trim().isEmpty ? null : _nameController.text.trim(),
            isGroup: true,
            memberIds: _selected.toList(),
          );
      if (!mounted) return;
      router.pop();
      router.push('/chat/${room.id}');
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Could not create group: $error')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(usersProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        title: const Text('New group'),
        actions: [
          users.when(
            data: (contacts) => TextButton(
              onPressed: (_selected.isEmpty || _creating) ? null : () => _create(contacts),
              child: _creating
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Create'),
            ),
            error: (_, __) => const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: users.when(
        error: (error, _) => Center(child: Text('Could not load contacts.\n$error')),
        loading: () => const Center(child: CircularProgressIndicator()),
        data: (contacts) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.onSurface.withOpacity(0.08),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.group_outlined),
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: CircleAvatar(
                          radius: 9,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          child: const Icon(Icons.camera_alt_outlined, size: 10, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(hintText: 'Group name'),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (_selected.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(10),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final id in _selected)
                      Builder(builder: (context) {
                        final contact = contacts.firstWhere((c) => c.id == id);
                        return Chip(
                          avatar: InitialAvatar(
                            initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
                            size: 16,
                          ),
                          label: Text(contact.displayName),
                        );
                      }),
                  ],
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Add more people', style: TextStyle(fontSize: 11)),
              ),
            ),
            if (contacts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Nobody else has connected yet.'),
              ),
            for (final contact in contacts)
              CheckboxListTile(
                value: _selected.contains(contact.id),
                onChanged: (checked) => setState(() {
                  if (checked ?? false) {
                    _selected.add(contact.id);
                  } else {
                    _selected.remove(contact.id);
                  }
                }),
                secondary: InitialAvatar(
                  initial: contact.displayName.isNotEmpty ? contact.displayName[0].toUpperCase() : '?',
                  size: 26,
                ),
                title: Text(contact.displayName),
                controlAffinity: ListTileControlAffinity.leading,
              ),
          ],
        ),
      ),
    );
  }
}
